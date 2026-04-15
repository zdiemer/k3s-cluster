#!/bin/bash

# ==============================================================================
# Kubernetes Node & NFS Client Setup Script
# ==============================================================================
# Run this script on new machines to join them to the cluster and mount the NAS.
# Supports joining as either a worker (agent) or control plane (server) node.
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
echo "          K3s Cluster Node Setup"
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
echo "Starting setup for NFS Client and K3s ${NODE_ROLE} node..."
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

    # Set TLP charge thresholds in config (for hardware TLP natively supports)
    if [ -f /etc/tlp.conf ]; then
        for VAR in START_CHARGE_THRESH_BAT0=75 STOP_CHARGE_THRESH_BAT0=80 \
                   START_CHARGE_THRESH_BAT1=75 STOP_CHARGE_THRESH_BAT1=80; do
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
            if [ -f "$END_FILE" ] && [ -f "$START_FILE" ]; then
                echo 80 > "$END_FILE" 2>/dev/null && \
                echo 75 > "$START_FILE" 2>/dev/null && \
                CHARGE_CONFIGURED=true && \
                echo "[SUCCESS] Set charge thresholds on $(basename "$BAT_PATH"): 75-80%"
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
    echo 75 > "$bat/charge_control_start_threshold" 2>/dev/null; \
  done'

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

# --- OOM tuning ---
echo "Configuring OOM behavior..."
cat > /etc/sysctl.d/99-k3s-node.conf << 'SYSCTLEOF'
# Let the OOM killer work rather than kernel panic
vm.panic_on_oom=0
# Kill the allocating task on OOM (keeps other processes alive)
vm.oom_kill_allocating_task=1
# No swap, so disable swappiness
vm.swappiness=0
SYSCTLEOF
sysctl -p /etc/sysctl.d/99-k3s-node.conf

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
apt-get install -y nfs-common open-iscsi jq btop smartmontools

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

echo "Downloading and running the K3s installation script..."
if [ "$NODE_ROLE" = "server" ]; then
    curl -sfL https://get.k3s.io | \
        K3S_TOKEN="$K3S_TOKEN" \
        K3S_NODE_NAME="$K3S_NODE_NAME" \
        sh -s - server \
        --server "https://$CONTROL_PLANE_IP:6443" \
        --kubelet-arg=max-pods="$MAX_PODS" \
        --kubelet-arg=eviction-hard="memory.available<512Mi,nodefs.available<1Gi" \
        --kubelet-arg=eviction-soft="memory.available<768Mi,nodefs.available<2Gi" \
        --kubelet-arg=eviction-soft-grace-period="memory.available=30s,nodefs.available=1m" \
        --kubelet-arg=kube-reserved="cpu=100m,memory=256Mi" \
        --kubelet-arg=system-reserved="cpu=100m,memory=512Mi" \
        --protect-kernel-defaults=false
else
    curl -sfL https://get.k3s.io | \
        K3S_URL="https://$CONTROL_PLANE_IP:6443" \
        K3S_TOKEN="$K3S_TOKEN" \
        K3S_NODE_NAME="$K3S_NODE_NAME" \
        sh -s - \
        --kubelet-arg=max-pods="$MAX_PODS" \
        --kubelet-arg=eviction-hard="memory.available<512Mi,nodefs.available<1Gi" \
        --kubelet-arg=eviction-soft="memory.available<768Mi,nodefs.available<2Gi" \
        --kubelet-arg=eviction-soft-grace-period="memory.available=30s,nodefs.available=1m" \
        --kubelet-arg=kube-reserved="cpu=100m,memory=256Mi" \
        --kubelet-arg=system-reserved="cpu=100m,memory=512Mi" \
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
# 10. Verification
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 10: Verification ---"

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
