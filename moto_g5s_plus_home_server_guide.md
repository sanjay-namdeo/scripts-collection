# Turn a Moto G5s Plus into a 24/7 Linux Home Server & Ad Blocker

A complete guide to repurposing an old **Moto G5s Plus** (*Snapdragon 625, 3GB/4GB RAM, ARM64*) into a low-power home server running **AdGuard Home** (network-wide DNS ad-blocker), **SSH**, and other self-hosted utilities.

---

## 1. Specifications & Feasibility

* **CPU**: Qualcomm Snapdragon 625 (8x ARM Cortex-A53 @ 2.0 GHz, 64-bit / aarch64)
* **RAM**: 3GB or 4GB LPDDR3 (ample for DNS, VPN, lightweight web servers)
* **Storage**: 32GB / 64GB onboard + MicroSD expansion
* **Power Draw**: ~2–4W under light-to-medium load (built-in battery acts as a UPS)

---

## 2. Prerequisites & Initial Phone Setup

1. **Factory Reset** the phone to ensure clean storage and remove unnecessary background apps.
2. **Assign Static IP**:
   * Open your home router's admin panel.
   * Add a DHCP reservation / Static IP for the phone's MAC address (e.g., `192.168.1.50`).
3. **Android Settings Tweaks**:
   * **Developer Options**: Go to *Settings > About Phone*, tap *Build Number* 7 times. Under *Developer Options*, enable **Stay awake while charging**.
   * **Wi-Fi Sleep Policy**: Set Wi-Fi to **"Always on during sleep"**.
   * **Battery Optimization**: Set Termux (after installation) to **Not Optimized** / **Unrestricted** to prevent Android from killing background processes.

---

## 3. Environment Setup (Termux & SSH)

> [!IMPORTANT]
> Do **NOT** install Termux from the Google Play Store (outdated and broken). Download it from **[F-Droid](https://f-droid.org/en/packages/com.termux/)** or the official **[Termux GitHub Releases](https://github.com/termux/termux-app/releases)**.

### 3.1 Install and Update Termux
Open Termux on the phone and run:
```bash
pkg update && pkg upgrade -y
```

### 3.2 Acquire Wake Lock
Prevent the CPU from throttling into deep sleep when the screen turns off:
```bash
termux-wake-lock
```

### 3.3 Setup Remote SSH Access
1. Install OpenSSH and create a user password:
   ```bash
   pkg install openssh curl tar -y
   passwd
   ```
2. Start the SSH daemon:
   ```bash
   sshd
   ```
3. Find the phone's local IP address:
   ```bash
   ip a
   ```
4. Connect from your PC/laptop (Termux default SSH port is `8022`):
   ```bash
   ssh -p 8022 <phone-ip>
   ```

---

## 4. Install & Configure AdGuard Home

AdGuard Home is distributed as a single standalone ARM64 binary with a lightweight web management dashboard and DoH/DoT support.

### 4.1 Download the Binary
```bash
cd ~
curl -s -S -L https://static.adguard.com/adguardhome/release/AdGuardHome_linux_arm64.tar.gz -o AdGuardHome.tar.gz
tar -xzvf AdGuardHome.tar.gz
cd AdGuardHome
```

### 4.2 Running AdGuard Home

#### Option A: Rooted Phone (Recommended)
Root access allows binding directly to standard DNS port `53`:
```bash
su
./AdGuardHome
```

#### Option B: Non-Rooted Phone
On non-rooted Android, standard ports below 1024 are restricted:
```bash
./AdGuardHome
```
*During initial setup, set the DNS listening port to an unprivileged port (e.g. `5353`). Then configure port forwarding/redirection (`53` → `5353`) on your router or use PRoot.*

### 4.3 Web Dashboard Configuration
1. Open your browser on any device in the network and visit:
   ```text
   http://<phone-ip>:3000
   ```
2. Follow the setup wizard to create an admin account.
3. Configure upstream DNS servers (e.g., Quad9: `9.9.9.9`, Cloudflare: `1.1.1.1`).
4. Add blocklists (e.g., *OISD*, *AdAway*, *StevenBlack hosts*).
5. Once configured, access the dashboard at `http://<phone-ip>:80` (or your configured port).

### 4.4 Set Router DNS
In your home Wi-Fi router settings, update the **Primary DNS Server** in the DHCP section to the static IP of the Moto G5s Plus (`192.168.1.50`).

---

## 5. Auto-Start Services on Boot (Termux:Boot)

To ensure your server restarts automatically if the phone reboots:

1. Install **Termux:Boot** from F-Droid.
2. Launch the Termux:Boot app once to register permissions.
3. Create the startup script in Termux:
   ```bash
   mkdir -p ~/.termux/boot
   cat << 'EOF' > ~/.termux/boot/start-services.sh
   #!/data/data/com.termux/files/usr/bin/sh
   termux-wake-lock
   sshd
   # Start AdGuard Home in background
   /data/data/com.termux/files/home/AdGuardHome/AdGuardHome &
   EOF

   chmod +x ~/.termux/boot/start-services.sh
   ```

---

## 6. Additional Home Server Utilities

With its 8-core CPU and 3GB/4GB RAM, you can host additional lightweight services:

| Utility | Description | Installation in Termux |
| :--- | :--- | :--- |
| **Tailscale** | Mesh VPN to access your DNS & local network remotely | `pkg install tailscale` |
| **Syncthing** | Continuous, decentralized file synchronization | `pkg install syncthing` |
| **Caddy / Nginx** | Lightweight reverse proxy & HTTPS web server | `pkg install caddy` |
| **Python / Node.js** | Host Telegram bots, scrapers, and automation scripts | `pkg install python nodejs` |
| **Debian PRoot** | Run a full Debian distribution for standard Linux tools | `pkg install proot-distro && proot-distro install debian` |

---

## 7. Battery & Hardware Health Best Practices

> [!CAUTION]
> Keeping a lithium-ion battery plugged in at 100% permanently can cause battery swelling and thermal wear over time.

1. **Charge Limiting via ACC (Rooted)**:
   * Install the **ACC (Advanced Charging Controller)** Magisk module or CLI tool (`acc`).
   * Set charging thresholds to stop charging at 70% and resume at 60%:
     ```bash
     acc 70 60
     ```
2. **Smart Plug Automation (Non-Rooted)**:
   * Plug the charger into a Wi-Fi smart plug.
   * Automate it (via Home Assistant or smart plug schedule) to charge for 30 minutes every 4–6 hours, keeping battery capacity between 20% and 80%.
3. **Wired Network Adapter (Optional)**:
   * To eliminate Wi-Fi latency and jitter, use a **Micro-USB OTG Y-Cable** with external power input paired with a USB-to-Ethernet adapter.
