#!/usr/bin/env bash
#
# OPA-ISP2LTE — installer satu perintah.
#   curl -fsSL <URL>/install.sh | sudo bash
#
# "Opa jagain internet lo, biar nggak mati."

set -euo pipefail

VERSION="2.0.0"
RAW_BASE="https://raw.githubusercontent.com/naufalmng/opa-isp2lte/main"

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
SWITCH_COOLDOWN=20
RECOVERY_COOLDOWN=60
PROBE_MODE=auto
TCP_PROBE_URL=http://connectivitycheck.gstatic.com/generate_204
PROBE_TIMEOUT=4
ROUTE_METRIC=50
MANAGE_ROUTES=1
VERIFY_BACKUP=1
RESTART_TAILSCALE=0
TAILSCALE_RESTART_COOLDOWN=300
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
    # fallback: ambil daemon versi terkini dari repo (JANGAN pakai salinan
    # embedded — salinan embedded di v1.0.0 membuat `curl | bash` selalu
    # memasang daemon buggy yang berbeda dari repo).
    info "daemon tidak ada di samping installer, mengunduh dari repo"
    if ! curl -fsSL "$RAW_BASE/opa-isp2lte.sh" -o /usr/local/sbin/opa-isp2lte.sh; then
        err "gagal mengunduh daemon dari $RAW_BASE"
        err "unduh repo lalu jalankan: sudo bash install.sh"
        exit 1
    fi
    chmod 0755 /usr/local/sbin/opa-isp2lte.sh
    ok "daemon installed (downloaded)"
fi

# pastikan LF, bukan CRLF — shebang dengan \r = "bad interpreter" dan
# unit systemd akan gagal start (akar masalah v1.0.0)
sed -i 's/\r$//' /usr/local/sbin/opa-isp2lte.sh
bash -n /usr/local/sbin/opa-isp2lte.sh || { err "daemon gagal syntax check"; exit 1; }
ok "daemon syntax ok"

# ===== 6. install CLI oitl + symlink =====
step "Installing CLI /usr/local/bin/oitl"
if [ -f "$SELF_DIR/oitl" ]; then
    install -m 0755 "$SELF_DIR/oitl" /usr/local/bin/oitl
    ln -sf /usr/local/bin/oitl /usr/local/bin/opa-isp2lte
    ok "CLI installed (oitl + opa-isp2lte)"
else
    warn "oitl CLI not found in installer dir — run 'oitl' may be unavailable."
fi

# ===== 7. write service =====
step "Writing systemd service"
if [ -f "$SELF_DIR/opa-isp2lte.service" ]; then
    install -m 0644 "$SELF_DIR/opa-isp2lte.service" /etc/systemd/system/opa-isp2lte.service
else
    curl -fsSL "$RAW_BASE/opa-isp2lte.service" -o /etc/systemd/system/opa-isp2lte.service \
        || { err "gagal menulis unit systemd"; exit 1; }
fi
sed -i 's/\r$//' /etc/systemd/system/opa-isp2lte.service
ok "service written"

# ===== 8. buang instance lama (orphan nohup) =====
# v1.0.0 sering dipasang manual sebagai `nohup bash opa-isp2lte.sh &`
# (PPid 1, tanpa unit). Kalau tidak dibunuh, dua instance berebut route.
step "Membersihkan instance lama"
if pgrep -f "opa-isp2lte\.sh" >/dev/null 2>&1; then
    systemctl stop opa-isp2lte.service >/dev/null 2>&1 || true
    pkill -f "opa-isp2lte\.sh" >/dev/null 2>&1 || true
    sleep 1
    pkill -9 -f "opa-isp2lte\.sh" >/dev/null 2>&1 || true
    ok "instance lama dimatikan"
else
    ok "tidak ada instance lama"
fi

# ===== 9. enable + start =====
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
