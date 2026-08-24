#!/usr/bin/env bash
# ==============================================================================
# diagnose-network-drops.sh
# Shell wrapper for diagnose_network_drops.py
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/diagnose_network_drops.py" "$@"
# ==============================================================================
# Advanced Standalone Linux Network & Packet Drop Diagnostic Tool
# Zero external dependencies: Uses 100% out-of-the-box Linux tools & built-ins
# (bash /dev/tcp, /proc, /sys, ip, ping, ss, awk, date, timeout, mtr/tracepath)
#
# Diagnoses intermittent packet drops, latency jitter, Wi-Fi power-save lag,
# gateway vs WAN drops, hop-by-hop loss, Path MTU blackholes, kernel backlog,
# and TCP connection stability between Source and Destination.
# ==============================================================================

set -uo pipefail

# Script Version
VERSION="2.1.0"

# Color Configuration
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[91m'
    C_GREEN=$'\033[92m'
    C_YELLOW=$'\033[93m'
    C_BLUE=$'\033[94m'
    C_MAGENTA=$'\033[95m'
    C_CYAN=$'\033[96m'
    C_WHITE=$'\033[97m'
else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_MAGENTA=''
    C_CYAN=''
    C_WHITE=''
fi

# Default Parameters
TARGET=""
TARGET_IP=""
PORT=""
SOURCE_IP=""
COUNT=30
DURATION=0
INTERVAL=0.2
TIMEOUT=2.0
OUTPUT_LOG=""
JSON_OUTPUT=0
VERBOSE=0
DISABLE_MTR=0

# Metrics / State tracking
PROBES_SENT=0
PROBES_SUCCESS=0
PROBES_TIMEOUT=0
PROBES_REFUSED=0
PROBES_ERROR=0
CONSECUTIVE_DROPS=0
MAX_BURST_DROPS=0
LATENCY_LIST=""
FAILURE_LOGS=()

# Initial timestamps and statistics
START_TIME_EPOCH=$(date +%s 2>/dev/null || echo 0)
START_TIME_ISO=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown")

# ------------------------------------------------------------------------------
# Formatting Helpers
# ------------------------------------------------------------------------------
print_header() {
    local title="$1"
    local width=78
    echo -e "\n${C_CYAN}${C_BOLD}$(printf '=%.0s' $(seq 1 $width))${C_RESET}"
    local title_len=${#title}
    local pad=$(( (width - title_len - 2) / 2 ))
    local pad_str=""
    [[ $pad -gt 0 ]] && pad_str=$(printf ' %.0s' $(seq 1 $pad))
    echo -e "${C_CYAN}${C_BOLD}${pad_str} ${title^^} ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}$(printf '=%.0s' $(seq 1 $width))${C_RESET}"
}

print_sub_header() {
    local title="$1"
    echo -e "\n${C_BLUE}${C_BOLD}--- ${title} ---${C_RESET}"
}

log_message() {
    local msg="$1"
    echo -e "$msg"
    if [[ -n "$OUTPUT_LOG" ]]; then
        # Strip ANSI colors for file logging
        echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$OUTPUT_LOG" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Usage & Help
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
${C_BOLD}Linux Network & Packet Drop Diagnostic Tool (v${VERSION})${C_RESET}
Diagnoses intermittent network connectivity, packet drops, jitter, and kernel drops.
100% Standalone: Works with standard Linux out-of-the-box utilities.

${C_BOLD}USAGE:${C_RESET}
    $0 -d <target_ip_or_host> [options]
    or run interactively without arguments:
    $0

${C_BOLD}OPTIONS:${C_RESET}
    -d, --target <host/ip>     Target Server IP address or Hostname (Required)
    -p, --port <port>          Target TCP Port (e.g. 80, 443, 8080, 3306). Optional.
    -s, --source-ip <ip>       Source IP to bind / route from (Optional, auto-detected)
    -c, --count <number>       Number of TCP/ICMP probes to send (Default: 30)
    -T, --duration <seconds>   Run probes for specified duration in seconds (Overrides -c)
    -i, --interval <seconds>   Interval between probes in seconds (Default: 0.2)
    -t, --timeout <seconds>    Socket connection timeout in seconds (Default: 2.0)
    -o, --log <file>           Save output and timestamped failure logs to file
    --no-mtr                   Skip intermediate hop-by-hop traceroute (MTR)
    --json                     Output summary metrics in JSON format
    -v, --verbose              Enable verbose output
    -h, --help                 Show this help message and exit

${C_BOLD}EXAMPLES:${C_RESET}
    # 1. Quick diagnostic of web host on port 443:
    $0 -d google.com -p 443

    # 2. General network path & gateway diagnosis without port:
    $0 -d 1.1.1.1 -c 50

    # 3. Continuous monitoring for 2 minutes (120s) to catch intermittent drops:
    $0 -d 10.0.0.1 -p 8080 -T 120 -i 0.1 -o /tmp/network_drop.log

    # 4. JSON telemetry for monitoring scripts:
    $0 -d 192.168.1.1 -p 22 -c 10 --json

EOF
}

# ------------------------------------------------------------------------------
# Command Line Argument Parsing
# ------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--target|--target-ip|--dst)
                TARGET="$2"
                shift 2
                ;;
            -p|--port)
                PORT="$2"
                shift 2
                ;;
            -s|--source|--source-ip|--src)
                SOURCE_IP="$2"
                shift 2
                ;;
            -c|--count)
                COUNT="$2"
                shift 2
                ;;
            -T|--duration)
                DURATION="$2"
                shift 2
                ;;
            -i|--interval)
                INTERVAL="$2"
                shift 2
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -o|--log|--output)
                OUTPUT_LOG="$2"
                shift 2
                ;;
            --no-mtr)
                DISABLE_MTR=1
                shift
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${C_RED}Error: Unknown argument '$1'${C_RESET}" >&2
                echo -e "Use '$0 --help' for usage information." >&2
                exit 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Interactive Prompting (if missing required arguments)
# ------------------------------------------------------------------------------
prompt_interactive() {
    local target_was_provided=1
    if [[ -z "$TARGET" ]]; then
        target_was_provided=0
        if [[ -t 0 ]]; then
            echo -e "${C_CYAN}${C_BOLD}=== Interactive Network Diagnostic Setup ===${C_RESET}"
            read -r -p "$(echo -e "${C_BOLD}Enter Target IP or Hostname (e.g. 1.1.1.1 or api.example.com): ${C_RESET}")" TARGET
            TARGET=$(echo "$TARGET" | tr -d '[:space:]')
        fi
    fi

    if [[ -z "$TARGET" ]]; then
        echo -e "${C_RED}Error: Target IP or Hostname is required. Specify with -d <target>${C_RESET}" >&2
        exit 1
    fi

    # Only prompt for port interactively if target was NOT provided via CLI
    if [[ $target_was_provided -eq 0 ]] && [[ -z "$PORT" ]] && [[ -t 0 ]]; then
        read -r -p "$(echo -e "${C_BOLD}Enter Target TCP Port (e.g. 80, 443, 8080) [Press Enter to skip port test]: ${C_RESET}")" PORT_INPUT
        PORT_INPUT=$(echo "$PORT_INPUT" | tr -d '[:space:]')
        if [[ -n "$PORT_INPUT" ]]; then
            if [[ "$PORT_INPUT" =~ ^[0-9]+$ ]] && [[ "$PORT_INPUT" -ge 1 ]] && [[ "$PORT_INPUT" -le 65535 ]]; then
                PORT="$PORT_INPUT"
            else
                echo -e "${C_YELLOW}Warning: Invalid port '$PORT_INPUT'. Proceeding without port-specific testing.${C_RESET}"
                PORT=""
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# IP Resolution & Routing Discovery
# ------------------------------------------------------------------------------
resolve_target_ip() {
    local target="$1"
    # Check if target is already an IPv4 address
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        TARGET_IP="$target"
        return 0
    fi

    # Try resolving via getent
    local resolved=""
    if command -v getent &>/dev/null; then
        resolved=$(getent ahostsv4 "$target" 2>/dev/null | awk '{print $1; exit}')
        if [[ -z "$resolved" ]]; then
            resolved=$(getent hosts "$target" 2>/dev/null | awk '{print $1; exit}')
        fi
    fi

    # Fallback to nslookup / dig / host / ping
    if [[ -z "$resolved" ]] && command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$target" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)
    fi
    if [[ -z "$resolved" ]] && command -v dig &>/dev/null; then
        resolved=$(dig +short A "$target" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    fi
    if [[ -z "$resolved" ]] && command -v host &>/dev/null; then
        resolved=$(host -t A "$target" 2>/dev/null | awk '/has address/ {print $4; exit}')
    fi
    if [[ -z "$resolved" ]]; then
        resolved=$(ping -c 1 -W 2 "$target" 2>&1 | grep -oE '\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)' | tr -d '()' | head -n1)
    fi

    if [[ -n "$resolved" ]]; then
        TARGET_IP="$resolved"
        return 0
    else
        echo -e "${C_RED}Error: Unable to resolve hostname '${target}' to an IPv4 address.${C_RESET}" >&2
        exit 1
    fi
}

get_routing_info() {
    OUT_IFACE=""
    GATEWAY=""
    ROUTE_SRC=""

    if command -v ip &>/dev/null; then
        local cmd="ip route get ${TARGET_IP}"
        if [[ -n "$SOURCE_IP" ]]; then
            cmd+=" from ${SOURCE_IP}"
        fi
        local route_out
        route_out=$($cmd 2>/dev/null || true)
        if [[ -n "$route_out" ]]; then
            OUT_IFACE=$(echo "$route_out" | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -n1)
            GATEWAY=$(echo "$route_out" | grep -oE 'via [^ ]+' | awk '{print $2}' | head -n1)
            ROUTE_SRC=$(echo "$route_out" | grep -oE 'src [^ ]+' | awk '{print $2}' | head -n1)
        fi
    fi

    # Fallback route discovery via /proc/net/route
    if [[ -z "$OUT_IFACE" ]] && [[ -f /proc/net/route ]]; then
        # Look for default gateway (Destination == 00000000)
        OUT_IFACE=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null || true)
        local gw_hex
        gw_hex=$(awk '$2=="00000000" {print $3; exit}' /proc/net/route 2>/dev/null || true)
        if [[ -n "$gw_hex" ]] && [[ ${#gw_hex} -eq 8 ]]; then
            GATEWAY=$(printf "%d.%d.%d.%d\n" 0x${gw_hex:6:2} 0x${gw_hex:4:2} 0x${gw_hex:2:2} 0x${gw_hex:0:2})
        fi
    fi

    if [[ -z "$SOURCE_IP" ]] && [[ -n "$ROUTE_SRC" ]]; then
        SOURCE_IP="$ROUTE_SRC"
    fi
}

# ------------------------------------------------------------------------------
# Kernel SNMP & Netstat Delta Tracking
# ------------------------------------------------------------------------------
parse_kernel_snmp() {
    awk '
    /^Tcp: [A-Za-z]/ {
        for (i=2; i<=NF; i++) h[i] = "Tcp_" $i
        getline
        for (i=2; i<=NF; i++) print h[i] "=" $i
    }
    /^TcpExt: [A-Za-z]/ {
        for (i=2; i<=NF; i++) h_ext[i] = "TcpExt_" $i
        getline
        for (i=2; i<=NF; i++) print h_ext[i] "=" $i
    }
    ' /proc/net/snmp /proc/net/netstat 2>/dev/null || true
}

get_snmp_val() {
    local data="$1"
    local key="$2"
    echo "$data" | awk -F'=' -v k="$key" '$1==k {print $2; exit}'
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 1: Local System, NIC, Wi-Fi & Kernel Health
# ------------------------------------------------------------------------------
NIC_RX_DROP=0
NIC_TX_DROP=0
NIC_RX_ERR=0
NIC_TX_ERR=0
SOFTNET_DROP=0
SOFTNET_SQUEEZE=0
CONNTRACK_COUNT=0
CONNTRACK_MAX=0
CONNTRACK_USAGE_PCT="0.0"
WIFI_POWER_SAVE=""
WIFI_SIGNAL_DBM=""
WIFI_BITRATE=""
ARP_GATEWAY_STATE=""

diagnose_phase1_local_health() {
    print_sub_header "Phase 1: Local System, NIC & Wi-Fi Health (${OUT_IFACE:-default})"

    # 1. Interface Hardware Statistics from /sys/class/net or ip -s link
    if [[ -n "$OUT_IFACE" ]]; then
        local sys_stat_dir="/sys/class/net/${OUT_IFACE}/statistics"
        if [[ -d "$sys_stat_dir" ]]; then
            NIC_RX_DROP=$(cat "${sys_stat_dir}/rx_dropped" 2>/dev/null || echo 0)
            NIC_TX_DROP=$(cat "${sys_stat_dir}/tx_dropped" 2>/dev/null || echo 0)
            NIC_RX_ERR=$(cat "${sys_stat_dir}/rx_errors" 2>/dev/null || echo 0)
            NIC_TX_ERR=$(cat "${sys_stat_dir}/tx_errors" 2>/dev/null || echo 0)
        elif command -v ip &>/dev/null; then
            local ip_out
            ip_out=$(ip -s link show "$OUT_IFACE" 2>/dev/null || true)
            if [[ -n "$ip_out" ]]; then
                NIC_RX_ERR=$(echo "$ip_out" | awk '/RX:/ {getline; print $3}')
                NIC_RX_DROP=$(echo "$ip_out" | awk '/RX:/ {getline; print $4}')
                NIC_TX_ERR=$(echo "$ip_out" | awk '/TX:/ {getline; print $3}')
                NIC_TX_DROP=$(echo "$ip_out" | awk '/TX:/ {getline; print $4}')
            fi
        fi

        local nic_color="$C_GREEN"
        if [[ "$NIC_RX_DROP" -gt 0 ]] || [[ "$NIC_TX_DROP" -gt 0 ]] || [[ "$NIC_RX_ERR" -gt 0 ]] || [[ "$NIC_TX_ERR" -gt 0 ]]; then
            nic_color="$C_YELLOW"
        fi
        log_message "[*] Interface ${C_BOLD}${OUT_IFACE}${C_RESET} Link Counters:"
        log_message "    - RX Errors: ${NIC_RX_ERR:-0} | RX Dropped: ${nic_color}${NIC_RX_DROP:-0}${C_RESET}"
        log_message "    - TX Errors: ${NIC_TX_ERR:-0} | TX Dropped: ${nic_color}${NIC_TX_DROP:-0}${C_RESET}"

        # Check Ethtool Hardware Drops (if ethtool available)
        if command -v ethtool &>/dev/null; then
            local eth_stats
            eth_stats=$(ethtool -S "$OUT_IFACE" 2>/dev/null || true)
            if [[ -n "$eth_stats" ]]; then
                local hw_drops
                hw_drops=$(echo "$eth_stats" | grep -Ei 'drop|discard|overrun|fifo|err|loss|miss' | awk -F: '$2 > 0 {print "        • " $1 ": " $2}' | head -n 6)
                if [[ -n "$hw_drops" ]]; then
                    log_message "    ${C_YELLOW}[!][Ethtool] Hardware Drop Counters Detected:${C_RESET}"
                    log_message "${C_RED}${hw_drops}${C_RESET}"
                else
                    log_message "    ${C_GREEN}✔${C_RESET} Ethtool hardware drop/error counters are 0."
                fi
            fi
        fi
    fi

    # 2. CPU Softnet backlog drops (/proc/net/softnet_stat)
    if [[ -f /proc/net/softnet_stat ]]; then
        local softnet_res
        softnet_res=$(awk '
        {
            dropped += sprintf("%d", "0x" $2)
            squeezed += sprintf("%d", "0x" $3)
        }
        END {
            print dropped " " squeezed
        }
        ' /proc/net/softnet_stat 2>/dev/null || echo "0 0")
        SOFTNET_DROP=$(echo "$softnet_res" | awk '{print $1}')
        SOFTNET_SQUEEZE=$(echo "$softnet_res" | awk '{print $2}')

        local softnet_color="$C_GREEN"
        [[ "$SOFTNET_DROP" -gt 0 ]] && softnet_color="$C_RED"
        log_message "[*] Kernel CPU Softnet Queue Processing:"
        log_message "    - Packets dropped by CPU backlog (netdev_max_backlog): ${softnet_color}${SOFTNET_DROP}${C_RESET}"
        log_message "    - CPU budget exceeded / SoftIRQ squeezed (netdev_budget): ${SOFTNET_SQUEEZE}"
    fi

    # 3. Conntrack State Table Saturation
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]] && [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        CONNTRACK_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
        CONNTRACK_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
        if [[ "$CONNTRACK_MAX" -gt 0 ]]; then
            CONNTRACK_USAGE_PCT=$(awk -v c="$CONNTRACK_COUNT" -v m="$CONNTRACK_MAX" 'BEGIN {printf "%.1f", (c/m)*100}')
            local ct_color="$C_GREEN"
            local ct_pct_int=${CONNTRACK_USAGE_PCT%.*}
            if [[ "$ct_pct_int" -ge 90 ]]; then
                ct_color="$C_RED"
            elif [[ "$ct_pct_int" -ge 75 ]]; then
                ct_color="$C_YELLOW"
            fi
            log_message "[*] Conntrack State Table: ${ct_color}${CONNTRACK_COUNT}/${CONNTRACK_MAX} (${CONNTRACK_USAGE_PCT}%)${C_RESET}"
        fi
    fi

    # 4. Wi-Fi Power-Save & Link Diagnostics (Critical for Linux intermittent latency/drops)
    if [[ "$OUT_IFACE" =~ ^wl ]] || [[ -f /proc/net/wireless ]] || command -v iw &>/dev/null; then
        local is_wifi=0
        if [[ -n "$OUT_IFACE" ]] && [[ -d "/sys/class/net/${OUT_IFACE}/wireless" || "$OUT_IFACE" =~ ^wl ]]; then
            is_wifi=1
        fi

        if [[ $is_wifi -eq 1 ]]; then
            log_message "[*] Wireless Interface Detected (${OUT_IFACE}):"
            
            # Check Power Save Status
            if command -v iw &>/dev/null; then
                WIFI_POWER_SAVE=$(iw dev "$OUT_IFACE" get power_save 2>/dev/null | awk '{print $NF}' || true)
            elif command -v iwconfig &>/dev/null; then
                WIFI_POWER_SAVE=$(iwconfig "$OUT_IFACE" 2>/dev/null | grep -oE 'Power Management:(on|off)' | awk -F: '{print $2}' || true)
            fi

            if [[ "$WIFI_POWER_SAVE" == "on" ]]; then
                log_message "    ${C_YELLOW}[!][Wi-Fi Power Save] Active (Power Management: ON)${C_RESET}"
                log_message "        ${C_YELLOW}→ Note: Wi-Fi power-saving is known on Linux to cause 100-300ms latency jitter and periodic drop bursts on idle connections.${C_RESET}"
            elif [[ "$WIFI_POWER_SAVE" == "off" ]]; then
                log_message "    ${C_GREEN}✔${C_RESET} Wi-Fi Power Management is OFF (Low-latency mode active)."
            fi

            # Check Signal Strength & Bitrate via iw or /proc/net/wireless
            if command -v iw &>/dev/null; then
                local iw_link
                iw_link=$(iw dev "$OUT_IFACE" link 2>/dev/null || true)
                WIFI_SIGNAL_DBM=$(echo "$iw_link" | grep -oE 'signal: -?[0-9]+ dBm' | awk '{print $2 " " $3}' || true)
                WIFI_BITRATE=$(echo "$iw_link" | grep -oE 'tx bitrate: [0-9.]+ [A-Za-z/]+' | sed 's/tx bitrate: //' || true)
                if [[ -n "$WIFI_SIGNAL_DBM" ]]; then
                    log_message "    - Signal Strength: ${C_BOLD}${WIFI_SIGNAL_DBM}${C_RESET} | TX Bitrate: ${WIFI_BITRATE:-Unknown}"
                fi
            fi
        fi
    fi

    # 5. ARP / Neighbor Gateway State
    if [[ -n "$GATEWAY" ]] && command -v ip &>/dev/null; then
        ARP_GATEWAY_STATE=$(ip neigh show "$GATEWAY" 2>/dev/null | awk '{print $NF}' | head -n1 || true)
        if [[ "$ARP_GATEWAY_STATE" == "FAILED" ]] || [[ "$ARP_GATEWAY_STATE" == "INCOMPLETE" ]]; then
            log_message "    ${C_RED}[!][ARP / Neighbor] Default Gateway ${GATEWAY} state is ${ARP_GATEWAY_STATE} (Possible LAN L2 loss/MAC conflict)${C_RESET}"
        elif [[ -n "$ARP_GATEWAY_STATE" ]]; then
            log_message "    ${C_GREEN}✔${C_RESET} ARP Gateway neighbor entry: ${GATEWAY} (${ARP_GATEWAY_STATE})"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 2: Dual Gateway vs. Target ICMP & Path MTU
# ------------------------------------------------------------------------------
GW_PING_SENT=0
GW_PING_RECV=0
GW_PING_LOSS=0
GW_RTT_AVG=""
TARGET_PING_SENT=0
TARGET_PING_RECV=0
TARGET_PING_LOSS=0
TARGET_RTT_AVG=""
PATH_MTU=""

diagnose_phase2_icmp_and_mtu() {
    print_sub_header "Phase 2: Dual Gateway vs. Target ICMP Isolation & Path MTU"
    local ping_count=5
    [[ "$COUNT" -lt 5 ]] && ping_count="$COUNT"
    [[ "$COUNT" -ge 10 ]] && ping_count=10

    # 1. Ping Local Default Gateway (LAN Check)
    if [[ -n "$GATEWAY" ]]; then
        log_message "[*] Probing Local Gateway (${GATEWAY}) to isolate LAN vs WAN loss..."
        local gw_out
        gw_out=$(ping -c "$ping_count" -W 1 "$GATEWAY" 2>&1 || true)
        local gw_loss_match
        gw_loss_match=$(echo "$gw_out" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | awk -F'%' '{print $1}')
        if [[ -n "$gw_loss_match" ]]; then
            GW_PING_LOSS="$gw_loss_match"
            GW_PING_SENT=$(echo "$gw_out" | grep -oE '[0-9]+ packets transmitted' | awk '{print $1}')
            GW_PING_RECV=$(echo "$gw_out" | grep -oE '[0-9]+ (packets )?received' | awk '{print $1}')
            GW_RTT_AVG=$(echo "$gw_out" | grep -oE '(min/avg/max|rtt min/avg/max)[^=]*= [0-9./]+' | awk -F'/' '{print $5}')
            
            local gw_col="$C_GREEN"
            local gw_loss_int=${GW_PING_LOSS%.*}
            [[ "$gw_loss_int" -gt 0 ]] && gw_col="$C_RED"
            log_message "    - Gateway (${GATEWAY}): Loss = ${gw_col}${GW_PING_LOSS}%${C_RESET} | Avg Latency = ${GW_RTT_AVG:-N/A} ms"
        else
            log_message "    ${C_YELLOW}[!][Gateway] No ICMP response from gateway (${GATEWAY}).${C_RESET}"
        fi
    fi

    # 2. Ping Target IP (End-to-End Check)
    log_message "[*] Probing Target IP (${TARGET_IP})..."
    local target_ping_cmd="ping -c ${ping_count} -W 1 "
    [[ -n "$SOURCE_IP" ]] && target_ping_cmd+="-I ${SOURCE_IP} "
    target_ping_cmd+="${TARGET_IP}"
    
    local target_out
    target_out=$($target_ping_cmd 2>&1 || true)
    local target_loss_match
    target_loss_match=$(echo "$target_out" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | awk -F'%' '{print $1}')
    if [[ -n "$target_loss_match" ]]; then
        TARGET_PING_LOSS="$target_loss_match"
        TARGET_PING_SENT=$(echo "$target_out" | grep -oE '[0-9]+ packets transmitted' | awk '{print $1}')
        TARGET_PING_RECV=$(echo "$target_out" | grep -oE '[0-9]+ (packets )?received' | awk '{print $1}')
        TARGET_RTT_AVG=$(echo "$target_out" | grep -oE '(min/avg/max|rtt min/avg/max)[^=]*= [0-9./]+' | awk -F'/' '{print $5}')
        
        local t_col="$C_GREEN"
        local t_loss_int=${TARGET_PING_LOSS%.*}
        if [[ "$t_loss_int" -gt 10 ]]; then
            t_col="$C_RED"
        elif [[ "$t_loss_int" -gt 0 ]]; then
            t_col="$C_YELLOW"
        fi
        log_message "    - Target (${TARGET_IP}): Loss = ${t_col}${TARGET_PING_LOSS}%${C_RESET} | Avg Latency = ${TARGET_RTT_AVG:-N/A} ms"
    else
        log_message "    ${C_YELLOW}[!][Target] ICMP dropped or filtered by intermediate firewall.${C_RESET}"
        TARGET_PING_LOSS=100
    fi

    # LAN vs WAN Isolation Summary
    if [[ -n "$GATEWAY" ]] && [[ -n "$GW_PING_LOSS" ]] && [[ -n "$TARGET_PING_LOSS" ]]; then
        local gw_loss_int=${GW_PING_LOSS%.*}
        local target_loss_int=${TARGET_PING_LOSS%.*}
        if [[ "$gw_loss_int" -gt 0 ]]; then
            log_message "    ${C_RED}▶ Isolation Analysis: Packet drops are occurring on the LOCAL LAN / Wi-Fi / Gateway (${GW_PING_LOSS}% loss at first hop).${C_RESET}"
        elif [[ "$gw_loss_int" -eq 0 ]] && [[ "$target_loss_int" -gt 0 ]]; then
            log_message "    ${C_YELLOW}▶ Isolation Analysis: Local LAN is 100% CLEAN. Packet drops are in the WAN / ISP / Transit Route / Target Server.${C_RESET}"
        fi
    fi

    # 3. Path MTU & DF-Bit Fragmentation Discovery
    log_message "[*] Testing Path MTU & Fragmentation Blackhole Detection..."
    local test_sizes=(1472 1400 1300 1000 500)
    for sz in "${test_sizes[@]}"; do
        local mtu_cmd="ping -M do -s ${sz} -c 1 -W 1 "
        [[ -n "$SOURCE_IP" ]] && mtu_cmd+="-I ${SOURCE_IP} "
        mtu_cmd+="${TARGET_IP}"
        local mtu_out
        mtu_out=$($mtu_cmd 2>&1 || true)
        if echo "$mtu_out" | grep -qE '1 packets received|1 received|0% packet loss'; then
            PATH_MTU=$(( sz + 28 ))
            log_message "    ${C_GREEN}✔${C_RESET} Max ICMP payload ${sz} bytes (MTU ${PATH_MTU}) passed cleanly without fragmentation."
            break
        elif echo "$mtu_out" | grep -qiE 'Frag needed|Message too long'; then
            log_message "    ${C_YELLOW}✘${C_RESET} Payload ${sz} bytes: Fragmentation needed / Path MTU exceeded."
        fi
    done

    if [[ -n "$PATH_MTU" ]]; then
        if [[ "$PATH_MTU" -lt 1500 ]]; then
            log_message "    ${C_YELLOW}[!] Path MTU is reduced to ${PATH_MTU} bytes (VPN / Tunnel encapsulation). Ensure TCP MSS Clamping is active.${C_RESET}"
        fi
    else
        log_message "    ${C_DIM}[*] Path MTU probe inconclusive (ICMP DF probes filtered).${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 3: Hop-by-Hop Path Tracing (MTR / Tracepath / Pure Bash)
# ------------------------------------------------------------------------------
diagnose_phase3_hop_trace() {
    if [[ "$DISABLE_MTR" -eq 1 ]]; then
        return 0
    fi

    print_sub_header "Phase 3: Hop-by-Hop Path Loss & Jitter Analysis"

    if command -v mtr &>/dev/null; then
        log_message "[*] Executing MTR hop-by-hop packet loss trace (5 cycles)..."
        local mtr_out
        mtr_out=$(mtr -r -c 5 -n "$TARGET_IP" 2>/dev/null || true)
        if [[ -n "$mtr_out" ]]; then
            log_message "$mtr_out"
            return 0
        fi
    fi

    if command -v tracepath &>/dev/null; then
        log_message "[*] Executing tracepath hop analysis..."
        local tp_out
        tp_out=$(tracepath -n "$TARGET_IP" 2>/dev/null | head -n 15 || true)
        if [[ -n "$tp_out" ]]; then
            log_message "$tp_out"
            return 0
        fi
    fi

    if command -v traceroute &>/dev/null; then
        log_message "[*] Executing traceroute hop analysis..."
        local tr_out
        tr_out=$(traceroute -n -w 1 -q 2 "$TARGET_IP" 2>/dev/null | head -n 15 || true)
        if [[ -n "$tr_out" ]]; then
            log_message "$tr_out"
            return 0
        fi
    fi

    # Fallback: Pure bash TTL stepping ping probe
    log_message "[*] Tracing hops via ICMP TTL stepping (fallback)..."
    for ttl in $(seq 1 12); do
        local hop_out
        hop_out=$(ping -c 1 -t "$ttl" -W 1 "$TARGET_IP" 2>&1 || true)
        local hop_ip
        hop_ip=$(echo "$hop_out" | grep -oE 'From [0-9.]+' | awk '{print $2}' || true)
        if [[ -z "$hop_ip" ]]; then
            if echo "$hop_out" | grep -qE '1 packets received|1 received'; then
                hop_ip="$TARGET_IP [Destination Reached]"
                log_message "    Hop ${ttl}: ${C_GREEN}${hop_ip}${C_RESET}"
                break
            else
                hop_ip="* * * (Request Timed Out)"
            fi
        fi
        log_message "    Hop ${ttl}: ${hop_ip}"
    done
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 4: DNS Resolution Health & Jitter
# ------------------------------------------------------------------------------
DNS_AVG_MS=""
DNS_DROPS=0

diagnose_phase4_dns_health() {
    if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi

    print_sub_header "Phase 4: DNS Resolution Stability & Latency Probes"
    log_message "[*] Testing 5 consecutive DNS resolutions for hostname '${C_BOLD}${TARGET}${C_RESET}'..."

    local dns_latencies=()
    local dns_failures=0

    for idx in {1..5}; do
        local t_start
        local t_end
        t_start=$(date +%s%N 2>/dev/null || echo 0)
        
        local resolved_ip=""
        if command -v getent &>/dev/null; then
            resolved_ip=$(getent ahostsv4 "$TARGET" 2>/dev/null | awk '{print $1; exit}')
        fi
        if [[ -z "$resolved_ip" ]] && command -v dig &>/dev/null; then
            resolved_ip=$(dig +short +time=1 +tries=1 A "$TARGET" 2>/dev/null | head -n1)
        fi

        t_end=$(date +%s%N 2>/dev/null || echo 0)

        if [[ -n "$resolved_ip" ]] && [[ "$t_start" -gt 0 ]] && [[ "$t_end" -gt "$t_start" ]]; then
            local rtt_ms=$(( (t_end - t_start) / 1000000 ))
            dns_latencies+=("$rtt_ms")
        else
            ((dns_failures++))
        fi
        sleep 0.05
    done

    DNS_DROPS=$dns_failures
    if [[ ${#dns_latencies[@]} -gt 0 ]]; then
        local sum=0
        for l in "${dns_latencies[@]}"; do sum=$((sum + l)); done
        DNS_AVG_MS=$(( sum / ${#dns_latencies[@]} ))
        local dns_col="$C_GREEN"
        [[ "$DNS_AVG_MS" -gt 100 ]] && dns_col="$C_YELLOW"
        log_message "    - DNS Lookup Avg Latency: ${dns_col}${DNS_AVG_MS} ms${C_RESET} (Resolved IP: ${TARGET_IP})"
    fi

    if [[ "$dns_failures" -gt 0 ]]; then
        log_message "    ${C_RED}[!][DNS Flapping] Detected ${dns_failures}/5 DNS resolution timeouts or drops.${C_RESET}"
    else
        log_message "    ${C_GREEN}✔${C_RESET} All DNS lookups resolved consistently."
    fi
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 5: TCP Port Handshake & Continuous Failure Logging
# ------------------------------------------------------------------------------
RTT_MIN=""
RTT_AVG=""
RTT_MAX=""
RTT_STDDEV=""
DROP_PCT="0.0"
FAILURE_PCT="0.0"

diagnose_phase5_tcp_probes() {
    if [[ -z "$PORT" ]]; then
        log_message "\n[*] No target port specified. Skipping TCP port transaction probes."
        return 0
    fi

    print_sub_header "Phase 5: Targeted Port-Level TCP Transaction Probes (Port ${PORT})"
    
    local mode_desc="${COUNT} probes"
    if [[ "$DURATION" -gt 0 ]]; then
        mode_desc="duration mode: ${DURATION}s"
    fi
    log_message "[*] Probing ${C_BOLD}${TARGET_IP}:${PORT}${C_RESET} (Timeout=${TIMEOUT}s, Interval=${INTERVAL}s, ${mode_desc})..."
    echo -ne "   Progress: ["

    local probe_num=0
    local loop_start_epoch
    loop_start_epoch=$(date +%s)
    local cur_burst=0

    while true; do
        ((probe_num++))
        PROBES_SENT=$probe_num

        local t_start
        local t_end
        local rtt_ms=0
        local probe_status="OK"
        local err_detail=""
        local ts_now
        ts_now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

        # Measure sub-millisecond connection time
        t_start=$(date +%s%N 2>/dev/null || echo 0)
        
        # Pure Bash TCP connection test with timeout
        local exit_code=0
        local tcp_err
        tcp_err=$(timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${TARGET_IP}/${PORT} && exec 3<&- && exec 3>&-" 2>&1) || exit_code=$?
        
        t_end=$(date +%s%N 2>/dev/null || echo 0)

        if [[ "$t_start" -gt 0 ]] && [[ "$t_end" -gt "$t_start" ]]; then
            rtt_ms=$(awk -v s="$t_start" -v e="$t_end" 'BEGIN {printf "%.2f", (e - s)/1000000}')
        fi

        if [[ $exit_code -eq 0 ]]; then
            ((PROBES_SUCCESS++))
            echo -ne "${C_GREEN}.${C_RESET}"
            LATENCY_LIST+="${rtt_ms} "
            cur_burst=0
        elif [[ $exit_code -eq 124 ]]; then
            # Timeout (Packet drop / silent discard)
            ((PROBES_TIMEOUT++))
            ((cur_burst++))
            [[ $cur_burst -gt $MAX_BURST_DROPS ]] && MAX_BURST_DROPS=$cur_burst
            echo -ne "${C_RED}T${C_RESET}"
            err_detail="Timeout (SYN Drop / No Response)"
            FAILURE_LOGS+=("[${ts_now}] Probe #${probe_num}: ${err_detail} after ${TIMEOUT}s")
            if [[ "$VERBOSE" -eq 1 ]]; then
                echo -e "\n  ${C_RED}[${ts_now}] Probe #${probe_num}: ${err_detail}${C_RESET}"
            fi
        elif echo "$tcp_err" | grep -qiE 'refused'; then
            # TCP Connection Refused (RST packet received)
            ((PROBES_REFUSED++))
            ((cur_burst++))
            [[ $cur_burst -gt $MAX_BURST_DROPS ]] && MAX_BURST_DROPS=$cur_burst
            echo -ne "${C_YELLOW}R${C_RESET}"
            err_detail="Connection Refused (TCP RST received from target)"
            FAILURE_LOGS+=("[${ts_now}] Probe #${probe_num}: ${err_detail}")
            if [[ "$VERBOSE" -eq 1 ]]; then
                echo -e "\n  ${C_YELLOW}[${ts_now}] Probe #${probe_num}: ${err_detail}${C_RESET}"
            fi
        else
            # General Socket Error
            ((PROBES_ERROR++))
            ((cur_burst++))
            [[ $cur_burst -gt $MAX_BURST_DROPS ]] && MAX_BURST_DROPS=$cur_burst
            echo -ne "${C_RED}E${C_RESET}"
            err_detail="Socket Error: ${tcp_err}"
            FAILURE_LOGS+=("[${ts_now}] Probe #${probe_num}: ${err_detail}")
        fi

        # Check termination condition
        if [[ "$DURATION" -gt 0 ]]; then
            local now_epoch
            now_epoch=$(date +%s)
            local elapsed=$(( now_epoch - loop_start_epoch ))
            if [[ $elapsed -ge $DURATION ]]; then
                break
            fi
        else
            if [[ $probe_num -ge $COUNT ]]; then
                break
            fi
        fi

        sleep "$INTERVAL"
    done

    echo -e "] Done.\n"

    # Calculate Latency Statistics using awk
    if [[ -n "$LATENCY_LIST" ]]; then
        local stats_out
        stats_out=$(awk -v list="$LATENCY_LIST" 'BEGIN {
            n = split(list, arr, " ")
            if (n > 0) {
                min = arr[1] + 0; max = arr[1] + 0; sum = 0
                for (i = 1; i <= n; i++) {
                    v = arr[i] + 0
                    if (v < min) min = v
                    if (v > max) max = v
                    sum += v
                }
                avg = sum / n
                var = 0
                for (i = 1; i <= n; i++) {
                    var += ((arr[i] + 0) - avg) ^ 2
                }
                stddev = (n > 1) ? sqrt(var / (n - 1)) : 0
                printf "%.2f %.2f %.2f %.2f", min, avg, max, stddev
            }
        }')
        RTT_MIN=$(echo "$stats_out" | awk '{print $1}')
        RTT_AVG=$(echo "$stats_out" | awk '{print $2}')
        RTT_MAX=$(echo "$stats_out" | awk '{print $3}')
        RTT_STDDEV=$(echo "$stats_out" | awk '{print $4}')
    fi

    # Calculate Drop Percentages
    local drop_count=$(( PROBES_TIMEOUT + PROBES_ERROR ))
    local total_failures=$(( PROBES_TIMEOUT + PROBES_REFUSED + PROBES_ERROR ))
    if [[ "$PROBES_SENT" -gt 0 ]]; then
        DROP_PCT=$(awk -v d="$drop_count" -v s="$PROBES_SENT" 'BEGIN {printf "%.1f", (d/s)*100}')
        FAILURE_PCT=$(awk -v f="$total_failures" -v s="$PROBES_SENT" 'BEGIN {printf "%.1f", (f/s)*100}')
    fi

    # Display TCP Probe Results
    local status_col="$C_GREEN"
    local drop_pct_int=${DROP_PCT%.*}
    if [[ "$drop_pct_int" -ge 10 ]]; then
        status_col="$C_RED"
    elif [[ "$drop_pct_int" -gt 0 ]]; then
        status_col="$C_YELLOW"
    fi

    log_message "[*] TCP Transaction Results:"
    log_message "    - Total Probes Sent     : ${PROBES_SENT}"
    log_message "    - Successful Handshakes : ${C_GREEN}${PROBES_SUCCESS}${C_RESET}"
    log_message "    - Dropped / Timed Out  : ${C_RED}${PROBES_TIMEOUT}${C_RESET}"
    log_message "    - Rejected (TCP RST)   : ${C_YELLOW}${PROBES_REFUSED}${C_RESET}"
    log_message "    - Packet / SYN Drop Rate: ${status_col}${C_BOLD}${DROP_PCT}%${C_RESET}"
    
    if [[ "$MAX_BURST_DROPS" -gt 1 ]]; then
        log_message "    - Drop Pattern Detected : ${C_YELLOW}Burst Flapping (${MAX_BURST_DROPS} consecutive drops)${C_RESET}"
    fi

    if [[ -n "$RTT_AVG" ]]; then
        log_message "[*] TCP Handshake (SYN -> SYN-ACK) RTT Latency:"
        log_message "    - Min Latency   : ${RTT_MIN} ms"
        log_message "    - Avg Latency   : ${C_BOLD}${RTT_AVG} ms${C_RESET}"
        log_message "    - Max Latency   : ${RTT_MAX} ms"
        log_message "    - Jitter/StdDev : ${RTT_STDDEV} ms"
    fi

    # Display Sample Failure Logs
    if [[ ${#FAILURE_LOGS[@]} -gt 0 ]]; then
        log_message "\n    ${C_YELLOW}Timestamped Failure Log (Sample):${C_RESET}"
        local count_shown=0
        for flog in "${FAILURE_LOGS[@]}"; do
            log_message "      • ${flog}"
            ((count_shown++))
            [[ $count_shown -ge 8 ]] && break
        done
        if [[ ${#FAILURE_LOGS[@]} -gt 8 ]]; then
            log_message "      • ... and $(( ${#FAILURE_LOGS[@]} - 8 )) more failed events."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 6: Active Socket Telemetry & Kernel SNMP Deltas
# ------------------------------------------------------------------------------
diagnose_phase6_active_sockets_and_deltas() {
    print_sub_header "Phase 6: Kernel Socket Telemetry & Metric Deltas"

    # Active socket flow inspection
    if [[ -n "$PORT" ]] && command -v ss &>/dev/null; then
        local ss_out
        ss_out=$(ss -t -i -e "dst ${TARGET_IP}:${PORT}" 2>/dev/null || true)
        if [[ -n "$ss_out" ]]; then
            log_message "[*] Active Kernel TCP Socket Flows to ${TARGET_IP}:${PORT}:"
            echo "$ss_out" | head -n 6 | while read -r line; do
                log_message "    $line"
            done
        else
            log_message "[*] No active persistent TCP sockets currently connected to ${TARGET_IP}:${PORT}."
        fi
    fi

    # Compute SNMP / Netstat Deltas
    local snmp_after
    snmp_after=$(parse_kernel_snmp)
    
    local deltas=()
    local check_keys=(
        "Tcp_RetransSegs:TCP Segments Retransmitted (Packet Loss / Retransmit)"
        "Tcp_InErrs:TCP Inbound Packet Errors"
        "Tcp_OutRsts:TCP Reset Sent"
        "TcpExt_TCPTimeouts:TCP Retransmission Timeouts (Severe packet drop)"
        "TcpExt_TCPLostRetransmit:TCP Retransmission Lost"
        "TcpExt_TCPFastRetrans:TCP Fast Retransmissions (Packet reordering or single drops)"
        "TcpExt_TCPBacklogDrop:TCP Socket Backlog Queue Overflow Drops"
        "TcpExt_TCPReqQFullDrop:TCP SYN Listen Queue Full Drops"
    )

    for item in "${check_keys[@]}"; do
        local k="${item%%:*}"
        local desc="${item#*:}"
        local v_before
        local v_after
        v_before=$(get_snmp_val "$SNMP_BEFORE" "$k")
        v_after=$(get_snmp_val "$snmp_after" "$k")
        v_before=${v_before:-0}
        v_after=${v_after:-0}
        local diff=$(( v_after - v_before ))
        if [[ $diff -gt 0 ]]; then
            deltas+=("+${diff}|${desc}|${k}")
        fi
    done

    if [[ ${#deltas[@]} -gt 0 ]]; then
        log_message "\n[*] ${C_BOLD}Kernel TCP Events During Diagnostic Run:${C_RESET}"
        for d in "${deltas[@]}"; do
            local diff="${d%%|*}"
            local rest="${d#*|}"
            local desc="${rest%%|*}"
            local k="${rest#*|}"
            log_message "    • ${C_RED}${diff}${C_RESET} : ${desc} (${k})"
        done
    fi
}

# ------------------------------------------------------------------------------
# Diagnostic Phase 7: Automated Root Cause Diagnosis & Linux Fix Actions
# ------------------------------------------------------------------------------
generate_root_cause_diagnosis() {
    print_header "Comprehensive Diagnosis & Root Cause Analysis"

    local findings=()
    local recommendations=()

    # 1. Local Gateway Drop vs Remote Target Drop
    local gw_loss_int=0
    [[ -n "$GW_PING_LOSS" ]] && gw_loss_int=${GW_PING_LOSS%.*}
    local target_loss_int=0
    [[ -n "$TARGET_PING_LOSS" ]] && target_loss_int=${TARGET_PING_LOSS%.*}
    local drop_pct_int=0
    [[ -n "$DROP_PCT" ]] && drop_pct_int=${DROP_PCT%.*}

    if [[ $gw_loss_int -gt 0 ]]; then
        findings+=("${C_RED}|Local Default Gateway Packet Loss (${GW_PING_LOSS}%)|Packet drops originate at the first hop (Local Wi-Fi router, Ethernet cable, or LAN switch).")
        recommendations+=("• Check local LAN hardware: Swap Ethernet cable, restart Wi-Fi router, or inspect local AP channel congestion.")
    fi

    if [[ $gw_loss_int -eq 0 ]] && [[ $target_loss_int -gt 0 ]]; then
        findings+=("${C_YELLOW}|WAN / ISP / Remote Route Packet Loss (${TARGET_PING_LOSS}%)|Local LAN is healthy; packet loss occurs in upstream ISP transit or remote server firewall.")
        recommendations+=("• Check intermediate hop loss in Phase 3 MTR results to identify the offending upstream router.")
    fi

    # 2. Wi-Fi Power Save Check
    if [[ "$WIFI_POWER_SAVE" == "on" ]]; then
        findings+=("${C_YELLOW}|Wi-Fi Power Management Active (power_save=on)|Linux kernel puts wireless adapter to sleep during idle periods, introducing 100-300ms latency spikes and dropped SYN packets.")
        recommendations+=("• Disable Wi-Fi Power Saving immediately: \`sudo iw dev ${OUT_IFACE:-wlan0} set power_save off\`")
        recommendations+=("• Persist in NetworkManager: Add \`[connection]\nwifi.powersave = 2\` to \`/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf\` and restart NetworkManager.")
    fi

    # 3. TCP Handshake Drops vs ICMP Health
    if [[ -n "$PORT" ]]; then
        if [[ $drop_pct_int -gt 0 ]]; then
            findings+=("${C_RED}|TCP SYN Handshake Drop (${DROP_PCT}% drop rate - ${PROBES_TIMEOUT}/${PROBES_SENT} probes timed out)|Client sent TCP SYN packets but received no SYN-ACK. Indicates intermediate stateful firewall timeout, conntrack drop, or target SYN backlog saturation.")
            recommendations+=("• Target Server Backlog: Increase server listen queue via \`sysctl -w net.core.somaxconn=65535\` and \`sysctl -w net.ipv4.tcp_max_syn_backlog=65535\`.")
            recommendations+=("• TCP Keepalive Tuning: Prevent stateful firewall/NAT drop on idle connections: \`sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=10 net.ipv4.tcp_keepalive_probes=6\`.")
        fi

        if [[ "$PROBES_REFUSED" -gt 0 ]]; then
            findings+=("${C_YELLOW}|TCP Connection Refused (${PROBES_REFUSED} RST packets)|Target server or local firewall actively rejected connection on port ${PORT}. Service may be restarting, crashing, or hitting max worker limits.")
            recommendations+=("• Check service status on target server for port ${PORT} (e.g. systemctl status, Nginx/database worker limits).")
        fi

        if [[ "$target_loss_int" -eq 0 ]] && [[ $drop_pct_int -gt 0 ]]; then
            findings+=("${C_RED}|ICMP Healthy (0% loss) but TCP Port ${PORT} Dropping (${DROP_PCT}%)|L3 routing is healthy, but L4/Application layer is failing due to firewall rate-limiting or target server socket exhaustion.")
        fi
    fi

    # 4. Latency Jitter
    if [[ -n "$RTT_STDDEV" ]]; then
        local stddev_int=${RTT_STDDEV%.*}
        if [[ $stddev_int -ge 25 ]]; then
            findings+=("${C_YELLOW}|High TCP Latency Jitter (StdDev: ${RTT_STDDEV} ms, Min: ${RTT_MIN}ms, Max: ${RTT_MAX}ms)|Severe latency variance caused by bufferbloat, Wi-Fi interference, or CPU scheduling spikes.")
            recommendations+=("• Enable FQ / BBR Congestion Control: \`sysctl -w net.core.default_qdisc=fq\` and \`sysctl -w net.ipv4.tcp_congestion_control=bbr\`.")
        fi
    fi

    # 5. Kernel Softnet Backlog Drops
    if [[ "$SOFTNET_DROP" -gt 0 ]]; then
        findings+=("${C_RED}|Kernel CPU Softnet Drops (${SOFTNET_DROP} packets)|Kernel dropped incoming packets because CPU backlog queue (netdev_max_backlog) was full.")
        recommendations+=("• Increase netdev backlog: \`sysctl -w net.core.netdev_max_backlog=10000\`.")
    fi

    # 6. Conntrack Saturation
    if [[ -n "$CONNTRACK_USAGE_PCT" ]]; then
        local ct_int=${CONNTRACK_USAGE_PCT%.*}
        if [[ $ct_int -ge 85 ]]; then
            findings+=("${C_RED}|Conntrack State Table Saturation (${CONNTRACK_USAGE_PCT}%)|Linux connection tracking table is nearly full (${CONNTRACK_COUNT}/${CONNTRACK_MAX}). Packets will be dropped.")
            recommendations+=("• Increase conntrack table max: \`sysctl -w net.netfilter.nf_conntrack_max=$(( CONNTRACK_MAX * 2 ))\`.")
        fi
    fi

    # 7. Path MTU Reduced
    if [[ -n "$PATH_MTU" ]] && [[ "$PATH_MTU" -lt 1500 ]]; then
        findings+=("${C_YELLOW}|Reduced Path MTU (${PATH_MTU} bytes)|Path MTU is smaller than standard 1500 bytes. Large payload packets may be dropped if DF bit is set.")
        recommendations+=("• Enable TCP MTU Probing: \`sysctl -w net.ipv4.tcp_mtu_probing=1\` or clamp MSS in iptables.")
    fi

    # 8. DNS Flapping
    if [[ "$DNS_DROPS" -gt 0 ]]; then
        findings+=("${C_RED}|DNS Resolution Failures (${DNS_DROPS}/5 queries dropped)|Intermittent DNS timeouts observed.")
        recommendations+=("• Switch to reliable low-latency DNS resolvers (e.g., 1.1.1.1, 8.8.8.8) or inspect systemd-resolved.")
    fi

    # Print Findings
    if [[ ${#findings[@]} -gt 0 ]]; then
        log_message "${C_BOLD}Identified Issues & Root Causes:${C_RESET}"
        for f in "${findings[@]}"; do
            local f_col="${f%%|*}"
            local rest="${f#*|}"
            local f_title="${rest%%|*}"
            local f_desc="${rest#*|}"
            log_message "  ${f_col}▶ ${C_BOLD}${f_title}${C_RESET}"
            log_message "    ${f_desc}"
        done
    else
        log_message "  ${C_GREEN}${C_BOLD}✔ All diagnostic checks passed with 0% packet drop and healthy latency!${C_RESET}"
    fi

    # Print Recommendations
    log_message "\n${C_CYAN}${C_BOLD}Recommended Actionable Next Steps & Fixes:${C_RESET}"
    if [[ ${#recommendations[@]} -gt 0 ]]; then
        for r in "${recommendations[@]}"; do
            log_message "  $r"
        done
    else
        log_message "  • Network connectivity and port stability are healthy."
        log_message "  • If intermittent drops occur in production over long periods:"
        log_message "    1. Run this script in continuous duration mode: \`$0 -d ${TARGET} ${PORT:+-p $PORT} -T 300 -i 0.1 -o /tmp/drops.log\`"
        log_message "    2. Capture TCP RST / FIN packets with tcpdump: \`sudo tcpdump -nn -i any 'tcp[tcpflags] & (tcp-rst|tcp-fin) != 0 and host ${TARGET_IP}'\`"
    fi
}

# ------------------------------------------------------------------------------
# JSON Output Mode
# ------------------------------------------------------------------------------
generate_json_output() {
    cat << EOF
{
  "timestamp": "${START_TIME_ISO}",
  "version": "${VERSION}",
  "target": "${TARGET}",
  "target_ip": "${TARGET_IP}",
  "port": ${PORT:-null},
  "source_ip": "${SOURCE_IP:-null}",
  "interface": "${OUT_IFACE:-null}",
  "gateway": "${GATEWAY:-null}",
  "gateway_ping": {
    "loss_pct": ${GW_PING_LOSS:-null},
    "avg_rtt_ms": ${GW_RTT_AVG:-null}
  },
  "target_ping": {
    "loss_pct": ${TARGET_PING_LOSS:-null},
    "avg_rtt_ms": ${TARGET_RTT_AVG:-null}
  },
  "path_mtu": ${PATH_MTU:-null},
  "wifi": {
    "power_save": "${WIFI_POWER_SAVE:-null}",
    "signal": "${WIFI_SIGNAL_DBM:-null}",
    "bitrate": "${WIFI_BITRATE:-null}"
  },
  "nic_counters": {
    "rx_dropped": ${NIC_RX_DROP:-0},
    "tx_dropped": ${NIC_TX_DROP:-0},
    "rx_errors": ${NIC_RX_ERR:-0},
    "tx_errors": ${NIC_TX_ERR:-0}
  },
  "kernel_softnet": {
    "dropped": ${SOFTNET_DROP:-0},
    "squeezed": ${SOFTNET_SQUEEZE:-0}
  },
  "conntrack": {
    "count": ${CONNTRACK_COUNT:-0},
    "max": ${CONNTRACK_MAX:-0},
    "usage_pct": ${CONNTRACK_USAGE_PCT:-0}
  },
  "tcp_probe": {
    "probes_sent": ${PROBES_SENT:-0},
    "probes_success": ${PROBES_SUCCESS:-0},
    "probes_timeout": ${PROBES_TIMEOUT:-0},
    "probes_refused": ${PROBES_REFUSED:-0},
    "drop_pct": ${DROP_PCT:-0},
    "rtt_min_ms": ${RTT_MIN:-null},
    "rtt_avg_ms": ${RTT_AVG:-null},
    "rtt_max_ms": ${RTT_MAX:-null},
    "rtt_stddev_ms": ${RTT_STDDEV:-null},
    "max_consecutive_drops": ${MAX_BURST_DROPS:-0}
  }
}
EOF
}

# ------------------------------------------------------------------------------
# Interrupt (Ctrl+C) Handler
# ------------------------------------------------------------------------------
on_interrupt() {
    echo -e "\n\n${C_YELLOW}[!] Interrupted by user (SIGINT / Ctrl+C). Summarizing metrics gathered so far...${C_RESET}"
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        generate_json_output
    else
        diagnose_phase6_active_sockets_and_deltas
        generate_root_cause_diagnosis
    fi
    exit 0
}

trap on_interrupt SIGINT SIGTERM

# ------------------------------------------------------------------------------
# Main Entry Point
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    prompt_interactive
    resolve_target_ip "$TARGET"
    get_routing_info

    # Parse initial SNMP state
    SNMP_BEFORE=$(parse_kernel_snmp)

    if [[ "$JSON_OUTPUT" -eq 0 ]]; then
        print_header "Linux Network & Packet Drop Diagnostic: ${SOURCE_IP:-Default} -> ${TARGET_IP}${PORT:+:$PORT}"
        log_message "[*] Timestamp       : ${START_TIME_ISO}"
        log_message "[*] Source IP       : ${SOURCE_IP:-Auto-Bind}"
        log_message "[*] Target Host/IP  : ${TARGET} (${TARGET_IP})"
        log_message "[*] Target Port     : ${PORT:-'None (Pure Network Path Mode)'}"
        log_message "[*] Outgoing Dev    : ${OUT_IFACE:-Unknown} (Gateway: ${GATEWAY:-Direct/Unknown})"
        [[ -n "$OUTPUT_LOG" ]] && log_message "[*] Logging To File : ${OUTPUT_LOG}"

        diagnose_phase1_local_health
        diagnose_phase2_icmp_and_mtu
        diagnose_phase3_hop_trace
        diagnose_phase4_dns_health
        diagnose_phase5_tcp_probes
        diagnose_phase6_active_sockets_and_deltas
        generate_root_cause_diagnosis
    else
        # Silent execution in JSON mode
        diagnose_phase1_local_health >/dev/null 2>&1
        diagnose_phase2_icmp_and_mtu >/dev/null 2>&1
        diagnose_phase4_dns_health >/dev/null 2>&1
        diagnose_phase5_tcp_probes >/dev/null 2>&1
        generate_json_output
    fi
}

main "$@"
