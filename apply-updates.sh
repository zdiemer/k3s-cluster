#!/bin/bash

# ==============================================================================
# Apply k3s Node Updates to Existing Nodes
# ==============================================================================
# Replays the tuning/optimization changes from join-cluster.sh onto a node
# that was already joined to the cluster.
#
# Idempotent: safe to re-run. Interactive prompts for destructive operations.
#
# Usage: sudo ./apply-updates.sh

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (using sudo)."
    exit 1
fi

echo "=============================================================================="
echo "          K3s Node Update Apply"
echo "=============================================================================="
echo ""

TARGET_USER=${SUDO_USER:-$USER}

# Detect role from running service
if systemctl is-enabled --quiet k3s 2>/dev/null; then
    K3S_SERVICE="k3s"
    NODE_ROLE="server"
elif systemctl is-enabled --quiet k3s-agent 2>/dev/null; then
    K3S_SERVICE="k3s-agent"
    NODE_ROLE="agent"
else
    echo "[WARNING] No k3s or k3s-agent service found. Continuing with system tuning only."
    K3S_SERVICE=""
    NODE_ROLE=""
fi
[ -n "$NODE_ROLE" ] && echo "Detected role: $NODE_ROLE (service: $K3S_SERVICE)"

CPU_CORES=$(nproc)
TOTAL_MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
echo "System: ${CPU_CORES} cores, ${TOTAL_MEM_GB}GB RAM"
echo ""

# ------------------------------------------------------------------------------
# 1. Kernel sysctls
# ------------------------------------------------------------------------------
echo "--- Step 1: Kernel sysctls ---"
cat > /etc/sysctl.d/99-k3s-node.conf << 'SYSCTLEOF'
# OOM: use killer rather than panic, kill offender not arbitrary victim
vm.panic_on_oom=0
vm.oom_kill_allocating_task=1
# No swap
vm.swappiness=0

# k8s workload limits — defaults too low for many-pod nodes
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=262144
fs.file-max=1048576
vm.max_map_count=262144
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=16384
net.netfilter.nf_conntrack_max=262144

# QUIC/UDP receive buffer — cloudflared wants ~7MB and warns on every start
# that it could not get it. Throughput nit only, but the default is far below
# what any QUIC userspace stack asks for.
net.core.rmem_max=7500000
net.core.wmem_max=7500000

# Resilience: auto-reboot 10s after kernel panic
kernel.panic=10
SYSCTLEOF
sysctl -p /etc/sysctl.d/99-k3s-node.conf >/dev/null
echo "[OK] Applied sysctls."

# ------------------------------------------------------------------------------
# 2. nofile/nproc limits
# ------------------------------------------------------------------------------
echo "--- Step 2: File/process limits ---"
cat > /etc/security/limits.d/99-k3s.conf << 'LIMITSEOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
*       soft    nproc   unlimited
*       hard    nproc   unlimited
LIMITSEOF
echo "[OK] Applied limits."

# ------------------------------------------------------------------------------
# 3. Laptop-only tweaks (BAT detection)
# ------------------------------------------------------------------------------
IS_LAPTOP=false
if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    IS_LAPTOP=true
fi

if [ "$IS_LAPTOP" = true ]; then
    echo "--- Step 3: Laptop-specific tweaks ---"

    # TLP AC mode (if TLP installed)
    if [ -f /etc/tlp.conf ]; then
        echo "Setting TLP to always use AC profile..."
        for VAR in TLP_DEFAULT_MODE=AC TLP_PERSISTENT_DEFAULT=1; do
            KEY="${VAR%%=*}"
            if grep -q "^${KEY}=" /etc/tlp.conf; then
                sed -i "s/^${KEY}=.*/${VAR}/" /etc/tlp.conf
            elif grep -q "^#${KEY}=" /etc/tlp.conf; then
                sed -i "s/^#${KEY}=.*/${VAR}/" /etc/tlp.conf
            else
                echo "$VAR" >> /etc/tlp.conf
            fi
        done
        systemctl restart tlp 2>/dev/null || true
        echo "[OK] TLP AC mode."
    fi

    # Thermald (Intel only)
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        if ! command -v thermald &>/dev/null; then
            echo "Installing thermald..."
            apt-get install -y thermald
        fi
        systemctl enable --now thermald 2>/dev/null || true
        echo "[OK] Thermald."
    fi

    # Block bluetooth
    echo "Blocking bluetooth radio..."
    rfkill block bluetooth 2>/dev/null || true
    cat > /etc/modprobe.d/blacklist-bluetooth.conf << 'BTEOF'
blacklist btusb
blacklist bluetooth
BTEOF
    echo "[OK] Bluetooth blocked."

    # Wake-on-LAN service
    if ! command -v ethtool &>/dev/null; then
        apt-get install -y ethtool
    fi
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
    echo "[OK] Wake-on-LAN service installed."

    # NVMe APST (interactive, via GRUB)
    if ls /dev/nvme*n1 &>/dev/null; then
        if grep -q "nvme_core.default_ps_max_latency_us" /etc/default/grub; then
            echo "[OK] NVMe APST already configured."
        else
            if dmesg 2>/dev/null | grep -qiE "nvme.*(reset|controller.*(timed out|failure))"; then
                echo "[NOTICE] NVMe reset errors detected in dmesg."
                APST_DEFAULT="y"
            else
                APST_DEFAULT="n"
            fi
            read -p "Disable NVMe APST? Fixes resets on some SSDs, costs ~1W idle. [y/N, default: $APST_DEFAULT]: " DISABLE_APST
            DISABLE_APST=${DISABLE_APST:-$APST_DEFAULT}
            if [[ "$DISABLE_APST" =~ ^[Yy]$ ]]; then
                sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvme_core.default_ps_max_latency_us=0"/' /etc/default/grub
                update-grub
                echo "[OK] NVMe APST disabled on next boot."
                NEED_REBOOT=true
            fi
        fi
    fi

    # lm-sensors
    if ! command -v sensors &>/dev/null; then
        echo "Installing lm-sensors..."
        apt-get install -y lm-sensors
        yes | sensors-detect --auto 2>/dev/null || true
        echo "[OK] lm-sensors."
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# 4. Remove iSCSI + install diagnostic tools
# ------------------------------------------------------------------------------
echo "--- Step 4: Package updates ---"

if dpkg -l open-iscsi 2>/dev/null | grep -q '^ii'; then
    echo "Removing open-iscsi (Longhorn not in use)..."
    systemctl disable --now iscsid 2>/dev/null || true
    apt-get -y purge open-iscsi 2>/dev/null || true
fi

echo "Installing diagnostic tools..."
apt-get update -qq
apt-get install -y \
    jq btop smartmontools \
    htop iotop iftop tcpdump lsof ncdu \
    dnsutils net-tools rsync ethtool conntrack
echo "[OK] Packages updated."
echo ""

# ------------------------------------------------------------------------------
# 5. k3s systemd unit updates (kube-reserved + container log rotation)
# ------------------------------------------------------------------------------
if [ -n "$K3S_SERVICE" ]; then
    echo "--- Step 5: k3s kubelet args ---"

    # Calculate RAM-scaled reservations
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
    echo "Target: kube=$KUBE_RESERVED, system=$SYSTEM_RESERVED"

    UNIT_FILE="/etc/systemd/system/${K3S_SERVICE}.service"
    if [ -f "$UNIT_FILE" ]; then
        UNIT_CHANGED=false
        # Update kube-reserved
        if grep -q -- "--kubelet-arg=kube-reserved=" "$UNIT_FILE" || \
           grep -q -- "'--kubelet-arg=kube-reserved=" "$UNIT_FILE"; then
            sed -i -E "s|(--kubelet-arg=kube-reserved=)[^' \\\\]*|\1${KUBE_RESERVED}|" "$UNIT_FILE"
            UNIT_CHANGED=true
        fi
        if grep -q -- "--kubelet-arg=system-reserved=" "$UNIT_FILE"; then
            sed -i -E "s|(--kubelet-arg=system-reserved=)[^' \\\\]*|\1${SYSTEM_RESERVED}|" "$UNIT_FILE"
            UNIT_CHANGED=true
        fi
        # Container log rotation
        if ! grep -q "container-log-max-size" "$UNIT_FILE"; then
            sed -i -E "s|(ExecStart=/usr/local/bin/k3s)|\1 '--kubelet-arg=container-log-max-size=10Mi' '--kubelet-arg=container-log-max-files=3'|" "$UNIT_FILE"
            UNIT_CHANGED=true
        fi
        if [ "$UNIT_CHANGED" = true ]; then
            echo "Updated $UNIT_FILE. Reloading + restarting $K3S_SERVICE..."
            systemctl daemon-reload
            systemctl restart "$K3S_SERVICE"
            echo "[OK] k3s kubelet args updated."
        else
            echo "[OK] k3s kubelet args already current."
        fi
    else
        echo "[WARN] $UNIT_FILE not found; skipping kubelet arg updates."
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# 6. Journald cap
# ------------------------------------------------------------------------------
echo "--- Step 6: Journald cap ---"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf << 'JRNLEOF'
[Journal]
SystemMaxUse=200M
JRNLEOF
systemctl restart systemd-journald
echo "[OK] Journald capped at 200M."
echo ""

# ------------------------------------------------------------------------------
# 7. fstrim
# ------------------------------------------------------------------------------
echo "--- Step 7: fstrim ---"
systemctl enable fstrim.timer 2>/dev/null || true
echo "[OK] fstrim.timer enabled."
echo ""

# ------------------------------------------------------------------------------
# 8. localepurge
# ------------------------------------------------------------------------------
echo "--- Step 8: localepurge ---"
if ! command -v localepurge &>/dev/null; then
    echo "localepurge localepurge/nopurge multiselect en, en_US, en_US.UTF-8" | debconf-set-selections
    echo "localepurge localepurge/use-dpkg-feature boolean true" | debconf-set-selections
    echo "localepurge localepurge/none_selected boolean false" | debconf-set-selections
    echo "localepurge localepurge/verbose boolean false" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y localepurge
fi
localepurge 2>/dev/null || true
echo "[OK] Locales purged."
echo ""

# ------------------------------------------------------------------------------
# 9. GNOME purge (interactive)
# ------------------------------------------------------------------------------
if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qE '^(ubuntu-desktop|ubuntu-desktop-minimal|gnome-shell)$'; then
    echo "--- Step 9: GNOME desktop purge (optional) ---"
    read -p "Purge GNOME desktop packages? (frees ~2-3GB disk) [y/N]: " PURGE_GNOME
    if [[ "$PURGE_GNOME" =~ ^[Yy]$ ]]; then
        echo "Pinning network + firmware packages..."
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
            echo "[OK] GNOME packages purged."
        fi
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# 10. Final cleanup
# ------------------------------------------------------------------------------
echo "--- Step 10: Final cleanup ---"
echo "Packages eligible for autoremove:"
apt-get -s autoremove --purge 2>&1 | grep -E "^(Remv|Purg)" | head -30 || echo "  (none)"
read -p "Run autoremove --purge? [Y/n]: " AUTOREMOVE_CONFIRM
AUTOREMOVE_CONFIRM=${AUTOREMOVE_CONFIRM:-y}
if [[ "$AUTOREMOVE_CONFIRM" =~ ^[Yy]$ ]]; then
    apt-get -y autoremove --purge 2>/dev/null || true
fi
apt-get clean
echo "[OK] Cleanup done."
echo ""

# ------------------------------------------------------------------------------
# Reboot prompt
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "Apply complete."
if [ "${NEED_REBOOT:-false}" = true ]; then
    echo "[NOTICE] GRUB changes applied — a reboot is required for NVMe APST to take effect."
fi
echo "=============================================================================="
read -p "Reboot now? [y/N]: " REBOOT_CONFIRM
if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
    reboot
fi
