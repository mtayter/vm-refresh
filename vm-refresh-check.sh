#!/usr/bin/env bash
# vm-refresh-check — edge-triggered VM-replacement detector.
#
# Polls every 15s (see vm-refresh-check.json.template: poll_interval_secs).
# Compares the current kernel boot_id (/proc/sys/kernel/random/boot_id)
# against the stored value in the last-boot file (default ~/.last_boot_id).
#
# Why 15s: short enough that recovery starts promptly after a replacement,
# and cheap because the check is just a file compare that stays silent
# (no tokens, no wake) when nothing changed.
#
# On a mismatch (VM was replaced):
#   1. Run the recovery dispatcher (vm-boot-recovery.sh) so prerequisites
#      are restored first. Dispatcher failures are logged but do NOT
#      suppress the wake — the persistent agent can repair.
#   2. Wake the persistent agent (side chat), which respawns the
#      long-running listener / processes from a context that survives.
#
# Confirm-after-respawn / at-least-once delivery:
# This script NEVER updates the stored boot_id. The persistent agent
# updates it AFTER respawning, confirming the respawn:
#     cat /proc/sys/kernel/random/boot_id > ~/.last_boot_id
# Until it does, this hook keeps waking on every poll — intentional
# at-least-once delivery. If a wake is lost, the next poll retries.
#
# Explicitly NOT done here — no level-triggered listener-health polling:
# Do NOT add "is the listener alive?" checks to this hook. A
# level-triggered liveness check wakes on EVERY poll while the condition
# holds (observed: 103 wakes in 35 minutes in testing) — a wake storm.
# Listener health is the listener owner's problem (its own supervision /
# restart path), never this hook's. This hook is boot_id-only,
# edge-triggered. The one wake reason is VM replacement.
#
# Service loops stay with their own repos: this script hardcodes no
# service paths. Recovery actions come from the dispatcher's local
# config, and the listener itself is respawned by the persistent agent.
#
# Runtime: the hook system provides $HATCH_HOOK_RUNTIME, which defines
# log / silent / wake. When run manually (no runtime), fallback stubs
# echo to stdout so the script stays testable.

set -uo pipefail

# --- hook runtime: log / silent / wake -------------------------------------
if [ -n "${HATCH_HOOK_RUNTIME:-}" ] && [ -f "$HATCH_HOOK_RUNTIME" ]; then
    # shellcheck disable=SC1090
    source "$HATCH_HOOK_RUNTIME"
else
    log()    { echo "[log] $1 ${2:-}"; }
    silent() { echo "[silent] $1 ${2:-}"; }
    wake()   { echo "[wake] $1 ${2:-}"; }
fi

LAST_BOOT_FILE="${VM_REFRESH_LAST_BOOT_FILE:-$HOME/.last_boot_id}"
RECOVERY_SCRIPT="${VM_REFRESH_RECOVERY_SCRIPT:-$HOME/hooks/scripts/vm-boot-recovery.sh}"

CURRENT_BOOT="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")"

# First run: initialize the file, stay silent.
if [ ! -f "$LAST_BOOT_FILE" ]; then
    printf '%s' "$CURRENT_BOOT" > "$LAST_BOOT_FILE"
    silent "initialized last_boot_id" "{\"boot_id\":\"$CURRENT_BOOT\"}"
    exit 0
fi

LAST_BOOT="$(cat "$LAST_BOOT_FILE" 2>/dev/null || echo "")"

if [ "$CURRENT_BOOT" != "$LAST_BOOT" ]; then
    log "VM replacement detected" "{\"old\":\"$LAST_BOOT\",\"new\":\"$CURRENT_BOOT\"}"
    # Run recovery BEFORE waking, so prerequisites are restored first.
    if [ -x "$RECOVERY_SCRIPT" ]; then
        if "$RECOVERY_SCRIPT" 2>&1 | head -20; then
            log "recovery dispatcher succeeded" '{}'
        else
            log "recovery dispatcher had errors" '{}'
        fi
    else
        log "no recovery dispatcher configured" "{\"path\":\"$RECOVERY_SCRIPT\"}"
    fi
    # Do NOT update the stored boot_id here. The persistent agent updates
    # it AFTER respawning, confirming the respawn (see header comment).
    wake "VM replacement detected" "{\"old_boot_id\":\"$LAST_BOOT\",\"new_boot_id\":\"$CURRENT_BOOT\"}"
    exit 0
fi

silent "healthy" "{\"boot_id\":\"$CURRENT_BOOT\"}"
