#!/usr/bin/env bash
# vm-boot-recovery — generalized, config-driven recovery dispatcher.
#
# Runs on VM replacement (invoked by vm-refresh-check.sh). Executes the
# ordered recovery actions from the local config file — nothing about
# this VM's services is hardcoded here. VM-specific actions live ONLY in
# the local config (mode 0600, never committed).
#
# Config: $VM_REFRESH_CONFIG, or ~/.config/vm-refresh/config.json.
# See config.example.json for the schema and an example first action.
#
# Action schema (each action needs a "name"):
#   {"name": str,
#    "enabled": bool (default true — false skips the action),
#    "type": "restore-file" | "run",
#    "continue_on_error": bool (default false — abort on failure),
#    restore-file: "source", "dest", "mode" (default "0600"),
#                  "if_missing" (default true — skip when dest exists),
#    run: "command" (shell command, run via bash -c)}
#
# Idempotency: the hook retries until the persistent agent confirms the
# respawn, so this dispatcher may run several times for one replacement.
# Every action MUST be idempotent. restore-file with if_missing is
# idempotent by construction; "run" actions must guard against
# double-start themselves (e.g. via a pid file).
#
# What goes here vs elsewhere: file restores and DETACHED service loops
# (loops that log to a file) belong here. The persistent listener does
# NOT belong here — the side chat spawns it so it keeps its stdout
# handoff. Service loops themselves live in their own repos; this
# dispatcher only references their installed paths via config.

set -uo pipefail

CONFIG="${VM_REFRESH_CONFIG:-$HOME/.config/vm-refresh/config.json}"

# --- config field lookup (re-parses per field; action lists are short) -----
cfg_field() { # cfg_field <index> <field> — prints the raw value or empty
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
actions = cfg.get("recovery_actions", [])
idx, field = int(sys.argv[2]), sys.argv[3]
if idx >= len(actions):
    print("")
    sys.exit(0)
v = actions[idx].get(field, "")
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("")
else:
    print(str(v))
' "$CONFIG" "$1" "$2"
}

fail_or_continue() { # fail_or_continue <continue_on_error> <message>
    echo "ERROR: $2" >&2
    if [ "$1" = "true" ]; then
        echo "continuing (continue_on_error=true)" >&2
        return 0
    fi
    exit 1
}

if [ ! -f "$CONFIG" ]; then
    echo "vm-boot-recovery: no config at $CONFIG — nothing to do" >&2
    exit 1
fi

PERMS="$(stat -c %a "$CONFIG" 2>/dev/null || echo "?")"
case "$PERMS" in
    600) ;;
    *) echo "WARNING: config $CONFIG has mode $PERMS, expected 0600" >&2 ;;
esac

if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG"; then
    echo "ERROR: invalid JSON in $CONFIG" >&2
    exit 1
fi

i=0
while true; do
    NAME="$(cfg_field "$i" name)"
    [ -n "$NAME" ] || break
    ENABLED="$(cfg_field "$i" enabled)"
    if [ "$ENABLED" = "false" ]; then
        echo "skip (disabled): $NAME"
        i=$((i + 1))
        continue
    fi
    TYPE="$(cfg_field "$i" type)"
    COE="$(cfg_field "$i" continue_on_error)"
    [ "$COE" = "true" ] || COE="false"

    case "$TYPE" in
        restore-file)
            SRC="$(cfg_field "$i" source)"
            DST="$(cfg_field "$i" dest)"
            SRC="${SRC/#\~/$HOME}"
            DST="${DST/#\~/$HOME}"
            MODE="$(cfg_field "$i" mode)"
            [ -n "$MODE" ] || MODE="0600"
            IFMISSING="$(cfg_field "$i" if_missing)"
            [ "$IFMISSING" = "false" ] || IFMISSING="true"
            if [ "$IFMISSING" = "true" ] && [ -e "$DST" ]; then
                echo "skip (dest exists): $NAME ($DST)"
            elif [ ! -f "$SRC" ]; then
                fail_or_continue "$COE" "restore-file source missing: $SRC ($NAME)" || true
                [ "$COE" = "true" ] || exit 1
            else
                mkdir -p "$(dirname "$DST")"
                cp "$SRC" "$DST"
                chmod "$MODE" "$DST"
                echo "restored: $NAME ($SRC -> $DST)"
            fi
            ;;
        run)
            CMD="$(cfg_field "$i" command)"
            if [ -z "$CMD" ]; then
                fail_or_continue "$COE" "run action has empty command: $NAME" || true
                [ "$COE" = "true" ] || exit 1
            elif OUT="$(bash -c "$CMD" 2>&1)"; then
                echo "ran: $NAME"
                [ -n "$OUT" ] && printf '%s\n' "$OUT" | head -20
            else
                printf '%s\n' "$OUT" | head -20 >&2
                fail_or_continue "$COE" "action '$NAME' failed" || true
                [ "$COE" = "true" ] || exit 1
            fi
            ;;
        *)
            fail_or_continue "$COE" "unknown action type '$TYPE' for '$NAME'" || true
            [ "$COE" = "true" ] || exit 1
            ;;
    esac
    i=$((i + 1))
done

echo "vm-boot-recovery complete"
