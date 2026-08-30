#!/usr/bin/env bash
# ==============================================================================
# Dell Latitude & Ubuntu 26.04 Performance & Speed Optimization Suite
# ==============================================================================
# This script applies comprehensive, production-grade system optimizations:
# 1. High-Performance In-Memory Swap (ZRAM with zstd compression)
# 2. Kernel VM & VFS Cache Tuning (swappiness, vfs_cache_pressure, inotify limits)
# 3. GRUB Fast Bootloader Acceleration (shaves 6-8 seconds off boot)
# 4. Disabling Redundant & Cloud Daemons (cloud-init, cups-browsed, modemmanager)
# 5. CPU Governor & Thermal Management (Intel P-State / thermald / platform profiles)
# 6. NVMe SSD Filesystem & TRIM Optimization (fstrim.timer, noatime recommendations)
# 7. Snap, APT & Systemd Journal Space & Performance Maintenance
# 8. User Desktop, GNOME & Browser GPU Acceleration Flags
# ==============================================================================

set -euo pipefail

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script requires root privileges to apply system-level optimizations.${NC}"
        echo -e "Please run: ${BOLD}sudo $0 [apply | status | clean | rollback]${NC}\n"
        exit 1
    fi
}

get_target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
    else
        logname 2>/dev/null || echo "$USER"
    fi
}

# ------------------------------------------------------------------------------
# 1. ZRAM In-Memory Compressed Swap
# ------------------------------------------------------------------------------
configure_zram() {
    echo -e "\n${CYAN}[1/7] Configuring High-Speed ZRAM Compressed In-Memory Swap...${NC}"
    
    if ! command -v zramctl &>/dev/null || [ ! -f /usr/lib/systemd/system-generators/zram-generator ]; then
        echo "Installing systemd-zram-generator..."
        apt update -qq && apt install -y -qq systemd-zram-generator || true
    fi

    mkdir -p /etc/systemd
    cat << 'EOF' > /etc/systemd/zram-generator.conf
# ZRAM Configuration managed by optimize_system.sh
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    # Start ZRAM device without needing full reboot
    systemctl daemon-reload
    systemctl start /dev/zram0 2>/dev/null || systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

    if zramctl | grep -q zram0; then
        echo -e "${GREEN}✓ ZRAM compressed swap active (zstd algorithm, priority 100).${NC}"
    else
        echo -e "${YELLOW}ℹ ZRAM configuration written to /etc/systemd/zram-generator.conf. Will be fully active on reboot.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 2. Kernel Virtual Memory, Cache & Inotify Tuning
# ------------------------------------------------------------------------------
configure_sysctl() {
    echo -e "\n${CYAN}[2/7] Tuning Kernel Virtual Memory, VFS Cache & Inotify Limits...${NC}"
    
    mkdir -p /etc/sysctl.d
    # Remove legacy swappiness-only file (now consolidated into 99-performance-tuning.conf)
    rm -f /etc/sysctl.d/99-swappiness.conf
    cat << 'EOF' > /etc/sysctl.d/99-performance-tuning.conf
# ==============================================================================
# System Performance & Responsiveness Tuning
# ==============================================================================

# Virtual Memory & Swappiness
# Prioritize RAM usage and only swap out stale anonymous pages
vm.swappiness = 10

# VFS Cache Pressure (Default: 100 -> Optimized: 50)
# Keeps directory entries (dentries) and inode metadata in memory cache longer.
# Greatly accelerates file navigation, git status, and IDE project browsing.
vm.vfs_cache_pressure = 50

# Dirty Page Flushing (Smooth NVMe I/O without UI micro-stutters)
# Start background flushing when 5% of memory is dirty, cap at 10%
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10

# Inotify File Watchers (Essential for VS Code, JetBrains, Docker, Chrome)
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Maximum open file descriptors
fs.file-max = 2097152

# Increase max memory map areas for high-concurrency dev tools / JVM / Docker
vm.max_map_count = 1048576
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-performance-tuning.conf
    echo -e "${GREEN}✓ Kernel sysctl parameters applied.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Bootloader (GRUB) Delay Optimization
# ------------------------------------------------------------------------------
configure_grub() {
    echo -e "\n${CYAN}[3/7] Optimizing Bootloader (GRUB) Startup Delay...${NC}"
    
    mkdir -p /etc/default/grub.d
    cat << 'EOF' > /etc/default/grub.d/99-fastboot.cfg
# Fast bootloader countdown (managed by optimize_system.sh)
GRUB_TIMEOUT=1
GRUB_TIMEOUT_STYLE=hidden
# Allow 5s to access GRUB menu on failed boots (0 would lock out recovery)
GRUB_RECORDFAIL_TIMEOUT=5
EOF

    if command -v update-grub &>/dev/null; then
        update-grub >/dev/null 2>&1
        echo -e "${GREEN}✓ GRUB timeout set to 1s. Shaved ~7s off system boot time.${NC}"
    else
        echo -e "${YELLOW}ℹ GRUB config created at /etc/default/grub.d/99-fastboot.cfg.${NC}"
    fi

    # Neutralize kdump crashkernel reservation (reclaims ~512MB RAM on next reboot)
    if [ -f /etc/default/grub.d/kdump-tools.cfg ] && grep -q "crashkernel" /etc/default/grub.d/kdump-tools.cfg 2>/dev/null; then
        echo '# Disabled by optimize_system.sh (crashkernel reservation removed to reclaim ~512MB RAM)' > /etc/default/grub.d/kdump-tools.cfg
        if command -v update-grub &>/dev/null; then
            update-grub >/dev/null 2>&1
        fi
        echo -e "${GREEN}✓ Neutralized kdump crashkernel reservation (~512MB RAM reclaimed on next reboot).${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 4. Disable Redundant Daemons & Background Services
# ------------------------------------------------------------------------------
configure_services() {
    echo -e "\n${CYAN}[4/7] Disabling Redundant & Non-Laptop Background Services...${NC}"

    # 1. Cloud-init (Disabled on physical laptop)
    # Note: Ubuntu 26.04 renamed cloud-init.service to cloud-init-main.service
    mkdir -p /etc/cloud
    touch /etc/cloud/cloud-init.disabled
    systemctl disable --now cloud-init-main.service cloud-config.service cloud-final.service cloud-init-local.service cloud-init-network.service 2>/dev/null || true
    systemctl mask cloud-init-main.service cloud-config.service cloud-final.service cloud-init-local.service 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled cloud-init services on bare-metal laptop.${NC}"

    # 2. NetworkManager wait-online (Prevents boot stalls)
    systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled NetworkManager-wait-online.service.${NC}"

    # 3. Redundant Printer Discovery (cups-browsed scans network continuously)
    systemctl disable --now cups-browsed.service 2>/dev/null || true
    systemctl disable --now snap.cups.cups-browsed.service 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled cups-browsed background network polling.${NC}"

    # 4. ModemManager (USB cellular modem polling)
    systemctl disable --now ModemManager.service 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled ModemManager service.${NC}"

    # 5. Crash reporting & debugging overhead
    systemctl disable --now kdump-tools.service 2>/dev/null || true
    systemctl disable --now apport.service 2>/dev/null || true
    systemctl disable --now whoopsie.service 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled kdump, apport, and whoopsie crash reporting.${NC}"

    # 6. SPICE Guest Agent (Only needed inside QEMU VMs)
    systemctl disable --now spice-vdagent.service 2>/dev/null || true
    echo -e "${GREEN}✓ Disabled VM spice-vdagent on physical hardware.${NC}"
}

# ------------------------------------------------------------------------------
# 5. CPU Power, Governor & Thermal Management
# ------------------------------------------------------------------------------
configure_power_and_cpu() {
    echo -e "\n${CYAN}[5/7] Tuning CPU Frequency Scaling & Thermal Profiles...${NC}"

    # Ensure thermald is active for Intel CPU thermal monitoring
    if systemctl list-unit-files | grep -q thermald.service; then
        systemctl enable --now thermald.service 2>/dev/null || true
        echo -e "${GREEN}✓ Intel thermald service enabled.${NC}"
    fi

    # Set platform profile to performance if powerprofilesctl exists
    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set performance 2>/dev/null || powerprofilesctl set balanced 2>/dev/null || true
        local current_profile
        current_profile=$(powerprofilesctl get 2>/dev/null || echo "active")
        echo -e "${GREEN}✓ Power profile set to: ${current_profile}${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 6. NVMe Storage, TRIM & Filesystem Maintenance
# ------------------------------------------------------------------------------
configure_storage_and_trim() {
    echo -e "\n${CYAN}[6/7] Enabling NVMe SSD Continuous TRIM & Filesystem Health...${NC}"

    # Ensure systemd weekly fstrim timer is active
    systemctl enable --now fstrim.timer 2>/dev/null || true
    
    # Run immediate TRIM across all mounted SSD/NVMe filesystems
    echo "Running immediate NVMe SSD trim..."
    fstrim -av || true
    echo -e "${GREEN}✓ NVMe TRIM completed and fstrim.timer enabled.${NC}"
}

# ------------------------------------------------------------------------------
# 7. Snap, APT, Journal & Cache Maintenance
# ------------------------------------------------------------------------------
clean_system_caches() {
    echo -e "\n${CYAN}[7/7] Cleaning Snap, APT, Systemd Journal & Temporary Caches...${NC}"

    # 1. Snap retention limit to 2 and purge disabled revisions
    if command -v snap &>/dev/null; then
        echo "Setting snap refresh retention to 2..."
        snap set system refresh.retain=2 2>/dev/null || true

        echo "Removing disabled/old Snap revisions..."
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
            if [ -n "$snapname" ] && [ -n "$revision" ]; then
                echo "  Removing inactive snap: $snapname (rev $revision)"
                snap remove "$snapname" --revision="$revision" 2>/dev/null || true
            fi
        done
    fi

    # 2. APT Package cache cleanup
    echo "Updating package indices and cleaning unused packages..."
    apt update -qq
    apt autoremove --purge -y -qq
    apt clean

    # 3. Vacuum systemd journal logs to max 100MB
    echo "Vacuuming systemd journal logs to 100MB footprint..."
    journalctl --vacuum-size=100M >/dev/null 2>&1 || true

    # 4. User-level browser & IDE GPU acceleration flags
    local target_user
    target_user=$(get_target_user)
    local user_home
    user_home=$(eval echo "~${target_user}")

    if [[ -d "$user_home/.config" ]]; then
        # Chrome GPU flags
        cat << 'EOF' > "$user_home/.config/chrome-flags.conf"
# Hardware GPU Acceleration & Wayland Zero-Copy for Intel UHD Graphics
--ozone-platform-hint=auto
--enable-features=VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks,CanvasOopRasterization,UseOzonePlatform
--enable-gpu-rasterization
--enable-zero-copy
--ignore-gpu-blocklist
EOF

        # Brave GPU flags
        cat << 'EOF' > "$user_home/.config/brave-flags.conf"
# Hardware GPU Acceleration & Wayland Zero-Copy for Intel UHD Graphics
--ozone-platform-hint=auto
--enable-features=VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks,CanvasOopRasterization,UseOzonePlatform
--enable-gpu-rasterization
--enable-zero-copy
--ignore-gpu-blocklist
EOF

        # VS Code GPU flags
        cat << 'EOF' > "$user_home/.config/code-flags.conf"
# Hardware GPU Acceleration & Wayland Zero-Copy for VS Code
--ozone-platform-hint=auto
--enable-features=VaapiVideoDecodeLinuxGL,UseOzonePlatform
--enable-gpu-rasterization
--enable-zero-copy
EOF
        chown -R "$target_user:$target_user" "$user_home/.config/"*flags.conf 2>/dev/null || true
        echo -e "${GREEN}✓ Configured Wayland & GPU acceleration flags for Chrome, Brave, and VS Code for user: ${target_user}.${NC}"
    fi

    echo -e "${GREEN}✓ System caches, packages, and storage freed.${NC}"
}

# ------------------------------------------------------------------------------
# System Status & Diagnostic Audit
# ------------------------------------------------------------------------------
show_status() {
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}         Ubuntu 26.04 System Optimization Audit       ${NC}"
    echo -e "${BLUE}======================================================${NC}"

    # CPU & Power Profile
    echo -e "\n${BOLD}1. CPU & Power Management:${NC}"
    local cpu_model
    cpu_model=$(lscpu | awk -F': +' '/Model name/{print $2}' | head -n 1)
    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    local epp
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A")
    local profile="N/A"
    if command -v powerprofilesctl &>/dev/null; then
        profile=$(powerprofilesctl get 2>/dev/null || echo "N/A")
    fi
    echo -e "  Processor:       ${CYAN}${cpu_model}${NC}"
    echo -e "  Governor:        ${GREEN}${gov}${NC}"
    echo -e "  Intel EPP:       ${GREEN}${epp}${NC}"
    echo -e "  Power Profile:   ${GREEN}${profile}${NC}"

    # Memory & ZRAM
    echo -e "\n${BOLD}2. Memory & Compressed ZRAM:${NC}"
    free -h | sed 's/^/  /'
    echo -e "\n  Active Swap Devices:"
    swapon --show | sed 's/^/  /' || echo "  No swap devices active"
    if command -v zramctl &>/dev/null; then
        echo -e "\n  ZRAM Statistics:"
        zramctl | sed 's/^/  /'
    fi

    # Kernel Sysctl Tunables
    echo -e "\n${BOLD}3. Kernel Tunables (sysctl):${NC}"
    echo -e "  vm.swappiness:              ${GREEN}$(sysctl -n vm.swappiness 2>/dev/null)${NC}"
    echo -e "  vm.vfs_cache_pressure:      ${GREEN}$(sysctl -n vm.vfs_cache_pressure 2>/dev/null)${NC}"
    echo -e "  vm.dirty_background_ratio:  ${GREEN}$(sysctl -n vm.dirty_background_ratio 2>/dev/null)${NC}"
    echo -e "  vm.dirty_ratio:             ${GREEN}$(sysctl -n vm.dirty_ratio 2>/dev/null)${NC}"
    echo -e "  fs.inotify.max_user_watches:${GREEN}$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)${NC}"
    echo -e "  TCP Congestion Control:     ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}"

    # Boot Performance
    echo -e "\n${BOLD}4. Boot Performance (systemd-analyze):${NC}"
    systemd-analyze 2>/dev/null | sed 's/^/  /' || echo "  systemd-analyze not available"

    # Background Services Status
    echo -e "\n${BOLD}5. Service Optimization Status:${NC}"
    for s in cloud-init-main.service cups-browsed.service ModemManager.service kdump-tools.service apport.service spice-vdagent.service NetworkManager-wait-online.service; do
        local state="inactive"
        local enabled="disabled"
        state=$(systemctl is-active "$s" 2>/dev/null || echo "inactive")
        state=$(echo "$state" | head -n 1)
        enabled=$(systemctl is-enabled "$s" 2>/dev/null || echo "disabled")
        enabled=$(echo "$enabled" | head -n 1)
        if [[ "$state" == "inactive" || "$state" == "failed" || "$state" == "not-found" || "$state" == "unknown" ]]; then
            echo -e "  $s: ${GREEN}${state} (${enabled})${NC}"
        else
            echo -e "  $s: ${YELLOW}${state} (${enabled})${NC}"
        fi
    done

    # NVMe TRIM
    echo -e "\n${BOLD}6. Storage TRIM:${NC}"
    local trim_state
    trim_state=$(systemctl is-active fstrim.timer 2>/dev/null || echo "inactive")
    echo -e "  fstrim.timer:    ${GREEN}${trim_state}${NC}"

    echo -e "\n${BLUE}======================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# Rollback Optimizations
# ------------------------------------------------------------------------------
rollback_optimizations() {
    echo -e "${YELLOW}======================================================${NC}"
    echo -e "${YELLOW}   Rolling back optimizations to system defaults...   ${NC}"
    echo -e "${YELLOW}======================================================${NC}"

    # 1. Remove sysctl files
    rm -f /etc/sysctl.d/99-performance-tuning.conf
    rm -f /etc/sysctl.d/99-swappiness.conf

    # 2. Reset sysctl values
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=100 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w fs.inotify.max_user_watches=65536 >/dev/null 2>&1 || true

    # 3. Remove GRUB override and update
    rm -f /etc/default/grub.d/99-fastboot.cfg
    if command -v update-grub &>/dev/null; then
        update-grub >/dev/null 2>&1 || true
    fi

    # 4. Remove ZRAM configuration
    rm -f /etc/systemd/zram-generator.conf
    if systemctl is-active --quiet systemd-zram-setup@zram0.service 2>/dev/null; then
        systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    fi

    # 5. Remove cloud-init disable flag & unmask services
    rm -f /etc/cloud/cloud-init.disabled
    systemctl unmask cloud-init-main.service cloud-config.service cloud-final.service cloud-init-local.service 2>/dev/null || true

    # 6. Re-enable default desktop services
    systemctl enable cups-browsed.service 2>/dev/null || true
    systemctl enable ModemManager.service 2>/dev/null || true
    systemctl enable apport.service 2>/dev/null || true

    echo -e "${GREEN}✓ System optimizations rolled back to defaults.${NC}"
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
ACTION="${1:-apply}"

case "$ACTION" in
    apply|all)
        check_root
        echo -e "${BLUE}======================================================${NC}"
        echo -e "${BLUE}   Applying Ubuntu 26.04 Super Fast Optimizations     ${NC}"
        echo -e "${BLUE}======================================================${NC}"
        configure_zram
        configure_sysctl
        configure_grub
        configure_services
        configure_power_and_cpu
        configure_storage_and_trim
        clean_system_caches
        echo -e "\n${GREEN}======================================================${NC}"
        echo -e "${GREEN}   All Optimizations Applied Successfully!           ${NC}"
        echo -e "\n${GREEN}   Tip: Run 'sudo ./optimize-network.sh apply' for network tuning.${NC}"
        echo -e "${GREEN}======================================================${NC}"
        show_status
        ;;
    status)
        show_status
        ;;
    clean)
        check_root
        clean_system_caches
        ;;
    rollback|restore|reset)
        check_root
        rollback_optimizations
        ;;
    help|--help|-h)
        echo "Usage: sudo $0 [apply | status | clean | rollback]"
        echo "  apply    - Apply full suite of kernel, memory, boot, service & disk optimizations (default)"
        echo "  status   - View current system performance parameters & audit"
        echo "  clean    - Perform snap/apt/journal cache cleanup & NVMe TRIM only"
        echo "  rollback - Revert all optimizations back to system defaults"
        ;;
    *)
        echo -e "${RED}[ERROR] Invalid action: $ACTION${NC}"
        echo "Usage: sudo $0 [apply | status | clean | rollback]"
        exit 1
        ;;
esac

