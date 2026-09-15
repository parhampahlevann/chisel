#!/bin/bash
# ==========================================================
#  Chisel Reverse Tunnel Manager (Gaming / High-Stability)
#  Server = Iran | Client = Kharej (Foreign)
# ==========================================================

CONF_DIR="/etc/chisel-tunnel"
BIN="/usr/local/bin/chisel"
WATCHDOG_SCRIPT="/usr/local/bin/chisel-watchdog.sh"
LOG_FILE="/var/log/chisel-watchdog.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${CYAN}Checking & installing dependencies...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl gzip ca-certificates iptables >/dev/null 2>&1
}

# ---------------- Install chisel binary (proven mirrored & verified method) ----------------
install_chisel() {
    if command -v chisel &>/dev/null; then
        echo -e "${GREEN}chisel is already installed: $(chisel --version)${NC}"
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
    ORIGIN_URL="https://github.com/jpillora/chisel/releases/download/v${CH_VER}/${FILE_NAME}"

    # Direct URL + several proxy/mirror fronts, since gh-proxy style mirrors
    # rotate/die often and github.com alone can be unreliable from Iran.
    MIRRORS=(
        "$ORIGIN_URL"
        "https://ghproxy.com/${ORIGIN_URL}"
        "https://ghproxy.net/${ORIGIN_URL}"
        "https://gh-proxy.com/${ORIGIN_URL}"
        "https://mirror.ghproxy.com/${ORIGIN_URL}"
        "https://hub.gitmirror.com/${ORIGIN_URL}"
        "https://ghps.cc/${ORIGIN_URL}"
        "https://gh.ddlc.top/${ORIGIN_URL}"
    )

    DOWNLOADED=0
    for URL in "${MIRRORS[@]}"; do
        echo -e "${YELLOW}Fetching Chisel binary from: $URL ...${NC}"
        rm -f /tmp/chisel.gz /tmp/chisel

        HTTP_CODE=$(curl -sL -4 --connect-timeout 8 --max-time 60 \
            --retry 2 --retry-delay 2 \
            -A "Mozilla/5.0 (X11; Linux x86_64) chisel-installer" \
            -o /tmp/chisel.gz -w "%{http_code}" "$URL")
        CURL_EXIT=$?

        if [ "$CURL_EXIT" -ne 0 ]; then
            echo -e "${RED}  -> curl failed (exit code $CURL_EXIT), trying next mirror...${NC}"
            continue
        fi
        if [ "$HTTP_CODE" != "200" ]; then
            echo -e "${RED}  -> HTTP $HTTP_CODE, trying next mirror...${NC}"
            continue
        fi
        if [ ! -s /tmp/chisel.gz ] || [ "$(stat -c%s /tmp/chisel.gz 2>/dev/null || echo 0)" -lt 100000 ]; then
            echo -e "${RED}  -> Downloaded file too small / corrupt, trying next mirror...${NC}"
            continue
        fi
        if ! gzip -t /tmp/chisel.gz 2>/dev/null; then
            echo -e "${RED}  -> File is not a valid gzip archive (likely an HTML error page), trying next mirror...${NC}"
            continue
        fi

        DOWNLOADED=1
        echo -e "${GREEN}Binary package downloaded and validated from: $URL${NC}"
        break
    done

    if [ "$DOWNLOADED" -ne 1 ]; then
        echo -e "${RED}Error: Failed to download Chisel automatically from any mirror.${NC}"
        echo -e "${YELLOW}Manual fallback:${NC}"
        echo -e "  1) Download on any machine with working internet:"
        echo -e "     ${ORIGIN_URL}"
        echo -e "  2) Upload/copy the extracted binary to: ${BIN}"
        echo -e "  3) Run: chmod +x ${BIN}"
        exit 1
    fi

    gzip -df /tmp/chisel.gz
    mv /tmp/chisel "$BIN"
    chmod +x "$BIN"

    if ! "$BIN" --version &>/dev/null; then
        echo -e "${RED}Error: Downloaded binary failed to execute (wrong arch or corrupted file).${NC}"
        rm -f "$BIN"
        exit 1
    fi

    echo -e "${GREEN}chisel v${CH_VER} installed successfully: $($BIN --version)${NC}"
}

# ---------------- Watchdog ----------------
setup_watchdog() {
    ROLE=$1   # server | client
    mkdir -p "$(dirname "$LOG_FILE")"
    cat > "$WATCHDOG_SCRIPT" <<EOF
#!/bin/bash
SERVICE="chisel-${ROLE}"
LOG="$LOG_FILE"

if ! systemctl is-active --quiet "\$SERVICE"; then
    systemctl restart "\$SERVICE"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$SERVICE was DOWN -> restarted" >> "\$LOG"
    exit 0
fi

# If there were many connection errors in the last 2 minutes, restart the service
ERR_COUNT=\$(journalctl -u "\$SERVICE" --since "2 min ago" 2>/dev/null | grep -ciE "connection error|dial tcp.*refused|EOF|i/o timeout|broken pipe")
if [ "\$ERR_COUNT" -ge 6 ]; then
    systemctl restart "\$SERVICE"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$SERVICE had \$ERR_COUNT errors -> restarted" >> "\$LOG"
fi
EOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > /etc/systemd/system/chisel-watchdog.service <<EOF
[Unit]
Description=Chisel Tunnel Watchdog (single check)

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
    systemctl enable --now chisel-watchdog.timer
    echo -e "${GREEN}Watchdog enabled (checks every 1 minute).${NC}"
}

# ---------------- Network Profile (Gaming / Low-Latency, High-Throughput) ----------------
apply_network_profile() {
    echo -e "${CYAN}Applying low-latency / high-stability network profile ...${NC}"

    modprobe tcp_bbr 2>/dev/null
    echo "tcp_bbr" > /etc/modules-load.d/chisel-bbr.conf 2>/dev/null

    cat > /etc/sysctl.d/99-chisel-tunnel.conf <<'EOF'
# ===== Chisel Tunnel - Low-Latency / High-Throughput Profile (gaming-grade) =====

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

net.ipv4.tcp_notsent_lowat = 16384

net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

fs.file-max = 1048576
EOF

    sysctl --system >/dev/null 2>&1

    if ! grep -q "chisel-tunnel" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# chisel-tunnel: raised file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi

    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$CC" == "bbr" ]; then
        echo -e "${GREEN}Network profile applied — congestion control: bbr, qdisc: fq.${NC}"
    else
        echo -e "${YELLOW}Network profile applied, but BBR isn't active (current: ${CC:-unknown}).${NC}"
        echo -e "${YELLOW}Your kernel may not support it — a reboot can help, otherwise it's not critical.${NC}"
    fi
}

# ---------------- Install Server (Iran) ----------------
install_server() {
    need_root
    install_chisel

    CTRL_PORT=""
    while [ -z "$CTRL_PORT" ]; do
        read -p "Control port (the port the client will connect to, e.g. 443, 2087, 51820): " CTRL_PORT
        if ! [[ "$CTRL_PORT" =~ ^[0-9]+$ ]] || [ "$CTRL_PORT" -lt 1 ] || [ "$CTRL_PORT" -gt 65535 ]; then
            echo -e "${RED}Invalid port. Enter a number between 1 and 65535.${NC}"
            CTRL_PORT=""
        fi
    done

    read -p "Ports whose traffic should pass through the tunnel (comma-separated, e.g. 443,2083,8443): " PORTS
    if [ -z "$PORTS" ]; then
        echo -e "${RED}You must enter at least one port.${NC}"
        return
    fi

    # Auth key: generated from /dev/urandom (NOT bare stdin — a bare `tr` with
    # no input source blocks forever waiting on the terminal and hangs the install).
    AUTH_SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20)
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
ExecStart=$BIN server --host 0.0.0.0 --port $CTRL_PORT --auth tunnel:$AUTH_SECRET --reverse --keepalive 10s
Restart=always
RestartSec=3
LimitNOFILE=1048576
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel-server

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
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    setup_watchdog "server"

    sleep 1
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$CTRL_PORT" 2>/dev/null; then
        echo -e "${GREEN}Local check passed: port $CTRL_PORT is open on this server.${NC}"
    else
        echo -e "${RED}Local check FAILED: port $CTRL_PORT isn't even reachable locally. Check 'systemctl status chisel-server'.${NC}"
    fi

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}Server installed and running successfully.${NC}"
    echo -e "Server IP    : $(curl -s -4 ifconfig.me 2>/dev/null || echo 'unknown')"
    echo -e "Control Port : ${YELLOW}$CTRL_PORT${NC}"
    echo -e "Ports        : ${YELLOW}$PORTS (TCP & UDP)${NC}"
    echo -e "Auth Key     : ${CYAN}tunnel:$AUTH_SECRET${NC}"
    echo -e "${GREEN}Save the Auth Key — you'll need it exactly when installing the Client.${NC}"
    echo -e "${YELLOW}If the Client still times out connecting, it's not this server's OS —${NC}"
    echo -e "${YELLOW}go check your hosting provider's control panel firewall/security group${NC}"
    echo -e "${YELLOW}and make sure inbound TCP $CTRL_PORT is allowed there too.${NC}"
    echo -e "${GREEN}======================================${NC}"
}

# ---------------- Install Client (Kharej) ----------------
install_client() {
    need_root
    install_chisel

    read -p "Iran server IP: " IRAN_IP
    read -p "Server control port: " CTRL_PORT
    read -p "Ports to forward (comma-separated, must match the server side exactly): " PORTS
    read -p "Auth Key (from server, e.g. tunnel:AbC123...): " AUTH_KEY

    if [ -z "$IRAN_IP" ] || [ -z "$CTRL_PORT" ] || [ -z "$PORTS" ] || [ -z "$AUTH_KEY" ]; then
        echo -e "${RED}Missing information.${NC}"
        return
    fi

    # Forward both TCP and UDP for each port (games/VPN protocols often need UDP)
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
ExecStart=$BIN client --auth $AUTH_KEY --keepalive 10s --max-retry-interval 3s ${IRAN_IP}:${CTRL_PORT}$RMAPS
Restart=always
RestartSec=3
LimitNOFILE=1048576
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel-client

    setup_watchdog "client"

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}Client installed and connected to ${IRAN_IP}:${CTRL_PORT}.${NC}"
    echo -e "Forwarded ports: ${YELLOW}$PORTS (TCP & UDP)${NC}"
    echo -e "Use the Status option to check the connection."
    echo -e "${GREEN}======================================${NC}"
}

# ---------------- Status ----------------
status_tunnel() {
    echo -e "${CYAN}====================== STATUS ======================${NC}"
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-server.service"; then
        echo -e "${YELLOW}[ Server - Iran ]${NC}"
        systemctl is-active chisel-server && echo -e "${GREEN}Status: Active${NC}" || echo -e "${RED}Status: Inactive${NC}"
        systemctl status chisel-server --no-pager -l | sed -n '1,10p'
        echo ""
        source "$CONF_DIR/server.conf" 2>/dev/null
        echo "Control Port: $CTRL_PORT | Ports: $PORTS"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-client.service"; then
        echo -e "${YELLOW}[ Client - Kharej ]${NC}"
        systemctl is-active chisel-client && echo -e "${GREEN}Status: Active${NC}" || echo -e "${RED}Status: Inactive${NC}"
        systemctl status chisel-client --no-pager -l | sed -n '1,10p'
        echo ""
        source "$CONF_DIR/client.conf" 2>/dev/null
        echo "Connected to: $IRAN_IP:$CTRL_PORT | Ports: $PORTS"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-watchdog.timer"; then
        echo -e "${YELLOW}[ Watchdog ]${NC}"
        systemctl is-active chisel-watchdog.timer && echo -e "${GREEN}Watchdog is active${NC}"
        if [ -f "$LOG_FILE" ]; then
            echo "Recent watchdog events:"
            tail -n 5 "$LOG_FILE"
        fi
    fi
    if [ -f /etc/sysctl.d/99-chisel-tunnel.conf ]; then
        echo -e "${YELLOW}[ Network Profile ]${NC}"
        echo "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    fi
    if ! systemctl list-unit-files 2>/dev/null | grep -qE "^chisel-(server|client)\.service"; then
        echo -e "${RED}No tunnel is installed.${NC}"
    fi
    echo -e "${CYAN}=====================================================${NC}"
}

# ---------------- Live Log ----------------
live_log() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-server.service"; then
        echo -e "${CYAN}Server live log (press Ctrl+C to exit):${NC}"
        journalctl -u chisel-server -f --no-pager
    elif systemctl list-unit-files 2>/dev/null | grep -q "^chisel-client.service"; then
        echo -e "${CYAN}Client live log (press Ctrl+C to exit):${NC}"
        journalctl -u chisel-client -f --no-pager
    else
        echo -e "${RED}No service is installed.${NC}"
    fi
}

# ---------------- Uninstall ----------------
uninstall_all() {
    read -p "Are you sure you want to fully remove the tunnel and all changes? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        return
    fi

    for svc in chisel-server chisel-client chisel-watchdog.timer chisel-watchdog.service; do
        systemctl disable --now "$svc" 2>/dev/null
    done

    for f in "$CONF_DIR/server.conf" "$CONF_DIR/client.conf"; do
        if [ -f "$f" ]; then
            source "$f"
            [ -n "$CTRL_PORT" ] && iptables -D INPUT -p tcp --dport "$CTRL_PORT" -j ACCEPT 2>/dev/null
            if [ -n "$PORTS" ]; then
                IFS=',' read -ra PARR <<< "$PORTS"
                for p in "${PARR[@]}"; do
                    p=$(echo "$p" | xargs)
                    iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
                    iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
                done
            fi
        fi
    done
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &>/dev/null && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    rm -f /etc/systemd/system/chisel-server.service
    rm -f /etc/systemd/system/chisel-client.service
    rm -f /etc/systemd/system/chisel-watchdog.service
    rm -f /etc/systemd/system/chisel-watchdog.timer
    rm -f "$WATCHDOG_SCRIPT"
    rm -f "$BIN"
    rm -rf "$CONF_DIR"
    rm -f "$LOG_FILE"

    rm -f /etc/sysctl.d/99-chisel-tunnel.conf
    rm -f /etc/modules-load.d/chisel-bbr.conf
    sed -i '/chisel-tunnel: raised file descriptor limits/,+2d' /etc/security/limits.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null

    echo -e "${GREEN}Everything (chisel binary, services, watchdog, and config files) has been removed.${NC}"
}

# ---------------- Menu ----------------
show_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}       Chisel Tunnel Manager (Reverse)   ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "1) Install Server (Iran)"
    echo "2) Install Client (Kharej)"
    echo "3) Status Tunnel"
    echo "4) Live Log"
    echo "5) Remove & Uninstall Chisel Tunnel"
    echo "0) Exit"
    echo -e "${CYAN}=========================================${NC}"
    read -p "Choose an option: " CHOICE
    case $CHOICE in
        1) install_server ;;
        2) install_client ;;
        3) status_tunnel ;;
        4) live_log ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    echo ""
    read -p "Press Enter to return to the menu..." _
}

need_root
while true; do
    show_menu
done
