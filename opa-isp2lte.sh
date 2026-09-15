#!/usr/bin/env bash
#
# OPA-ISP2LTE — failover otomatis ISP <-> Modem LTE (SIM) untuk homelab.
# "Opa jagain internet lo, biar nggak mati."
#
#   PRIMARY = enx00e04c8f6956 (ISP)       gw 192.168.100.1
#   BACKUP  = enx0202025b3531 (modem LTE) gw 192.168.200.1
#
# Cara kerja:
#   - Ping target eksternal tiap INTERVAL detik.
#   - FAIL_THRESHOLD gagal beruntun  -> switch ke jalur lain.
#   - Failback: PRIMARY stabil FAILBACK_HOLD detik baru balik.
#   - Saat switch: ganti route + flush conntrack + restart tailscale.
#
# Konfigurasi ada di atas (edit & restart service utk menerapkan).

set -u

# ===== LOGO (ANSI Shadow, plain text untuk log) =====
LOGO=' ██████╗ ██████╗  █████╗       ██╗███████╗██████╗ ██████╗ ██╗  ████████╗███████╗
██╔═══██╗██╔══██╗██╔══██╗      ██║██╔════╝██╔══██╗╚════██╗██║  ╚══██╔══╝██╔════╝
██║   ██║██████╔╝███████║█████╗██║███████╗██████╔╝ █████╔╝██║     ██║   █████╗
██║   ██║██╔═══╝ ██╔══██║╚════╝██║╚════██║██╔═══╝ ██╔═══╝ ██║     ██║   ██╔══╝
╚██████╔╝██║     ██║  ██║      ██║███████║██║     ███████╗███████╗██║   ███████╗
 ╚═════╝ ╚═╝     ╚═╝  ╚═╝      ╚═╝╚══════╝╚═╝     ╚══════╝╚══════╝╚═╝   ╚══════╝'

# ===== KONFIGURASI =====
PRIMARY="enx00e04c8f6956"
BACKUP="enx0202025b3531"
PRIMARY_GW="192.168.100.1"
BACKUP_GW="192.168.200.1"

PING_TARGETS=("8.8.8.8" "1.1.1.1")
INTERVAL=10          # detik antar cek
FAIL_THRESHOLD=3     # gagal beruntun -> switch
FAILBACK_HOLD=60     # PRIMARY stabil segini detik baru failback
# ======================

LOGFILE="/var/log/opa-isp2lte.log"
STATE_DIR="/var/lib/opa-isp2lte"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

current_iface() { ip route show default 2>/dev/null | awk '{print $5}' | head -1; }
link_up() { [ -e "/sys/class/net/$1/carrier" ] && [ "$(cat /sys/class/net/$1/carrier 2>/dev/null)" = "1" ]; }

ping_ok() {
    local iface="$1" t
    for t in "${PING_TARGETS[@]}"; do
        ping -c 1 -W 2 -I "$iface" "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

switch_to() {
    local iface="$1" gw="$2"
    while ip route show default >/dev/null 2>&1; do ip route del default 2>/dev/null || break; done
    ip route add default via "$gw" dev "$iface" 2>/dev/null || { log "ERROR: add route via $gw gagal"; return 1; }
    log "route -> via $gw dev $iface"
    command -v conntrack >/dev/null 2>&1 && conntrack -F >/dev/null 2>&1 && log "conntrack flushed"
    command -v tailscale  >/dev/null 2>&1 && systemctl restart tailscaled >/dev/null 2>&1 && log "tailscaled restarted"
    return 0
}

main() {
    local fail_count=0 stable_sec=0 cur=""
    mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
    log "$LOGO"
    log "=== OPA-ISP2LTE started (${INTERVAL}s, fail ${FAIL_THRESHOLD}x, hold ${FAILBACK_HOLD}s) ==="

    if [ -z "$(current_iface)" ]; then
        if link_up "$PRIMARY"; then switch_to "$PRIMARY" "$PRIMARY_GW"
        elif link_up "$BACKUP"; then switch_to "$BACKUP" "$BACKUP_GW"; fi
    fi

    while true; do
        cur="$(current_iface)"; [ -z "$cur" ] && cur="$PRIMARY"
        local primary_up=0 backup_up=0
        link_up "$PRIMARY" && primary_up=1
        link_up "$BACKUP"  && backup_up=1

        if [ "$cur" = "$PRIMARY" ]; then
            if ping_ok "$PRIMARY"; then fail_count=0
            else fail_count=$((fail_count+1)); log "PRIMARY ping fail ($fail_count/$FAIL_THRESHOLD)"; fi

            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                [ "$backup_up" = "1" ] && { log ">>> SWITCH ke BACKUP (LTE)"; switch_to "$BACKUP" "$BACKUP_GW" && log "OK: aktif via LTE"; } \
                                  || log "PRIMARY down & BACKUP link down"
                fail_count=0
            fi
            stable_sec=0
        else
            if ping_ok "$BACKUP"; then fail_count=0
            else fail_count=$((fail_count+1)); log "BACKUP ping fail ($fail_count/$FAIL_THRESHOLD)"; fi

            if [ "$primary_up" = "1" ] && ping_ok "$PRIMARY"; then
                stable_sec=$((stable_sec+INTERVAL)); log "PRIMARY stabil ${stable_sec}/${FAILBACK_HOLD}s"
                if [ "$stable_sec" -ge "$FAILBACK_HOLD" ]; then
                    log ">>> FAILBACK ke PRIMARY (ISP)"; switch_to "$PRIMARY" "$PRIMARY_GW" && log "OK: aktif via ISP"; stable_sec=0
                fi
            else stable_sec=0; fi

            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && [ "$primary_up" = "1" ]; then
                log ">>> BACKUP down, paksa PRIMARY"; switch_to "$PRIMARY" "$PRIMARY_GW" && log "OK: PRIMARY"; fail_count=0
            fi
        fi
        sleep "$INTERVAL"
    done
}

main
