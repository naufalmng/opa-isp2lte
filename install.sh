#!/usr/bin/env bash
#
# OPA-ISP2LTE — installer satu perintah.
#   curl -fsSL <URL>/install.sh | sudo bash
#
# "Opa jagain internet lo, biar nggak mati."

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root (pakai sudo)."; exit 1; }

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

echo -e "${BOLD}==============================================${NC}"
echo -e "${BOLD}  OPA-ISP2LTE — failover ISP <-> Modem LTE${NC}"
echo -e "${BOLD}  Opa jagain internet lo, biar nggak mati.${NC}"
echo -e "${BOLD}==============================================${NC}"
echo

# ===== 1. Deteksi interface =====
info "Mendeteksi interface jaringan..."
mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tailscale|tun|virbr)' | sort -u)

if [ "${#IFACES[@]}" -lt 2 ]; then
    err "Butuh minimal 2 interface (ISP + modem). Terdeteksi: ${IFACES[*]:-tidak ada}"
    exit 1
fi

echo "Interface yang terdeteksi:"
for i in "${!IFACES[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${IFACES[$i]}"
done
echo

# ===== 2. Pilih interface =====
pick_iface() {
    local label="$1"
    local sel
    while true; do
        read -rp "$label (1-${#IFACES[@]}): " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#IFACES[@]}" ]; then
            echo "${IFACES[$((sel-1))]}"
            return
        fi
        warn "Pilihan tidak valid."
    done
}

info "Pilih interface untuk masing-masing jalur:"
PRIMARY=$(pick_iface "  Interface ISP (utama)")
BACKUP=$(pick_iface "  Interface modem LTE (cadangan)")

# ===== 3. Deteksi IP & gateway =====
detect_gw() {
    local iface="$1"
    # ambil subnet dari IP interface, asumsikan gateway = .1
    local ip
    ip=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$ip" ]; then
        warn "Interface $iface belum punya IP. Gateway harus diisi manual."
        return 1
    fi
    local base
    base=$(echo "$ip" | cut -d/ -f1)
    echo "$(echo "$base" | cut -d. -f1-3).1"
}

PRIMARY_GW=$(detect_gw "$PRIMARY" || true)
BACKUP_GW=$(detect_gw "$BACKUP" || true)

echo
info "Konfigurasi yang akan dipakai:"
echo -e "  PRIMARY : ${BOLD}$PRIMARY${NC}  gateway ${BOLD}${PRIMARY_GW:-?}${NC}"
echo -e "  BACKUP  : ${BOLD}$BACKUP${NC}  gateway ${BACKUP_GW:-?}${NC}"
echo

read -rp "  Gateway ISP [$PRIMARY_GW]: " ans_primary
[ -n "$ans_primary" ] && PRIMARY_GW="$ans_primary"
read -rp "  Gateway modem [$BACKUP_GW]: " ans_backup
[ -n "$ans_backup" ] && BACKUP_GW="$ans_backup"

if [ -z "$PRIMARY_GW" ] || [ -z "$BACKUP_GW" ]; then
    err "Gateway tidak boleh kosong."
    exit 1
fi

# ===== 4. Parameter deteksi (opsional, default dipakai) =====
INTERVAL=10; FAIL_THRESHOLD=3; FAILBACK_HOLD=60

# ===== 5. Instal dependensi =====
info "Menginstal dependensi (conntrack)..."
if ! command -v conntrack >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y conntrack >/dev/null 2>&1 && ok "conntrack terpasang" || warn "conntrack gagal dipasang (opsional)"
else
    ok "conntrack sudah ada"
fi

# ===== 6. Tulis script =====
info "Menulis script ke /usr/local/sbin/opa-isp2lte.sh..."
cat > /usr/local/sbin/opa-isp2lte.sh <<EOF
#!/usr/bin/env bash
# OPA-ISP2LTE — failover ISP <-> Modem LTE
set -u
PRIMARY="$PRIMARY"
BACKUP="$BACKUP"
PRIMARY_GW="$PRIMARY_GW"
BACKUP_GW="$BACKUP_GW"
PING_TARGETS=("8.8.8.8" "1.1.1.1")
INTERVAL=$INTERVAL
FAIL_THRESHOLD=$FAIL_THRESHOLD
FAILBACK_HOLD=$FAILBACK_HOLD
LOGFILE="/var/log/opa-isp2lte.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOGFILE"; }
current_iface() { ip route show default 2>/dev/null | awk '{print \$5}' | head -1; }
link_up() { [ -e "/sys/class/net/\$1/carrier" ] && [ "\$(cat /sys/class/net/\$1/carrier 2>/dev/null)" = "1" ]; }
ping_ok() { local iface="\$1" t; for t in "\${PING_TARGETS[@]}"; do ping -c 1 -W 2 -I "\$iface" "\$t" >/dev/null 2>&1 && return 0; done; return 1; }
switch_to() { local iface="\$1" gw="\$2"; while ip route show default >/dev/null 2>&1; do ip route del default 2>/dev/null || break; done; ip route add default via "\$gw" dev "\$iface" 2>/dev/null || { log "ERROR: add route via \$gw gagal"; return 1; }; log "route -> via \$gw dev \$iface"; command -v conntrack >/dev/null 2>&1 && conntrack -F >/dev/null 2>&1 && log "conntrack flushed"; command -v tailscale >/dev/null 2>&1 && systemctl restart tailscaled >/dev/null 2>&1 && log "tailscaled restarted"; return 0; }
main() {
    local fail_count=0 stable_sec=0 cur=""
    mkdir -p "\$(dirname "\$LOGFILE")"
    log "=== OPA-ISP2LTE started (\${INTERVAL}s, fail \${FAIL_THRESHOLD}x, hold \${FAILBACK_HOLD}s) ==="
    if [ -z "\$(current_iface)" ]; then
        if link_up "\$PRIMARY"; then switch_to "\$PRIMARY" "\$PRIMARY_GW"
        elif link_up "\$BACKUP"; then switch_to "\$BACKUP" "\$BACKUP_GW"; fi
    fi
    while true; do
        cur="\$(current_iface)"; [ -z "\$cur" ] && cur="\$PRIMARY"
        local primary_up=0 backup_up=0
        link_up "\$PRIMARY" && primary_up=1
        link_up "\$BACKUP"  && backup_up=1
        if [ "\$cur" = "\$PRIMARY" ]; then
            if ping_ok "\$PRIMARY"; then fail_count=0; else fail_count=\$((fail_count+1)); log "PRIMARY ping fail (\$fail_count/\$FAIL_THRESHOLD)"; fi
            if [ "\$fail_count" -ge "\$FAIL_THRESHOLD" ]; then
                [ "\$backup_up" = "1" ] && { log ">>> SWITCH ke BACKUP"; switch_to "\$BACKUP" "\$BACKUP_GW" && log "OK: LTE"; } || log "PRIMARY down & BACKUP down"
                fail_count=0
            fi
            stable_sec=0
        else
            if ping_ok "\$BACKUP"; then fail_count=0; else fail_count=\$((fail_count+1)); log "BACKUP ping fail (\$fail_count/\$FAIL_THRESHOLD)"; fi
            if [ "\$primary_up" = "1" ] && ping_ok "\$PRIMARY"; then
                stable_sec=\$((stable_sec+INTERVAL)); log "PRIMARY stabil \${stable_sec}/\${FAILBACK_HOLD}s"
                if [ "\$stable_sec" -ge "\$FAILBACK_HOLD" ]; then log ">>> FAILBACK ke PRIMARY"; switch_to "\$PRIMARY" "\$PRIMARY_GW" && log "OK: ISP"; stable_sec=0; fi
            else stable_sec=0; fi
            if [ "\$fail_count" -ge "\$FAIL_THRESHOLD" ] && [ "\$primary_up" = "1" ]; then log ">>> BACKUP down, paksa PRIMARY"; switch_to "\$PRIMARY" "\$PRIMARY_GW" && log "OK: PRIMARY"; fail_count=0; fi
        fi
        sleep "\$INTERVAL"
    done
}
main
EOF
chmod 0755 /usr/local/sbin/opa-isp2lte.sh
ok "script ditulis"

# ===== 7. Tulis service =====
info "Menulis systemd service..."
cat > /etc/systemd/system/opa-isp2lte.service <<EOF
[Unit]
Description=OPA-ISP2LTE — WAN failover (ISP <-> Modem LTE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/opa-isp2lte.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
ok "service ditulis"

# ===== 8. Aktifkan =====
systemctl daemon-reload
systemctl enable --now opa-isp2lte.service >/dev/null 2>&1
sleep 3

echo
if systemctl is-active --quiet opa-isp2lte.service; then
    ok "OPA-ISP2LTE aktif dan berjalan!"
    echo
    echo -e "${GREEN}Installasi selesai.${NC}"
    echo "  Log   : tail -f /var/log/opa-isp2lte.log"
    echo "  Status: systemctl status opa-isp2lte"
    echo "  Cek   : ip route show default"
else
    err "Service gagal start. Cek: journalctl -u opa-isp2lte -n 50"
    exit 1
fi
