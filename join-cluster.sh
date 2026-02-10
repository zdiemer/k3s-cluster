#!/bin/bash

# ==============================================================================
# Kubernetes Worker Node & NFS Client Setup Script
# ==============================================================================
# Run this script on new machines to join them to the cluster and mount the NAS.
# Requires root privileges (run with sudo).

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (using sudo)."
  exit 1
fi

echo "=============================================================================="
echo "          K3s Worker Node & NFS Setup"
echo "=============================================================================="
echo ""

# ------------------------------------------------------------------------------
# 0. Tailscale Setup & Control Plane Selection
# ------------------------------------------------------------------------------
echo "--- Step 0: Tailscale Configuration ---"

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
        echo "Authenticating Tailscale with Auth Key..."
        tailscale up --authkey="$TS_AUTH_KEY"
    else
        echo "Starting Tailscale interactive authentication."
        echo "Please click the link below to authenticate in your browser. The script will pause until you complete this step."
        tailscale up
    fi
else
    echo "Tailscale is already connected."
fi

echo ""
echo "--- Step 0.5: Select Control Plane ---"
echo "Fetching available machines on your Tailnet..."

# Read tailscale status output, filtering out the header and offline machines (optional, but good for cleanliness)
# Using mapfile to cleanly read lines into an array
mapfile -t TAILSCALE_MACHINES < <(tailscale status | awk '/^[0-9]/ {print $1, $2}')

if [ ${#TAILSCALE_MACHINES[@]} -eq 0 ]; then
    echo "Error: No machines found on the Tailnet. Ensure Tailscale is connected."
    exit 1
fi

echo "Available Tailscale Machines:"
# Print the array as a numbered menu
for i in "${!TAILSCALE_MACHINES[@]}"; do
    echo "$((i+1)). ${TAILSCALE_MACHINES[$i]}"
done

echo ""
# Loop until a valid selection is made
while true; do
    read -p "Select the number corresponding to your Control Plane: " SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "${#TAILSCALE_MACHINES[@]}" ]; then
        # Extract the IP address from the selected line
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

# --- Interactive Prompts (Continued) ---
# SSH Auto-Fetch for the Token
read -p "Enter your SSH username for $CONTROL_PLANE_HOSTNAME to auto-fetch the token via Tailscale: " SSH_USER

if [ -z "$SSH_USER" ]; then
    echo "Error: SSH Username is required."
    exit 1
fi

echo "Fetching K3s token from $CONTROL_PLANE_IP via SSH..."
echo "---------------------------------------------------"
echo "NOTE: You may see Tailscale authentication prompts or be asked for your Control Panel password here."
echo "---------------------------------------------------"

# Force SSH to run the command, output the result, and immediately terminate the session
# We use 'cat' directly if permissions allow, or 'sudo sh -c' to ensure it runs and exits
K3S_TOKEN=$(ssh "$SSH_USER@$CONTROL_PLANE_IP" "sudo sh -c 'cat /var/lib/rancher/k3s/server/node-token; exit'" </dev/null 2>/dev/null | tr -d '\r' | xargs)

if [ -z "$K3S_TOKEN" ]; then
    echo "Error: Failed to retrieve the K3s token automatically."
    echo "Please ensure you can SSH into $CONTROL_PLANE_IP and run 'sudo cat /var/lib/rancher/k3s/server/node-token'"
    
    # Fallback to manual entry if SSH fails or hangs
    read -p "Paste the K3s Node Token manually: " K3S_TOKEN
    if [ -z "$K3S_TOKEN" ]; then
        echo "Error: Token is required to proceed."
        exit 1
    fi
else
    echo "[SUCCESS] Token retrieved automatically."
fi

# --- Dynamic Resource Calculation ---
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

echo ""
echo "Starting setup for NFS Client and K3s Worker Node..."
echo ""

# ------------------------------------------------------------------------------
# 1. Server Environment Tuning
# ------------------------------------------------------------------------------
echo "--- Step 1: Configuring Server Settings ---"

echo "Masking sleep and suspend targets..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "Configuring logind to ignore lid switch..."
sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind

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
# 2. NFS Client Setup
# ------------------------------------------------------------------------------
echo "--- Step 2: Configuring NFS Client ---"

echo "Installing nfs-common..."
apt-get update
apt-get install -y nfs-common

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
# 3. Join K3s Cluster
# ------------------------------------------------------------------------------
echo "--- Step 3: Joining K3s Cluster ---"

echo "Downloading and running the K3s installation script..."
curl -sfL https://get.k3s.io | K3S_URL="https://$CONTROL_PLANE_IP:6443" K3S_TOKEN="$K3S_TOKEN" sh -s - --kubelet-arg=max-pods="$MAX_PODS"

# ------------------------------------------------------------------------------
# 4. Verification
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 4: Verification ---"
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