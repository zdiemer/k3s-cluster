#!/bin/bash

# ==============================================================================
# Kubernetes Node Setup Script
# ==============================================================================
# Run this script on new machines to join them to the cluster.
# Supports joining as either a worker (agent) or control plane (server) node.
# Requires root privileges (run with sudo).
#
# Usage: sudo ./join-cluster.sh [--driver-cache /path/to/debs] [--zram|--no-zram]

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (using sudo)."
  exit 1
fi

# --- Parse CLI arguments ---
DRIVER_CACHE=""
ENABLE_ZRAM=""  # "", "yes", "no" — empty means prompt with RAM-based default
while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver-cache)
            DRIVER_CACHE="$2"
            shift 2
            ;;
        --zram)
            ENABLE_ZRAM="yes"
            shift
            ;;
        --no-zram)
            ENABLE_ZRAM="no"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo ./join-cluster.sh [--driver-cache /path/to/debs] [--zram|--no-zram]"
            exit 1
            ;;
    esac
done

echo "=============================================================================="
echo "          K3s Cluster Node Setup"
echo "=============================================================================="
echo ""

# ------------------------------------------------------------------------------
# Shared: iSCSI initiator setup (mirrored in apply-updates.sh)
# ------------------------------------------------------------------------------
# Called from Step 7, after open-iscsi is installed. Idempotent.
configure_iscsi_initiator() {
    echo "Configuring iSCSI initiator..."

    # Every initiator on the network must have a unique IQN. Two nodes sharing
    # one will fight over sessions and corrupt them — a real risk when a node is
    # built by cloning another's disk. A node can only spot a missing name
    # locally; cross-node duplicate detection needs a cluster view and lives in
    # selfhosted/scripts/k3s/iscsi-prereq.sh.
    if [ ! -s /etc/iscsi/initiatorname.iscsi ] || \
       ! grep -q '^InitiatorName=iqn\.' /etc/iscsi/initiatorname.iscsi; then
        echo "  Generating initiator IQN..."
        echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
        chmod 600 /etc/iscsi/initiatorname.iscsi
    fi

    # Log back into targets automatically after a reboot, otherwise volumes only
    # reattach when something forces a re-login.
    sed -i 's/^node\.startup\s*=.*/node.startup = automatic/' /etc/iscsi/iscsid.conf
    grep -q '^node\.startup' /etc/iscsi/iscsid.conf || \
        echo 'node.startup = automatic' >> /etc/iscsi/iscsid.conf

    # How long I/O stalls before errors are returned upward. The 120s default
    # read-onlys every ext4 volume over a brief NAS blip; 300s rides out a reboot
    # or short maintenance while still failing in a bounded time on a genuine
    # hardware failure. Planned NAS windows should still be quiesced with
    # selfhosted/scripts/k3s/nas-maintenance.sh rather than relying on this.
    sed -i 's/^node\.session\.timeo\.replacement_timeout\s*=.*/node.session.timeo.replacement_timeout = 300/' \
        /etc/iscsi/iscsid.conf
    grep -q '^node\.session\.timeo\.replacement_timeout' /etc/iscsi/iscsid.conf || \
        echo 'node.session.timeo.replacement_timeout = 300' >> /etc/iscsi/iscsid.conf

    # Shield iscsid from the OOM killer. This is not paranoia: iscsid was
    # oom-killed on zachd-ubuntu on 2026-08-06, and a dead iscsid takes every
    # iSCSI volume on that node read-only — worse than losing almost any
    # workload the killer might have picked instead. Storage infrastructure gets
    # the same treatment as kubelet and containerd. -1000 means never.
    mkdir -p /etc/systemd/system/iscsid.service.d
    cat > /etc/systemd/system/iscsid.service.d/oom.conf << 'ISCSIOOMEOF'
[Service]
OOMScoreAdjust=-1000
ISCSIOOMEOF
    systemctl daemon-reload

    systemctl enable --now iscsid open-iscsi 2>/dev/null || true

    echo "  [OK] $(grep '^InitiatorName=' /etc/iscsi/initiatorname.iscsi)"
}

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
# 2b. Node Role Selection
# ------------------------------------------------------------------------------
echo "--- Step 2b: Node Role ---"
echo ""
echo "How should this node join the cluster?"
echo "  1. Worker (agent) — runs workloads only"
echo "  2. Control Plane (server) — runs etcd + API server + workloads"
echo ""
echo "NOTE: Joining as a control plane node requires the existing control plane"
echo "      to be running with --cluster-init (embedded etcd)."
echo ""

while true; do
    read -p "Select node role [1]: " ROLE_SELECTION
    ROLE_SELECTION=${ROLE_SELECTION:-1}
    if [ "$ROLE_SELECTION" = "1" ]; then
        NODE_ROLE="agent"
        echo "This node will join as a Worker (agent)."
        break
    elif [ "$ROLE_SELECTION" = "2" ]; then
        NODE_ROLE="server"
        echo "This node will join as a Control Plane (server)."
        break
    else
        echo "Invalid selection. Please enter 1 or 2."
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

# Join at the control plane's k3s version, not whatever upstream "stable" is
# today — an unpinned install can put a fresh node a minor ahead of the fleet.
# Override with INSTALL_K3S_VERSION=... for a deliberate version.
if [ -z "${INSTALL_K3S_VERSION:-}" ]; then
    INSTALL_K3S_VERSION=$(ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$CONTROL_PLANE_IP" "k3s --version" 2>/dev/null | head -1 | awk '{print $3}')
fi
if [ -z "$INSTALL_K3S_VERSION" ]; then
    echo "Error: could not detect the control plane's k3s version."
    read -p "Enter the k3s version to install (e.g. v1.34.6+k3s1): " INSTALL_K3S_VERSION
fi
echo "Joining with k3s $INSTALL_K3S_VERSION"

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
echo "Starting setup for K3s ${NODE_ROLE} node..."
echo ""

# ------------------------------------------------------------------------------
# 6. Server Environment Tuning
# ------------------------------------------------------------------------------
echo "--- Step 6: Configuring Server Settings ---"

# --- Disable disk swap ---
echo "Disabling disk swap..."
swapoff -a
sed -i '/\sswap\s/{/^#/!s/^/#/}' /etc/fstab

# --- Optional: zram swap (compressed in-RAM) ---
# Absorbs short-lived memory spikes (e.g. browser child processes inside
# scraper pods) by compressing cold pages with zstd instead of writing them
# to disk. Costs CPU on each page-in/page-out; net win for low-RAM nodes.
if [ "$TOTAL_MEM_GB" -le 8 ]; then
    ZRAM_DEFAULT="y"
else
    ZRAM_DEFAULT="n"
fi

if [ "$ENABLE_ZRAM" = "yes" ]; then
    ZRAM_CHOICE="y"
elif [ "$ENABLE_ZRAM" = "no" ]; then
    ZRAM_CHOICE="n"
else
    read -p "Enable zram swap (compressed in-RAM)? Recommended on <=8GB nodes. [y/N, default: $ZRAM_DEFAULT]: " ZRAM_CHOICE
    ZRAM_CHOICE=${ZRAM_CHOICE:-$ZRAM_DEFAULT}
fi

ZRAM_ENABLED=false
if [[ "$ZRAM_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Configuring zram swap (zstd, ram/2)..."
    apt-get install -y systemd-zram-generator
    cat > /etc/systemd/zram-generator.conf << 'ZRAMEOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMEOF
    systemctl daemon-reload
    # systemd-zram-generator wires up systemd-zram-setup@zram0.service.
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || \
        systemctl start dev-zram0.swap 2>/dev/null || true
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; then
        echo "[SUCCESS] zram swap active."
        ZRAM_ENABLED=true
    else
        echo "[WARNING] zram configured but not active yet — will start on next boot."
        ZRAM_ENABLED=true
    fi
fi

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

# --- NetworkManager: always restart ---
# Memory pressure or a kernel stall can starve systemd long enough for its
# bus calls to time out; on recovery it concludes dbus-using services are
# dead and SIGTERMs them. NM exits 0 (clean), and the default
# Restart=on-failure does not catch a clean exit — leaving the node LAN-less
# until manual intervention. Force a restart on any exit.
echo "Configuring NetworkManager always-restart drop-in..."
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/restart.conf << 'NMRSTEOF'
[Service]
Restart=always
RestartSec=5s
NMRSTEOF

# tailscaled has the same exposure: default Restart=on-failure, but the
# dbus-cascade SIGTERMs cause a clean exit (or leave the process alive
# but stalled with "subscriber slow Xm elapsed" / DNS timeouts seen on
# 2026-05-08). Force a restart on any exit, including hangs detected by
# WatchdogSec at the unit level if/when systemd watchdog is enabled.
echo "Configuring tailscaled always-restart drop-in..."
mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/restart.conf << 'TSRSTEOF'
[Service]
Restart=always
RestartSec=5s
TSRSTEOF
systemctl daemon-reload

# --- Battery health (for laptops) ---
if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    echo "Laptop detected. Configuring battery health settings..."
    apt-get install -y tlp

    # Set TLP charge thresholds in config (for hardware TLP natively supports)
    if [ -f /etc/tlp.conf ]; then
        for VAR in START_CHARGE_THRESH_BAT0=75 STOP_CHARGE_THRESH_BAT0=80 \
                   START_CHARGE_THRESH_BAT1=75 STOP_CHARGE_THRESH_BAT1=80 \
                   TLP_DEFAULT_MODE=AC TLP_PERSISTENT_DEFAULT=1; do
            KEY="${VAR%%=*}"
            if grep -q "^${KEY}=" /etc/tlp.conf; then
                sed -i "s/^${KEY}=.*/${VAR}/" /etc/tlp.conf
            elif grep -q "^#${KEY}=" /etc/tlp.conf; then
                sed -i "s/^#${KEY}=.*/${VAR}/" /etc/tlp.conf
            else
                echo "$VAR" >> /etc/tlp.conf
            fi
        done
    fi
    systemctl enable --now tlp

    CHARGE_CONFIGURED=false

    # --- Dell SMBIOS battery control ---
    # Dell laptops need smbios-battery-ctl for real charge limiting;
    # sysfs threshold files accept writes but the firmware ignores them.
    if dmidecode -s system-manufacturer 2>/dev/null | grep -qi dell; then
        echo "Dell detected. Setting charge mode via SMBIOS..."
        apt-get install -y smbios-utils 2>/dev/null
        if command -v smbios-battery-ctl >/dev/null 2>&1; then
            smbios-battery-ctl --set-charging-mode=custom 2>/dev/null
            smbios-battery-ctl --set-custom-charge-interval 75 80 2>/dev/null
            CFG=$(smbios-battery-ctl --get-charging-cfg 2>/dev/null)
            if echo "$CFG" | grep -q "custom"; then
                echo "[SUCCESS] Dell charge mode: custom (75-80%)"
                CHARGE_CONFIGURED=true
            else
                echo "[WARNING] Dell SMBIOS charge config failed."
            fi
        fi
    fi

    # --- Direct sysfs thresholds (non-Dell hardware) ---
    if [ "$CHARGE_CONFIGURED" = false ]; then
        for BAT_PATH in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
            [ -d "$BAT_PATH" ] || continue
            START_FILE="$BAT_PATH/charge_control_start_threshold"
            END_FILE="$BAT_PATH/charge_control_end_threshold"
            # Only the end threshold is required: plenty of ECs (the Grunt/Galtic
            # Chromebooks, for one) expose end but no start. Requiring both meant
            # those machines fell through and charged to 100% forever.
            if [ -f "$END_FILE" ]; then
                if echo 80 > "$END_FILE" 2>/dev/null; then
                    [ -f "$START_FILE" ] && echo 75 > "$START_FILE" 2>/dev/null
                    CHARGE_CONFIGURED=true
                    echo "[SUCCESS] Set charge thresholds on $(basename "$BAT_PATH"): 75-80%"
                fi
            fi
        done
        if [ "$CHARGE_CONFIGURED" = true ]; then
            cat > /etc/systemd/system/battery-threshold.service << 'BATEOF'
[Unit]
Description=Apply battery charge thresholds
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  for bat in /sys/class/power_supply/BAT*; do \
    [ -f "$bat/charge_control_end_threshold" ] || continue; \
    echo 80 > "$bat/charge_control_end_threshold" 2>/dev/null; \
    [ -f "$bat/charge_control_start_threshold" ] && \
      echo 75 > "$bat/charge_control_start_threshold" 2>/dev/null; \
  done; exit 0'

[Install]
WantedBy=multi-user.target
BATEOF
            systemctl enable battery-threshold.service
            echo "Installed battery-threshold.service for boot persistence."
        fi
    fi

    # --- Apple SMC BCLM + ACEN drain ---
    # Intel Macs: BCLM caps charge level (persists in NVRAM), ACEN toggles
    # AC power to force drain. Standard SMC write cmd (0x02) is firmware-locked;
    # cmd 0x11 works. Requires a kernel module since the applesmc driver
    # doesn't expose key writes via sysfs.
    if [ "$CHARGE_CONFIGURED" = false ] \
        && [ -d /sys/devices/platform/applesmc.768 ]; then
        echo "Apple SMC detected. Setting BCLM charge limit via kernel module..."
        SMC_BUILD_DIR=$(mktemp -d)
        cat > "$SMC_BUILD_DIR/smc_rw.c" << 'SMCEOF'
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/ioport.h>
#include <linux/io.h>
#include <linux/delay.h>

#define SMC_PORT_BASE 0x0300
#define SMC_PORT_DATA 0x0300
#define SMC_PORT_CMD  0x0304
#define SMC_NUM_PORTS 32
#define SMC_CMD_WRITE 0x11
#define SMC_CMD_READ  0x10
#define SMC_MAX_WAIT  50000

static char *key = "BCLM";
module_param(key, charp, 0);
static int value = 80;
module_param(value, int, 0);

static int wait_status(u8 mask, u8 val)
{
	int i; u8 s = 0;
	for (i = 0; i < SMC_MAX_WAIT; i++) {
		s = inb(SMC_PORT_CMD);
		if ((s & mask) == val) return 0;
		udelay(10);
	}
	return -EIO;
}

static int smc_send_byte(u8 c, u16 port)
{
	int ret = wait_status(0x02, 0x00);
	if (ret) return ret;
	outb(c, port);
	return 0;
}

static int smc_rw(u8 cmd, const char *k, u8 *buf, u8 l, int is_read)
{
	int i, ret;
	ret = smc_send_byte(cmd, SMC_PORT_CMD);
	if (ret) return ret;
	for (i = 0; i < 4; i++) {
		ret = smc_send_byte(k[i], SMC_PORT_DATA);
		if (ret) return ret;
	}
	ret = smc_send_byte(l, SMC_PORT_DATA);
	if (ret) return ret;
	for (i = 0; i < l; i++) {
		if (is_read) {
			ret = wait_status(0x01, 0x01);
			if (ret) return ret;
			buf[i] = inb(SMC_PORT_DATA);
		} else {
			ret = smc_send_byte(buf[i], SMC_PORT_DATA);
			if (ret) return ret;
		}
	}
	return 0;
}

static int __init smc_init(void)
{
	u8 buf[1], check[1] = {0};
	unsigned long flags;
	char k[5] = {0};

	if (value < 0 || value > 100) return -EINVAL;
	strscpy(k, key, 5);

	if (!request_region(SMC_PORT_BASE, SMC_NUM_PORTS, "smc_rw"))
		return -EBUSY;

	buf[0] = (u8)value;
	local_irq_save(flags);

	smc_rw(SMC_CMD_READ, k, check, 1, 1);
	pr_info("smc_rw: %s before = %d\n", k, check[0]);
	udelay(500);

	smc_rw(SMC_CMD_WRITE, k, buf, 1, 0);
	udelay(500);

	smc_rw(SMC_CMD_READ, k, check, 1, 1);
	pr_info("smc_rw: %s after = %d %s\n", k, check[0],
		check[0] == (u8)value ? "SUCCESS" : "UNCHANGED");

	local_irq_restore(flags);
	release_region(SMC_PORT_BASE, SMC_NUM_PORTS);
	return -EAGAIN;
}

static void __exit smc_exit(void) {}
module_init(smc_init);
module_exit(smc_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Write Apple SMC key via IO ports (cmd 0x11)");
SMCEOF

        cat > "$SMC_BUILD_DIR/Makefile" << 'SMCMKEOF'
obj-m := smc_rw.o
KDIR := /lib/modules/$(shell uname -r)/build
all:
	make -C $(KDIR) M=$(PWD) modules
SMCMKEOF

        HEADERS_PKG="linux-headers-$(uname -r)"
        if ! dpkg -l | grep -q "$HEADERS_PKG"; then
            echo "Installing kernel headers for module build..."
            apt-get install -y "$HEADERS_PKG"
        fi

        if make -C "$SMC_BUILD_DIR" 2>/dev/null; then
            SMC_MOD="$SMC_BUILD_DIR/smc_rw.ko"

            # Helper to load the module for a single key write
            smc_write_key() {
                rmmod applesmc 2>/dev/null; sleep 1
                insmod "$SMC_MOD" key="$1" value="$2" 2>/dev/null
                modprobe applesmc 2>/dev/null
            }

            # Set BCLM (charge level max, persists in NVRAM)
            smc_write_key BCLM 80
            RESULT=$(dmesg | grep "smc_rw: BCLM after" | tail -1)
            if echo "$RESULT" | grep -q "SUCCESS"; then
                echo "[SUCCESS] Apple SMC BCLM set to 80%."
                CHARGE_CONFIGURED=true
            else
                echo "[WARNING] SMC BCLM write did not take effect."
            fi

            # Install the compiled module for the drain service to use
            if [ "$CHARGE_CONFIGURED" = true ]; then
                cp "$SMC_MOD" /usr/lib/modules/smc_rw.ko

                # Drain service: toggles ACEN (AC enable) to drain battery
                # down to the BCLM target. BCLM alone only caps charging —
                # it doesn't actively drain. This runs at boot and periodically
                # to bring the battery in line with BCLM.
                cat > /usr/local/bin/apple-battery-drain << 'DRAINEOF'
#!/bin/bash
# Only run on Apple hardware with the SMC module available
[ -d /sys/devices/platform/applesmc.768 ] || exit 0
[ -f /usr/lib/modules/smc_rw.ko ] || exit 0

BCLM_TARGET=80
BAT=/sys/class/power_supply/BAT0
[ -d "$BAT" ] || exit 0

DESIGN=$(cat "$BAT/charge_full_design" 2>/dev/null) || exit 0
NOW=$(cat "$BAT/charge_now" 2>/dev/null) || exit 0
TARGET_MAH=$(( DESIGN * BCLM_TARGET / 100 ))

if [ "$NOW" -le "$TARGET_MAH" ]; then
    logger -t apple-battery-drain "Charge $NOW <= target $TARGET_MAH mAh, ensuring AC enabled"
    rmmod applesmc 2>/dev/null; sleep 1
    insmod /usr/lib/modules/smc_rw.ko key=ACEN value=1 2>/dev/null
    modprobe applesmc 2>/dev/null
    exit 0
fi

logger -t apple-battery-drain "Charge $NOW > target $TARGET_MAH mAh, disabling AC to drain"
rmmod applesmc 2>/dev/null; sleep 1
insmod /usr/lib/modules/smc_rw.ko key=ACEN value=0 2>/dev/null
modprobe applesmc 2>/dev/null
DRAINEOF
                chmod +x /usr/local/bin/apple-battery-drain

                cat > /etc/systemd/system/apple-battery-drain.service << 'DRAINSVCEOF'
[Unit]
Description=Drain Apple MacBook battery to BCLM target
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apple-battery-drain
DRAINSVCEOF

                cat > /etc/systemd/system/apple-battery-drain.timer << 'DRAINTMEOF'
[Unit]
Description=Check Apple battery drain every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
DRAINTMEOF

                systemctl daemon-reload
                systemctl enable --now apple-battery-drain.timer
                echo "Installed apple-battery-drain service (checks every 10min)."
            fi
        else
            echo "[WARNING] Failed to build SMC kernel module. Install kernel headers."
        fi
        rm -rf "$SMC_BUILD_DIR"
    fi

    if [ "$CHARGE_CONFIGURED" = false ]; then
        echo "[INFO] No charge control support — thresholds depend on TLP or BIOS."
    fi

    # --- Verify the cap is actually honoured ---
    # CHARGE_CONFIGURED only means "the write succeeded", not "the firmware
    # obeyed it". On some hardware (notably the XPS 13 9350) the sysfs threshold
    # files accept writes and the EC ignores them, so the node reports success at
    # join time and then sits pinned at 100% indefinitely. Record the intent and
    # let a timer confirm the battery actually settles into the band.
    if [ "$CHARGE_CONFIGURED" = true ]; then
        cat > /usr/local/bin/battery-cap-verify << 'VERIFYEOF'
#!/bin/bash
# Warn if the battery is charging well above the configured cap. Charge control
# is best-effort across vendors; this turns a silent no-op into a visible one.
#
# Config (all optional) comes from /etc/battery-cap-verify.env:
#   NTFY_URL, NTFY_TOPIC, NTFY_TOKEN — publish warnings to ntfy. With no token
#   the check still logs to syslog; ntfy is additive, never required.
CAP=80
GRACE=5
STATE_DIR=/var/lib/battery-cap-verify
RENOTIFY_SECS=86400   # a stuck battery is a standing condition, not hourly news

[ -r /etc/battery-cap-verify.env ] && . /etc/battery-cap-verify.env

mkdir -p "$STATE_DIR"

notify() {
    local title="$1" body="$2"
    [ -n "$NTFY_TOKEN" ] && [ -n "$NTFY_TOPIC" ] || return 0
    curl -fsS --max-time 10 \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: high" \
        -H "Tags: battery,warning" \
        -d "$body" \
        "${NTFY_URL:-https://ntfy.zachd.duckdns.org}/${NTFY_TOPIC}" >/dev/null 2>&1 \
        || logger -t battery-cap-verify -p daemon.warning "ntfy publish failed"
}

for bat in /sys/class/power_supply/BAT*; do
    [ -f "$bat/capacity" ] || continue
    cap=$(cat "$bat/capacity" 2>/dev/null)
    status=$(cat "$bat/status" 2>/dev/null)
    name=$(basename "$bat")
    [ -n "$cap" ] || continue

    stamp="$STATE_DIR/$name.notified"

    if [ "$cap" -gt "$((CAP + GRACE))" ] && [ "$status" != "Discharging" ]; then
        msg="$name at ${cap}% (status=$status) exceeds cap ${CAP}% — charge control not honoured by firmware"
        logger -t battery-cap-verify -p daemon.warning "$msg"

        now=$(date +%s)
        last=0
        [ -r "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
        if [ "$((now - last))" -ge "$RENOTIFY_SECS" ]; then
            notify "Battery cap not holding on $(hostname)" \
                   "$(hostname): $msg"
            echo "$now" > "$stamp"
        fi
    else
        # Back in band — clear the throttle so a recurrence notifies promptly.
        rm -f "$stamp"
    fi
done
exit 0
VERIFYEOF
        chmod +x /usr/local/bin/battery-cap-verify

        # Publish target for the watchdog. NTFY_TOKEN is picked up from the
        # environment at join time if present; otherwise the file is written
        # with an empty token and the check degrades to syslog-only until it
        # is filled in. The token belongs to ntfy's write-only `alerts` user
        # and lives in 1Password:
        #   NTFY_TOKEN=$(op read "op://homelab/ntfy-battery-watchdog/credential")
        # Revoke with: ntfy token remove alerts <token>  (in the ntfy pod).
        if [ ! -f /etc/battery-cap-verify.env ]; then
            cat > /etc/battery-cap-verify.env << ENVEOF
NTFY_URL=${NTFY_URL:-https://ntfy.zachd.duckdns.org}
NTFY_TOPIC=${NTFY_TOPIC:-homelab-battery}
NTFY_TOKEN=${NTFY_TOKEN:-}
ENVEOF
            chmod 600 /etc/battery-cap-verify.env
            if [ -z "${NTFY_TOKEN:-}" ]; then
                echo "[INFO] /etc/battery-cap-verify.env written with an empty NTFY_TOKEN."
                echo "[INFO] Warnings go to syslog only until a token is added."
            fi
        fi

        cat > /etc/systemd/system/battery-cap-verify.service << 'VSVCEOF'
[Unit]
Description=Verify battery charge cap is honoured by firmware

[Service]
Type=oneshot
EnvironmentFile=-/etc/battery-cap-verify.env
ExecStart=/usr/local/bin/battery-cap-verify
VSVCEOF

        cat > /etc/systemd/system/battery-cap-verify.timer << 'VTMEOF'
[Unit]
Description=Check hourly that the battery charge cap is holding

[Timer]
OnBootSec=30min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
VTMEOF
        systemctl enable --now battery-cap-verify.timer
        echo "Installed battery-cap-verify.timer (hourly cap check)."

        # Immediate feedback at join time, before the timer's first run.
        sleep 5
        for BAT_PATH in /sys/class/power_supply/BAT*; do
            [ -f "$BAT_PATH/capacity" ] || continue
            NOW=$(cat "$BAT_PATH/capacity" 2>/dev/null)
            ST=$(cat "$BAT_PATH/status" 2>/dev/null)
            if [ -n "$NOW" ] && [ "$NOW" -gt 85 ] && [ "$ST" != "Discharging" ]; then
                echo "[WARNING] $(basename "$BAT_PATH") is at ${NOW}% (${ST}) despite a configured 75-80% cap."
                echo "[WARNING] The firmware is likely ignoring it. Verify before trusting the cap on this model."
            fi
        done
    fi

    # --- Thermal management (Intel) ---
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        echo "Installing thermald for Intel thermal management..."
        apt-get install -y thermald
        systemctl enable --now thermald
    fi

    # --- Block bluetooth radio ---
    echo "Blocking bluetooth radio..."
    rfkill block bluetooth 2>/dev/null || true
    cat > /etc/modprobe.d/blacklist-bluetooth.conf << 'BTEOF'
blacklist btusb
blacklist bluetooth
BTEOF

    # --- Wake-on-LAN on wired NICs ---
    echo "Installing Wake-on-LAN enablement service..."
    cat > /etc/systemd/system/wol-enable.service << 'WOLEOF'
[Unit]
Description=Enable Wake-on-LAN on wired interfaces
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for i in $(ls /sys/class/net); do [ -d "/sys/class/net/$i/wireless" ] && continue; case "$i" in lo|tailscale*|docker*|cni*|flannel*|veth*) continue;; esac; ethtool "$i" 2>/dev/null | grep -q "Supports Wake-on" && ethtool -s "$i" wol g 2>/dev/null && logger -t wol-enable "WoL enabled on $i"; done'

[Install]
WantedBy=multi-user.target
WOLEOF
    systemctl daemon-reload
    systemctl enable --now wol-enable.service 2>/dev/null || true

    # --- NVMe APST (opt-in; applied via GRUB below) ---
    DISABLE_APST=""
    if ls /dev/nvme*n1 &>/dev/null; then
        if dmesg 2>/dev/null | grep -qiE "nvme.*(reset|controller.*(timed out|failure))"; then
            echo "[NOTICE] NVMe reset errors detected in dmesg."
            APST_DEFAULT="y"
        else
            APST_DEFAULT="n"
        fi
        read -p "Disable NVMe APST? Fixes resets on some SSDs, costs ~1W idle. [y/N, default: $APST_DEFAULT]: " DISABLE_APST
        DISABLE_APST=${DISABLE_APST:-$APST_DEFAULT}
    fi

    # --- Hardware sensors ---
    echo "Installing lm-sensors..."
    apt-get install -y lm-sensors
    yes | sensors-detect --auto 2>/dev/null || true
fi

# --- GRUB: console blanking & USB autosuspend ---
echo "Configuring GRUB kernel parameters..."
GRUB_FILE="/etc/default/grub"
GRUB_CHANGED=false

# panic=10: a panicking kernel reboots rather than sitting at the trace. These
# nodes are headless and not all of them are somewhere convenient, so a panic
# that waits for a human is an outage until someone walks over to it.
GRUB_PARAMS=("consoleblank=0" "usbcore.autosuspend=-1" "panic=10")
if [[ "${DISABLE_APST:-n}" =~ ^[Yy]$ ]]; then
    GRUB_PARAMS+=("nvme_core.default_ps_max_latency_us=0")
fi
for PARAM in "${GRUB_PARAMS[@]}"; do
    if ! grep -q "$PARAM" "$GRUB_FILE"; then
        sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ${PARAM}\"/" "$GRUB_FILE"
        GRUB_CHANGED=true
    fi
done

# The other half of surviving a bad boot, and the one that bites hardest: after
# an unclean shutdown Ubuntu sets recordfail and then holds the boot menu open
# *indefinitely* waiting for a keypress. On a headless node that turns a single
# failed boot into a node that never comes back, whatever actually went wrong.
if ! grep -q "^GRUB_RECORDFAIL_TIMEOUT=" "$GRUB_FILE"; then
    echo 'GRUB_RECORDFAIL_TIMEOUT=5' >> "$GRUB_FILE"
    GRUB_CHANGED=true
fi

if [ "$GRUB_CHANGED" = true ]; then
    echo "Updating GRUB..."
    update-grub
fi

# --- Unattended upgrades ---
echo "Installing and configuring unattended-upgrades..."
apt-get install -y unattended-upgrades
# Automatic-Reboot was already false, but that only defers a kernel — it does
# not stop one being installed, and the node then boots it on the next restart
# for any reason at all. That is how a laptop here took a 7.0 kernel it could
# not boot, with nothing linking the eventual panic to an upgrade days earlier.
#
# The fleet mixes server hardware with old laptops and a kernel fine on one is
# not necessarily fine on another, so kernel changes are made deliberately, via
# scripts/k3s/update.sh, where they are drained and observed one node at a
# time. Everything else still updates unattended.
cat > /etc/apt/apt.conf.d/50unattended-upgrades-local << 'UUEOF'
Unattended-Upgrade::Automatic-Reboot "false";

Unattended-Upgrade::Package-Blacklist {
    "linux-image-";
    "linux-headers-";
    "linux-generic";
    "linux-image-generic";
    "linux-headers-generic";
    "linux-modules-";
    "linux-tools-";
};
UUEOF

# --- CPU governor ---
echo "Setting CPU governor to performance..."
apt-get install -y cpufrequtils
cat > /etc/default/cpufrequtils << 'CPUEOF'
GOVERNOR="performance"
CPUEOF
systemctl restart cpufrequtils 2>/dev/null || cpufreq-set -g performance 2>/dev/null || true

# --- Kernel tuning ---
echo "Configuring kernel sysctls..."
if [ "$ZRAM_ENABLED" = true ]; then
    SWAPPINESS=180
    SWAP_COMMENT="# zram swap active — eagerly use compressed in-RAM swap"
else
    SWAPPINESS=0
    SWAP_COMMENT="# No swap — never page out"
fi
cat > /etc/sysctl.d/99-k3s-node.conf << SYSCTLEOF
# OOM: use killer rather than panic, kill offender not arbitrary victim
vm.panic_on_oom=0
vm.oom_kill_allocating_task=1
${SWAP_COMMENT}
vm.swappiness=${SWAPPINESS}

# k8s workload limits — defaults too low for many-pod nodes
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=262144
fs.file-max=1048576
vm.max_map_count=262144
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=16384
net.netfilter.nf_conntrack_max=262144

# Resilience: auto-reboot 10s after kernel panic
kernel.panic=10
SYSCTLEOF
sysctl -p /etc/sysctl.d/99-k3s-node.conf

# --- File descriptor & process limits ---
echo "Setting nofile/nproc limits..."
cat > /etc/security/limits.d/99-k3s.conf << 'LIMITSEOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
*       soft    nproc   unlimited
*       hard    nproc   unlimited
LIMITSEOF

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
# 7. Storage Clients, Tools & Diagnostics
# ------------------------------------------------------------------------------
echo "--- Step 7: Storage Clients, Tools & Diagnostics ---"

# open-iscsi and nfs-common are REQUIRED, not optional. Cluster PVCs live on the
# TrueNAS via democratic-csi: iSCSI zvols for RWO, NFS datasets for RWX. Without
# these the node joins looking perfectly healthy and then fails to mount every
# volume the moment a stateful pod is scheduled onto it.
#
# These were dropped in 9e8dc84 alongside an fstab NFS mount that only ever
# exposed the control plane's own disk. Removing that mount was right; removing
# the client packages was collateral. Only the packages come back — democratic-csi
# mounts each volume itself, so there is no fstab entry to restore.
echo "Installing storage clients, diagnostic tools and storage utilities..."
apt-get update
apt-get install -y \
    open-iscsi nfs-common \
    jq btop smartmontools \
    htop iotop iftop tcpdump lsof ncdu \
    dnsutils net-tools rsync ethtool conntrack

configure_iscsi_initiator

# ------------------------------------------------------------------------------
# 8. Join K3s Cluster
# ------------------------------------------------------------------------------
echo "--- Step 8: Joining K3s Cluster ---"

# Create systemd drop-in so k3s waits for Tailscale
if [ "$NODE_ROLE" = "server" ]; then
    K3S_SERVICE="k3s"
else
    K3S_SERVICE="k3s-agent"
fi

echo "Creating systemd drop-in for Tailscale dependency..."
mkdir -p /etc/systemd/system/${K3S_SERVICE}.service.d
cat > /etc/systemd/system/${K3S_SERVICE}.service.d/tailscale.conf << 'DROPEOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=always
RestartSec=10
StartLimitIntervalSec=0
DROPEOF
systemctl daemon-reload

# Scale kube/system-reserved to node RAM so kubelet advertises honest allocatable
if [ "$TOTAL_MEM_GB" -le 8 ]; then
    KUBE_RESERVED="cpu=100m,memory=384Mi"
    SYSTEM_RESERVED="cpu=100m,memory=640Mi"
elif [ "$TOTAL_MEM_GB" -le 16 ]; then
    KUBE_RESERVED="cpu=100m,memory=512Mi"
    SYSTEM_RESERVED="cpu=100m,memory=768Mi"
else
    KUBE_RESERVED="cpu=200m,memory=768Mi"
    SYSTEM_RESERVED="cpu=200m,memory=1Gi"
fi
echo "Kubelet reservations: kube=$KUBE_RESERVED, system=$SYSTEM_RESERVED"

echo "Downloading and running the K3s installation script..."
if [ "$NODE_ROLE" = "server" ]; then
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
        K3S_TOKEN="$K3S_TOKEN" \
        K3S_NODE_NAME="$K3S_NODE_NAME" \
        sh -s - server \
        --server "https://$CONTROL_PLANE_IP:6443" \
        --kubelet-arg=max-pods="$MAX_PODS" \
        --kubelet-arg=eviction-hard="memory.available<512Mi,nodefs.available<1Gi" \
        --kubelet-arg=eviction-soft="memory.available<768Mi,nodefs.available<2Gi" \
        --kubelet-arg=eviction-soft-grace-period="memory.available=30s,nodefs.available=1m" \
        --kubelet-arg=kube-reserved="$KUBE_RESERVED" \
        --kubelet-arg=system-reserved="$SYSTEM_RESERVED" \
        --protect-kernel-defaults=false
else
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
        K3S_URL="https://$CONTROL_PLANE_IP:6443" \
        K3S_TOKEN="$K3S_TOKEN" \
        K3S_NODE_NAME="$K3S_NODE_NAME" \
        sh -s - \
        --kubelet-arg=max-pods="$MAX_PODS" \
        --kubelet-arg=eviction-hard="memory.available<512Mi,nodefs.available<1Gi" \
        --kubelet-arg=eviction-soft="memory.available<768Mi,nodefs.available<2Gi" \
        --kubelet-arg=eviction-soft-grace-period="memory.available=30s,nodefs.available=1m" \
        --kubelet-arg=kube-reserved="$KUBE_RESERVED" \
        --kubelet-arg=system-reserved="$SYSTEM_RESERVED" \
        --protect-kernel-defaults=false
fi

# ------------------------------------------------------------------------------
# 9. Watchdog Services
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 9: Installing Watchdog Services ---"

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

systemctl enable --now tailscale-watchdog.timer
echo "Tailscale watchdog installed."

# Battery temperature watchdog (laptops only)
# On Macs and some other laptops, software charge limiting isn't possible from
# Linux. This watchdog monitors battery temperature to catch swelling or thermal
# runaway — the actual fire hazard — and shuts down safely before it's dangerous.
if [ -f /sys/class/power_supply/BAT0/temp ] || [ -f /sys/class/power_supply/BAT1/temp ]; then
    cat > /usr/local/bin/battery-watchdog << 'BATWDEOF'
#!/bin/bash
WARN_TEMP=450   # 45.0°C — elevated, log warning
CRIT_TEMP=550   # 55.0°C — dangerous, shut down

for bat in /sys/class/power_supply/BAT*; do
    [ -f "$bat/temp" ] || continue
    temp=$(cat "$bat/temp" 2>/dev/null) || continue
    name=$(basename "$bat")

    if [ "$temp" -ge "$CRIT_TEMP" ] 2>/dev/null; then
        logger -t battery-watchdog -p daemon.crit \
            "CRITICAL: $name temperature ${temp} ($(awk "BEGIN{printf \"%.1f\", $temp/10}")°C) — initiating shutdown"
        shutdown now "Battery temperature critical"
    elif [ "$temp" -ge "$WARN_TEMP" ] 2>/dev/null; then
        logger -t battery-watchdog -p daemon.warning \
            "WARNING: $name temperature ${temp} ($(awk "BEGIN{printf \"%.1f\", $temp/10}")°C)"
    fi
done
BATWDEOF
    chmod +x /usr/local/bin/battery-watchdog

    cat > /etc/systemd/system/battery-watchdog.service << 'BATWDSVCEOF'
[Unit]
Description=Battery temperature safety watchdog
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/battery-watchdog
BATWDSVCEOF

    cat > /etc/systemd/system/battery-watchdog.timer << 'BATWDTIMEOF'
[Unit]
Description=Run battery temperature watchdog every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
BATWDTIMEOF

    systemctl enable --now battery-watchdog.timer
    echo "Battery temperature watchdog installed."
fi

# ------------------------------------------------------------------------------
# 10. Headless & Resource Optimization
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 10: Headless & Resource Optimization ---"

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
    # Prevent snapd from being reinstalled as a dependency
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
SystemMaxUse=200M
JRNLEOF
systemctl restart systemd-journald

# --- Container log rotation (via k3s config.yaml, merged on restart) ---
echo "Configuring container log rotation..."
mkdir -p /etc/rancher/k3s
if [ ! -f /etc/rancher/k3s/config.yaml ] || ! grep -q "container-log-max" /etc/rancher/k3s/config.yaml; then
    cat >> /etc/rancher/k3s/config.yaml << 'K3SCFGEOF'
kubelet-arg:
  - "container-log-max-size=10Mi"
  - "container-log-max-files=3"
K3SCFGEOF
fi

# --- fstrim timer for SSD longevity ---
echo "Enabling weekly fstrim..."
systemctl enable fstrim.timer 2>/dev/null || true

# --- localepurge to strip unused locales ---
echo "Installing localepurge..."
echo "localepurge localepurge/nopurge multiselect en, en_US, en_US.UTF-8" | debconf-set-selections
echo "localepurge localepurge/use-dpkg-feature boolean true" | debconf-set-selections
echo "localepurge localepurge/none_selected boolean false" | debconf-set-selections
echo "localepurge localepurge/verbose boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y localepurge
localepurge 2>/dev/null || true

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
if grep -q "GenuineIntel" /proc/cpuinfo; then
    apt-get install -y intel-microcode
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    apt-get install -y amd64-microcode
else
    echo "Unknown CPU vendor — skipping microcode."
fi

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

# --- Final cleanup ---
echo ""
echo "Apt cleanup — packages eligible for autoremove:"
apt-get -s autoremove --purge 2>&1 | grep -E "^(Remv|Purg)" | head -30 || echo "  (none)"
read -p "Run autoremove --purge? [Y/n]: " AUTOREMOVE_CONFIRM
AUTOREMOVE_CONFIRM=${AUTOREMOVE_CONFIRM:-y}
if [[ "$AUTOREMOVE_CONFIRM" =~ ^[Yy]$ ]]; then
    apt-get -y autoremove --purge 2>/dev/null || true
fi
apt-get clean

# ------------------------------------------------------------------------------
# 11. Verification
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 11: Verification ---"

echo "Verifying swap configuration..."
NON_ZRAM_SWAP=$(swapon --show=NAME --noheadings 2>/dev/null | grep -v '^/dev/zram' || true)
if [ -n "$NON_ZRAM_SWAP" ]; then
    echo "[WARNING] Disk swap still active: $NON_ZRAM_SWAP"
elif [ "$ZRAM_ENABLED" = true ]; then
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; then
        echo "[SUCCESS] zram swap active, no disk swap."
    else
        echo "[INFO] zram configured (will activate on reboot), no disk swap."
    fi
else
    echo "[SUCCESS] Swap is disabled."
fi

echo "Verifying Tailscale is running..."
if systemctl is-active --quiet tailscaled; then
    echo "[SUCCESS] Tailscale is running."
else
    echo "[WARNING] Tailscale service is not running."
fi

echo "Verifying K3s ${NODE_ROLE} service..."
if systemctl is-active --quiet "$K3S_SERVICE"; then
    echo "[SUCCESS] K3s ${NODE_ROLE} service is running."
else
    echo "[ERROR] K3s ${NODE_ROLE} service is not running. Check logs with: journalctl -u $K3S_SERVICE"
fi

echo ""
echo "=============================================================================="
echo "Verifying smartctl is installed..." 
if command -v smartctl &> /dev/null; then 
    echo "[SUCCESS] smartctl is installed." 
else 
    echo "[WARNING] smartctl is not installed." 
fi 

echo "Setup and Verification Complete!"
if [ "$NODE_ROLE" = "server" ]; then
    echo "This node joined as a control plane (server). Verify with: sudo k3s kubectl get nodes"
else
    echo "Verify cluster status by running: sudo k3s kubectl get nodes on the Control Plane."
fi
echo "=============================================================================="

echo ""
echo "Rebooting in 10 seconds to apply all changes (headless mode, microcode, etc.)..."
echo "The node will come back up via Tailscale SSH."
sleep 10
reboot
