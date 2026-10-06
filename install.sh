#!/bin/bash
# ==========================================================
#  Chisel Reverse Tunnel Manager  (IPv4 + IPv6)
#  Server = Iran | Client = Kharej (Foreign)
# ==========================================================

CONF_DIR="/etc/chisel-tunnel"
BIN="/usr/local/bin/chisel"
WATCHDOG_SCRIPT="/usr/local/bin/chisel-watchdog.sh"
LOG_FILE="/var/log/chisel-watchdog.log"
IPV6_SYSCTL="/etc/sysctl.d/98-chisel-ipv6.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

need_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

# ---------------- IPv6 helpers ----------------
ipv6_supported() {
    [ -f /proc/net/if_inet6 ]
}

enable_ipv6_sysctl() {
    cat > "$IPV6_SYSCTL" <<'EOF'
# chisel-tunnel: make sure IPv6 is not disabled
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    sysctl -p "$IPV6_SYSCTL" >/dev/null 2>&1
}

# Remove brackets/spaces the user may have typed: "[2001:db8::1]" -> "2001:db8::1"
normalize_ipv6() {
    echo "$1" | tr -d '[] '
}

valid_ipv6() {
    [[ "$1" == *:*:* ]] && [[ "$1" =~ ^[0-9a-fA-F:.]+$ ]]
}

get_local_ipv6() {
    local v6
    v6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1)
    [ -z "$v6" ] && v6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null)
    echo "$v6"
}

# ---------------- Firewall helpers (IPv4 + IPv6) ----------------
# fw_allow <proto> <port>   (ip6tables rules only when ENABLE_V6=yes)
fw_allow() {
    iptables -C INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$1" --dport "$2" -j ACCEPT
    if [ "$ENABLE_V6" = "yes" ] && command -v ip6tables &>/dev/null; then
        ip6tables -C INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p "$1" --dport "$2" -j ACCEPT
    fi
}

fw_remove() {
    iptables -D INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null
    command -v ip6tables &>/dev/null && ip6tables -D INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null
}

fw_save() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
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
        echo -e "${RED}Could not find the latest chisel release. Check internet connection.${NC}"
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
    ROLE=$1
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

# ---------------- Base System Limits ----------------
apply_base_limits() {
    modprobe tcp_bbr 2>/dev/null
    echo "tcp_bbr" > /etc/modules-load.d/chisel-bbr.conf 2>/dev/null

    if ! grep -q "chisel-tunnel" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# chisel-tunnel: raised file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi
}

# ---------------- Profile 1: Gaming (Low-Latency & Anti-Jitter) ----------------
apply_profile_gaming() {
    echo -e "${CYAN}Applying Gaming Profile (Ultra-Low Latency & Anti-Jitter)...${NC}"
    apply_base_limits

    cat > /etc/sysctl.d/99-chisel-tunnel.conf <<'EOF'
# ===== Profile: Gaming / Ultra-Low Latency =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Anti-Jitter: immediate packet delivery without buffering delay
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

# DPI & Filtering Compatibility
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_mtu_probing = 1

# Fast failure cleanup (avoids long socket freezes)
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 4

# Balanced buffers (Prevent bufferbloat on lossy links)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 0
net.ipv4.tcp_window_scaling = 1
fs.file-max = 1048576
EOF
    sysctl --system >/dev/null 2>&1
    echo "PROFILE=gaming" > "$CONF_DIR/profile.conf"
    echo -e "${GREEN}Gaming profile successfully loaded.${NC}"
}

# ---------------- Profile 2: High-Speed (Optimized for Iran Links) ----------------
apply_profile_speed() {
    echo -e "${CYAN}Applying Optimized High-Speed Profile (Anti-Drop & Smooth Pacing)...${NC}"
    apply_base_limits

    cat > /etc/sysctl.d/99-chisel-tunnel.conf <<'EOF'
# ===== Profile: High Speed / Stable Throughput =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Anti-Burst: Prevent traffic policer drops and carrier rate-limiting
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

# DPI & Filtering Compatibility (prevents dropped SYNs/RSTs)
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_mtu_probing = 1

# Optimal 16MB buffers (Prevents bufferbloat while saturating link)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

# Traffic queues
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384

# Quick recovery from half-dead connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 4

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 0
net.ipv4.tcp_window_scaling = 1
fs.file-max = 1048576
EOF
    sysctl --system >/dev/null 2>&1
    echo "PROFILE=speed" > "$CONF_DIR/profile.conf"
    echo -e "${GREEN}High-Speed profile successfully loaded and applied.${NC}"
}

# ---------------- Profile Selector Prompt ----------------
select_network_profile() {
    echo ""
    echo -e "${CYAN}Select Network Optimization Profile:${NC}"
    echo -e "  1) ${GREEN}Gaming & Low-Latency${NC}  (Anti-Jitter, Low Ping, Anti-Bufferbloat) [Default]"
    echo -e "  2) ${YELLOW}High-Speed & Throughput${NC} (Optimized for Download/Upload without Packet Drops)"
    read -p "Choose [1 or 2] (Default: 1): " PROF_CHOICE

    mkdir -p "$CONF_DIR"
    rm -f "$CONF_DIR/profile.conf"

    case "$PROF_CHOICE" in
        2)
            apply_profile_speed
            ;;
        *)
            apply_profile_gaming
            ;;
    esac
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

    # ---- IPv6 (dual-stack) ----
    ENABLE_V6="no"
    LISTEN_HOST="0.0.0.0"
    if ipv6_supported; then
        read -p "Enable IPv6 (dual-stack: accept both IPv4 and IPv6)? [Y/n]: " V6_CHOICE
        case "$V6_CHOICE" in
            n|N|no|NO) ENABLE_V6="no" ;;
            *)         ENABLE_V6="yes" ;;
        esac
    else
        echo -e "${YELLOW}IPv6 is not available in this kernel. Continuing with IPv4 only.${NC}"
    fi
    if [ "$ENABLE_V6" = "yes" ]; then
        enable_ipv6_sysctl
        LISTEN_HOST="[::]"
    fi

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/server.conf" <<EOF
ROLE=server
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
IPV6_ENABLED=$ENABLE_V6
EOF

    select_network_profile

    cat > /etc/systemd/system/chisel-server.service <<EOF
[Unit]
Description=Chisel Reverse Tunnel Server (Iran)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN server --host $LISTEN_HOST --port $CTRL_PORT --reverse --keepalive 10s
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

    fw_allow tcp "$CTRL_PORT"
    IFS=',' read -ra PARR <<< "$PORTS"
    for p in "${PARR[@]}"; do
        p=$(echo "$p" | xargs)
        fw_allow tcp "$p"
        fw_allow udp "$p"
    done
    fw_save

    setup_watchdog "server"

    sleep 1
    if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$CTRL_PORT" 2>/dev/null; then
        echo -e "${GREEN}Local check passed (IPv4): port $CTRL_PORT is open on this server.${NC}"
    else
        echo -e "${RED}Local check FAILED (IPv4): port $CTRL_PORT isn't reachable locally. Check 'systemctl status chisel-server'.${NC}"
    fi
    if [ "$ENABLE_V6" = "yes" ]; then
        if timeout 3 bash -c "echo > /dev/tcp/::1/$CTRL_PORT" 2>/dev/null; then
            echo -e "${GREEN}Local check passed (IPv6): port $CTRL_PORT is open on [::1].${NC}"
        else
            echo -e "${RED}Local check FAILED (IPv6): port $CTRL_PORT isn't reachable on [::1]. Check 'systemctl status chisel-server'.${NC}"
        fi
    fi

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}Server installed and running successfully.${NC}"
    echo -e "Server IPv4  : $(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo 'unknown')"
    if [ "$ENABLE_V6" = "yes" ]; then
        V6_ADDR=$(get_local_ipv6)
        echo -e "Server IPv6  : ${YELLOW}${V6_ADDR:-not found (no global IPv6 on this server)}${NC}"
    else
        echo -e "Server IPv6  : disabled"
    fi
    echo -e "Control Port : ${YELLOW}$CTRL_PORT${NC}"
    echo -e "Ports        : ${YELLOW}$PORTS${NC}"
    echo -e "${GREEN}======================================${NC}"
}

# ---------------- Install Client (Kharej) ----------------
install_client() {
    need_root
    install_chisel

    read -p "Iran server IPv4 (press Enter to skip if you only use IPv6): " IRAN_IP
    read -p "Iran server IPv6 (optional, press Enter to skip): " IRAN_IPV6
    IRAN_IPV6=$(normalize_ipv6 "$IRAN_IPV6")
    read -p "Server control port: " CTRL_PORT
    read -p "Ports to forward (comma-separated, must match server side): " PORTS

    if [ -z "$CTRL_PORT" ] || [ -z "$PORTS" ] || { [ -z "$IRAN_IP" ] && [ -z "$IRAN_IPV6" ]; }; then
        echo -e "${RED}Missing information (need at least an IPv4 or IPv6 address, the control port and the ports).${NC}"
        return
    fi
    if [ -n "$IRAN_IPV6" ] && ! valid_ipv6 "$IRAN_IPV6"; then
        echo -e "${RED}Invalid IPv6 address: $IRAN_IPV6${NC}"
        return
    fi

    # ---- Decide how the client connects (IPv6 preferred when given) ----
    USE_V6="no"
    BIND_HOST="0.0.0.0"
    SERVER_ADDR="${IRAN_IP}:${CTRL_PORT}"

    if [ -n "$IRAN_IPV6" ]; then
        enable_ipv6_sysctl
        if ! ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
            echo -e "${YELLOW}Warning: this server has no global IPv6 address, an IPv6 connection will probably fail.${NC}"
        fi
        echo -e "${CYAN}Testing IPv6 connection to [${IRAN_IPV6}]:${CTRL_PORT} ...${NC}"
        if timeout 5 bash -c "echo > /dev/tcp/${IRAN_IPV6}/${CTRL_PORT}" 2>/dev/null; then
            echo -e "${GREEN}IPv6 connection to the Iran server works.${NC}"
            USE_V6="yes"
        else
            echo -e "${RED}Could not reach [${IRAN_IPV6}]:${CTRL_PORT} over IPv6 (server not installed yet / IPv6 not routed / port blocked).${NC}"
            if [ -n "$IRAN_IP" ]; then
                read -p "Fall back to IPv4 (${IRAN_IP}) for the tunnel connection? [Y/n]: " FB
                case "$FB" in
                    n|N|no|NO) USE_V6="yes" ;;
                    *)         USE_V6="no" ;;
                esac
            else
                read -p "Continue anyway with IPv6? (y/N): " CONT
                if [ "$CONT" = "y" ] || [ "$CONT" = "Y" ]; then
                    USE_V6="yes"
                else
                    echo "Cancelled."
                    return
                fi
            fi
        fi
    fi

    if [ "$USE_V6" = "yes" ]; then
        SERVER_ADDR="[${IRAN_IPV6}]:${CTRL_PORT}"
        BIND_HOST="[::]"   # Iran side listens on IPv4 + IPv6 for the forwarded ports
    fi

    IFS=',' read -ra PARR <<< "$PORTS"
    RMAPS=""
    for p in "${PARR[@]}"; do
        p=$(echo "$p" | xargs)
        RMAPS="$RMAPS R:${BIND_HOST}:${p}:127.0.0.1:${p}"
    done

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/client.conf" <<EOF
ROLE=client
IRAN_IP=$IRAN_IP
IRAN_IPV6=$IRAN_IPV6
USE_V6=$USE_V6
CTRL_PORT=$CTRL_PORT
PORTS=$PORTS
EOF

    select_network_profile

    cat > /etc/systemd/system/chisel-client.service <<EOF
[Unit]
Description=Chisel Reverse Tunnel Client (Kharej)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN client --keepalive 10s --max-retry-interval 3s ${SERVER_ADDR}${RMAPS}
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
    echo -e "${GREEN}Client installed and connected to ${SERVER_ADDR}.${NC}"
    echo -e "Connection   : ${YELLOW}$([ "$USE_V6" = "yes" ] && echo IPv6 || echo IPv4)${NC}"
    echo -e "Forwarded ports: ${YELLOW}$PORTS${NC}"
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
        echo "Control Port: $CTRL_PORT | Ports: $PORTS | IPv6: ${IPV6_ENABLED:-no}"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "^chisel-client.service"; then
        echo -e "${YELLOW}[ Client - Kharej ]${NC}"
        systemctl is-active chisel-client && echo -e "${GREEN}Status: Active${NC}" || echo -e "${RED}Status: Inactive${NC}"
        systemctl status chisel-client --no-pager -l | sed -n '1,10p'
        echo ""
        source "$CONF_DIR/client.conf" 2>/dev/null
        if [ "$USE_V6" = "yes" ]; then
            echo "Connected to: [$IRAN_IPV6]:$CTRL_PORT (IPv6) | Ports: $PORTS"
        else
            echo "Connected to: $IRAN_IP:$CTRL_PORT (IPv4) | Ports: $PORTS"
        fi
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
        echo -e "${YELLOW}[ Active Profile ]${NC}"
        [ -f "$CONF_DIR/profile.conf" ] && source "$CONF_DIR/profile.conf"
        echo "Tuning Profile: ${PROFILE:-custom}"
        echo "Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | Qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
        echo "TCP Auto-corking: $(sysctl -n net.ipv4.tcp_autocorking 2>/dev/null)"
        echo "Max Read Buffer: $(sysctl -n net.core.rmem_max 2>/dev/null)"
    fi
    if [ -f "$IPV6_SYSCTL" ]; then
        echo -e "${YELLOW}[ IPv6 ]${NC}"
        echo "Local global IPv6: $(get_local_ipv6 | sed 's/^$/none/')"
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
            [ -n "$CTRL_PORT" ] && fw_remove tcp "$CTRL_PORT"
            if [ -n "$PORTS" ]; then
                IFS=',' read -ra PARR <<< "$PORTS"
                for p in "${PARR[@]}"; do
                    p=$(echo "$p" | xargs)
                    fw_remove tcp "$p"
                    fw_remove udp "$p"
                done
            fi
        fi
    done
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save &>/dev/null && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
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
    rm -f "$IPV6_SYSCTL"
    rm -f /etc/modules-load.d/chisel-bbr.conf
    sed -i '/chisel-tunnel: raised file descriptor limits/,+4d' /etc/security/limits.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null

    echo -e "${GREEN}Everything has been cleanly removed.${NC}"
}

# ---------------- Menu ----------------
show_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}   Chisel Tunnel Manager (Reverse, v6)   ${NC}"
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
