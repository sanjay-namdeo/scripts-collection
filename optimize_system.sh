#!/usr/bin/env bash
set -e

echo "=== 1. Disabling NetworkManager-wait-online.service ==="
systemctl disable NetworkManager-wait-online.service || true

echo "=== 2. Setting swappiness to 10 ==="
sysctl vm.swappiness=10
echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf

echo "=== 4. Setting Snap retention limit to 2 & cleaning old revisions ==="
snap set system refresh.retain=2 || true
snap list --all | awk '/disabled/{print $1, $3}' | while read snapname revision; do
    if [ -n "$snapname" ] && [ -n "$revision" ]; then
        echo "Removing old snap: $snapname (rev $revision)"
        snap remove "$snapname" --revision="$revision" || true
    fi
done

echo "=== 5. Cleaning apt caches and running NVMe trim ==="
apt update
apt autoremove --purge -y
apt clean
fstrim -av

echo "=== 6. Vacumming system journal logs to 100M ==="
journalctl --vacuum-size=100M

echo "=== All optimizations applied successfully! ==="
