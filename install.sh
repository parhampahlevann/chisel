#!/bin/bash
# ==========================================================
# Chisel Reverse Tunnel Manager
# Server = Iran
# Client = Kharej
#
# Fixed control port : 2087
# Fixed auth         : tunnel:123Aa
#
# TCP + UDP reverse forwarding
# BBR + FQ low-latency profile
# Fast reconnect + watchdog
# ==========================================================

set -u

CONF_DIR="/etc/chisel-tunnel"
BIN="/usr/local/bin/chisel"

WATCHDOG_SCRIPT="/usr/local/bin/chisel-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/chisel-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/chisel-watchdog.timer"

SERVER_SERVICE="/etc/systemd/system/chisel-server.service"
CLIENT_SERVICE="/etc/systemd/system/chisel-client.service"

SYSCTL_FILE="/etc/sysctl.d/99-chisel-tunnel.conf"
MODULE_FILE="/etc/modules-load.d/chisel-bbr.conf"

LOG_FILE="/var/log/chisel-watchdog.log"

# ==========================================================
# FIXED SETTINGS
# ==========================================================

CTRL_PORT="2087"
AUTH_USER="tunnel"
AUTH_PASS="123Aa"
AUTH_KEY="${AUTH_USER}:${AUTH_PASS}"

CH_VER="1.11.8"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==========================================================
# ROOT
# ==========================================================

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script must be run as root.${NC}"
        exit 1
    fi
}

# ==========================================================
# DEPENDENCIES
# ==========================================================

install_dependencies() {

    echo -e "${CYAN}Installing required packages...${NC}"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y >/dev/null 2>&1

    apt-get install -y \
        curl \
        gzip \
        ca-certificates \
        iptables \
        iproute2 \
        procps \
        net-tools \
        >/dev/null 2>&1

    echo -e "${GREEN}Dependencies OK.${NC}"
}

# ==========================================================
# INSTALL CHISEL
# ==========================================================

install_chisel() {

    install_dependencies

    CURRENT=""

    if [ -x "$BIN" ]; then
        CURRENT=$("$BIN" --version 2>/dev/null || true)
    fi

    if echo "$CURRENT" | grep -q "$CH_VER"; then
        echo -e "${GREEN}Chisel already installed: $CURRENT${NC}"
        return
    fi

    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            CH_ARCH="amd64"
            ;;
        aarch64|arm64)
            CH_ARCH="arm64"
            ;;
        armv7l)
            CH_ARCH="arm"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac

    FILE_NAME="chisel_${CH_VER}_linux_${CH_ARCH}.gz"

    ORIGIN_URL="https://github.com/jpillora/chisel/releases/download/v${CH_VER}/${FILE_NAME}"

    MIRRORS=(
        "$ORIGIN_URL"
        "https://ghproxy.com/${ORIGIN_URL}"
        "https://ghproxy.net/${ORIGIN_URL}"
        "https://gh-proxy.com/${ORIGIN_URL}"
        "https://hub.gitmirror.com/${ORIGIN_URL}"
        "https://ghps.cc/${ORIGIN_URL}"
    )

    DOWNLOADED=0

    for URL in "${MIRRORS[@]}"; do

        echo -e "${YELLOW}Downloading Chisel ${CH_VER}...${NC}"
        echo "$URL"

        rm -f /tmp/chisel.gz
        rm -f /tmp/chisel

        HTTP_CODE=$(curl \
            -4 \
            -fL \
            --connect-timeout 10 \
            --max-time 90 \
            --retry 2 \
            --retry-delay 2 \
            -A "Mozilla/5.0 ChiselInstaller" \
            -o /tmp/chisel.gz \
            -w "%{http_code}" \
            "$URL" 2>/dev/null)

        CURL_EXIT=$?

        if [ "$CURL_EXIT" -ne 0 ]; then
            echo -e "${RED}Download failed.${NC}"
            continue
        fi

        if [ "$HTTP_CODE" != "200" ]; then
            echo -e "${RED}HTTP $HTTP_CODE.${NC}"
            continue
        fi

        if [ ! -s /tmp/chisel.gz ]; then
            echo -e "${RED}Empty download.${NC}"
            continue
        fi

        if ! gzip -t /tmp/chisel.gz 2>/dev/null; then
            echo -e "${RED}Invalid gzip archive.${NC}"
            continue
        fi

        DOWNLOADED=1
        break
    done

    if [ "$DOWNLOADED" -ne 1 ]; then
        echo -e "${RED}Could not download Chisel ${CH_VER}.${NC}"
        echo
        echo "Manual URL:"
        echo "$ORIGIN_URL"
        exit 1
    fi

    gzip -df /tmp/chisel.gz

    install -m 0755 /tmp/chisel "$BIN"

    rm -f /tmp/chisel

    if ! "$BIN" --version >/dev/null 2>&1; then
        echo -e "${RED}Installed Chisel binary cannot execute.${NC}"
        rm -f "$BIN"
        exit 1
    fi

    echo -e "${GREEN}Installed: $("$BIN" --version)${NC}"
}

# ==========================================================
# NETWORK / GAMING PROFILE
# ==========================================================

apply_network_profile() {

    echo -e "${CYAN}Applying stable low-latency network profile...${NC}"

    # ------------------------------------------------------
    # BBR
    # ------------------------------------------------------

    modprobe tcp_bbr 2>/dev/null || true

    cat > "$MODULE_FILE" <<EOF
tcp_bbr
EOF

    # ------------------------------------------------------
    # Stable TCP tuning
    #
    # Intentionally avoiding absurd buffer/backlog values.
    # Huge queues can increase bufferbloat and gaming latency.
    # ------------------------------------------------------

    cat > "$SYSCTL_FILE" <<'EOF'
# ==========================================================
# Chisel low-latency / stable network profile
# ==========================================================

# Queue discipline / congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffers
net.core.rmem_default = 262144
net.core.wmem_default = 262144

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

# TCP behavior
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

# Faster recovery / connection establishment
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# Keep connections alive through NAT/firewalls
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# Reduce idle slow-start penalty
net.ipv4.tcp_slow_start_after_idle = 0

# Reduce excessive unsent buffering
net.ipv4.tcp_notsent_lowat = 16384

# Reasonable connection queues
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384

# Reasonable network receive queue
net.core.netdev_max_backlog = 8192

# TIME_WAIT / connection reuse
net.ipv4.tcp_fin_timeout = 20

# File descriptors
fs.file-max = 1048576
EOF

    sysctl --system >/dev/null 2>&1 || true

    # ------------------------------------------------------
    # File limits
    # ------------------------------------------------------

    if ! grep -q "chisel-tunnel: raised file descriptor limits" \
        /etc/security/limits.conf 2>/dev/null; then

        cat >> /etc/security/limits.conf <<'EOF'

# chisel-tunnel: raised file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
EOF

    fi

    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)

    echo
    echo -e "${GREEN}Network profile applied.${NC}"
    echo "Congestion control : $CC"
    echo "Qdisc              : $QDISC"

    if [ "$CC" != "bbr" ]; then
        echo -e "${YELLOW}Warning: BBR is not active on this kernel.${NC}"
    fi
}

# ==========================================================
# FIREWALL HELPERS
# ==========================================================

allow_tcp_port() {

    local PORT="$1"

    iptables -C INPUT \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT 2>/dev/null ||

    iptables -I INPUT \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT
}

allow_udp_port() {

    local PORT="$1"

    iptables -C INPUT \
        -p udp \
        --dport "$PORT" \
        -j ACCEPT 2>/dev/null ||

    iptables -I INPUT \
        -p udp \
        --dport "$PORT" \
        -j ACCEPT
}

remove_tcp_port() {

    local PORT="$1"

    while iptables -C INPUT \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT 2>/dev/null; do

        iptables -D INPUT \
            -p tcp \
            --dport "$PORT" \
            -j ACCEPT

    done
}

remove_udp_port() {

    local PORT="$1"

    while iptables -C INPUT \
        -p udp \
        --dport "$PORT" \
        -j ACCEPT 2>/dev/null; do

        iptables -D INPUT \
            -p udp \
            --dport "$PORT" \
            -j ACCEPT

    done
}

save_firewall() {

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true

    elif command -v iptables-save >/dev/null 2>&1; then

        mkdir -p /etc/iptables

        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

# ==========================================================
# CONFIG VALIDATION
# ==========================================================

validate_ports() {

    local PORTS="$1"

    IFS=',' read -ra PARR <<< "$PORTS"

    for p in "${PARR[@]}"; do

        p=$(echo "$p" | xargs)

        if ! [[ "$p" =~ ^[0-9]+$ ]] ||
           [ "$p" -lt 1 ] ||
           [ "$p" -gt 65535 ]; then

            echo -e "${RED}Invalid port: $p${NC}"
            return 1
        fi

        if [ "$p" = "$CTRL_PORT" ]; then
            echo -e "${RED}Forwarded port cannot be the control port $CTRL_PORT.${NC}"
            return 1
        fi
    done

    return 0
}

# ==========================================================
# WATCHDOG
# ==========================================================

setup_watchdog() {

    local ROLE="$1"
    local SERVICE="chisel-${ROLE}"

    mkdir -p "$(dirname "$LOG_FILE")"

    cat > "$WATCHDOG_SCRIPT" <<EOF
#!/bin/bash

SERVICE="$SERVICE"
LOG="$LOG_FILE"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

if ! systemctl is-active --quiet "\$SERVICE"; then

    echo "\$(timestamp) - \$SERVICE DOWN -> restarting" >> "\$LOG"

    systemctl restart "\$SERVICE"

    exit 0
fi

# Detect repeated tunnel failures.
ERR_COUNT=\$(journalctl \
    -u "\$SERVICE" \
    --since "2 minutes ago" \
    --no-pager \
    2>/dev/null |
    grep -ciE \
    "connection error|dial tcp.*refused|i/o timeout|broken pipe|connection reset|EOF|authentication failed" || true)

if [ "\$ERR_COUNT" -ge 8 ]; then

    echo "\$(timestamp) - \$SERVICE had \$ERR_COUNT errors in 2m -> restarting" >> "\$LOG"

    systemctl restart "\$SERVICE"

fi

# Keep watchdog log small.
if [ -f "\$LOG" ]; then
    tail -n 500 "\$LOG" > "\${LOG}.tmp" &&
    mv "\${LOG}.tmp" "\$LOG"
fi
EOF

    chmod 0755 "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=Chisel Tunnel Watchdog

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

    cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Chisel Tunnel Watchdog Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=chisel-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now chisel-watchdog.timer

    echo -e "${GREEN}Watchdog enabled: every 30 seconds.${NC}"
}

# ==========================================================
# SERVER INSTALL
# ==========================================================

install_server() {

    need_root
    install_chisel

    echo
    echo -e "${CYAN}========== SERVER / IRAN ==========${NC}"
    echo
    echo "Control port : $CTRL_PORT"
    echo "Auth         : $AUTH_KEY"
    echo

    while true; do

        read -rp \
        "Ports to forward (comma-separated, e.g. 25565,443,8443): " \
        PORTS

        if [ -z "$PORTS" ]; then
            echo -e "${RED}Enter at least one port.${NC}"
            continue
        fi

        if validate_ports "$PORTS"; then
            break
        fi

    done

    mkdir -p "$CONF_DIR"

    chmod 0700 "$CONF_DIR"

    cat > "$CONF_DIR/server.conf" <<EOF
ROLE=server
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
AUTH_KEY=$AUTH_KEY
EOF

    chmod 0600 "$CONF_DIR/server.conf"

    apply_network_profile

    # ------------------------------------------------------
    # Server service
    # ------------------------------------------------------

    cat > "$SERVER_SERVICE" <<EOF
[Unit]
Description=Chisel Reverse Tunnel Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=$BIN server \\
    --host 0.0.0.0 \\
    --port $CTRL_PORT \\
    --auth "$AUTH_KEY" \\
    --reverse \\
    --keepalive 5s

Restart=always
RestartSec=2

LimitNOFILE=1048576
LimitNPROC=65535

Nice=-5

# Keep systemd from killing the process during normal operation.
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable chisel-server >/dev/null 2>&1
    systemctl restart chisel-server

    sleep 2

    # ------------------------------------------------------
    # Firewall
    # ------------------------------------------------------

    allow_tcp_port "$CTRL_PORT"

    IFS=',' read -ra PARR <<< "$PORTS"

    for p in "${PARR[@]}"; do

        p=$(echo "$p" | xargs)

        allow_tcp_port "$p"
        allow_udp_port "$p"

    done

    save_firewall

    setup_watchdog server

    # ------------------------------------------------------
    # Local service test
    # ------------------------------------------------------

    echo
    echo -e "${CYAN}Checking Chisel server...${NC}"

    if systemctl is-active --quiet chisel-server; then
        echo -e "${GREEN}Service: ACTIVE${NC}"
    else
        echo -e "${RED}Service: FAILED${NC}"
        journalctl -u chisel-server \
            --no-pager \
            -n 30

        return 1
    fi

    if ss -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(^|:)${CTRL_PORT}$"; then

        echo -e "${GREEN}TCP $CTRL_PORT is listening.${NC}"

    else

        echo -e "${RED}TCP $CTRL_PORT is NOT listening.${NC}"

        journalctl -u chisel-server \
            --no-pager \
            -n 30

        return 1
    fi

    SERVER_IP=$(
        curl -4 -fsS --max-time 5 \
        https://api.ipify.org 2>/dev/null ||
        echo "unknown"
    )

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Chisel Server installed successfully${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo "Server IP     : $SERVER_IP"
    echo "Control port  : $CTRL_PORT"
    echo "Auth          : $AUTH_KEY"
    echo "Forward ports : $PORTS"
    echo
    echo -e "${YELLOW}IMPORTANT:${NC}"
    echo "Allow TCP $CTRL_PORT in your VPS/provider firewall."
    echo
    echo "Client command will use automatically:"
    echo "  http://${SERVER_IP}:${CTRL_PORT}"
    echo
    echo -e "${GREEN}========================================${NC}"
}

# ==========================================================
# CLIENT INSTALL
# ==========================================================

install_client() {

    need_root
    install_chisel

    echo
    echo -e "${CYAN}========== CLIENT / KHAREJ ==========${NC}"
    echo

    read -rp "Iran server IP: " IRAN_IP

    if [ -z "$IRAN_IP" ]; then
        echo -e "${RED}Server IP is required.${NC}"
        return 1
    fi

    while true; do

        read -rp \
        "Ports to forward (same ports configured on server): " \
        PORTS

        if [ -z "$PORTS" ]; then
            echo -e "${RED}Enter at least one port.${NC}"
            continue
        fi

        if validate_ports "$PORTS"; then
            break
        fi

    done

    # ------------------------------------------------------
    # Build reverse remotes
    #
    # TCP:
    # R:0.0.0.0:PORT:127.0.0.1:PORT/tcp
    #
    # UDP:
    # R:0.0.0.0:PORT:127.0.0.1:PORT/udp
    # ------------------------------------------------------

    REMOTES=()

    IFS=',' read -ra PARR <<< "$PORTS"

    for p in "${PARR[@]}"; do

        p=$(echo "$p" | xargs)

        REMOTES+=(
            "R:0.0.0.0:${p}:127.0.0.1:${p}/tcp"
        )

        REMOTES+=(
            "R:0.0.0.0:${p}:127.0.0.1:${p}/udp"
        )

    done

    mkdir -p "$CONF_DIR"

    chmod 0700 "$CONF_DIR"

    cat > "$CONF_DIR/client.conf" <<EOF
ROLE=client
IRAN_IP=$IRAN_IP
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
AUTH_KEY=$AUTH_KEY
EOF

    chmod 0600 "$CONF_DIR/client.conf"

    apply_network_profile

    # ------------------------------------------------------
    # Generate systemd service
    # ------------------------------------------------------

    {
        echo "[Unit]"
        echo "Description=Chisel Reverse Tunnel Client"
        echo "After=network-online.target"
        echo "Wants=network-online.target"
        echo
        echo "[Service]"
        echo "Type=simple"
        echo
        printf 'ExecStart=%q client --auth %q --keepalive 5s --min-retry-interval 1s --max-retry-interval 5s %q' \
            "$BIN" \
            "$AUTH_KEY" \
            "http://${IRAN_IP}:${CTRL_PORT}"

        for remote in "${REMOTES[@]}"; do
            printf ' %q' "$remote"
        done

        echo
        echo
        echo "Restart=always"
        echo "RestartSec=2"
        echo "LimitNOFILE=1048576"
        echo "LimitNPROC=65535"
        echo "Nice=-5"
        echo
        echo "[Install]"
        echo "WantedBy=multi-user.target"

    } > "$CLIENT_SERVICE"

    systemctl daemon-reload

    systemctl enable chisel-client >/dev/null 2>&1
    systemctl restart chisel-client

    setup_watchdog client

    echo
    echo -e "${CYAN}Testing connection to Iran server...${NC}"

    # ------------------------------------------------------
    # Check TCP connectivity to control port
    # ------------------------------------------------------

    CONNECTED=0

    for i in $(seq 1 15); do

        if timeout 3 bash -c \
            "cat < /dev/null > /dev/tcp/${IRAN_IP}/${CTRL_PORT}" \
            2>/dev/null; then

            CONNECTED=1
            break
        fi

        sleep 1
    done

    if [ "$CONNECTED" -eq 1 ]; then

        echo -e "${GREEN}TCP connection to ${IRAN_IP}:${CTRL_PORT} is reachable.${NC}"

    else

        echo -e "${RED}Cannot reach ${IRAN_IP}:${CTRL_PORT}.${NC}"
        echo
        echo "Possible causes:"
        echo "1. Provider firewall/security-group blocks TCP $CTRL_PORT."
        echo "2. Wrong Iran server IP."
        echo "3. chisel-server is not listening."
        echo "4. Server firewall blocks TCP $CTRL_PORT."
        echo
        echo "Client log:"
        journalctl -u chisel-client \
            --no-pager \
            -n 30

        return 1
    fi

    # ------------------------------------------------------
    # Give Chisel time to authenticate/create remotes
    # ------------------------------------------------------

    sleep 3

    echo
    echo -e "${CYAN}Checking Chisel client state...${NC}"

    if systemctl is-active --quiet chisel-client; then

        echo -e "${GREEN}Client service: ACTIVE${NC}"

    else

        echo -e "${RED}Client service: FAILED${NC}"

        journalctl -u chisel-client \
            --no-pager \
            -n 40

        return 1
    fi

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Chisel Client installed successfully${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo "Iran server   : $IRAN_IP"
    echo "Control port  : $CTRL_PORT"
    echo "Auth          : $AUTH_KEY"
    echo "Forward ports : $PORTS"
    echo
    echo "Reconnect     : 1s -> 5s"
    echo "Keepalive     : 5s"
    echo
    echo -e "${GREEN}========================================${NC}"
}

# ==========================================================
# STATUS
# ==========================================================

status_tunnel() {

    echo
    echo -e "${CYAN}================ TUNNEL STATUS ================${NC}"

    # ------------------------------------------------------
    # Server
    # ------------------------------------------------------

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^chisel-server.service"; then

        echo
        echo -e "${YELLOW}[ SERVER / IRAN ]${NC}"

        if systemctl is-active --quiet chisel-server; then
            echo -e "${GREEN}Service: ACTIVE${NC}"
        else
            echo -e "${RED}Service: INACTIVE${NC}"
        fi

        if [ -f "$CONF_DIR/server.conf" ]; then
            # shellcheck disable=SC1091
            source "$CONF_DIR/server.conf"

            echo "Control port : $CTRL_PORT"
            echo "Ports        : $PORTS"
            echo "Auth         : $AUTH_KEY"
        fi

        echo
        echo "Listening ports:"
        ss -lntup 2>/dev/null |
            grep -E ":(${CTRL_PORT}|$(echo "${PORTS:-}" | tr ',' '|'))([^0-9]|$)" \
            || true

        echo
        echo "Recent log:"
        journalctl -u chisel-server \
            --no-pager \
            -n 10

    fi

    # ------------------------------------------------------
    # Client
    # ------------------------------------------------------

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^chisel-client.service"; then

        echo
        echo -e "${YELLOW}[ CLIENT / KHAREJ ]${NC}"

        if systemctl is-active --quiet chisel-client; then
            echo -e "${GREEN}Service: ACTIVE${NC}"
        else
            echo -e "${RED}Service: INACTIVE${NC}"
        fi

        if [ -f "$CONF_DIR/client.conf" ]; then
            unset ROLE CTRL_PORT PORTS AUTH_KEY

            # shellcheck disable=SC1091
            source "$CONF_DIR/client.conf"

            echo "Iran server : $IRAN_IP"
            echo "Control     : $CTRL_PORT"
            echo "Ports       : $PORTS"
        fi

        echo
        echo "Recent log:"
        journalctl -u chisel-client \
            --no-pager \
            -n 15

    fi

    # ------------------------------------------------------
    # Watchdog
    # ------------------------------------------------------

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^chisel-watchdog.timer"; then

        echo
        echo -e "${YELLOW}[ WATCHDOG ]${NC}"

        if systemctl is-active --quiet chisel-watchdog.timer; then
            echo -e "${GREEN}Watchdog: ACTIVE${NC}"
        else
            echo -e "${RED}Watchdog: INACTIVE${NC}"
        fi

        if [ -f "$LOG_FILE" ]; then
            echo
            echo "Watchdog events:"
            tail -n 10 "$LOG_FILE"
        fi
    fi

    # ------------------------------------------------------
    # Network
    # ------------------------------------------------------

    if [ -f "$SYSCTL_FILE" ]; then

        echo
        echo -e "${YELLOW}[ NETWORK PROFILE ]${NC}"

        echo "Congestion : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
        echo "Qdisc      : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
        echo "BBR module : $(lsmod 2>/dev/null | grep -q '^tcp_bbr' && echo loaded || echo not-loaded)"
    fi

    echo
    echo -e "${CYAN}=================================================${NC}"
}

# ==========================================================
# LIVE LOG
# ==========================================================

live_log() {

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^chisel-server.service"; then

        echo -e "${CYAN}Server log — Ctrl+C to exit${NC}"

        journalctl \
            -u chisel-server \
            -f \
            --no-pager

        return
    fi

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^chisel-client.service"; then

        echo -e "${CYAN}Client log — Ctrl+C to exit${NC}"

        journalctl \
            -u chisel-client \
            -f \
            --no-pager

        return
    fi

    echo -e "${RED}No Chisel service installed.${NC}"
}

# ==========================================================
# UNINSTALL
# ==========================================================

uninstall_all() {

    need_root

    echo
    read -rp \
        "Remove Chisel tunnel and network profile? (yes/no): " \
        CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        return
    fi

    # ------------------------------------------------------
    # Read existing configs before deleting
    # ------------------------------------------------------

    SERVER_PORTS=""
    CLIENT_PORTS=""

    if [ -f "$CONF_DIR/server.conf" ]; then
        unset ROLE CTRL_PORT PORTS AUTH_KEY

        # shellcheck disable=SC1091
        source "$CONF_DIR/server.conf"

        SERVER_PORTS="${PORTS:-}"
    fi

    if [ -f "$CONF_DIR/client.conf" ]; then
        unset ROLE CTRL_PORT PORTS AUTH_KEY IRAN_IP

        # shellcheck disable=SC1091
        source "$CONF_DIR/client.conf"

        CLIENT_PORTS="${PORTS:-}"
    fi

    # ------------------------------------------------------
    # Stop services
    # ------------------------------------------------------

    systemctl disable --now \
        chisel-server \
        chisel-client \
        chisel-watchdog.timer \
        chisel-watchdog.service \
        2>/dev/null || true

    # ------------------------------------------------------
    # Firewall cleanup
    # ------------------------------------------------------

    remove_tcp_port "$CTRL_PORT"

    for PORT_LIST in "$SERVER_PORTS" "$CLIENT_PORTS"; do

        [ -z "$PORT_LIST" ] && continue

        IFS=',' read -ra PARR <<< "$PORT_LIST"

        for p in "${PARR[@]}"; do

            p=$(echo "$p" | xargs)

            remove_tcp_port "$p"
            remove_udp_port "$p"

        done
    done

    save_firewall

    # ------------------------------------------------------
    # Remove systemd files
    # ------------------------------------------------------

    rm -f "$SERVER_SERVICE"
    rm -f "$CLIENT_SERVICE"

    rm -f "$WATCHDOG_SERVICE"
    rm -f "$WATCHDOG_TIMER"

    rm -f "$WATCHDOG_SCRIPT"

    # ------------------------------------------------------
    # Remove Chisel
    # ------------------------------------------------------

    rm -f "$BIN"

    rm -rf "$CONF_DIR"

    rm -f "$LOG_FILE"

    # ------------------------------------------------------
    # Remove sysctl profile
    # ------------------------------------------------------

    rm -f "$SYSCTL_FILE"
    rm -f "$MODULE_FILE"

    sed -i \
        '/chisel-tunnel: raised file descriptor limits/,+2d' \
        /etc/security/limits.conf 2>/dev/null || true

    sysctl --system >/dev/null 2>&1 || true

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    echo
    echo -e "${GREEN}Chisel tunnel completely removed.${NC}"
    echo -e "${GREEN}Services, watchdog, config and network profile removed.${NC}"
}

# ==========================================================
# MENU
# ==========================================================

show_menu() {

    clear

    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}       Chisel Reverse Tunnel Manager          ${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo
    echo " Control Port : $CTRL_PORT"
    echo " Auth         : $AUTH_KEY"
    echo
    echo " 1) Install Server (Iran)"
    echo " 2) Install Client (Kharej)"
    echo " 3) Status Tunnel"
    echo " 4) Live Log"
    echo " 5) Remove / Uninstall"
    echo " 0) Exit"
    echo
    echo -e "${CYAN}==============================================${NC}"

    read -rp "Choose: " CHOICE

    case "$CHOICE" in

        1)
            install_server
            ;;

        2)
            install_client
            ;;

        3)
            status_tunnel
            ;;

        4)
            live_log
            ;;

        5)
            uninstall_all
            ;;

        0)
            exit 0
            ;;

        *)
            echo -e "${RED}Invalid option.${NC}"
            ;;
    esac

    echo
    read -rp "Press Enter to continue..." _
}

# ==========================================================
# MAIN
# ==========================================================

need_root

while true; do
    show_menu
done
