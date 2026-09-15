#!/bin/bash
# ==========================================================
#  Chisel Ultra-Low Latency Reverse Tunnel (Gaming Grade)
#  Server = Iran | Client = Kharej (Foreign)
# ==========================================================

CONF_DIR="/etc/chisel-tunnel"
BIN="/usr/local/bin/chisel"
WATCHDOG_SCRIPT="/usr/local/bin/chisel-watchdog.sh"
LOG_FILE="/var/log/chisel-watchdog.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${CYAN}Checking & installing dependencies...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl gzip ca-certificates iptables >/dev/null 2>&1
}

# ---------------- Install Chisel Binary (Mirrored & Verified) ----------------
install_chisel() {
    if command -v chisel &>/dev/null; then
        echo -e "${GREEN}Chisel is already installed: $(chisel --version)${NC}"
        return
    fi

    install_dependencies

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) CH_ARCH="amd64" ;;
        aarch64|arm64) CH_ARCH="arm64" ;;
        armv7l) CH_ARCH="arm" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac

    CH_VER="1.10.1"
    FILE_NAME="chisel_${CH_VER}_linux_${CH_ARCH}.gz"

    MIRRORS=(
        "https://gh-proxy.com/https://github.com/jpillora/chisel/releases/download/v${CH_VER}/${FILE_NAME}"
        "https://mirror.ghproxy.com/https://github.com/jpillora/chisel/releases/download/v${CH_VER}/${FILE_NAME}"
        "https://github.com/jpillora/chisel/releases/download/v${CH_VER}/${FILE_NAME}"
    )

    DOWNLOADED=0
    for URL in "${MIRRORS[@]}"; do
        echo -e "${YELLOW}Fetching Chisel binary from: $URL ...${NC}"
        rm -f /tmp/chisel.gz /tmp/chisel
        if curl -f -sL --connect-timeout 8 --max-time 45 "$URL" -o /tmp/chisel.gz; then
            if gzip -t /tmp/chisel.gz 2>/dev/null; then
                DOWNLOADED=1
                echo -e "${GREEN}Binary package downloaded and validated.${NC}"
                break
            fi
        fi
    done

    if [ "$DOWNLOADED" -ne 1 ]; then
        echo -e "${RED}Error: Failed to download Chisel automatically.${NC}"
        echo -e "${YELLOW}Please upload the binary manually to $BIN and run chmod +x $BIN${NC}"
        exit 1
    fi

    gzip -df /tmp/chisel.gz
    mv /tmp/chisel "$BIN"
    chmod +x "$BIN"
    echo -e "${GREEN}Chisel v${CH_VER} installed successfully.${NC}"
}

# ---------------- Network Profile (Anti-Bufferbloat & Low Jitter) ----------------
apply_network_profile() {
    echo -e "${CYAN}Applying gaming-grade low-latency network profile...${NC}"

    modprobe tcp_bbr 2>/dev/null
    echo "tcp_bbr" > /etc/modules-load.d/chisel-bbr.conf 2>/dev/null

    cat > /etc/sysctl.d/99-chisel-tunnel.conf <<'EOF'
# Congestion Control & Queueing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Anti-Bufferbloat: Moderate buffers prevent massive ping spikes on lossy links
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608

# Instant transmission (zero delay for tiny UDP/TCP game packets)
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fastopen = 3

# Aggressive keepalive & dead connection drop
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 4

# Backlogs
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
fs.file-max = 1048576
EOF

    sysctl --system >/dev/null 2>&1

    if ! grep -q "chisel-tunnel" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# chisel-tunnel fd limits
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
}

# ---------------- Safe Watchdog ----------------
setup_watchdog() {
    ROLE=$1
    mkdir -p "$(dirname "$LOG_FILE")"
    cat > "$WATCHDOG_SCRIPT" <<EOF
#!/bin/bash
SERVICE="chisel-${ROLE}"
LOG="$LOG_FILE"

if ! systemctl is-active --quiet "\$SERVICE"; then
    systemctl restart "\$SERVICE"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$SERVICE was inactive -> restarted" >> "\$LOG"
    exit 0
fi

# Only restart if persistent hard connection failures occur (avoids restart loops)
ERR_COUNT=\$(journalctl -u "\$SERVICE" --since "1 min ago" --no-pager 2>/dev/null | grep -ciE "handshake failed|connection refused|broken pipe")
if [ "\$ERR_COUNT" -ge 20 ]; then
    systemctl restart "\$SERVICE"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$SERVICE hit critical error ceiling (\$ERR_COUNT) -> restarted" >> "\$LOG"
fi
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > /etc/systemd/system/chisel-watchdog.service <<EOF
[Unit]
Description=Chisel Tunnel Watchdog Worker

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

    cat > /etc/systemd/system/chisel-watchdog.timer <<EOF
[Unit]
Description=Run Chisel Watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=chisel-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel-watchdog.timer >/dev/null 2>&1
}

# ---------------- Server (Iran) ----------------
install_server() {
    need_root
    install_chisel

    read -p "Enter Control Port (e.g. 443, 2087, 8443): " CTRL_PORT
    while ! [[ "$CTRL_PORT" =~ ^[0-9]+$ ]] || [ "$CTRL_PORT" -lt 1 ] || [ "$CTRL_PORT" -gt 65535 ]; do
        read -p "Invalid port. Enter valid port (1-65535): " CTRL_PORT
    done

    read -p "Ports to forward through tunnel (comma-separated, e.g. 2083,51820): " PORTS
    if [ -z "$PORTS" ]; then
        echo -e "${RED}Error: Port list cannot be empty.${NC}"
        return
    fi

    AUTH_SECRET=$(tr -dc A-Za-z0-9 2>/dev/null | head -c 20)
    [ -z "$AUTH_SECRET" ] && AUTH_SECRET="SecretKey$(date +%s)"

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/server.conf" <<EOF
ROLE=server
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
AUTH_KEY=tunnel:$AUTH_SECRET
EOF

    apply_network_profile

    cat > /etc/systemd/system/chisel-server.service <<EOF
[Unit]
Description=Chisel Reverse Tunnel Server (Iran)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN server --host 0.0.0.0 --port $CTRL_PORT --auth tunnel:$AUTH_SECRET --reverse --keepalive 5s
Restart=always
RestartSec=2
LimitNOFILE=1048576
Nice=-10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel-server

    # Firewall setup for TCP & UDP
    if command -v ufw &>/dev/null; then
        ufw allow "${CTRL_PORT}/tcp" >/dev/null 2>&1
        IFS=',' read -ra PARR <<< "$PORTS"
        for p in "${PARR[@]}"; do
            p=$(echo "$p" | xargs)
            ufw allow "${p}/tcp" >/dev/null 2>&1
            ufw allow "${p}/udp" >/dev/null 2>&1
        done
    fi

    iptables -C INPUT -p tcp --dport "$CTRL_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$CTRL_PORT" -j ACCEPT
    IFS=',' read -ra PARR <<< "$PORTS"
    for p in "${PARR[@]}"; do
        p=$(echo "$p" | xargs)
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
    done

    setup_watchdog "server"

    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}Chisel Server installed and active!${NC}"
    echo -e "Server Control Port : ${YELLOW}$CTRL_PORT${NC}"
    echo -e "Forwarded Ports     : ${YELLOW}$PORTS (TCP & UDP Enabled)${NC}"
    echo -e "Auth Key            : ${CYAN}tunnel:$AUTH_SECRET${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${YELLOW}Save the Auth Key. It is required during Client setup.${NC}"
}

# ---------------- Client (Kharej) ----------------
install_client() {
    need_root
    install_chisel

    read -p "Iran Server IP: " IRAN_IP
    read -p "Server Control Port: " CTRL_PORT
    read -p "Ports to bridge (comma-separated, same as server): " PORTS
    read -p "Auth Key (from server): " AUTH_KEY

    if [ -z "$IRAN_IP" ] || [ -z "$CTRL_PORT" ] || [ -z "$PORTS" ] || [ -z "$AUTH_KEY" ]; then
        echo -e "${RED}Error: All inputs are required.${NC}"
        return
    fi

    # Forwarding both TCP and UDP for each target port
    IFS=',' read -ra PARR <<< "$PORTS"
    RMAPS=""
    for p in "${PARR[@]}"; do
        p=$(echo "$p" | xargs)
        RMAPS="$RMAPS R:0.0.0.0:${p}:127.0.0.1:${p} R:0.0.0.0:${p}:127.0.0.1:${p}/udp"
    done

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/client.conf" <<EOF
ROLE=client
IRAN_IP=$IRAN_IP
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
AUTH_KEY=$AUTH_KEY
EOF

    apply_network_profile

    cat > /etc/systemd/system/chisel-client.service <<EOF
[Unit]
Description=Chisel Reverse Tunnel Client (Kharej)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN client --auth $AUTH_KEY --keepalive 5s --max-retry-interval 1s ${IRAN_IP}:${CTRL_PORT} $RMAPS
Restart=always
RestartSec=2
LimitNOFILE=1048576
Nice=-10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel-client

    setup_watchdog "client"

    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}Chisel Client is configured and connected!${NC}"
    echo -e "Remote Server : ${IRAN_IP}:${CTRL_PORT}"
    echo -e "Bridged Ports : ${YELLOW}$PORTS (TCP + UDP Active)${NC}"
    echo -e "${GREEN}==============================================${NC}"
}

# ---------------- Status ----------------
status_tunnel() {
    echo -e "${CYAN}====================== STATUS ======================${NC}"
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-server.service"; then
        echo -e "${YELLOW}[ Server - Iran ]${NC}"
        systemctl is-active chisel-server && echo -e "${GREEN}State: Active${NC}" || echo -e "${RED}State: Inactive${NC}"
        [ -f "$CONF_DIR/server.conf" ] && source "$CONF_DIR/server.conf"
        echo "Control Port: $CTRL_PORT | Bridge Ports: $PORTS"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-client.service"; then
        echo -e "${YELLOW}[ Client - Kharej ]${NC}"
        systemctl is-active chisel-client && echo -e "${GREEN}State: Active${NC}" || echo -e "${RED}State: Inactive${NC}"
        [ -f "$CONF_DIR/client.conf" ] && source "$CONF_DIR/client.conf"
        echo "Remote IP: $IRAN_IP:$CTRL_PORT | Bridge Ports: $PORTS"
    fi
    if [ -f /etc/sysctl.d/99-chisel-tunnel.conf ]; then
        echo -e "${YELLOW}[ Gaming Profile Status ]${NC}"
        echo "Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | Qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
        echo "TCP Autocorking   : $(sysctl -n net.ipv4.tcp_autocorking 2>/dev/null) (0 = Realtime Send)"
    fi
    echo -e "${CYAN}=====================================================${NC}"
}

# ---------------- Live Logs ----------------
live_log() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-server.service"; then
        journalctl -u chisel-server -f --no-pager
    elif systemctl list-unit-files 2>/dev/null | grep -q "^chisel-client.service"; then
        journalctl -u chisel-client -f --no-pager
    else
        echo -e "${RED}No active tunnel service found.${NC}"
    fi
}

# ---------------- Complete Uninstall ----------------
uninstall_all() {
    read -p "Are you sure you want to remove the tunnel and reset sysctl? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo "Aborted."; return; }

    systemctl disable --now chisel-server chisel-client chisel-watchdog.timer chisel-watchdog.service 2>/dev/null

    rm -f /etc/systemd/system/chisel-server.service
    rm -f /etc/systemd/system/chisel-client.service
    rm -f /etc/systemd/system/chisel-watchdog.service
    rm -f /etc/systemd/system/chisel-watchdog.timer
    rm -f "$WATCHDOG_SCRIPT" "$BIN" "$LOG_FILE"
    rm -rf "$CONF_DIR"

    rm -f /etc/sysctl.d/99-chisel-tunnel.conf
    rm -f /etc/modules-load.d/chisel-bbr.conf
    sed -i '/chisel-tunnel fd limits/,+2d' /etc/security/limits.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1

    systemctl daemon-reload
    echo -e "${GREEN}Tunnel completely uninstalled and settings reverted.${NC}"
}

# ---------------- Interactive Menu ----------------
show_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}   Chisel Reverse Tunnel (Gaming Pro)    ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "1) Install Server (Iran)"
    echo "2) Install Client (Kharej)"
    echo "3) Status Tunnel"
    echo "4) Live Logs"
    echo "5) Uninstall Everything"
    echo "0) Exit"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Select an option [0-5]: " CHOICE
    case $CHOICE in
        1) install_server ;;
        2) install_client ;;
        3) status_tunnel ;;
        4) live_log ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid selection.${NC}" ;;
    esac
    echo ""
    read -p "Press Enter to return to menu..." _
}

need_root
while true; do
    show_menu
done
