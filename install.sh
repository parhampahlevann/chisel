# ---------------- Network Profile (Gaming / TCP Low-Latency) ----------------
apply_network_profile() {
    echo -e "${CYAN}Applying optimized TCP low-latency profile ...${NC}"

    # ==========================================================
    # Load BBR if available
    # ==========================================================
    modprobe tcp_bbr 2>/dev/null || true

    if [ -d /etc/modules-load.d ]; then
        echo "tcp_bbr" > /etc/modules-load.d/chisel-bbr.conf
    fi

    # ==========================================================
    # Select congestion control
    # ==========================================================
    ALLOWED_CC=$(sysctl -n net.ipv4.tcp_allowed_congestion_control 2>/dev/null || true)

    if echo "$ALLOWED_CC" | grep -qw bbr; then
        TCP_CC="bbr"
    else
        TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    fi

    # ==========================================================
    # Select queue discipline
    #
    # fq is preferred with BBR.
    # ==========================================================
    if tc qdisc add dev lo root fq 2>/dev/null; then
        tc qdisc del dev lo root 2>/dev/null || true
        QDISC="fq"
    elif tc qdisc add dev lo root fq_codel 2>/dev/null; then
        tc qdisc del dev lo root 2>/dev/null || true
        QDISC="fq_codel"
    else
        QDISC="fq"
    fi

    # ==========================================================
    # TCP / Low Latency Profile
    # ==========================================================
    cat > /etc/sysctl.d/99-chisel-tunnel.conf <<EOF
# ==========================================================
# Chisel TCP Low-Latency / High-Stability Profile
# ==========================================================

# ---------------- Congestion control ----------------
net.ipv4.tcp_congestion_control = ${TCP_CC}
net.core.default_qdisc = ${QDISC}

# ---------------- TCP buffers ----------------
#
# Large enough for high-BDP international links,
# without creating unnecessarily huge queues.
#
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

net.core.rmem_default = 262144
net.core.wmem_default = 262144

net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432

# ---------------- TCP window scaling ----------------
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

# ---------------- TCP Fast Open ----------------
net.ipv4.tcp_fastopen = 3

# ---------------- PMTU / MTU handling ----------------
#
# Helps TCP recover when ICMP fragmentation-needed
# messages are filtered somewhere in the path.
#
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# ---------------- Idle connections ----------------
#
# Don't unnecessarily reduce congestion window after
# a short idle period.
#
net.ipv4.tcp_slow_start_after_idle = 0

# Keep TCP metrics between connections.
net.ipv4.tcp_no_metrics_save = 0

# ---------------- Latency control ----------------
#
# Prevent excessive unsent data from accumulating
# in the TCP socket.
#
net.ipv4.tcp_notsent_lowat = 16384

# ---------------- Connection queues ----------------
#
# Deliberately moderate values.
# Huge queues can increase bufferbloat and jitter.
#
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# ---------------- Network RX backlog ----------------
#
# 250000 is unnecessarily aggressive for latency-sensitive
# traffic and can increase queueing delay.
#
net.core.netdev_max_backlog = 8192

# ---------------- TCP keepalive ----------------
#
# Useful for long-lived Chisel connections through NAT,
# firewalls and stateful network devices.
#
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 4

# ---------------- TCP cleanup ----------------
net.ipv4.tcp_fin_timeout = 20

# ---------------- Ephemeral ports ----------------
#
# Gives the host a larger source-port range.
#
net.ipv4.ip_local_port_range = 10240 65535

# ---------------- SYN protection ----------------
net.ipv4.tcp_syncookies = 1

# ---------------- File descriptors ----------------
fs.file-max = 1048576
EOF

    # ==========================================================
    # Apply sysctl configuration
    # ==========================================================
    if sysctl --system >/dev/null 2>&1; then
        echo -e "${GREEN}TCP sysctl profile applied successfully.${NC}"
    else
        echo -e "${YELLOW}Some sysctl parameters could not be applied.${NC}"
    fi

    # ==========================================================
    # File descriptor limits
    # ==========================================================
    if ! grep -q "chisel-tunnel: raised file descriptor limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'

# chisel-tunnel: raised file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi

    # ==========================================================
    # Verification
    # ==========================================================
    ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    ACTIVE_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    MTU_PROBING=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "unknown")
    NOTSENT_LOWAT=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "unknown")

    echo ""
    echo -e "${CYAN}========== TCP PROFILE ==========${NC}"
    echo -e "Congestion control : ${YELLOW}${ACTIVE_CC}${NC}"
    echo -e "Default qdisc      : ${YELLOW}${ACTIVE_QDISC}${NC}"
    echo -e "MTU probing        : ${YELLOW}${MTU_PROBING}${NC}"
    echo -e "TCP notsent lowat  : ${YELLOW}${NOTSENT_LOWAT}${NC}"

    if [ "$ACTIVE_CC" = "bbr" ]; then
        echo -e "${GREEN}BBR: ACTIVE${NC}"
    else
        echo -e "${YELLOW}BBR: unavailable — using ${ACTIVE_CC}${NC}"
    fi

    if [ "$ACTIVE_QDISC" = "fq" ]; then
        echo -e "${GREEN}FQ: ACTIVE${NC}"
    else
        echo -e "${YELLOW}Qdisc: ${ACTIVE_QDISC}${NC}"
    fi

    echo -e "${CYAN}=================================${NC}"
}
