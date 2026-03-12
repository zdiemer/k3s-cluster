#!/bin/bash

# ==============================================================================
# Kubernetes Worker Node & NFS Client Setup Script
# ==============================================================================
# Run this script on new machines to join them to the cluster and mount the NAS.
# Requires root privileges (run with sudo).
#
# Usage: sudo ./join-cluster.sh [--driver-cache /path/to/debs]

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (using sudo)."
  exit 1
fi

# --- Parse CLI arguments ---
DRIVER_CACHE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver-cache)
            DRIVER_CACHE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo ./join-cluster.sh [--driver-cache /path/to/debs]"
            exit 1
            ;;
    esac
done

echo "=============================================================================="
echo "          K3s Worker Node & NFS Setup"
echo "=============================================================================="
echo ""

# ------------------------------------------------------------------------------
# 0. WiFi Driver Detection & Install
# ------------------------------------------------------------------------------
echo "--- Step 0: WiFi Driver Detection ---"

# Check if a wireless interface already exists
if iw dev 2>/dev/null | grep -q "Interface"; then
    echo "WiFi interface already detected. Skipping driver setup."
else
    # Check for Broadcom hardware
    BROADCOM_DEVICE=$(lspci -nn 2>/dev/null | grep "14e4" || true)
    if [ -n "$BROADCOM_DEVICE" ]; then
        echo "Broadcom wireless hardware detected:"
        echo "  $BROADCOM_DEVICE"
        echo ""

        if [ -n "$DRIVER_CACHE" ]; then
            # Offline install from pre-staged packages
            echo "Installing drivers from local cache: $DRIVER_CACHE"
            dpkg -i "$DRIVER_CACHE"/*.deb
        elif echo "$BROADCOM_DEVICE" | grep -q "43602"; then
            # BCM43602 uses brcmfmac (in-kernel) + firmware
            echo "BCM43602 detected — installing linux-firmware for brcmfmac driver..."
            apt-get update
            apt-get install -y linux-firmware
            modprobe brcmfmac 2>/dev/null || true
        else
            # Other Broadcom chips — try ubuntu-drivers first, fall back to bcmwl
            echo "Attempting ubuntu-drivers autoinstall..."
            if command -v ubuntu-drivers &>/dev/null && ubuntu-drivers autoinstall 2>/dev/null; then
                echo "ubuntu-drivers autoinstall succeeded."
            else
                echo "Falling back to manual bcmwl-kernel-source install..."
                apt-get update
                apt-get install -y bcmwl-kernel-source
            fi

            # Blacklist conflicting open-source drivers when using wl
            echo "Blacklisting conflicting drivers..."
            cat > /etc/modprobe.d/broadcom-blacklist.conf << 'BLEOF'
blacklist b43
blacklist b43legacy
blacklist ssb
blacklist bcma
blacklist brcmsmac
BLEOF
            modprobe wl 2>/dev/null || true
        fi

        # Install DKMS auto-rebuild hook for kernel upgrades
        echo "Installing DKMS auto-rebuild hook..."
        cat > /etc/apt/apt.conf.d/99-broadcom-dkms-rebuild << 'HOOKEOF'
DPkg::Post-Invoke { "dkms autoinstall || true"; };
HOOKEOF

        # Connect to WiFi automatically
        echo ""
        echo "WiFi driver installed. Waiting for wireless interface..."
        sleep 3

        WIFI_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
        if [ -z "$WIFI_IFACE" ]; then
            echo "[WARNING] No wireless interface found after driver install."
            echo "You may need to reboot. Continuing with current connection..."
        else
            echo "Wireless interface detected: $WIFI_IFACE"
            echo "Scanning for WiFi networks..."
            nmcli device wifi rescan ifname "$WIFI_IFACE" 2>/dev/null || true
            sleep 2

            mapfile -t WIFI_SSIDS < <(nmcli -t -f SSID,SIGNAL device wifi list ifname "$WIFI_IFACE" | grep -v '^:' | sort -t: -k2 -rn | awk -F: '!seen[$1]++ {print $1}')

            if [ ${#WIFI_SSIDS[@]} -eq 0 ]; then
                echo "No WiFi networks found. Entering SSID manually."
                read -p "Enter WiFi SSID: " WIFI_SSID
            else
                echo "Available WiFi Networks:"
                for i in "${!WIFI_SSIDS[@]}"; do
                    echo "  $((i+1)). ${WIFI_SSIDS[$i]}"
                done
                echo ""
                while true; do
                    read -p "Select a network (number) or type an SSID manually: " WIFI_SEL
                    if [[ "$WIFI_SEL" =~ ^[0-9]+$ ]] && [ "$WIFI_SEL" -ge 1 ] && [ "$WIFI_SEL" -le "${#WIFI_SSIDS[@]}" ]; then
                        WIFI_SSID="${WIFI_SSIDS[$((WIFI_SEL-1))]}"
                        break
                    elif [ -n "$WIFI_SEL" ]; then
                        WIFI_SSID="$WIFI_SEL"
                        break
                    else
                        echo "Invalid selection."
                    fi
                done
            fi

            read -s -p "Enter WiFi password for $WIFI_SSID: " WIFI_PASS
            echo ""

            echo "Connecting to $WIFI_SSID..."
            nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" ifname "$WIFI_IFACE"
            unset WIFI_PASS

            echo "Waiting for connectivity..."
            if nmcli networking connectivity check | grep -q "full"; then
                echo "[SUCCESS] WiFi connected."
            else
                # Give it a moment to get an IP
                sleep 5
                if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
                    echo "[SUCCESS] WiFi connected."
                else
                    echo "[WARNING] WiFi may not be fully connected. Continuing anyway..."
                fi
            fi
        fi
    else
        echo "No Broadcom wireless hardware detected. Skipping driver setup."
    fi
fi

echo ""

# ------------------------------------------------------------------------------
# 1. Tailscale Setup
# ------------------------------------------------------------------------------
echo "--- Step 1: Tailscale Configuration ---"

if ! command -v tailscale &> /dev/null; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "Tailscale is already installed."
fi

# Check if Tailscale is already connected
if ! tailscale status &> /dev/null; then
    read -p "Enter a Tailscale Auth Key (or press Enter to authenticate via browser): " TS_AUTH_KEY
    if [ -n "$TS_AUTH_KEY" ]; then
        echo "Authenticating Tailscale with Auth Key and enabling SSH..."
        tailscale up --authkey="$TS_AUTH_KEY" --ssh
    else
        echo "Starting Tailscale interactive authentication..."
        echo "Please click the link below to authenticate in your browser. The script will pause until you complete this step."
        tailscale up --ssh
    fi
else
    echo "Tailscale is already connected. Ensuring Tailscale SSH is enabled..."
    tailscale up --ssh
fi

echo ""

# ------------------------------------------------------------------------------
# 2. Control Plane Selection
# ------------------------------------------------------------------------------
echo "--- Step 2: Select Control Plane ---"
echo "Fetching available machines on your Tailnet..."

# Read tailscale status output, filtering out the header and offline machines
mapfile -t TAILSCALE_MACHINES < <(tailscale status | awk '/^[0-9]/ {print $1, $2}')

if [ ${#TAILSCALE_MACHINES[@]} -eq 0 ]; then
    echo "Error: No machines found on the Tailnet. Ensure Tailscale is connected."
    exit 1
fi

echo "Available Tailscale Machines:"
for i in "${!TAILSCALE_MACHINES[@]}"; do
    echo "$((i+1)). ${TAILSCALE_MACHINES[$i]}"
done

echo ""
while true; do
    read -p "Select the number corresponding to your Control Plane: " SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#TAILSCALE_MACHINES[@]}" ]; then
        SELECTED_INDEX=$((SELECTION-1))
        CONTROL_PLANE_IP=$(echo "${TAILSCALE_MACHINES[$SELECTED_INDEX]}" | awk '{print $1}')
        CONTROL_PLANE_HOSTNAME=$(echo "${TAILSCALE_MACHINES[$SELECTED_INDEX]}" | awk '{print $2}')
        echo "Selected Control Plane: $CONTROL_PLANE_HOSTNAME ($CONTROL_PLANE_IP)"
        break
    else
        echo "Invalid selection. Please enter a number between 1 and ${#TAILSCALE_MACHINES[@]}."
    fi
done
echo ""

# ------------------------------------------------------------------------------
# 3. SSH Token Fetch
# ------------------------------------------------------------------------------
echo "--- Step 3: Fetching K3s Token ---"

read -p "Enter your SSH username for $CONTROL_PLANE_HOSTNAME to auto-fetch the token via Tailscale: " SSH_USER

if [ -z "$SSH_USER" ]; then
    echo "Error: SSH Username is required."
    exit 1
fi

read -s -p "Enter the sudo password for $SSH_USER on the Control Plane: " REMOTE_SUDO_PW
echo ""

echo "Fetching K3s token from $CONTROL_PLANE_IP via SSH..."

K3S_TOKEN=$(echo "$REMOTE_SUDO_PW" | ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$CONTROL_PLANE_IP" "sudo -S cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '\r' | xargs)

unset REMOTE_SUDO_PW

if [ -z "$K3S_TOKEN" ]; then
    echo "Error: Failed to retrieve the K3s token."
    read -p "Paste the K3s Node Token manually: " K3S_TOKEN
else
    echo "[SUCCESS] Token retrieved."
fi

# ------------------------------------------------------------------------------
# 4. Resource Calculation
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 4: Resource Calculation ---"

CPU_CORES=$(nproc)
TOTAL_MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

LIMIT_BY_CPU=$((CPU_CORES * 10))
LIMIT_BY_RAM=$((TOTAL_MEM_GB * 10))

RECOMMENDED_PODS=$LIMIT_BY_CPU
if [ "$LIMIT_BY_RAM" -lt "$RECOMMENDED_PODS" ]; then
    RECOMMENDED_PODS=$LIMIT_BY_RAM
fi

if [ "$RECOMMENDED_PODS" -gt 110 ]; then RECOMMENDED_PODS=110; fi
if [ "$RECOMMENDED_PODS" -lt 10 ]; then RECOMMENDED_PODS=10; fi

echo "System Analysis:"
echo "- CPU Cores: $CPU_CORES"
echo "- Total RAM: ${TOTAL_MEM_GB}GB"
echo "- Recommended Max Pods: $RECOMMENDED_PODS"
echo ""

read -p "Enter the maximum number of pods for this node [Default: $RECOMMENDED_PODS]: " MAX_PODS
MAX_PODS=${MAX_PODS:-$RECOMMENDED_PODS}

# --- Configuration Variables ---
NFS_SERVER_PATH="/mnt/shared_storage"
LOCAL_MOUNT_POINT="/mnt/nfs_clientshare"
TARGET_USER=${SUDO_USER:-$USER}

# Exit immediately if a command exits with a non-zero status
set -e

# ------------------------------------------------------------------------------
# 5. Hostname Setup
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 5: Hostname Setup ---"

CURRENT_HOSTNAME=$(hostname)
echo "Current hostname: $CURRENT_HOSTNAME"
read -p "Enter desired hostname for this node [Default: $CURRENT_HOSTNAME]: " NEW_HOSTNAME
NEW_HOSTNAME=${NEW_HOSTNAME:-$CURRENT_HOSTNAME}

if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    echo "Setting hostname to $NEW_HOSTNAME..."
    hostnamectl set-hostname "$NEW_HOSTNAME"
else
    echo "Keeping current hostname."
fi

K3S_NODE_NAME="$NEW_HOSTNAME"

echo ""
echo "Starting setup for NFS Client and K3s Worker Node..."
echo ""

# ------------------------------------------------------------------------------
# 6. Server Environment Tuning
# ------------------------------------------------------------------------------
echo "--- Step 6: Configuring Server Settings ---"

# --- Disable swap ---
echo "Disabling swap..."
swapoff -a
sed -i '/\sswap\s/{/^#/!s/^/#/}' /etc/fstab

# --- Mask sleep/suspend targets ---
echo "Masking sleep and suspend targets..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# --- Lid switch & power key handling ---
echo "Configuring logind to ignore lid switch and power key..."
for SETTING in HandleLidSwitch HandleLidSwitchDocked HandleLidSwitchExternalPower HandlePowerKey; do
    sed -i "s/^#*${SETTING}=.*/${SETTING}=ignore/" /etc/systemd/logind.conf
    if ! grep -q "^${SETTING}=" /etc/systemd/logind.conf; then
        echo "${SETTING}=ignore" >> /etc/systemd/logind.conf
    fi
done
systemctl kill -s HUP systemd-logind

# --- Battery health (for laptops) ---
if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    echo "Laptop detected. Configuring battery health settings..."
    apt-get install -y tlp
    # Configure TLP to limit charge to 80% to preserve battery health
    # Note: Threshold support depends on hardware (e.g., ThinkPads, some Dells/HPs)
    if [ -f /etc/tlp.conf ]; then
        sed -i 's/^#START_CHARGE_THRESH_BAT0=.*/START_CHARGE_THRESH_BAT0=75/' /etc/tlp.conf
        sed -i 's/^#STOP_CHARGE_THRESH_BAT0=.*/STOP_CHARGE_THRESH_BAT0=80/' /etc/tlp.conf
        sed -i 's/^#START_CHARGE_THRESH_BAT1=.*/START_CHARGE_THRESH_BAT1=75/' /etc/tlp.conf
        sed -i 's/^#STOP_CHARGE_THRESH_BAT1=.*/STOP_CHARGE_THRESH_BAT1=80/' /etc/tlp.conf
    fi
    systemctl enable --now tlp
fi

# --- GRUB: console blanking & USB autosuspend ---
echo "Configuring GRUB kernel parameters..."
GRUB_FILE="/etc/default/grub"
GRUB_CHANGED=false

for PARAM in "consoleblank=0" "usbcore.autosuspend=-1"; do
    PARAM_NAME="${PARAM%%=*}"
    if ! grep -q "$PARAM" "$GRUB_FILE"; then
        sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${PARAM}\"/" "$GRUB_FILE"
        GRUB_CHANGED=true
    fi
done

if [ "$GRUB_CHANGED" = true ]; then
    echo "Updating GRUB..."
    update-grub
fi

# --- Unattended upgrades ---
echo "Installing and configuring unattended-upgrades..."
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades-local << 'UUEOF'
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF

# --- CPU governor ---
echo "Setting CPU governor to performance..."
apt-get install -y cpufrequtils
cat > /etc/default/cpufrequtils << 'CPUEOF'
GOVERNOR="performance"
CPUEOF
systemctl restart cpufrequtils 2>/dev/null || cpufreq-set -g performance 2>/dev/null || true

# --- Bash prompt with git integration ---
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
    echo "Applying bash prompt with git integration for $TARGET_USER..."
    BASHRC_PATH=$(eval echo ~$TARGET_USER/.bashrc)

    if ! grep -q "parse_git_branch" "$BASHRC_PATH"; then
        cat << 'EOF' >> "$BASHRC_PATH"

# Simplified prompt with Git branch visibility
parse_git_branch() {
     git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}
export PS1='\u@\h:\w\[\033[32m\]$(parse_git_branch)\[\033[00m\]$ '
EOF
    fi
fi

# ------------------------------------------------------------------------------
# 7. Storage & Longhorn Prerequisites
# ------------------------------------------------------------------------------
echo "--- Step 7: Configuring Storage & Longhorn Prerequisites ---"

echo "Installing nfs-common, open-iscsi, jq, and btop..."
apt-get update
apt-get install -y nfs-common open-iscsi jq btop

echo "Enabling and starting iscsid..."
systemctl enable --now iscsid

echo "Creating local mount directory at $LOCAL_MOUNT_POINT..."
mkdir -p "$LOCAL_MOUNT_POINT"

echo "Mounting NFS share from $CONTROL_PLANE_IP:$NFS_SERVER_PATH..."
mount -t nfs "$CONTROL_PLANE_IP:$NFS_SERVER_PATH" "$LOCAL_MOUNT_POINT"

if grep -q "$CONTROL_PLANE_IP:$NFS_SERVER_PATH" /etc/fstab; then
    echo "NFS entry already exists in /etc/fstab. Skipping."
else
    echo "Adding NFS mount to /etc/fstab for persistence..."
    printf "%s:%s    %s   nfs auto,nofail,noatime,nolock,intr,tcp,actimeo=1800 0 0\n" "$CONTROL_PLANE_IP" "$NFS_SERVER_PATH" "$LOCAL_MOUNT_POINT" >> /etc/fstab
fi

# ------------------------------------------------------------------------------
# 8. Join K3s Cluster
# ------------------------------------------------------------------------------
echo "--- Step 8: Joining K3s Cluster ---"

# Create systemd drop-in so k3s-agent waits for Tailscale
echo "Creating systemd drop-in for Tailscale dependency..."
mkdir -p /etc/systemd/system/k3s-agent.service.d
cat > /etc/systemd/system/k3s-agent.service.d/tailscale.conf << 'DROPEOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service
DROPEOF
systemctl daemon-reload

echo "Downloading and running the K3s installation script..."
curl -sfL https://get.k3s.io | \
    K3S_URL="https://$CONTROL_PLANE_IP:6443" \
    K3S_TOKEN="$K3S_TOKEN" \
    K3S_NODE_NAME="$K3S_NODE_NAME" \
    sh -s - \
    --kubelet-arg=max-pods="$MAX_PODS" \
    --kubelet-arg=eviction-hard="memory.available<256Mi,nodefs.available<1Gi" \
    --kubelet-arg=kube-reserved="cpu=100m,memory=256Mi" \
    --kubelet-arg=system-reserved="cpu=100m,memory=256Mi" \
    --protect-kernel-defaults=false

# ------------------------------------------------------------------------------
# 9. Verification
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 9: Verification ---"

echo "Verifying swap is disabled..."
if [ "$(swapon --show | wc -l)" -eq 0 ]; then
    echo "[SUCCESS] Swap is disabled."
else
    echo "[WARNING] Swap is still active."
fi

echo "Verifying Tailscale is running..."
if systemctl is-active --quiet tailscaled; then
    echo "[SUCCESS] Tailscale is running."
else
    echo "[WARNING] Tailscale service is not running."
fi

echo "Verifying NFS Mount..."
if mountpoint -q "$LOCAL_MOUNT_POINT"; then
    echo "[SUCCESS] NFS share is successfully mounted at $LOCAL_MOUNT_POINT."

    TEST_FILE="$LOCAL_MOUNT_POINT/.nfs_test_$(date +%s)"
    if touch "$TEST_FILE" 2>/dev/null; then
         echo "[SUCCESS] Write access to NFS share verified."
         rm "$TEST_FILE"
    else
         echo "[WARNING] NFS share is mounted, but write access failed."
    fi
else
    echo "[ERROR] NFS share failed to mount."
fi

echo "Verifying K3s Agent Service..."
if systemctl is-active --quiet k3s-agent; then
    echo "[SUCCESS] K3s agent service is running."
else
    echo "[ERROR] K3s agent service is not running. Check logs with: journalctl -u k3s-agent"
fi

echo ""
echo "=============================================================================="
echo "Setup and Verification Complete!"
echo "Verify cluster status by running: sudo k3s kubectl get nodes on the Control Plane."
echo "=============================================================================="
