#!/usr/bin/env bash
#
# OPA-ISP2LTE — failover otomatis ISP <-> Modem LTE (SIM) untuk homelab.
# "Opa jagain internet lo, biar nggak mati."
#
#   PRIMARY = enx00e04c8f6956 (ISP)       gw 192.168.100.1
#   BACKUP  = enx0202025b3531 (modem LTE) gw 192.168.200.1
#
# Cara kerja:
#   - Probe jalur aktif tiap INTERVAL detik (TCP dulu, ICMP sebagai fallback).
#   - FAIL_THRESHOLD gagal beruntun -> switch ke jalur lain.
#   - Failback: PRIMARY stabil FAILBACK_HOLD detik baru balik.
#   - Route dikelola NON-DESTRUKTIF: OPA cuma punya satu route ber-metric
#     ROUTE_METRIC. Route milik NetworkManager TIDAK PERNAH dihapus, jadi
#     kalau opa mati box tetap punya default route.
#
# v2 — perbaikan dibanding v1:
#   * route non-destruktif (v1: `ip route del default` semua -> blackout total
#     kalau `ip route add` gagal)
#   * gate BACKUP: LTE cuma dipakai kalau benar-benar ada internet (v1: cuma
#     cek carrier -> switch ke LTE tanpa pulsa = outage)
#   * probe TCP, bukan cuma ICMP (v1: ICMP di-block = false failover;
#     ICMP hidup tapi data mati = gagal failover)
#   * parser config strip inline comment (v1: `INTERVAL=10 # detik` bikin
#     sleep gagal -> loop spin)
#   * flock single instance (v1: bisa jalan dobel)
#   * restart tailscaled opsional + di-throttle (v1: tiap switch)
#   * state persist ke STATE_DIR (v1: restart kehilangan mode)

set -uo pipefail

VERSION="2.0.0"

# ===== LOGO (ANSI Shadow, plain text untuk log) =====
LOGO=' ██████╗ ██████╗  █████╗       ██╗███████╗██████╗ ██████╗ ██╗  ████████╗███████╗
██╔═══██╗██╔══██╗██╔══██╗      ██║██╔════╝██╔══██╗╚════██╗██║  ╚══██╔══╝██╔════╝
██║   ██║██████╔╝███████║█████╗██║███████╗██████╔╝ █████╔╝██║     ██║   █████╗
██║   ██║██╔═══╝ ██╔══██║╚════╝██║╚════██║██╔═══╝ ██╔═══╝ ██║     ██║   ██╔══╝
╚██████╔╝██║     ██║  ██║      ██║███████║██║     ███████╗███████╗██║   ███████╗
 ╚═════╝ ╚═╝     ╚═╝  ╚═╝      ╚═╝╚══════╝╚═╝     ╚══════╝╚══════╝╚═╝   ╚══════╝'

# ===== KONFIGURASI (dibaca dari /etc/opa-isp2lte.conf) =====
CONF="${OPA_CONF:-/etc/opa-isp2lte.conf}"

# default (fallback kalau config file tidak ada)
PRIMARY="enx00e04c8f6956"
BACKUP="enx0202025b3531"
PRIMARY_GW="192.168.100.1"
BACKUP_GW="192.168.200.1"
PING_TARGETS=(8.8.8.8 1.1.1.1)
INTERVAL=10
FAIL_THRESHOLD=3
FAILBACK_HOLD=60
RECOVERY_COOLDOWN=60
SWITCH_COOLDOWN=20
LOGFILE="/var/log/opa-isp2lte.log"
STATE_DIR="/var/lib/opa-isp2lte"

# v2 knobs
PROBE_MODE="auto"                                     # auto | tcp | icmp
TCP_PROBE_URL="http://connectivitycheck.gstatic.com/generate_204"
PROBE_TIMEOUT=4
ROUTE_METRIC=50                                       # metric milik opa (NM pakai >=100)
MANAGE_ROUTES=1                                       # 0 = monitor-only, jangan sentuh route
VERIFY_BACKUP=1                                       # 1 = wajib probe BACKUP sebelum switch
RESTART_TAILSCALE=0                                   # 1 = restart tailscaled tiap switch
TAILSCALE_RESTART_COOLDOWN=300

# --- config loader: strip inline comment, trim spasi, tolak value kosong ---
_cfg_clean() {
    # buang komentar inline (# ...) yang tidak di-escape, lalu trim
    local v="$1"
    v="${v%%[[:space:]]#*}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

if [ -f "$CONF" ]; then
    while IFS= read -r line; do
        # skip baris kosong & komentar penuh
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        rawval="${line#*=}"
        key="$(_cfg_clean "$key")"
        val="$(_cfg_clean "$rawval")"
        [ -z "$key" ] && continue
        case "$key" in
            PRIMARY)                      PRIMARY="$val" ;;
            BACKUP)                       BACKUP="$val" ;;
            PRIMARY_GW)                   PRIMARY_GW="$val" ;;
            BACKUP_GW)                    BACKUP_GW="$val" ;;
            PING_TARGETS)                 read -r -a PING_TARGETS <<< "$val" ;;
            INTERVAL)                     INTERVAL="$val" ;;
            FAIL_THRESHOLD)               FAIL_THRESHOLD="$val" ;;
            FAILBACK_HOLD)                FAILBACK_HOLD="$val" ;;
            RECOVERY_COOLDOWN)            RECOVERY_COOLDOWN="$val" ;;
            SWITCH_COOLDOWN)              SWITCH_COOLDOWN="$val" ;;
            LOGFILE)                      LOGFILE="$val" ;;
            PROBE_MODE)                   PROBE_MODE="$val" ;;
            TCP_PROBE_URL)                TCP_PROBE_URL="$val" ;;
            PROBE_TIMEOUT)                PROBE_TIMEOUT="$val" ;;
            ROUTE_METRIC)                 ROUTE_METRIC="$val" ;;
            MANAGE_ROUTES)                MANAGE_ROUTES="$val" ;;
            VERIFY_BACKUP)                VERIFY_BACKUP="$val" ;;
            RESTART_TAILSCALE)            RESTART_TAILSCALE="$val" ;;
            TAILSCALE_RESTART_COOLDOWN)   TAILSCALE_RESTART_COOLDOWN="$val" ;;
        esac
    done < "$CONF"
fi

# --- sanitasi angka: kalau config korup, jangan biarkan loop spin ---
_sane_int() {
    local name="$1" val="$2" def="$3" min="$4"
    case "$val" in
        ''|*[!0-9]*) printf '%s' "$def" ; return 0 ;;
    esac
    [ "$val" -lt "$min" ] && { printf '%s' "$def"; return 0; }
    printf '%s' "$val"
}
INTERVAL="$(_sane_int INTERVAL "$INTERVAL" 10 2)"
FAIL_THRESHOLD="$(_sane_int FAIL_THRESHOLD "$FAIL_THRESHOLD" 3 1)"
FAILBACK_HOLD="$(_sane_int FAILBACK_HOLD "$FAILBACK_HOLD" 60 0)"
RECOVERY_COOLDOWN="$(_sane_int RECOVERY_COOLDOWN "$RECOVERY_COOLDOWN" 60 0)"
SWITCH_COOLDOWN="$(_sane_int SWITCH_COOLDOWN "$SWITCH_COOLDOWN" 20 0)"
PROBE_TIMEOUT="$(_sane_int PROBE_TIMEOUT "$PROBE_TIMEOUT" 4 1)"
ROUTE_METRIC="$(_sane_int ROUTE_METRIC "$ROUTE_METRIC" 50 1)"
TAILSCALE_RESTART_COOLDOWN="$(_sane_int TAILSCALE_RESTART_COOLDOWN "$TAILSCALE_RESTART_COOLDOWN" 300 0)"

LAST_PRIMARY_RECOVERY=0
LAST_BACKUP_RECOVERY=0
LAST_SWIT=0
LAST_TS_RESTART=0

# --- logging: file + journal (kalau jalan di bawah systemd) ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$msg" >> "$LOGFILE" 2>/dev/null || true
    [ -t 1 ] || printf '%s\n' "$msg" >&2
}

# --- helper ---
have() { command -v "$1" >/dev/null 2>&1; }
link_up() { [ -e "/sys/class/net/$1/carrier" ] && [ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null)" = "1" ]; }
ip_ready() { ip -o -4 addr show dev "$1" scope global 2>/dev/null | grep -q .; }

# route milik opa = satu-satunya default route dengan metric ROUTE_METRIC
opa_route_iface() {
    ip route show default metric "$ROUTE_METRIC" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
# jalur efektif = default route dengan metric terkecil (urutan `ip route` sudah tersortir)
current_iface() {
    ip route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
# metric terkecil yang aktif
active_metric() {
    ip route show default 2>/dev/null | sed -n 's/.*metric \([0-9]*\).*/\1/p' | sort -n | head -1
}

probe_icmp() {
    local iface="$1" t
    for t in "${PING_TARGETS[@]}"; do
        [ -z "$t" ] && continue
        ping -c 1 -W "$PROBE_TIMEOUT" -I "$iface" "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

probe_tcp() {
    local iface="$1"
    have curl || return 2          # 2 = tidak tersedia
    local code
    code=$(curl --interface "$iface" -s -o /dev/null -m "$PROBE_TIMEOUT" \
                -w '%{http_code}' "$TCP_PROBE_URL" 2>/dev/null)
    # 204 = internet sehat; 2xx/3xx lain juga dianggap hidup
    case "$code" in
        2??|3??) return 0 ;;
        *)       return 1 ;;
    esac
}

# probe_ok: 0 = jalur punya internet nyata
probe_ok() {
    local iface="$1"
    case "$PROBE_MODE" in
        icmp) probe_icmp "$iface" ;;
        tcp)  probe_tcp  "$iface"; [ $? -eq 2 ] && probe_icmp "$iface" ;;
        *)
            # auto: TCP authoritative, ICMP fallback kalau curl tidak ada
            probe_tcp "$iface"
            case $? in
                0) return 0 ;;
                2) probe_icmp "$iface" ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

# Pasang route opa secara ATOMIK. `ip route replace` = tidak pernah ada
# jendela waktu di mana box kehilangan default route.
set_route() {
    local iface="$1" gw="$2"
    [ "$MANAGE_ROUTES" = "1" ] || { log "MANAGE_ROUTES=0, route tidak disentuh"; return 0; }
    if ip route replace default via "$gw" dev "$iface" metric "$ROUTE_METRIC" 2>/dev/null; then
        log "route: default via $gw dev $iface metric $ROUTE_METRIC"
        return 0
    fi
    log "ERROR: gagal pasang route via $gw dev $iface"
    return 1
}

flush_conntrack() {
    if have conntrack; then
        conntrack -F >/dev/null 2>&1 && log "conntrack flushed" || log "WARN: conntrack flush gagal"
    else
        log "WARN: binary 'conntrack' tidak ada — koneksi lama bisa nyangkut di jalur mati"
    fi
}

maybe_restart_tailscale() {
    [ "$RESTART_TAILSCALE" = "1" ] || return 0
    have tailscale || return 0
    local now; now=$(date +%s)
    if [ $((now - LAST_TS_RESTART)) -lt "$TAILSCALE_RESTART_COOLDOWN" ]; then
        log "tailscaled restart di-skip (cooldown ${TAILSCALE_RESTART_COOLDOWN}s)"
        return 0
    fi
    LAST_TS_RESTART="$now"
    systemctl restart tailscaled >/dev/null 2>&1 && log "tailscaled restarted" || log "WARN: restart tailscaled gagal"
}

# Recover interface saat carrier ada tapi NetworkManager kehilangan IPv4.
recover_interface() {
    local role="$1" iface="$2" now last
    now=$(date +%s)
    if [ "$role" = "PRIMARY" ]; then last="$LAST_PRIMARY_RECOVERY"; else last="$LAST_BACKUP_RECOVERY"; fi
    [ $((now - last)) -lt "$RECOVERY_COOLDOWN" ] && return 1
    if [ "$role" = "PRIMARY" ]; then LAST_PRIMARY_RECOVERY="$now"; else LAST_BACKUP_RECOVERY="$now"; fi
    log "$role carrier up tapi IPv4 hilang; minta NetworkManager reconnect $iface"
    if have nmcli && nmcli device connect "$iface" >/dev/null 2>&1; then
        log "$role NetworkManager reconnect diminta"
        return 0
    fi
    log "WARN: $role NetworkManager reconnect gagal"
    return 1
}

save_state() { printf '%s\n' "$1" > "$STATE_DIR/mode" 2>/dev/null || true; }
load_state() { cat "$STATE_DIR/mode" 2>/dev/null || true; }

switch_to() {
    local iface="$1" gw="$2" role="$3" now
    now=$(date +%s)
    # anti-thrash: jangan bolak-balik lebih cepat dari SWITCH_COOLDOWN
    if [ $((now - LAST_SWITCH)) -lt "$SWITCH_COOLDOWN" ]; then
        log "switch ke $role di-skip (cooldown ${SWITCH_COOLDOWN}s)"
        return 1
    fi
    LAST_SWITCH="$now"

    set_route "$iface" "$gw" || return 1
    save_state "$role"
    flush_conntrack
    maybe_restart_tailscale
    return 0
}

# Gate: boleh switch ke BACKUP hanya kalau BACKUP benar-benar ada internet.
backup_usable() {
    link_up "$BACKUP" || return 1
    ip_ready "$BACKUP" || return 1
    [ "$VERIFY_BACKUP" = "1" ] || return 0
    if probe_ok "$BACKUP"; then
        return 0
    fi
    log "GATE: BACKUP ($BACKUP) tidak lolos probe — TIDAK switch (hindari outage LTE tanpa data)"
    return 1
}

main() {
    local fail_count=0 stable_sec=0 cur="" role=""

    mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR" 2>/dev/null || true

    # single instance
    if have flock; then
        exec 9>"$STATE_DIR/lock"
        if ! flock -n 9; then
            log "instance lain sudah jalan, keluar"
            exit 0
        fi
    fi

    log "$LOGO"
    log "=== OPA-ISP2LTE v$VERSION started (${INTERVAL}s, fail ${FAIL_THRESHOLD}x, hold ${FAILBACK_HOLD}s, probe=$PROBE_MODE, metric=$ROUTE_METRIC) ==="

    role="$(load_state)"
    [ -z "$role" ] && role="PRIMARY"

    # kalau tidak ada default route sama sekali, pasang sendiri (atomik)
    if [ -z "$(current_iface)" ]; then
        if link_up "$PRIMARY" && ip_ready "$PRIMARY"; then
            set_route "$PRIMARY" "$PRIMARY_GW"; role="PRIMARY"
        elif backup_usable; then
            set_route "$BACKUP" "$BACKUP_GW"; role="BACKUP"
        else
            log "WARN: tidak ada default route & tidak ada jalur siap"
        fi
    fi

    while true; do
        local primary_up=0 backup_up=0
        link_up "$PRIMARY" && primary_up=1
        link_up "$BACKUP"  && backup_up=1

        # link UP tapi NM buang IPv4 -> minta recover
        if [ "$primary_up" = "1" ] && ! ip_ready "$PRIMARY"; then
            recover_interface "PRIMARY" "$PRIMARY" || true
        fi
        if [ "$backup_up" = "1" ] && ! ip_ready "$BACKUP"; then
            recover_interface "BACKUP" "$BACKUP" || true
        fi

        # jalur efektif menurut kernel, bukan asumsi
        cur="$(current_iface)"
        [ -z "$cur" ] && cur="$PRIMARY"

        if [ "$cur" = "$PRIMARY" ]; then
            if probe_ok "$PRIMARY"; then
                fail_count=0
                [ "$role" != "PRIMARY" ] && { role="PRIMARY"; save_state "PRIMARY"; }
            else
                fail_count=$((fail_count+1))
                log "PRIMARY probe fail ($fail_count/$FAIL_THRESHOLD)"
            fi

            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                if backup_usable; then
                    log ">>> SWITCH ke BACKUP (LTE)"
                    if switch_to "$BACKUP" "$BACKUP_GW" "BACKUP"; then
                        log "OK: aktif via LTE"
                        role="BACKUP"
                    else
                        log "switch ditolak/di-skip, tetap di PRIMARY"
                    fi
                else
                    log "PRIMARY down & BACKUP tidak layak — tetap di PRIMARY (jangan blackout)"
                fi
                fail_count=0
            fi
            stable_sec=0
        else
            # sedang di BACKUP
            if probe_ok "$BACKUP"; then fail_count=0
            else
                fail_count=$((fail_count+1))
                log "BACKUP probe fail ($fail_count/$FAIL_THRESHOLD)"
            fi

            if [ "$primary_up" = "1" ] && ip_ready "$PRIMARY" && probe_ok "$PRIMARY"; then
                stable_sec=$((stable_sec+INTERVAL))
                log "PRIMARY stabil ${stable_sec}/${FAILBACK_HOLD}s"
                if [ "$stable_sec" -ge "$FAILBACK_HOLD" ]; then
                    log ">>> FAILBACK ke PRIMARY (ISP)"
                    if switch_to "$PRIMARY" "$PRIMARY_GW" "PRIMARY"; then
                        log "OK: aktif via ISP"
                        role="PRIMARY"
                    fi
                    stable_sec=0
                fi
            else
                stable_sec=0
            fi

            # BACKUP mati tapi PRIMARY kelihatan hidup -> paksa balik
            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && [ "$primary_up" = "1" ] \
               && ip_ready "$PRIMARY" && probe_ok "$PRIMARY"; then
                log ">>> BACKUP down, paksa PRIMARY"
                if switch_to "$PRIMARY" "$PRIMARY_GW" "PRIMARY"; then
                    log "OK: PRIMARY"
                    role="PRIMARY"
                fi
                fail_count=0
            fi
        fi

        sleep "$INTERVAL"
    done
}

self_test() {
    echo "OPA-ISP2LTE v$VERSION — self test (read-only, tidak mengubah apa pun)"
    echo "config        : $CONF"
    echo
    echo "== nilai efektif =="
    printf '%-28s %s\n' PRIMARY "$PRIMARY"
    printf '%-28s %s\n' BACKUP "$BACKUP"
    printf '%-28s %s\n' PRIMARY_GW "$PRIMARY_GW"
    printf '%-28s %s\n' BACKUP_GW "$BACKUP_GW"
    printf '%-28s %s\n' PING_TARGETS "${PING_TARGETS[*]}"
    printf '%-28s %s\n' INTERVAL "$INTERVAL"
    printf '%-28s %s\n' FAIL_THRESHOLD "$FAIL_THRESHOLD"
    printf '%-28s %s\n' FAILBACK_HOLD "$FAILBACK_HOLD"
    printf '%-28s %s\n' SWITCH_COOLDOWN "$SWITCH_COOLDOWN"
    printf '%-28s %s\n' PROBE_MODE "$PROBE_MODE"
    printf '%-28s %s\n' TCP_PROBE_URL "$TCP_PROBE_URL"
    printf '%-28s %s\n' ROUTE_METRIC "$ROUTE_METRIC"
    printf '%-28s %s\n' MANAGE_ROUTES "$MANAGE_ROUTES"
    printf '%-28s %s\n' VERIFY_BACKUP "$VERIFY_BACKUP"
    printf '%-28s %s\n' RESTART_TAILSCALE "$RESTART_TAILSCALE"
    echo
    echo "== dependency =="
    for b in ip ping curl nmcli conntrack flock tailscale; do
        printf '%-12s ' "$b"
        have "$b" && echo "ok" || echo "MISSING"
    done
    echo
    echo "== interface =="
    for i in "$PRIMARY" "$BACKUP"; do
        printf '%-20s carrier=%s ipv4=%s\n' "$i" \
            "$(cat "/sys/class/net/$i/carrier" 2>/dev/null || echo '?')" \
            "$(ip_ready "$i" && echo yes || echo no)"
    done
    echo
    echo "== route =="
    echo "-- semua default route --"
    ip route show default 2>/dev/null || echo "(tidak ada)"
    echo "-- route milik opa (metric $ROUTE_METRIC) --"
    ip route show default metric "$ROUTE_METRIC" 2>/dev/null || echo "(tidak ada)"
    echo "-- jalur efektif --"
    echo "$(current_iface)"
    echo
    echo "== probe =="
    for i in "$PRIMARY" "$BACKUP"; do
        printf '%-20s icmp=%s tcp=%s\n' "$i" \
            "$(probe_icmp "$i" && echo pass || echo fail)" \
            "$(probe_tcp "$i"; case $? in 0) echo pass;; 2) echo n/a;; *) echo fail;; esac)"
    done
    echo
    echo "== gate =="
    backup_usable && echo "BACKUP layak dipakai untuk failover" || echo "BACKUP TIDAK layak — opa tidak akan switch ke LTE"
    exit 0
}

# --- CLI ---
case "${1:-}" in
    --check|--self-test|check) self_test ;;
    --version|-V) echo "opa-isp2lte v$VERSION"; exit 0 ;;
esac

main "$@"
