#!/bin/bash
# ==========================================================
#  Chisel Reverse Tunnel Manager
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

# ---------------- Install chisel binary ----------------
install_chisel() {
    if command -v chisel &>/dev/null; then
        echo -e "${GREEN}chisel is already installed: $(chisel --version)${NC}"
        return
    fi
    echo -e "${CYAN}Installing chisel ...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) CH_ARCH="amd64" ;;
        aarch64|arm64) CH_ARCH="arm64" ;;
        armv7l) CH_ARCH="arm" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac

    command -v curl &>/dev/null || { apt-get update -y && apt-get install -y curl; }

    LATEST_VER=$(curl -s https://api.github.com/repos/jpillora/chisel/releases/latest | grep '"tag_name"' | cut -d '"' -f4)
    if [ -z "$LATEST_VER" ]; then
        echo -e "${RED}Could not find the latest chisel release. Check the server's internet connection.${NC}"
        exit 1
    fi
    VER_NUM=${LATEST_VER#v}
    URL="https://github.com/jpillora/chisel/releases/download/${LATEST_VER}/chisel_${VER_NUM}_linux_${CH_ARCH}.gz"

    curl -L -o /tmp/chisel.gz "$URL" || { echo -e "${RED}Failed to download chisel.${NC}"; exit 1; }
    gunzip -f /tmp/chisel.gz
    mv /tmp/chisel "$BIN"
    chmod +x "$BIN"
    echo -e "${GREEN}chisel $LATEST_VER installed.${NC}"
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

# ---------------- Install Server (Iran) ----------------
install_server() {
    need_root
    install_chisel

    read -p "Control port (the port the client will connect to) [443]: " CTRL_PORT
    CTRL_PORT=${CTRL_PORT:-443}

    read -p "Ports whose traffic should pass through the tunnel (comma-separated, e.g. 443,2083,8443): " PORTS
    if [ -z "$PORTS" ]; then
        echo -e "${RED}You must enter at least one port.${NC}"
        return
    fi

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/server.conf" <<EOF
ROLE=server
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
EOF

    cat > /etc/systemd/system/chisel-server.service <<EOF
[Unit]
Description=Chisel Reverse Tunnel Server (Iran)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN server --host 0.0.0.0 --port $CTRL_PORT --reverse --keepalive 25s
Restart=always
RestartSec=3
LimitNOFILE=1048576
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now chisel-server

    # Open firewall ports: ufw (if present) AND raw iptables (in case the
    # default INPUT policy is DROP even without ufw active)
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

    # Local reachability self-test
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
    echo -e "Ports        : ${YELLOW}$PORTS${NC}"
    echo -e "${GREEN}You'll need this info when installing the Client — save it somewhere safe.${NC}"
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

    if [ -z "$IRAN_IP" ] || [ -z "$CTRL_PORT" ] || [ -z "$PORTS" ]; then
        echo -e "${RED}Missing information.${NC}"
        return
    fi

    IFS=',' read -ra PARR <<< "$PORTS"
    RMAPS=""
    for p in "${PARR[@]}"; do
        p=$(echo "$p" | xargs)
        RMAPS="$RMAPS R:0.0.0.0:${p}:127.0.0.1:${p}"
    done

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/client.conf" <<EOF
ROLE=client
IRAN_IP=$IRAN_IP
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
EOF

    cat > /etc/systemd/system/chisel-client.service <<EOF
[Unit]
Description=Chisel Reverse Tunnel Client (Kharej)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN client --keepalive 25s --max-retry-interval 5s ${IRAN_IP}:${CTRL_PORT}${RMAPS}
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
    echo -e "Forwarded ports: ${YELLOW}$PORTS${NC}"
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

    # Remove the iptables rules we added, using the saved config
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
