#!/usr/bin/env bash
#
# OPA-ISP2LTE — installer satu perintah.
#   curl -fsSL <URL>/install.sh | sudo bash
#
# "Opa jagain internet lo, biar nggak mati."

set -euo pipefail

VERSION="1.0.0"

# ===== color (with --no-color + TTY fallback) =====
if [[ " $* " == *" --no-color "* ]] || [ ! -t 1 ]; then
    NO_COLOR=1
    C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RED="" C_DIM=""
else
    NO_COLOR=0
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
    C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_CYAN=$'\033[0;36m'; C_RED=$'\033[0;31m'
fi

ok()   { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
info() { printf '%s[→]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
step() { printf '%s==>%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

# ===== logo (ANSI Shadow, pure-bash truecolor gradient — zero dependency) =====
# Logo mentah (plain block chars). Gradient diwarnai oleh bash murni di bawah.
LOGO_PLAIN=' ██████╗ ██████╗  █████╗       ██╗███████╗██████╗ ██████╗ ██╗  ████████╗███████╗
██╔═══██╗██╔══██╗██╔══██╗      ██║██╔════╝██╔══██╗╚════██╗██║  ╚══██╔══╝██╔════╝
██║   ██║██████╔╝███████║█████╗██║███████╗██████╔╝ █████╔╝██║     ██║   █████╗
██║   ██║██╔═══╝ ██╔══██║╚════╝██║╚════██║██╔═══╝ ██╔═══╝ ██║     ██║   ██╔══╝
╚██████╔╝██║     ██║  ██║      ██║███████║██║     ███████╗███████╗██║   ███████╗
 ╚═════╝ ╚═╝     ╚═╝  ╚═╝      ╚═╝╚══════╝╚═╝     ╚══════╝╚══════╝╚═╝   ╚══════╝'

# warnai satu baris logo dengan gradient truecolor cyan->magenta (murni bash)
#   $1 = lebar baris, teks dibaca dari stdin
gradient_line() {
    local w="$1" line r g b i
    IFS= read -r line
    for ((i=0; i<${#line}; i++)); do
        local ch="${line:i:1}"
        if [ "$ch" = " " ]; then
            printf ' '
        else
            # interpolasi warna: r naik 0->255, g turun 255->0, b tetap 255
            r=$(( i * 255 / (w > 1 ? w - 1 : 1) ))
            g=$(( 255 - r ))
            b=255
            printf '\033[38;2;%d;%d;%dm%s\033[0m' "$r" "$g" "$b" "$ch"
        fi
    done
    printf '\n'
}

banner() {
    local w line
    if [ "$NO_COLOR" = "1" ]; then
        printf '%s\n' "$LOGO_PLAIN"
    else
        # lebar baris terpanjang buat normalisasi gradient
        w=$(printf '%s\n' "$LOGO_PLAIN" | awk '{ if (length($0) > m) m=length($0) } END { print m }')
        while IFS= read -r line; do
            printf '%s\n' "$line" | gradient_line "$w"
        done <<< "$LOGO_PLAIN"
    fi
    printf '  %sOpa jagain internet lo, biar nggak mati.%s\n\n' "$C_DIM" "$C_RESET"
}

usage() {
    banner
    cat <<EOF
${C_BOLD}OPA-ISP2LTE${C_RESET} — automatic WAN failover (ISP <-> LTE) installer

${C_BOLD}Usage:${C_RESET}
  curl -fsSL <URL>/install.sh | sudo bash [options]

${C_BOLD}Options:${C_RESET}
  --help              Show this help
  --version           Show version
  --no-color          Disable colored output
  --non-interactive   Auto-detect interfaces & gateways (no prompts)
  --primary IFACE     Primary interface (ISP)   [default: auto-detect]
  --backup IFACE      Backup interface (LTE)    [default: auto-detect]

${C_BOLD}Examples:${C_RESET}
  curl -fsSL <URL>/install.sh | sudo bash
  curl -fsSL <URL>/install.sh | sudo bash -- --non-interactive
  curl -fsSL <URL>/install.sh | sudo bash -- --primary enp1s0 --backup enx0011

EOF
}

# ===== arg parsing =====
NON_INTERACTIVE=0
PRIMARY_ARG=""
BACKUP_ARG=""

for arg in "$@"; do
    case "$arg" in
        --help|-h)            usage; exit 0 ;;
        --version|-V)         echo "OPA-ISP2LTE v${VERSION}"; exit 0 ;;
        --no-color)           : ;;
        --non-interactive|-y) NON_INTERACTIVE=1 ;;
        --primary)            PRIMARY_ARG="${2:-}"; shift ;;
        --backup)             BACKUP_ARG="${2:-}"; shift ;;
        *) err "Unknown argument: '$arg'"; echo "Run with --help for usage." >&2; exit 1 ;;
    esac
    shift 2>/dev/null || true
done

# ===== root check =====
if [ "$EUID" -ne 0 ]; then
    err "This installer needs root privileges."
    echo "Fix: run with sudo — curl ... | sudo bash" >&2
    exit 1
fi

banner

# ===== 1. detect interfaces =====
step "Detecting network interfaces"
mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|tailscale|tun|virbr)' | sort -u)

if [ "${#IFACES[@]}" -lt 2 ]; then
    err "Need at least 2 interfaces (ISP + modem), found ${#IFACES[@]}."
    echo "Detected: ${IFACES[*]:-none}" >&2
    echo "Fix: plug in both the ISP ethernet and the LTE modem, then re-run." >&2
    exit 1
fi

pick_iface() {
    local label="$1" sel
    while true; do
        printf '%s (1-%d): ' "$label" "${#IFACES[@]}"
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#IFACES[@]}" ]; then
            echo "${IFACES[$((sel-1))]}"; return
        fi
        warn "Invalid choice '$sel'. Pick 1-${#IFACES[@]}."
    done
}

if [ -n "$PRIMARY_ARG" ] && [ -n "$BACKUP_ARG" ]; then
    PRIMARY="$PRIMARY_ARG"; BACKUP="$BACKUP_ARG"
    info "Using provided: PRIMARY=$PRIMARY BACKUP=$BACKUP"
elif [ "$NON_INTERACTIVE" = "1" ]; then
    PRIMARY="${IFACES[0]}"; BACKUP="${IFACES[1]}"
    info "Non-interactive: PRIMARY=$PRIMARY BACKUP=$BACKUP"
else
    echo "Available interfaces:"
    for i in "${!IFACES[@]}"; do printf '  %d) %s\n' "$((i+1))" "${IFACES[$i]}"; done
    echo
    info "Pick which interface is which:"
    PRIMARY=$(pick_iface "  ISP interface (primary)")
    BACKUP=$(pick_iface "  LTE modem interface (backup)")
fi

# ===== 2. gateways =====
detect_gw() {
    local ip base
    ip=$(ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4}' | head -1)
    [ -z "$ip" ] && return 1
    base=$(echo "$ip" | cut -d/ -f1)
    echo "$(echo "$base" | cut -d. -f1-3).1"
}

PRIMARY_GW=$(detect_gw "$PRIMARY" || true)
BACKUP_GW=$(detect_gw "$BACKUP" || true)

if [ "$NON_INTERACTIVE" = "0" ]; then
    echo
    step "Confirm gateways"
    read -rp "  ISP gateway   [$PRIMARY_GW]: " ans; [ -n "$ans" ] && PRIMARY_GW="$ans"
    read -rp "  Modem gateway [$BACKUP_GW]: " ans;  [ -n "$ans" ] && BACKUP_GW="$ans"
fi

if [ -z "$PRIMARY_GW" ] || [ -z "$BACKUP_GW" ]; then
    err "Could not determine gateways."
    echo "Primary gateway: ${PRIMARY_GW:-missing}" >&2
    echo "Backup gateway:  ${BACKUP_GW:-missing}" >&2
    echo "Fix: set static IPs on both interfaces first, or pass gateways manually." >&2
    exit 1
fi

echo
step "Configuration summary"
printf '  PRIMARY : %s%s%s  gw %s%s%s\n' "$C_BOLD" "$PRIMARY" "$C_RESET" "$C_BOLD" "$PRIMARY_GW" "$C_RESET"
printf '  BACKUP  : %s%s%s  gw %s%s%s\n' "$C_BOLD" "$BACKUP" "$C_RESET" "$C_BOLD" "$BACKUP_GW" "$C_RESET"

# ===== 3. dependencies =====
echo
step "Installing dependency: conntrack"
if command -v conntrack >/dev/null 2>&1; then
    ok "conntrack already installed"
else
    info "apt-get install conntrack ..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y conntrack >/dev/null 2>&1 && ok "conntrack installed" || warn "conntrack failed to install (optional)"
fi

# ===== 4. write config file =====
step "Writing /etc/opa-isp2lte.conf"
cat > /etc/opa-isp2lte.conf <<EOF
# OPA-ISP2LTE configuration
PRIMARY=$PRIMARY
BACKUP=$BACKUP
PRIMARY_GW=$PRIMARY_GW
BACKUP_GW=$BACKUP_GW
PING_TARGETS=8.8.8.8 1.1.1.1
INTERVAL=10
FAIL_THRESHOLD=3
FAILBACK_HOLD=60
LOGFILE=/var/log/opa-isp2lte.log
EOF
ok "config written"

# ===== 5. copy daemon (dari repo ini sendiri, kalau ada; kalau tidak, generate) =====
step "Installing daemon /usr/local/sbin/opa-isp2lte.sh"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '.')"
if [ -f "$SELF_DIR/opa-isp2lte.sh" ]; then
    install -m 0755 "$SELF_DIR/opa-isp2lte.sh" /usr/local/sbin/opa-isp2lte.sh
    ok "daemon installed (from repo)"
else
    # fallback: minimal daemon (baca config, logika sama)
    cat > /usr/local/sbin/opa-isp2lte.sh <<'EOF'
#!/usr/bin/env bash
# OPA-ISP2LTE — failover daemon (config di /etc/opa-isp2lte.conf)
set -u
CONF="${OPA_CONF:-/etc/opa-isp2lte.conf}"
PRIMARY="enx00e04c8f6956"; BACKUP="enx0202025b3531"
PRIMARY_GW="192.168.100.1"; BACKUP_GW="192.168.200.1"
PING_TARGETS=(8.8.8.8 1.1.1.1); INTERVAL=10; FAIL_THRESHOLD=3; FAILBACK_HOLD=60
LOGFILE="/var/log/opa-isp2lte.log"; STATE_DIR="/var/lib/opa-isp2lte"
if [ -f "$CONF" ]; then
    while IFS='=' read -r key val; do
        case "$key" in
            ''|\#*) continue ;;
            PRIMARY) PRIMARY="$val";; BACKUP) BACKUP="$val";;
            PRIMARY_GW) PRIMARY_GW="$val";; BACKUP_GW) BACKUP_GW="$val";;
            PING_TARGETS) read -r -a PING_TARGETS <<< "$val";;
            INTERVAL) INTERVAL="$val";; FAIL_THRESHOLD) FAIL_THRESHOLD="$val";;
            FAILBACK_HOLD) FAILBACK_HOLD="$val";; LOGFILE) LOGFILE="$val";;
        esac
    done < <(grep -vE '^\s*(#|$)' "$CONF")
fi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }
current_iface() { ip route show default 2>/dev/null | awk '{print $5}' | head -1; }
link_up() { [ -e "/sys/class/net/$1/carrier" ] && [ "$(cat /sys/class/net/$1/carrier 2>/dev/null)" = "1" ]; }
ping_ok() { local iface="$1" t; for t in "${PING_TARGETS[@]}"; do ping -c 1 -W 2 -I "$iface" "$t" >/dev/null 2>&1 && return 0; done; return 1; }
switch_to() { local iface="$1" gw="$2"; while ip route show default >/dev/null 2>&1; do ip route del default 2>/dev/null || break; done; ip route add default via "$gw" dev "$iface" 2>/dev/null || { log "ERROR: add route via $gw gagal"; return 1; }; log "route -> via $gw dev $iface"; command -v conntrack >/dev/null 2>&1 && conntrack -F >/dev/null 2>&1 && log "conntrack flushed"; command -v tailscale >/dev/null 2>&1 && systemctl restart tailscaled >/dev/null 2>&1 && log "tailscaled restarted"; return 0; }
main() {
    local fail_count=0 stable_sec=0 cur=""
    mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
    log "=== OPA-ISP2LTE started (${INTERVAL}s, fail ${FAIL_THRESHOLD}x, hold ${FAILBACK_HOLD}s) ==="
    if [ -z "$(current_iface)" ]; then
        if link_up "$PRIMARY"; then switch_to "$PRIMARY" "$PRIMARY_GW"
        elif link_up "$BACKUP"; then switch_to "$BACKUP" "$BACKUP_GW"; fi
    fi
    while true; do
        cur="$(current_iface)"; [ -z "$cur" ] && cur="$PRIMARY"
        local primary_up=0 backup_up=0
        link_up "$PRIMARY" && primary_up=1; link_up "$BACKUP" && backup_up=1
        if [ "$cur" = "$PRIMARY" ]; then
            if ping_ok "$PRIMARY"; then fail_count=0; else fail_count=$((fail_count+1)); log "PRIMARY ping fail ($fail_count/$FAIL_THRESHOLD)"; fi
            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                [ "$backup_up" = "1" ] && { log ">>> SWITCH ke BACKUP"; switch_to "$BACKUP" "$BACKUP_GW" && log "OK: LTE"; } || log "PRIMARY down & BACKUP down"
                fail_count=0
            fi
            stable_sec=0
        else
            if ping_ok "$BACKUP"; then fail_count=0; else fail_count=$((fail_count+1)); log "BACKUP ping fail ($fail_count/$FAIL_THRESHOLD)"; fi
            if [ "$primary_up" = "1" ] && ping_ok "$PRIMARY"; then
                stable_sec=$((stable_sec+INTERVAL)); log "PRIMARY stabil ${stable_sec}/${FAILBACK_HOLD}s"
                if [ "$stable_sec" -ge "$FAILBACK_HOLD" ]; then log ">>> FAILBACK ke PRIMARY"; switch_to "$PRIMARY" "$PRIMARY_GW" && log "OK: ISP"; stable_sec=0; fi
            else stable_sec=0; fi
            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && [ "$primary_up" = "1" ]; then log ">>> BACKUP down, paksa PRIMARY"; switch_to "$PRIMARY" "$PRIMARY_GW" && log "OK: PRIMARY"; fail_count=0; fi
        fi
        sleep "$INTERVAL"
    done
}
main
EOF
    chmod 0755 /usr/local/sbin/opa-isp2lte.sh
    ok "daemon installed (fallback generated)"
fi

# ===== 6. install CLI oitl + symlink =====
step "Installing CLI /usr/local/bin/oitl"
if [ -f "$SELF_DIR/oitl" ]; then
    install -m 0755 "$SELF_DIR/oitl" /usr/local/bin/oitl
    ln -sf /usr/local/bin/oitl /usr/local/bin/opa-isp2lte
    ok "CLI installed (oitl + opa-isp2lte)"
else
    warn "oitl CLI not found in installer dir — run 'oitl' may be unavailable."
fi

# ===== 5. write service =====
step "Writing systemd service"
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
ok "service written"

# ===== 6. enable + start =====
step "Enabling and starting service"
systemctl daemon-reload
systemctl enable --now opa-isp2lte.service >/dev/null 2>&1
sleep 3

echo
if systemctl is-active --quiet opa-isp2lte.service; then
    ok "OPA-ISP2LTE is running!"
    printf '\n%sInstalled successfully.%s\n' "$C_GREEN" "$C_RESET"
    printf '  Log    : %stail -f /var/log/opa-isp2lte.log%s\n' "$C_CYAN" "$C_RESET"
    printf '  Status : %ssystemctl status opa-isp2lte%s\n' "$C_CYAN" "$C_RESET"
    printf '  Check  : %sip route show default%s\n' "$C_CYAN" "$C_RESET"
    exit 0
else
    err "Service failed to start."
    echo "Fix: check logs with 'journalctl -u opa-isp2lte -n 50'" >&2
    exit 1
fi
