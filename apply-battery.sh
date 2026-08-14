#!/bin/bash

# ==============================================================================
# Apply battery health tooling to an already-joined node
# ==============================================================================
# Replays just the battery blocks from join-cluster.sh onto an existing node:
# the ntfy publisher, the charge-cap verifier, and the temperature watchdog.
#
# Exists because those blocks only ever run at join time, and the fleet was
# joined long before they were correct. See BATTERY-REMEDIATION.md.
#
# Idempotent: safe to re-run.
#
# Usage:
#   sudo NTFY_TOKEN=... ./apply-battery.sh          # install / refresh
#   sudo ./apply-battery.sh --check                 # report only, change nothing
#
# NTFY_TOKEN comes from 1Password:
#   op read "op://homelab/ntfy-battery-watchdog/credential"

set -u

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (using sudo)."
    exit 1
fi

HOST=$(hostname)
echo "=============================================================================="
echo "  Battery health tooling — $HOST"
[ "$CHECK_ONLY" = true ] && echo "  (--check: reporting only, nothing will be changed)"
echo "=============================================================================="

if [ ! -d /sys/class/power_supply/BAT0 ] && [ ! -d /sys/class/power_supply/BAT1 ]; then
    echo "[INFO] No battery present. Nothing to do."
    exit 0
fi

# ------------------------------------------------------------------------------
# Current state
# ------------------------------------------------------------------------------
echo ""
echo "--- Current state ---"
for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] || continue
    n=$(basename "$b")
    cap=$(cat "$b/capacity" 2>/dev/null)
    st=$(cat "$b/status" 2>/dev/null)
    end=$(cat "$b/charge_control_end_threshold" 2>/dev/null || echo "n/a")
    echo "  $n: ${cap}% ($st), end_threshold=$end"
    for p in energy charge; do
        f="$b/${p}_full"; g="$b/${p}_full_design"
        if [ -r "$f" ] && [ -r "$g" ]; then
            fv=$(cat "$f"); gv=$(cat "$g")
            [ "$gv" -gt 0 ] 2>/dev/null && echo "  $n: health $((fv * 100 / gv))% of design"
        fi
    done
done

# Which temperature tier will this machine land in?
TIER="none"
TIER_DETAIL=""
if ls /sys/class/power_supply/BAT*/temp >/dev/null 2>&1; then
    TIER="true-sensor"
    TIER_DETAIL=$(for t in /sys/class/power_supply/BAT*/temp; do echo -n "$(cat "$t" 2>/dev/null) "; done)
else
    for h in /sys/class/hwmon/hwmon*; do
        chip=$(cat "$h/name" 2>/dev/null)
        case "$chip" in dell_smm | cros_ec) ;; *) continue ;; esac
        for lf in "$h"/temp*_label; do
            [ -f "$lf" ] || continue
            case "$(cat "$lf" 2>/dev/null)" in
                Ambient | Charger)
                    TIER="proxy"
                    TIER_DETAIL="$chip/$(cat "$lf" 2>/dev/null)"
                    break 2
                    ;;
            esac
        done
    done
fi

case "$TIER" in
    true-sensor) echo "  temp tier: TRUE battery sensor ($TIER_DETAIL) — warn 45C, shutdown 55C" ;;
    proxy)       echo "  temp tier: PROXY $TIER_DETAIL — warn only at 60C, NO auto-shutdown" ;;
    none)        echo "  temp tier: NONE — this machine has no battery thermal protection" ;;
esac

if [ "$CHECK_ONLY" = true ]; then
    echo ""
    echo "--- Installed units ---"
    for u in battery-threshold.service battery-cap-verify.timer battery-watchdog.timer; do
        state=$(systemctl is-enabled "$u" 2>/dev/null || echo "absent")
        echo "  $u: $state"
    done
    echo "  /etc/battery-notify.env: $([ -f /etc/battery-notify.env ] && echo present || echo absent)"
    exit 0
fi

# ------------------------------------------------------------------------------
# 1. Shared ntfy publisher
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 1: ntfy publisher ---"
mkdir -p /usr/local/lib
cat > /usr/local/lib/battery-notify.sh << 'NOTIFYEOF'
# shellcheck shell=bash
[ -r /etc/battery-notify.env ] && . /etc/battery-notify.env

battery_notify() {
    local title="$1" body="$2" priority="${3:-high}"
    [ -n "$NTFY_TOKEN" ] && [ -n "$NTFY_TOPIC" ] || return 0
    curl -fsS --max-time 10 \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: battery,warning" \
        -d "$body" \
        "${NTFY_URL:-https://ntfy.zachd.duckdns.org}/${NTFY_TOPIC}" > /dev/null 2>&1 \
        || logger -t battery-notify -p daemon.warning "ntfy publish failed"
}
NOTIFYEOF

# Preserve an existing token if this is a re-run and no new one was passed.
EXISTING_TOKEN=""
if [ -r /etc/battery-notify.env ]; then
    EXISTING_TOKEN=$(sed -n 's/^NTFY_TOKEN=//p' /etc/battery-notify.env)
fi
TOKEN="${NTFY_TOKEN:-$EXISTING_TOKEN}"

cat > /etc/battery-notify.env << ENVEOF
NTFY_URL=${NTFY_URL:-https://ntfy.zachd.duckdns.org}
NTFY_TOPIC=${NTFY_TOPIC:-homelab-battery}
NTFY_TOKEN=${TOKEN}
ENVEOF
chmod 600 /etc/battery-notify.env

if [ -z "$TOKEN" ]; then
    echo "[WARNING] No NTFY_TOKEN. Alerts will go to syslog only."
    echo "[WARNING] Re-run with: sudo NTFY_TOKEN=\$(op read op://homelab/ntfy-battery-watchdog/credential) $0"
else
    echo "[SUCCESS] ntfy configured (topic ${NTFY_TOPIC:-homelab-battery})."
fi

# ------------------------------------------------------------------------------
# 2. Charge cap — Dell SMBIOS first, then sysfs
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 2: Charge cap ---"
CHARGE_CONFIGURED=false

if dmidecode -s system-manufacturer 2>/dev/null | grep -qi dell; then
    echo "Dell detected. Setting charge mode via SMBIOS..."
    command -v smbios-battery-ctl > /dev/null 2>&1 || apt-get install -y smbios-utils 2>/dev/null
    if command -v smbios-battery-ctl > /dev/null 2>&1; then
        smbios-battery-ctl --set-charging-mode=custom 2>/dev/null
        smbios-battery-ctl --set-custom-charge-interval 75 80 2>/dev/null
        if smbios-battery-ctl --get-charging-cfg 2>/dev/null | grep -q "custom"; then
            echo "[SUCCESS] Dell charge mode: custom (75-80%)"
            CHARGE_CONFIGURED=true
        else
            echo "[WARNING] Dell SMBIOS charge config did not take."
        fi
    else
        echo "[WARNING] smbios-battery-ctl unavailable; falling back to sysfs."
    fi
fi

if [ "$CHARGE_CONFIGURED" = false ]; then
    for BAT_PATH in /sys/class/power_supply/BAT0 /sys/class/power_supply/BAT1; do
        [ -d "$BAT_PATH" ] || continue
        END_FILE="$BAT_PATH/charge_control_end_threshold"
        START_FILE="$BAT_PATH/charge_control_start_threshold"
        # End threshold only: several ECs expose no start file at all.
        if [ -f "$END_FILE" ]; then
            if echo 80 > "$END_FILE" 2>/dev/null; then
                [ -f "$START_FILE" ] && echo 75 > "$START_FILE" 2>/dev/null
                CHARGE_CONFIGURED=true
                echo "[SUCCESS] Set charge threshold on $(basename "$BAT_PATH") to 80%"
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
ExecStart=/bin/bash -c 'for bat in /sys/class/power_supply/BAT*; do [ -f "$bat/charge_control_end_threshold" ] || continue; echo 80 > "$bat/charge_control_end_threshold" 2>/dev/null; if [ -f "$bat/charge_control_start_threshold" ]; then echo 75 > "$bat/charge_control_start_threshold" 2>/dev/null; fi; done; exit 0'

[Install]
WantedBy=multi-user.target
BATEOF
        systemctl daemon-reload
        systemctl enable battery-threshold.service > /dev/null 2>&1
        echo "[SUCCESS] battery-threshold.service enabled."
    fi
fi

[ "$CHARGE_CONFIGURED" = false ] \
    && echo "[WARNING] No charge control available on this hardware."

# ------------------------------------------------------------------------------
# 3. Cap verifier — catches a cap the firmware silently ignores
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 3: Charge cap verifier ---"
cat > /usr/local/bin/battery-cap-verify << 'VERIFYEOF'
#!/bin/bash
CAP=80
GRACE=5
STATE_DIR=/var/lib/battery-cap-verify
RENOTIFY_SECS=86400

. /usr/local/lib/battery-notify.sh
mkdir -p "$STATE_DIR"

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
            battery_notify "Battery cap not holding on $(hostname)" "$(hostname): $msg"
            echo "$now" > "$stamp"
        fi
    else
        rm -f "$stamp"
    fi
done
exit 0
VERIFYEOF
chmod +x /usr/local/bin/battery-cap-verify

cat > /etc/systemd/system/battery-cap-verify.service << 'VSVCEOF'
[Unit]
Description=Verify battery charge cap is honoured by firmware

[Service]
Type=oneshot
EnvironmentFile=-/etc/battery-notify.env
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

systemctl daemon-reload
systemctl enable --now battery-cap-verify.timer > /dev/null 2>&1
echo "[SUCCESS] battery-cap-verify.timer enabled (hourly)."

# ------------------------------------------------------------------------------
# 4. Temperature watchdog
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 4: Temperature watchdog ---"
cat > /usr/local/bin/battery-watchdog << 'BATWDEOF'
#!/bin/bash
# Tier 1: BAT*/temp, a real thermistor — warn 45C, shut down 55C.
# Tier 2: nearest sensor to the battery bay (dell_smm Ambient, cros_ec
#         Charger/Ambient) — WARN ONLY at 60C, never shuts down.
# CPU/package/coretemp zones are deliberately excluded: they idle at 55-75C on
# this hardware and would cause an immediate, permanent shutdown loop.
WARN_TEMP=450
CRIT_TEMP=550
PROXY_WARN=600
STATE_DIR=/var/lib/battery-watchdog
RENOTIFY_SECS=3600

. /usr/local/lib/battery-notify.sh
mkdir -p "$STATE_DIR"

throttled() {
    local stamp="$STATE_DIR/$1.notified" now last=0
    now=$(date +%s)
    [ -r "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
    if [ "$((now - last))" -ge "$RENOTIFY_SECS" ]; then
        echo "$now" > "$stamp"
        return 1
    fi
    return 0
}

c() { awk "BEGIN{printf \"%.1f\", $1/10}"; }

found_sensor=0

for bat in /sys/class/power_supply/BAT*; do
    [ -f "$bat/temp" ] || continue
    temp=$(cat "$bat/temp" 2>/dev/null) || continue
    [ -n "$temp" ] || continue
    name=$(basename "$bat")
    found_sensor=1

    if [ "$temp" -ge "$CRIT_TEMP" ] 2>/dev/null; then
        logger -t battery-watchdog -p daemon.crit \
            "CRITICAL: $name temperature ${temp} ($(c "$temp")C) — initiating shutdown"
        battery_notify "BATTERY CRITICAL on $(hostname)" \
            "$(hostname): $name at $(c "$temp")C — exceeded limit, shutting down now." urgent
        sleep 2
        shutdown now "Battery temperature critical"
    elif [ "$temp" -ge "$WARN_TEMP" ] 2>/dev/null; then
        logger -t battery-watchdog -p daemon.warning \
            "WARNING: $name temperature ${temp} ($(c "$temp")C)"
        throttled "$name" || battery_notify "Battery warm on $(hostname)" \
            "$(hostname): $name at $(c "$temp")C (warn threshold $(c "$WARN_TEMP")C)."
    fi
done

if [ "$found_sensor" -eq 0 ]; then
    for h in /sys/class/hwmon/hwmon*; do
        chip=$(cat "$h/name" 2>/dev/null)
        case "$chip" in dell_smm | cros_ec) ;; *) continue ;; esac
        for lf in "$h"/temp*_label; do
            [ -f "$lf" ] || continue
            label=$(cat "$lf" 2>/dev/null)
            case "$label" in Ambient | Charger) ;; *) continue ;; esac
            input="${lf%_label}_input"
            [ -f "$input" ] || continue
            raw=$(cat "$input" 2>/dev/null) || continue
            [ -n "$raw" ] || continue
            temp=$((raw / 100))
            found_sensor=1
            if [ "$temp" -ge "$PROXY_WARN" ] 2>/dev/null; then
                logger -t battery-watchdog -p daemon.warning \
                    "WARNING: proxy sensor $chip/$label at $(c "$temp")C (no true battery sensor)"
                throttled "$chip-$label" || battery_notify "Battery-area temp high on $(hostname)" \
                    "$(hostname): $chip/$label at $(c "$temp")C. Proxy sensor — no shutdown will occur."
            fi
        done
    done
fi

if [ "$found_sensor" -eq 0 ]; then
    logger -t battery-watchdog -p daemon.warning \
        "no battery or proxy temperature sensor found — NO thermal protection"
fi
exit 0
BATWDEOF
chmod +x /usr/local/bin/battery-watchdog

cat > /etc/systemd/system/battery-watchdog.service << 'BATWDSVCEOF'
[Unit]
Description=Battery temperature safety watchdog
After=multi-user.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/battery-notify.env
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

systemctl daemon-reload
systemctl enable --now battery-watchdog.timer > /dev/null 2>&1

case "$TIER" in
    true-sensor) echo "[SUCCESS] Watchdog active on a true battery sensor (warn 45C, shutdown 55C)." ;;
    proxy)       echo "[WARNING] No true battery sensor. Using proxy $TIER_DETAIL, warn-only at 60C." ;;
    none)        echo "[WARNING] No sensor at all — watchdog installed but has nothing to read." ;;
esac

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "--- Summary for $HOST ---"
systemctl start battery-cap-verify.service 2>/dev/null
systemctl start battery-watchdog.service 2>/dev/null
for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] || continue
    echo "  $(basename "$b"): $(cat "$b/capacity" 2>/dev/null)% ($(cat "$b/status" 2>/dev/null)), end=$(cat "$b/charge_control_end_threshold" 2>/dev/null || echo n/a)"
done
echo "  Recent watchdog log:"
journalctl -t battery-watchdog -t battery-cap-verify -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
echo ""
echo "Done. Note: a charge cap can take hours to visibly drain toward 80%."
