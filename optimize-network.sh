#!/usr/bin/env bash
# ==============================================================================
# Network Speed & Latency Optimization Script for Linux (Ubuntu/Debian)
# ==============================================================================
# Features:
# 1. Enables Google's BBR TCP congestion control algorithm & FQ qdisc
# 2. Tunes TCP/IP network buffers, TCP Fast Open, and MTU probing
# 3. Disables Wi-Fi Power Save to eliminate latency spikes / jitter
# 4. Configures high-performance DNS resolvers (Cloudflare 1.1.1.1 + Google 8.8.8.8)
# 5. Provides rollback / reset capabilities
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be run as root (or with sudo).${NC}"
        echo -e "Usage: sudo $0 [apply | status | rollback]"
        exit 1
    fi
}

detect_wifi_interfaces() {
    if command -v iw &>/dev/null; then
        iw dev | awk '$1=="Interface"{print $2}'
    elif command -v ip &>/dev/null; then
        ip -o link show | awk -F': ' '$2 ~ /^wl/ {print $2}'
    fi
}

apply_optimizations() {
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}   Applying Network Speed Optimizations       ${NC}"
    echo -e "${BLUE}==============================================${NC}"

    # 1. Enable BBR Kernel Module
    echo -e "\n${YELLOW}[1/4] Configuring TCP BBR Kernel Module...${NC}"
    mkdir -p /etc/modules-load.d
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    modprobe tcp_bbr || {
        echo -e "${RED}[WARNING] Failed to load tcp_bbr directly. Continuing...${NC}"
    }

    # 2. Sysctl TCP Network Stack Tuning
    echo -e "${YELLOW}[2/4] Applying TCP/IP sysctl performance tuning...${NC}"
    cat << 'EOF' > /etc/sysctl.d/99-network-tuning.conf
# Queueing Discipline and TCP Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Buffer Size Optimizations (Max 16MB)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP Fast Open (3 = client and server)
net.ipv4.tcp_fastopen = 3

# Network backlog and packet handling
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-network-tuning.conf
    echo -e "${GREEN}✓ TCP BBR and network buffers tuned.${NC}"

    # 3. Disable Wi-Fi Power Save
    echo -e "\n${YELLOW}[3/4] Disabling Wi-Fi Power Saving (Ping/Jitter Fix)...${NC}"
    mkdir -p /etc/NetworkManager/conf.d
    cat << 'EOF' > /etc/NetworkManager/conf.d/99-disable-wifi-powersave.conf
[connection]
wifi.powersave = 2
EOF

    # Apply immediately to all active wireless interfaces
    for iface in $(detect_wifi_interfaces); do
        if command -v iw &>/dev/null; then
            iw dev "$iface" set power_save off 2>/dev/null && \
                echo -e "${GREEN}✓ Disabled active power saving on interface: $iface${NC}" || true
        fi
    done

    # 4. Optimize DNS with systemd-resolved
    echo -e "\n${YELLOW}[4/4] Configuring Fast DNS Resolvers (Cloudflare + Google)...${NC}"
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat << 'EOF' > /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888
FallbackDNS=1.0.0.1 8.8.4.4
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
EOF
        systemctl restart systemd-resolved
        echo -e "${GREEN}✓ Fast DNS configured via systemd-resolved.${NC}"
    else
        echo -e "${YELLOW}ℹ systemd-resolved not running. Skipping resolved configuration.${NC}"
    fi

    echo -e "\n${GREEN}==============================================${NC}"
    echo -e "${GREEN}   Network Optimizations Applied Successfully!${NC}"
    echo -e "${GREEN}==============================================${NC}"
    show_status
}

show_status() {
    echo -e "\n${BLUE}--- Current Network Settings & Status ---${NC}"
    
    # TCP Congestion Control
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    echo -e "TCP Congestion Control: ${GREEN}${cc}${NC} (qdisc: ${GREEN}${qdisc}${NC})"

    # Fast Open
    local fo
    fo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "unknown")
    echo -e "TCP Fast Open:          ${GREEN}${fo}${NC}"

    # Wi-Fi Power Save Status
    for iface in $(detect_wifi_interfaces); do
        if command -v iw &>/dev/null; then
            local ps
            ps=$(iw dev "$iface" get power_save 2>/dev/null || echo "N/A")
            echo -e "Wi-Fi (${iface}) Power:     ${GREEN}${ps}${NC}"
        fi
    done

    # Active DNS
    echo -e "\nDNS Server Info:"
    if command -v resolvectl &>/dev/null; then
        resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers" | head -n 4 || true
    fi

    # Ping check
    echo -e "\nTesting ping latency to Cloudflare DNS (1.1.1.1):"
    ping -c 3 1.1.1.1 2>/dev/null || echo "Ping test failed."
}

rollback_optimizations() {
    echo -e "${YELLOW}==============================================${NC}"
    echo -e "${YELLOW}   Rolling back optimizations to defaults...  ${NC}"
    echo -e "${YELLOW}==============================================${NC}"

    rm -f /etc/modules-load.d/bbr.conf
    rm -f /etc/sysctl.d/99-network-tuning.conf
    rm -f /etc/NetworkManager/conf.d/99-disable-wifi-powersave.conf
    rm -f /etc/systemd/resolved.conf.d/dns_servers.conf

    # Reset congestion control to cubic
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true

    # Re-enable powersave if needed
    for iface in $(detect_wifi_interfaces); do
        if command -v iw &>/dev/null; then
            iw dev "$iface" set power_save on 2>/dev/null || true
        fi
    done

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl restart systemd-resolved
    fi

    echo -e "${GREEN}✓ Rolled back to system defaults.${NC}"
}

# Main Dispatcher
check_root

ACTION="${1:-apply}"

case "$ACTION" in
    apply)
        apply_optimizations
        ;;
    status)
        show_status
        ;;
    rollback|restore|reset)
        rollback_optimizations
        ;;
    *)
        echo "Usage: sudo $0 [apply | status | rollback]"
        exit 1
        ;;
esac
