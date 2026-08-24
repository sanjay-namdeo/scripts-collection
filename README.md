# Scripts & Guides Collection

A curated collection of automation scripts, system performance tweaks, hardware configuration utilities, and self-hosting guides for Linux (Ubuntu/Debian) and Android environments.

---

## 📑 Repository Index

| File | Type | Description |
| :--- | :--- | :--- |
| [`diagnose-network-drops.sh`](./diagnose-network-drops.sh) | Bash Script | 100% Standalone zero-dependency network drop & packet loss diagnostic tool for Linux |
| [`diagnose_network_drops.py`](./diagnose_network_drops.py) | Python Script | Python companion diagnostic suite for packet drops, jitter, and kernel telemetry |
| [`optimize-network.sh`](./optimize-network.sh) | Bash Script | Tunes TCP BBR, network buffers, fast open, disables Wi-Fi power save, and configures fast DNS |
| [`optimize_system.sh`](./optimize_system.sh) | Bash Script | System maintenance: trims swap, cleans Snap/APT cache, vacuums journal logs, runs SSD trim |
| [`setup-fingerprint.sh`](./setup-fingerprint.sh) | Bash Script | Installs Broadcom ControlVault 3 TOD drivers and enables PAM fingerprint authentication |
| [`moto_g5s_plus_home_server_guide.md`](./moto_g5s_plus_home_server_guide.md) | Guide (Markdown) | Complete walkthrough to turn a Moto G5s Plus into a 24/7 AdGuard Home DNS & SSH server |
| [`fix-flickering.txt`](./fix-flickering.txt) | Guide (Text) | Step-by-step troubleshooting guide for laptop screen & brightness flickering in Ubuntu |
| [`gpt_sol_luna_orchestration.txt`](./gpt_sol_luna_orchestration.txt) | Reference / Prompt | Specification and prompt for multi-agent Codex orchestration architectures |

---

## 🛠️ Script Details & Usage

### 1. `optimize-network.sh`
### 1. `diagnose-network-drops.sh`
**Purpose**: Advanced standalone Linux network diagnostic tool to troubleshoot and isolate intermittent packet drops, latency jitter, and TCP connection failures. **100% zero external dependencies** (uses only standard Linux out-of-the-box utilities: `/dev/tcp`, `/proc`, `/sys`, `ip`, `ping`, `ss`, `awk`, `date`, `timeout`, `mtr`/`tracepath`).

#### Key Features:
- **LAN vs WAN Drop Isolation**: Concurrently probes default gateway and target IP to isolate if packet drops are local (Wi-Fi/Ethernet) or remote (ISP/Transit/Target).
- **Wi-Fi Power-Save & Link Diagnostics**: Detects if Linux Wi-Fi power saving (`power_save = on`) is active (the #1 cause of 100-300ms latency spikes and idle connection drops on laptops).
- **Hop-by-Hop Trace (MTR / Tracepath)**: Auto-detects and pinpoints the exact intermediate router dropping packets.
- **Port Transaction Probes**: Native sub-millisecond TCP handshake (`SYN -> SYN-ACK`) testing with failure burst pattern detection.
- **Continuous / Duration-based Monitoring (`-T`)**: Run for hours or minutes to capture sporadic, intermittent drops.
- **Timestamped Failure Logs**: Records precise ISO timestamps for every failed probe to correlate with router, firewall, or server logs.
- **Kernel Stack Health**: Audits CPU softnet backlog drops (`/proc/net/softnet_stat`), conntrack saturation, NIC ring buffer drops, and TCP retransmit deltas.
- **Actionable Remediation Engine**: Recommends exact Linux `sysctl`, `iw`, `ethtool`, and firewall commands to fix detected bottlenecks.

#### Usage:
```bash
# 1. Quick diagnostic of web host on port 443:
./diagnose-network-drops.sh -d google.com -p 443

# 2. General network path & gateway diagnosis without port:
./diagnose-network-drops.sh -d 1.1.1.1 -c 50

# 3. Continuous monitoring for 2 minutes (120s) to catch intermittent drops:
./diagnose-network-drops.sh -d 10.0.0.1 -p 8080 -T 120 -i 0.1 -o /tmp/network_drop.log

# 4. JSON telemetry for monitoring scripts:
./diagnose-network-drops.sh -d 192.168.1.1 -p 22 -c 10 --json
```

---

### 2. `optimize-network.sh`
**Purpose**: Maximizes network throughput and minimizes latency/jitter for Linux laptops and desktop systems.

#### Key Features:
- **TCP BBR**: Enables Google's BBR congestion control algorithm and Fair Queueing (`fq` qdisc).
- **Buffer & Stack Tuning**: Adjusts TCP read/write buffer maximums (up to 16MB), enables TCP Fast Open (`tcp_fastopen = 3`), and enables MTU probing.
- **Wi-Fi Latency Fix**: Disables Wi-Fi power saving mode via NetworkManager and `iw` to stop ping spikes and packet latency jitter.
- **DNS Acceleration**: Configures Cloudflare (`1.1.1.1`) and Google (`8.8.8.8`) DNS with DoT (DNS-over-TLS) support in `systemd-resolved`.
- **Full Rollback Support**: Reverts all settings cleanly to system defaults.

#### Usage:
```bash
# Apply all optimizations
sudo ./optimize-network.sh apply

# Check current status of TCP BBR, buffers, Wi-Fi power save, and DNS
sudo ./optimize-network.sh status

# Rollback changes back to system defaults
sudo ./optimize-network.sh rollback
```

---

### 2. `optimize_system.sh`
**Purpose**: Routine system maintenance and performance optimization for Ubuntu/Debian.

#### Key Features:
- **Boot Optimization**: Disables `NetworkManager-wait-online.service` to speed up system boot times.
- **Memory Tuning**: Sets `vm.swappiness=10` to prioritize physical RAM usage over swap space.
- **Snap Cleanup**: Sets Snap refresh retention limit to 2 and removes old, disabled Snap revisions to reclaim disk space.
- **Package Management Cleanup**: Updates apt repositories, purges orphaned packages (`autoremove --purge`), and clears apt cache.
- **Storage Maintenance**: Executes `fstrim -av` to optimize NVMe/SSD drive wear and speed.
- **Log Management**: Vacuums `systemd` journal logs to a maximum footprint of 100MB.

#### Usage:
```bash
sudo ./optimize_system.sh
```

---

### 3. `setup-fingerprint.sh`
**Purpose**: Automated installation of proprietary Broadcom ControlVault fingerprint reader drivers on Ubuntu (Dell laptops and compatible systems).

#### Key Features:
- Detects Broadcom ControlVault 3 sensors (`0a5c:584x` via `lsusb`).
- Installs `fprintd`, `libpam-fprintd`, and `libfprint-2-tod1`.
- Fetches and installs official Canonical Dell OEM `libfprint-2-tod1-broadcom` driver package.
- Enables PAM fingerprint authentication via `pam-auth-update`.
- Offers immediate interactive fingerprint enrollment (`fprintd-enroll`).

#### Usage:
```bash
sudo ./setup-fingerprint.sh
```

To enroll additional fingerprints after installation:
```bash
fprintd-enroll
```

---

## 📖 Guides & References

### 1. `moto_g5s_plus_home_server_guide.md`
A comprehensive guide for repurposing an old **Moto G5s Plus** (*Snapdragon 625, 3GB/4GB RAM*) as a low-power, 24/7 ARM64 Linux home server running:
- **Termux & SSH** for headless remote management.
- **AdGuard Home** for network-wide DNS ad-blocking and tracking protection.
- **Termux:Boot** for service persistence across reboots.
- **Battery Health Controls** via Advanced Charging Controller (ACC) or smart plugs.

### 2. `fix-flickering.txt`
Troubleshooting checklist for Ubuntu display/brightness flickering issues:
- Disabling ambient light sensor / automatic brightness in GNOME.
- Switching between Wayland and Xorg display servers.
- Disabling Panel Self Refresh (PSR) via kernel parameters (`i915.enable_psr=0` or `amdgpu.dcfeaturemask=0` in `/etc/default/grub`).
- Installing proprietary NVIDIA drivers via `ubuntu-drivers autoinstall`.

### 3. `gpt_sol_luna_orchestration.txt`
Specification and system prompt template for configuring multi-agent Codex orchestration, setting up lead orchestrators, subagent model-routing policies, and session turn-forking constraints.

---

## 🛡️ License & Contributing
Feel free to open issues or contribute additional utility scripts and optimizations to this collection.
