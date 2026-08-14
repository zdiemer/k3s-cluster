# Battery remediation — pending SSH work

Everything here is **committed but not deployed**. It all needs `tailscale ssh`,
which is gated behind an interactive tailnet auth check.

Context: `zachd-ubuntu-laptop-3` died on 2026-08-13 and an audit of the fleet's
battery health found that the charge cap and the temperature watchdog were both
silently inert on most nodes. The code is fixed; the machines are not.

---

## 0. Prerequisites

Tailscale SSH needs an interactive approval that a headless session can't do:

```bash
tailscale ssh root@zachd-ubuntu-laptop-2 true
# visit the printed https://login.tailscale.com/a/... URL, then re-run
```

The scripts in `~/code/selfhosted/scripts/k3s` default `SSH_USER` to `$(id -un)`,
which is `node` in the claude-workspace pod, and the tailnet only permits `root`.
**Always export `SSH_USER=root` from the pod** or every remote check silently
reports `N/A` while still printing a clean-looking report:

```bash
SSH_USER=root ./debug.sh --all
```

Get the ntfy token (already minted, write-only `alerts` user):

```bash
eval "$(bash ~/code/selfhosted/scripts/op-session.sh ensure)"
export NTFY_TOKEN=$(op read "op://homelab/ntfy-battery-watchdog/credential")
```

---

## 1. Deploy the battery tooling to all six laptops

`apply-battery.sh` replays the battery blocks from `join-cluster.sh` onto an
already-joined node. Idempotent; `--check` reports without changing anything.

```bash
cd ~/code/k3s-cluster

for n in zachd-ubuntu-laptop zachd-ubuntu-laptop-1 zachd-ubuntu-laptop-2 \
         zachd-ubuntu-laptop-4 zachd-ubuntu-laptop-5 zachd-ubuntu-laptop-6; do
  echo "=== $n"
  tailscale ssh root@$n "NTFY_TOKEN='$NTFY_TOKEN' bash -s" < apply-battery.sh
done
```

Dry run first if you'd rather look before touching anything:

```bash
tailscale ssh root@zachd-ubuntu-laptop-2 "bash -s -- --check" < apply-battery.sh
```

This installs, on each node: `/usr/local/lib/battery-notify.sh`,
`/etc/battery-notify.env` (mode 600), `battery-cap-verify` + hourly timer, and
`battery-watchdog` + 2-minute timer. It also re-applies the charge cap, taking
the Dell SMBIOS path where that's the right one.

---

## 2. The two Dells whose charge cap never worked

`zachd-ubuntu-laptop` (XPS 13 9350) and `zachd-ubuntu-laptop-2` (Latitude E7250)
report sysfs thresholds of 75-80 while sitting at 100% and 91%. The firmware
accepts the write and ignores it — `join-cluster.sh` even documents this. Step 1
handles it via `smbios-battery-ctl`, but verify it actually took:

```bash
tailscale ssh root@zachd-ubuntu-laptop  'smbios-battery-ctl --get-charging-cfg'
tailscale ssh root@zachd-ubuntu-laptop-2 'smbios-battery-ctl --get-charging-cfg'
# expect: custom, 75-80
```

The XPS is the priority: worst battery in the fleet at **63% of design**, pinned
at 100% for its entire 112-day uptime, and one of three etcd voters.

If SMBIOS still refuses, the fallback is the BIOS setup screen (Dell calls it
Primary/Custom charge mode), which needs physical access.

---

## 3. Confirm laptop-4's cap took

Set to 80 via a privileged pod on 2026-08-14 while it read `Charging` at 96%.
The write stuck (reads back 80) but the EC hadn't acted yet, so this is unproven.

```bash
tailscale ssh root@zachd-ubuntu-laptop-4 \
  'cat /sys/class/power_supply/BAT0/{capacity,status,charge_control_end_threshold}'
```

Capacity should now be at or near 80. If it's still 96% and `Charging`, the
Grunt's EC is ignoring the threshold and the node needs the same treatment as
the Dells — or acceptance that it has no working cap.

Also note: `battery-threshold.service` was installed there by symlink rather than
`systemctl enable`, so confirm systemd picked it up:

```bash
tailscale ssh root@zachd-ubuntu-laptop-4 'systemctl is-enabled battery-threshold.service'
```

---

## 4. laptop-3 post-mortem — do this first when it powers on

The most important single command in this document. `zachd-ubuntu-laptop-3` is a
2011 MacBook Pro, the same Apple platform as laptop-1, so it is one of the only
two machines in the fleet that had a **working** battery temperature watchdog.
It went completely dark — no ARP response on 192.168.4.27 from a wired node on
the same subnet — which is consistent with a clean `shutdown now`.

If the watchdog fired, the battery reached 55C, which points toward swelling
rather than away from it.

```bash
journalctl -b -1 -t battery-watchdog --no-pager
journalctl -b -1 -p err --no-pager | tail -50
```

**Before powering it on**, physically check for a bowed bottom case or a
trackpad that no longer clicks — the classic swollen-cell tells. If either is
present, do not power it on; remove the battery first.

The node is otherwise expendable: zero PVs, no unique workloads, everything
rescheduled cleanly, and it's the slowest machine in the fleet
(i5-2435M, 4 GB, 5400 rpm HDD). Retiring it is a reasonable outcome.

```bash
kubectl delete node zachd-ubuntu-laptop-3   # clears the stuck Terminating pods
```

Then drop it from `selfhosted/infra/duckdns/values.yaml:101`.

---

## 5. Verify the whole thing end to end

```bash
SSH_USER=root ~/code/selfhosted/scripts/k3s/debug.sh --all
```

Per-node spot check:

```bash
for n in zachd-ubuntu-laptop zachd-ubuntu-laptop-1 zachd-ubuntu-laptop-2 \
         zachd-ubuntu-laptop-4 zachd-ubuntu-laptop-5 zachd-ubuntu-laptop-6; do
  echo "=== $n"
  tailscale ssh root@$n 'systemctl is-enabled battery-watchdog.timer battery-cap-verify.timer; \
     journalctl -t battery-watchdog -t battery-cap-verify -n 3 --no-pager'
done
```

Force a test alert to confirm ntfy reaches your phone:

```bash
tailscale ssh root@zachd-ubuntu-laptop-6 \
  '. /usr/local/lib/battery-notify.sh; battery_notify "test" "reachability check" low'
```

---

## Fleet state as of 2026-08-14

Battery health is percent of design capacity. "Cap holding" is whether the
75-80% charge limit is actually in effect, not merely configured.

| Node | Machine | Health | Cap holding | Temp tier |
|---|---|---|---|---|
| `zachd-ubuntu-laptop` | XPS 13 9350 | **63%** | **NO** — 100%, firmware ignores sysfs | proxy (`dell_smm/Ambient`) |
| `zachd-ubuntu-laptop-1` | MacBookAir6,2 2013 | 86% | yes — BCLM + drain timer, 69% | **true sensor** |
| `zachd-ubuntu-laptop-2` | Latitude E7250 | unknown (firmware misreports) | suspect — 91% | proxy (`dell_smm/Ambient`) |
| `zachd-ubuntu-laptop-3` | MacBookPro8,1 2011 | unknown — **dead** | unknown | true sensor (presumed) |
| `zachd-ubuntu-laptop-4` | Grunt Chromebook | 98% | unproven — set to 80 on 2026-08-14 | proxy (`cros_ec/Charger`) |
| `zachd-ubuntu-laptop-5` | Galtic Chromebook | 96% | yes — 76% | proxy (`cros_ec/Charger`) |
| `zachd-ubuntu-laptop-6` | Latitude 3190 | 71% | yes — 78% | proxy (`dell_smm/Ambient`) |

`zachd-ubuntu`, `zachd-ubuntu-1`, and `zachd-ubuntu-2` have no battery.

Only laptop-1 has a true battery thermistor, so it is the only machine that will
auto-shut-down on a hot cell. Everything else is warn-only by design — see the
tier comments in `battery-watchdog`.

---

## Known gaps

- `apply-battery.sh` duplicates the battery blocks in `join-cluster.sh`. They
  were reconciled by hand on 2026-08-14 and will drift. Worth factoring into one
  sourced file, or folding into `apply-updates.sh` (which already exists for
  exactly this "replay onto an existing node" purpose).
- `laptop-6` runs at 76C, the hottest in the fleet, doing real work on WiFi with
  no ethernet. Worth checking its fan and vents while you're in there.
- `zachd-ubuntu-laptop-1` is a 4 GB 2013 MacBook Air serving as an etcd voter.
  Its battery is fine; the fragility is the role. Promoting `zachd-ubuntu-2`
  (Mac mini, 6c/12t, 32 GB) to etcd and demoting it is worth doing regardless of
  the battery work.
- `debug.sh` reports SSH failures as `N/A` rather than an error, so a wrong
  `SSH_USER` produces a report that looks healthy and is entirely empty.
