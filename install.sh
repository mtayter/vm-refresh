#!/usr/bin/env bash
# install.sh — install the vm-refresh hook + recovery dispatcher from this repo.
#
# What it does:
#   1. Reads the LOCAL config (default ~/.config/vm-refresh/config.json,
#      or $VM_REFRESH_CONFIG). If it is missing, prints setup instructions
#      and exits — it never invents a side-chat ID.
#   2. Ensures the config is mode 0600 (it holds the side-chat ID and
#      this VM's recovery actions — never commit it).
#   3. Copies vm-refresh-check.sh and vm-boot-recovery.sh to the hook
#      script destinations from the config, mode +x.
#   4. Unless --skip-hook-definition: renders vm-refresh-check.json.template
#      with the side-chat ID from the config and writes the live hook
#      definition (backing up any existing one to .bak first).
#
# The side-chat ID is read from the config inside Python and never
# printed, echoed, or passed on a command line.
#
# Usage:
#   ./install.sh                        # full install
#   ./install.sh --dry-run              # show what would be done, write nothing
#   ./install.sh --skip-hook-definition # install scripts only, leave the
#                                       # live hook definition untouched
#   ./install.sh --config PATH          # use a different config file
#
# After installing, the persistent agent's respawn flow is unchanged:
# on VM replacement the hook wakes it, it respawns the listener, then it
# confirms by updating the stored boot ID (see README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${VM_REFRESH_CONFIG:-$HOME/.config/vm-refresh/config.json}"
DRY_RUN=0
SKIP_DEF=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --skip-hook-definition) SKIP_DEF=1; shift ;;
        --config) CONFIG="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

expand() { # expand leading ~/ in a path
    case "$1" in
        # NOTE: do NOT use ${1#~/} here — the ~/ in a ${var#...} pattern
        # gets tilde-expanded, so it never matches. Substring is safe.
        "~/"*) printf '%s/%s' "$HOME" "${1:2}" ;;
        "~") printf '%s' "$HOME" ;;
        *) printf '%s' "$1" ;;
    esac
}

# --- config ---------------------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    cat >&2 <<EOF
No config at $CONFIG.

Set it up first:
  mkdir -p ~/.config/vm-refresh
  cp "$SCRIPT_DIR/config.example.json" ~/.config/vm-refresh/config.json
  chmod 600 ~/.config/vm-refresh/config.json
  # edit it: fill in side_chat_id + your recovery_actions
Then re-run ./install.sh.
EOF
    exit 1
fi

# Validate config + resolve destinations (ID is never printed).
# NOTE: the Python exit status must be checked explicitly — a failure
# inside $(...) alone would NOT stop the script (the substitution's
# status is discarded; only `read`'s status would remain).
VALIDATED="$(python3 - "$CONFIG" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
sid = cfg.get("side_chat_id", "")
assert sid and sid != "YOUR_SIDE_CHAT_ID_HERE", \
    "side_chat_id is missing or still the placeholder — fill in config first"
assert isinstance(cfg.get("recovery_actions", []), list), \
    "recovery_actions must be an array"
print(cfg.get("hook_script_dest", "~/hooks/scripts/vm-refresh-check.sh"),
      cfg.get("recovery_script_dest", "~/hooks/scripts/vm-boot-recovery.sh"),
      cfg.get("hook_definition_dest", "~/hooks/definitions/vm-refresh-check.json"))
PYEOF
)" || {
    echo "ERROR: config validation failed (see above) — not installing." >&2
    exit 1
}
read -r HOOK_SCRIPT_DEST RECOVERY_SCRIPT_DEST HOOK_DEF_DEST <<<"$VALIDATED"
HOOK_SCRIPT_DEST="$(expand "$HOOK_SCRIPT_DEST")"
RECOVERY_SCRIPT_DEST="$(expand "$RECOVERY_SCRIPT_DEST")"
HOOK_DEF_DEST="$(expand "$HOOK_DEF_DEST")"

say() { echo "$*"; }

if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] would chmod 600 $CONFIG"
    say "[dry-run] would copy $SCRIPT_DIR/vm-refresh-check.sh -> $HOOK_SCRIPT_DEST (+x)"
    say "[dry-run] would copy $SCRIPT_DIR/vm-boot-recovery.sh -> $RECOVERY_SCRIPT_DEST (+x)"
    if [ "$SKIP_DEF" = 1 ]; then
        say "[dry-run] would skip hook definition (--skip-hook-definition)"
    else
        say "[dry-run] would render vm-refresh-check.json.template -> $HOOK_DEF_DEST"
        say "[dry-run] (side_chat_id: set, not shown)"
    fi
    exit 0
fi

chmod 600 "$CONFIG"
say "Config $CONFIG is mode 0600."

mkdir -p "$(dirname "$HOOK_SCRIPT_DEST")" "$(dirname "$RECOVERY_SCRIPT_DEST")"
cp "$SCRIPT_DIR/vm-refresh-check.sh" "$HOOK_SCRIPT_DEST"
cp "$SCRIPT_DIR/vm-boot-recovery.sh" "$RECOVERY_SCRIPT_DEST"
chmod +x "$HOOK_SCRIPT_DEST" "$RECOVERY_SCRIPT_DEST"
say "Installed hook script -> $HOOK_SCRIPT_DEST"
say "Installed recovery dispatcher -> $RECOVERY_SCRIPT_DEST"

if [ "$SKIP_DEF" = 1 ]; then
    say "Skipped hook definition (--skip-hook-definition). Live hook definition untouched."
    exit 0
fi

mkdir -p "$(dirname "$HOOK_DEF_DEST")"
if [ -f "$HOOK_DEF_DEST" ]; then
    cp "$HOOK_DEF_DEST" "$HOOK_DEF_DEST.bak"
    say "Backed up existing hook definition -> $HOOK_DEF_DEST.bak"
fi
# Render the template with the side-chat ID from the config. The ID is
# read from the config file inside Python — never printed or argv-passed.
python3 - "$CONFIG" "$SCRIPT_DIR/vm-refresh-check.json.template" "$HOOK_DEF_DEST" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
sid = cfg.get("side_chat_id", "")
assert sid and sid != "YOUR_SIDE_CHAT_ID_HERE", "side_chat_id missing or placeholder"
text = open(sys.argv[2]).read()
assert "YOUR_SIDE_CHAT_ID_HERE" in text, "template missing placeholder"
text = text.replace("YOUR_SIDE_CHAT_ID_HERE", sid)
assert "YOUR_SIDE_CHAT_ID_HERE" not in text, "placeholder survived rendering"
json.loads(text)  # rendered definition must be valid JSON
open(sys.argv[3], "w").write(text)
PYEOF
say "Rendered live hook definition -> $HOOK_DEF_DEST"
say "Install complete. The hook takes effect when the hook system next loads the definition."
