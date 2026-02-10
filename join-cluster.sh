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

# --- Dynamic Resource Calculation ---
# Calculate a recommended max pod limit based on available resources.
# Rules: ~10 pods per CPU core, ~10 pods per GB RAM. Do not exceed 110.

CPU_CORES=$(nproc)
# Get total memory in MB, convert to GB
TOTAL_MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

# Calculate theoretical limits
LIMIT_BY_CPU=$((CPU_CORES * 10))
LIMIT_BY_RAM=$((TOTAL_MEM_GB * 10))

# Find the lowest bottleneck
RECOMMENDED_PODS=$LIMIT_BY_CPU
if [ "$LIMIT_BY_RAM" -lt "$RECOMMENDED_PODS" ]; then
    RECOMMENDED_PODS=$LIMIT_BY_RAM
fi

# Enforce the Kubernetes hard limit of 110
if [ "$RECOMMENDED_PODS" -gt 110 ]; then
    RECOMMENDED_PODS=110
fi

# Ensure it doesn't calculate something absurdly low
if [ "$RECOMMENDED_PODS" -lt 10 ]; then
    RECOMMENDED_PODS=10
fi

echo "System Analysis:"
echo "- CPU Cores: $CPU_CORES"
echo "- Total RAM: ${TOTAL_MEM_GB}GB"
echo "- Recommended Max Pods: $RECOMMENDED_PODS"
echo ""

# --- Interactive Prompts ---
read -p "Enter the Control Plane IP Address (e.g., 192.168.1.10): " CONTROL_PLANE_IP
read -p "Enter the K3s Node Token: " K3S_TOKEN
read -p "Enter the maximum number of pods for this node [Default: $RECOMMENDED_PODS]: " MAX_PODS

# Set default max pods if input is empty
MAX_PODS=${MAX_PODS:-$RECOMMENDED_PODS}

# Validate required inputs aren't empty
if [ -z "$CONTROL_PLANE_IP" ] || [ -z "$K3S_TOKEN" ]; then
    echo "Error: Both IP Address and Token are required."
    exit 1
fi

# --- Configuration Variables ---
NFS_SERVER_PATH="/mnt/shared_storage" 
LOCAL_MOUNT_POINT="/mnt/nfs_clientshare"
TARGET_USER=${SUDO_USER:-$USER}

# Exit immediately if a command exits with a non-zero status
set -e

echo ""
echo "Starting setup for NFS Client and K3s Worker Node..."
echo "Target Control Plane: $CONTROL_PLANE_IP"
echo "Max Pods Limit: $MAX_PODS"
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

# Prompt with Git branch visibility
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
    # Using printf to safely append the line
    printf "%s:%s    %s   nfs auto,nofail,noatime,nolock,intr,tcp,actimeo=1800 0 0\n" "$CONTROL_PLANE_IP" "$NFS_SERVER_PATH" "$LOCAL_MOUNT_POINT" >> /etc/fstab
fi

# ------------------------------------------------------------------------------
# 3. Join K3s Cluster
# ------------------------------------------------------------------------------
echo "--- Step 3: Joining K3s Cluster ---"

echo "Downloading and running the K3s installation script..."
# Pass the max-pods argument to the K3s installer
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
         echo "[WARNING] NFS share is mounted, but write access failed. Check permissions on the Control Plane."
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