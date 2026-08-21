#!/bin/bash

# ==============================================================================
# Headless & Resource Optimization for Existing k3s Nodes
# ==============================================================================
# Applies the Step 9 (watchdogs) and Step 10 (headless/resource) work from
# join-cluster.sh to nodes that never got it — either because they were joined
# before those steps existed, or because join-cluster.sh died at Step 8 and
# `set -e` took the rest of the run with it. A node that failed to join is the
# common case: Steps 0-7 land, everything after the k3s install does not.
# Idempotent — safe to re-run.
# Requires root (run with sudo).
#
# Battery watchdogs are deliberately not here; apply-battery.sh owns those.
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

# --- Container log rotation (via k3s config.yaml, merged on restart) ---
echo "Configuring container log rotation..."
mkdir -p /etc/rancher/k3s
if [ ! -f /etc/rancher/k3s/config.yaml ] || ! grep -q "container-log-max" /etc/rancher/k3s/config.yaml; then
    cat >> /etc/rancher/k3s/config.yaml << 'K3SCFGEOF'
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
K3SCFGEOF
    echo "  container-log-max written — takes effect on the next k3s restart."
else
    echo "  Already configured."
fi

# --- fstrim timer for SSD longevity ---
echo "Enabling weekly fstrim..."
systemctl enable fstrim.timer 2>/dev/null || true

# --- localepurge to strip unused locales ---
if ! dpkg -l localepurge 2>/dev/null | grep -q '^ii'; then
    echo "Installing localepurge..."
    echo "localepurge localepurge/nopurge multiselect en, en_US, en_US.UTF-8" | debconf-set-selections
    echo "localepurge localepurge/use-dpkg-feature boolean true" | debconf-set-selections
    echo "localepurge localepurge/none_selected boolean false" | debconf-set-selections
    echo "localepurge localepurge/verbose boolean false" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y localepurge
fi
localepurge 2>/dev/null || true

# ------------------------------------------------------------------------------
# Watchdog services (Step 9 of join-cluster.sh)
# ------------------------------------------------------------------------------
echo ""
echo "--- Watchdog Services ---"

# WiFi reconnect watchdog
cat > /usr/local/bin/wifi-watchdog << 'WIFIEOF'
#!/bin/bash
IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
[ -z "$IFACE" ] && exit 0
if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    logger -t wifi-watchdog "No connectivity on $IFACE — attempting reconnect"
    nmcli device disconnect "$IFACE" 2>/dev/null || true
    sleep 2
    nmcli device connect "$IFACE" 2>/dev/null || true
fi
WIFIEOF
chmod +x /usr/local/bin/wifi-watchdog

cat > /etc/systemd/system/wifi-watchdog.service << 'WIFISVCEOF'
[Unit]
Description=WiFi connectivity watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-watchdog
WIFISVCEOF

cat > /etc/systemd/system/wifi-watchdog.timer << 'WIFITIMEOF'
[Unit]
Description=Run WiFi watchdog every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
WIFITIMEOF

systemctl daemon-reload
systemctl enable --now wifi-watchdog.timer
echo "WiFi watchdog installed."

# Tailscale reconnect watchdog
cat > /usr/local/bin/tailscale-watchdog << 'TSEOF'
#!/bin/bash
if ! tailscale status &>/dev/null; then
    logger -t tailscale-watchdog "Tailscale unreachable — restarting tailscaled"
    systemctl restart tailscaled
fi
TSEOF
chmod +x /usr/local/bin/tailscale-watchdog

cat > /etc/systemd/system/tailscale-watchdog.service << 'TSSVCEOF'
[Unit]
Description=Tailscale connectivity watchdog
After=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-watchdog
TSSVCEOF

cat > /etc/systemd/system/tailscale-watchdog.timer << 'TSTIMEOF'
[Unit]
Description=Run Tailscale watchdog every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
TSTIMEOF

systemctl daemon-reload
systemctl enable --now tailscale-watchdog.timer
echo "Tailscale watchdog installed."

# --- GNOME desktop purge (opt-in) ---
if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qE '^(ubuntu-desktop|ubuntu-desktop-minimal|gnome-shell)$'; then
    echo ""
    read -p "Purge GNOME desktop packages? (frees ~2-3GB disk) [y/N]: " PURGE_GNOME
    if [[ "$PURGE_GNOME" =~ ^[Yy]$ ]]; then
        echo "Pinning network + firmware packages to prevent accidental removal..."
        apt-mark manual network-manager 2>/dev/null || true
        dpkg -l 'linux-firmware*' 2>/dev/null | awk '/^ii/{print $2}' | xargs -r apt-mark manual 2>/dev/null || true
        dpkg -l 'network-manager-*' 2>/dev/null | awk '/^ii/{print $2}' | xargs -r apt-mark manual 2>/dev/null || true

        echo "Packages that would be removed:"
        apt-get -s purge ubuntu-desktop ubuntu-desktop-minimal gnome-shell 2>&1 | grep -E "^(Remv|Purg)" | head -40
        echo ""
        read -p "Proceed with purge? [y/N]: " PURGE_CONFIRM
        if [[ "$PURGE_CONFIRM" =~ ^[Yy]$ ]]; then
            apt-get -y purge ubuntu-desktop ubuntu-desktop-minimal gnome-shell 2>/dev/null || true
            apt-get -y autoremove --purge 2>/dev/null || true
            echo "[SUCCESS] GNOME packages purged."
        fi
    fi
fi

echo ""
echo "=============================================================================="
echo "Optimizations applied. A reboot is required to activate:"
echo "  - multi-user.target (drop the GUI)"
echo "  - CPU microcode updates"
echo "  - container log rotation (applied when k3s next restarts)"
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
