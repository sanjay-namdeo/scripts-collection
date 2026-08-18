#!/usr/bin/env bash
set -e

DRIVER_URL="http://dell.archive.canonical.com/updates/pool/public/libf/libfprint-2-tod1-broadcom/libfprint-2-tod1-broadcom_5.15.285-5.15.010.0-0ubuntu2~22.04.1~oem1_amd64.deb"
DEB_FILE="/tmp/libfprint-2-tod1-broadcom.deb"

# Ensure script is run with sudo/root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Please run this script with sudo: sudo $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"

echo "=== 1. Checking Fingerprint Hardware ==="
if lsusb | grep -i "0a5c:584"; then
    echo "[+] Detected Broadcom ControlVault 3 sensor."
else
    echo "[!] Warning: Broadcom sensor (0a5c:584x) not found via lsusb. Continuing anyway..."
fi

echo ""
echo "=== 2. Updating Repositories and Installing Prerequisites ==="
apt update
apt install -y fprintd libpam-fprintd libfprint-2-tod1 wget

echo ""
echo "=== 3. Downloading and Installing Broadcom TOD Driver ==="
echo "Downloading driver from Canonical Dell OEM archives..."
wget -q --show-progress "$DRIVER_URL" -O "$DEB_FILE"

dpkg -i "$DEB_FILE" || apt-get install -f -y
rm -f "$DEB_FILE"

echo ""
echo "=== 4. Restarting Fingerprint Daemon ==="
systemctl restart fprintd

echo ""
echo "=== 5. Enabling PAM Fingerprint Authentication ==="
pam-auth-update --enable fingerprint

echo ""
echo "=== 6. Verifying Driver Setup ==="
if fprintd-list "$REAL_USER" 2>&1 | grep -iq "found"; then
    echo "[+] Fingerprint reader is active and detected by fprintd!"
else
    echo "[*] Driver installed. Device status:"
    fprintd-list "$REAL_USER" || true
fi

echo ""
echo "========================================================"
echo " Fingerprint login setup completed successfully!        "
echo "========================================================"
echo ""
echo "You can enroll your fingerprint now by running:"
echo "  fprintd-enroll"
echo ""
echo "Or configure it in Settings -> Users -> Fingerprint Login"
echo ""

# Prompt for immediate enrollment if running in an interactive terminal
if [ -t 0 ] && [ -n "$SUDO_USER" ]; then
    read -rp "Would you like to enroll a fingerprint for user '$SUDO_USER' right now? [y/N]: " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        su - "$SUDO_USER" -c "fprintd-enroll"
    fi
fi
