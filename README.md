# vm-refresh

Detect VM replacement via boot-ID change and run ordered, config-driven
recovery. VM-only runtime: it reads `/proc/sys/kernel/random/boot_id` and
runs under the hook system (`$HATCH_HOOK_RUNTIME` provides `log` /
`silent` / `wake`; without it the hook falls back to echo stubs).

## How it works

```
VM replaced (boot_id changes)
  → vm-refresh-check.sh (15s poll) detects the mismatch
    → runs vm-boot-recovery.sh (ordered actions from local config)
    → wakes the persistent agent (side chat)
      → persistent agent respawns the long-running listener / processes
      → persistent agent CONFIRMS by updating the stored boot ID:
          cat /proc/sys/kernel/random/boot_id > ~/.last_boot_id
```

Three design rules, all load-bearing:

1. **Edge-triggered, boot-ID only.** The hook compares the current boot
   ID against the stored one. That is its only wake reason.
2. **Confirm-after-respawn / at-least-once delivery.** The hook NEVER
   updates the stored boot ID. The persistent agent updates it AFTER
   respawning, confirming the respawn. Until it does, the hook keeps
   waking on every poll — intentional at-least-once delivery. If a wake
   is lost, the next poll retries.
3. **No level-triggered listener-health polling.** Do NOT add "is the
   listener alive?" checks to this hook. A level-triggered liveness
   check wakes on EVERY poll while the condition holds (observed: 103
   wakes in 35 minutes in testing) — a wake storm. Listener health is
   the listener owner's problem (its own supervision / restart path),
   never this hook's.

## Files

- `vm-refresh-check.sh` — the hook script: boot-ID detection, recovery
  run, wake. No service paths hardcoded.
- `vm-boot-recovery.sh` — generalized recovery dispatcher. Executes the
  ordered `recovery_actions` from the local config. Nothing about this
  VM's services is hardcoded here.
- `vm-refresh-check.json.template` — hook-definition template. The
  installer renders it with the side-chat ID from local config.
- `config.example.json` — example local config (mode 0600, never
  committed). The first action restores the persistent SSH config that
  VM replacement wipes (`~/.ssh/config` → `/root/.ssh/config`).
- `install.sh` — installs the scripts and renders the live hook
  definition from the template + local config.

## Setup

```bash
mkdir -p ~/.config/vm-refresh
cp config.example.json ~/.config/vm-refresh/config.json
chmod 600 ~/.config/vm-refresh/config.json
# edit it: fill in side_chat_id + your recovery_actions
./install.sh
```

`install.sh` never prints the side-chat ID. Options:

- `./install.sh --dry-run` — show what would be done, write nothing.
- `./install.sh --skip-hook-definition` — install scripts only, leave
  the live hook definition untouched.
- `./install.sh --config PATH` — use a different config file.

## Recovery config

`recovery_actions` run in order on every VM replacement. The hook
retries until the persistent agent confirms the respawn, so every
action MUST be idempotent.

Action types:

- `restore-file` — copy `source` → `dest` (default `mode` `0600`,
  default `if_missing` `true`: skip when `dest` already exists).
  Idempotent by construction.
- `run` — run a shell `command` via `bash -c`. The command must guard
  against double-start itself (e.g. via a pid file).

`continue_on_error` (default `false`) controls whether a failed action
aborts the dispatcher. `enabled: false` skips an action.

What belongs in recovery vs elsewhere:

- Belongs here: file restores, and DETACHED service loops (loops that
  log to a file). Service loops themselves live in their own repos;
  the dispatcher only references their installed paths via config.
- Does NOT belong here: the persistent listener. The side chat spawns
  it so it keeps its stdout handoff. Spawns from ephemeral hook runs
  get reaped when the run ends.

## What this repo is NOT

- Not a message listener or sender — that client lives in its own repo.
- Not a health checker — it never polls service health (see rule 3).
- Not a generic cron/supervisor — it runs only on VM replacement.
