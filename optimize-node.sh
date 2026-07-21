#!/bin/bash

# ==============================================================================
# Headless & Resource Optimization for Existing k3s Nodes
# ==============================================================================
# Applies the Step 10 optimizations from join-cluster.sh to nodes that were
# joined before that step existed. Idempotent — safe to re-run.
# Requires root (run with sudo).
#
# Run on each node one at a time, waiting for `kubectl get nodes` to show
# Ready between reboots.
# ==============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)."
    exit 1
fi

echo "--- Headless & Resource Optimization ---"

# --- Switch to multi-user (no GUI) on next boot ---
CURRENT_TARGET=$(systemctl get-default)
if [ "$CURRENT_TARGET" = "graphical.target" ]; then
    echo "Switching default boot target to multi-user (headless)..."
    echo "  (GUI remains active for this session; takes effect on next reboot)"
    echo "  (To restore: sudo systemctl set-default graphical.target)"
    systemctl set-default multi-user.target
else
    echo "Already booting to $CURRENT_TARGET."
fi

# --- Disable desktop services that aren't useful on a k8s node ---
echo "Disabling unnecessary desktop services..."
DISABLE_SERVICES=(
    cups.service cups-browsed.service    # Printing
    avahi-daemon.service                 # mDNS/Bonjour
    ModemManager.service                 # Cellular modems
    bluetooth.service                    # Bluetooth
    switcheroo-control.service           # GPU switching
    whoopsie.service                     # Ubuntu error reporting
    kerneloops.service                   # Kernel oops reporting
)
for svc in "${DISABLE_SERVICES[@]}"; do
    [[ "$svc" == \#* ]] && continue
    if systemctl list-unit-files "$svc" &>/dev/null; then
        systemctl disable --now "$svc" 2>/dev/null && echo "  Disabled $svc" || true
    fi
done

# --- Remove snapd ---
if command -v snap &>/dev/null; then
    echo "Removing snapd (frees RAM, removes loopback mounts)..."
    snap list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r pkg; do
        snap remove --purge "$pkg" 2>/dev/null || true
    done
    apt-get autopurge -y snapd 2>/dev/null || apt-get purge -y snapd
    rm -rf /snap /var/snap /var/lib/snapd ~/snap
    cat > /etc/apt/preferences.d/no-snapd << 'NOSNAPEOF'
Package: snapd
Pin: release *
Pin-Priority: -1
NOSNAPEOF
    echo "snapd removed."
else
    echo "snapd not installed."
fi

# --- Cap journald storage ---
echo "Configuring journald storage limits..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf << 'JRNLEOF'
[Journal]
SystemMaxUse=500M
JRNLEOF
systemctl restart systemd-journald

# --- Ensure time sync ---
echo "Ensuring time synchronization is active..."
timedatectl set-ntp true 2>/dev/null || true
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
    echo "[SUCCESS] NTP is synchronized."
else
    echo "[INFO] NTP enabled — may take a moment to synchronize."
fi

# --- CPU microcode ---
echo "Installing CPU microcode updates..."
apt-get update -qq
if grep -q "GenuineIntel" /proc/cpuinfo; then
    apt-get install -y intel-microcode
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    apt-get install -y amd64-microcode
else
    echo "Unknown CPU vendor — skipping microcode."
fi

echo ""
echo "=============================================================================="
echo "Optimizations applied. A reboot is required to activate:"
echo "  - multi-user.target (drop the GUI)"
echo "  - CPU microcode updates"
echo "=============================================================================="
echo ""
read -p "Reboot now? [y/N]: " REBOOT_CONFIRM
if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot
else
    echo "Skipping reboot. Run 'sudo reboot' manually when ready."
fi
