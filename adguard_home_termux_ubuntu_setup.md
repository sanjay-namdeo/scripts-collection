# AdGuard Home Setup Guide for Termux Ubuntu (Moto G5)

This guide documents the complete process for setting up and running **AdGuard Home** as a 24/7 low-power network ad blocker on an unrooted Moto G5 (or any Android device) running Ubuntu inside Termux.

---

## 1. Prerequisites & Key Technical Details

* **Device**: Moto G5 (Snapdragon 430, ARMv8 / Cortex-A53)
* **Environment**: Termux + PRoot Ubuntu
* **Port Limitations on Unrooted Android**:
  * Unrooted Android prohibits apps from binding to **privileged ports (< 1024)** such as standard DNS (`53`) and HTTP (`80`).
  * **Solution**: Configure AdGuard Home to listen on unprivileged ports:
    * **Web UI Dashboard**: `8080` (or `3000`)
    * **DNS Listener**: `5353` (or other ports > 1024)

---

## 2. Step-by-Step Installation

### Step 2.1: Verify Architecture
Inside your Termux Ubuntu environment, check whether your userland is 64-bit or 32-bit:
```bash
uname -m
```
* If `aarch64` -> 64-bit ARM
* If `armv7l` or `armhf` -> 32-bit ARM

---

### Step 2.2: Install Required Packages and Download AdGuard Home
```bash
apt update && apt install -y curl tar net-tools tmux
```

**Download binary according to architecture:**

* **For 64-bit (`aarch64`):**
  ```bash
  curl -s -S -L https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_arm64.tar.gz -o AdGuardHome.tar.gz
  ```

* **For 32-bit (`armv7l` / `armhf`):**
  ```bash
  curl -s -S -L https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz -o AdGuardHome.tar.gz
  ```

**Extract the package:**
```bash
tar -xvf AdGuardHome.tar.gz
cd AdGuardHome
```

---

### Step 2.3: Create Initial Configuration (`AdGuardHome.yaml`)

To avoid the default `CAP_NET_BIND_SERVICE` permission error on startup, create an initial configuration file that specifies unprivileged ports:

```bash
cat << 'CONFIG_EOF' > /root/AdGuardHome/AdGuardHome.yaml
http:
  address: 0.0.0.0:8080
  session_ttl: 720h
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5353
  upstream_dns:
    - 1.1.1.1
    - 8.8.8.8
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  all_servers: false
  fastest_addr: false
  fastest_timeout: 1s
schema_version: 34
CONFIG_EOF
```

---

### Step 2.4: Launch AdGuard Home & Verify

Start AdGuard Home:
```bash
cd /root/AdGuardHome && ./AdGuardHome
```

Look for the log output confirming that the services have bound to the ports:
```text
[info] webapi: web server is listening on [::]:8080
[info] webapi: AdGuard Home is available at the following addresses:
[info] webapi: go to http://127.0.0.1:8080
[info] webapi: go to http://<YOUR-PHONE-IP>:8080
[info] dnsproxy: listening to udp addr=[::]:5353
[info] dnsproxy: listening to tcp addr=[::]:5353
```

Access the dashboard in your web browser:
```text
http://<PHONE-IP>:8080
```
*(e.g. `http://192.168.1.48:8080`)*

---

## 3. Running 24/7 in the Background

### 3.1: Prevent Android Sleep
In Termux (exit Ubuntu or in another session), run:
```bash
termux-wake-lock
```
*(Also ensure battery optimization is disabled for Termux in Android Settings -> Apps -> Termux -> Battery).*

---

### 3.2: Manage with `tmux`
Use `tmux` to keep AdGuard Home running after closing your terminal:

1. **Start a new tmux session:**
   ```bash
   tmux new -s adguard
   ```

2. **Run AdGuard Home inside the session:**
   ```bash
   cd /root/AdGuardHome && ./AdGuardHome
   ```

3. **Detach from the session:**
   * Press `Ctrl + B`, release, then press `D`.

4. **Re-attach anytime:**
   ```bash
   tmux attach -t adguard
   ```

---

## 4. Connecting Network Devices to AdGuard Home

Because AdGuard Home runs on port `5353` instead of the privileged port `53`:

1. **Router Port Forwarding / NAT Redirect (Recommended for Whole-Home Blocking)**:
   * If your router supports custom NAT/iptables rules (e.g. OpenWrt, DD-WRT, Asuswrt-Merlin):
     * Redirect outbound UDP/TCP port 53 traffic to `<PHONE-IP>:5353`.
2. **Encrypted DNS (DoH / DoT)**:
   * In the AdGuard Home Web UI under **Settings -> Encryption settings**, you can configure DNS-over-HTTPS (DoH) or DNS-over-TLS (DoT) on custom unprivileged ports (e.g. port `8443` or `8530`).
   * Configure modern browsers (Chrome/Firefox) and mobile devices to use your private DoH endpoint.
3. **If Device is Rooted (Direct Port 53)**:
   * Run Termux with `tsu` / `sudo` to allow AdGuard Home to listen on standard port `53`.

---

## 5. Recommended Blocklists

In the web interface (**Filters -> DNS blocklists -> Add blocklist**), add:
* **AdGuard DNS filter** (Default)
* **OISD (Small / Basic)**: `https://small.oisd.nl`
* **AdAway Default Blocklist**: `https://adaway.org/hosts.txt`
