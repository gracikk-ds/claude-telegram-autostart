# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A small macOS-only Bash project that auto-starts the Claude Code Telegram channel listener at login and keeps it healthy. Two LaunchAgents drive two shell scripts; there is no application code, no test suite, no build step. Total surface: ~4 shell scripts and 2 plist templates.

## Common commands

```sh
./install.sh                # interactive install
./install.sh --dry-run      # print actions only
./install.sh --no-load      # install files but skip launchctl bootstrap
./install.sh --yes          # non-interactive (uses $PROJECT_DIR or $HOME)

./uninstall.sh              # interactive cleanup
./uninstall.sh --yes        # non-interactive
./uninstall.sh --purge      # also wipe ~/.claude/channels/telegram (forces re-pair)

# Manual exercise of installed scripts (post-install paths):
~/.local/bin/start-claude-telegram.sh           # pops the dialog, starts session
WATCHDOG=1 ~/.local/bin/start-claude-telegram.sh # bypass dialog (used by watchdog)
~/.local/bin/claude-telegram-watchdog.sh         # one-shot probe + recover

# Inspect the running session:
tmux ls
tmux attach -t claude-tg                         # detach: Ctrl-b d

# LaunchAgent state:
launchctl print "gui/$(id -u)/com.$(id -un).claude-telegram"
launchctl print "gui/$(id -u)/com.$(id -un).claude-telegram-watchdog"

# Lint shell changes (no CI; run locally):
shellcheck bin/*.sh install.sh uninstall.sh
```

There are **no tests**. Verification is empirical: install on a Mac, look at `~/Library/Logs/claude-telegram*.log`, and confirm `tmux has-session -t claude-tg`.

## Architecture — what requires reading multiple files to understand

### The two-LaunchAgent model

Login flow and watchdog flow are **separate** agents with different lifetimes:

- `com.<user>.claude-telegram` — `RunAtLoad=true`, `LimitLoadToSessionType=Aqua`, `ProcessType=Interactive`. Fires once per GUI login. Runs `start-claude-telegram.sh`.
- `com.<user>.claude-telegram-watchdog` — `StartInterval=60`, `ProcessType=Background`. Fires every 60s. Runs `watchdog.sh`.

Both are rendered from templates in `launchd/` by `install.sh` (sed substitutions: `__LABEL__`, `__SCRIPT__`, `__HOME__`, `__PATH__`). LaunchAgents run with a minimal `PATH`, which is why the install script hard-codes `/opt/homebrew/bin:/usr/local/bin:...` into the plist and resolves `tmux` / `claude` absolute paths into `config.env`.

### The detachment chain

`launchd → start-claude-telegram.sh → osascript dialog → tmux new-session -d → claude --channels … → bun MCP server`

Why `tmux`: the `claude` CLI is interactive and needs a TTY. `nohup` / `&` won't work. A detached `tmux` session provides a virtual PTY that survives sleep/wake and is attachable on demand. Killing the `claude` process kills the `bun` Telegram MCP server because the latter is a child.

The PID file at `~/.claude/channels/telegram/bot.pid` is written **by the plugin**, not by us. We only read it (to detect "already running") and delete it (during recovery). Treat it as plugin-owned state.

### The watchdog state machine

`watchdog.sh` is a 2-strike state machine designed for **silent failures the plugin cannot detect itself** — primarily a half-open TCP socket after a WireGuard NAT rebind, where `getUpdates` blocks forever on a dead long-poll socket.

Each invocation:
1. **Bail-outs that do not increment strikes** (so they don't trigger spurious recovery):
   - No tmux session (treat as user-initiated stop).
   - `curl https://api.telegram.org/` fails (real network outage / VPN down).
2. **Foreign-bot bail-out** (`bot_is_foreign`): if `bot.pid` points to a live plugin bun whose ppid chain does NOT lead to our tmux pane's claude, another app has spawned its own `bun` for this plugin (most commonly Cursor with telegram in `~/.cursor/mcp.json`) and is racing us for `getUpdates`. We log it, reset strikes, and exit without recovery — SIGHUPing or killing a foreign process would be hostile, and a `hard_restart` would just trigger an immediate respawn loop with the other app. The user must close the other instance.
3. **Probe**: bot PID alive AND ppid chain leads to our tmux pane's claude AND `netstat` shows an `ESTABLISHED` TCP connection to the Telegram CIDRs (`149.154.` or `91.108.`).
   - **Don't switch `netstat` for `lsof`.** lsof reports CLOSED for these sockets when Kaspersky Web Protection intercepts TLS at the network-extension layer. netstat reads the kernel TCP table directly. This is documented inline in `has_established_to_telegram()` and is the reason for the netstat-based probe.
   - **Why ancestry, not just cwd.** Pre-fix, `bot_pid()` only checked `cwd` matches the plugin path. A parallel claude/MCP runner on the same machine (Cursor, a second tmux, etc.) would also pass cwd check, and watchdog would see "ok" forever even though the foreign bun was eating all the messages. The `is_descendant` walk from `bot.pid` up to the tmux pane PID is the discriminator.
4. On probe success → reset strikes. On failure → increment strikes; recover only at strike 2 (`STRIKE_THRESHOLD=2`, ~120s real-world delay) to give grammy a chance to reconnect on its own.
5. **Recovery escalation**: SIGHUP the bot PID, wait `SIGHUP_GRACE_SECONDS=10`, re-probe. If still bad, `tmux kill-session` + re-invoke `start-claude-telegram.sh` with `WATCHDOG=1` (which skips the macOS confirmation dialog).

Persistent state: strike counter at `~/.claude/channels/telegram/watchdog.state`. Single-flight via `mkdir` lock at `~/.claude/channels/telegram/watchdog.lock.d/` — atomic on macOS, no `flock` needed; stale locks older than 600s are reclaimed.

### Orphan bun sweep

Both `start-claude-telegram.sh` and `uninstall.sh` define the same `find_plugin_bun_pids()` helper. The plugin's `bun` argv shows `/private/tmp/bun-node-*/bun` with no plugin path, so process matching by command line doesn't work. Identify by **cwd via `lsof`** matching `*claude-plugins-official/telegram*`. Orphans from prior crashed sessions race the live bot on `getUpdates` and hold half-open sockets — they must be killed before starting a fresh session, or the new bot will silently lose `getUpdates` polls to the orphan.

If you change the cwd-matching pattern in one place, **change it in both files** — there is no shared lib.

### Configuration flow

`config/config.example.env` is documentation. The actual config file `~/.config/claude-telegram-autostart/config.env` is **generated by `install.sh`** with auto-detected `TMUX_BIN` / `CLAUDE_BIN` and a user-supplied `PROJECT_DIR`. Both runtime scripts source it; the watchdog sources it **first** and then overrides `LOG_FILE`-equivalent paths so it doesn't write to the start script's log.

### What separates "infrastructure" state from "plugin" state

| Owner   | Files |
|---------|-------|
| Plugin  | `~/.claude/channels/telegram/{.env, access.json, approved/, bot.pid}` |
| This repo | `~/.claude/channels/telegram/{watchdog.state, watchdog.lock.d/}` |

`uninstall.sh` (without `--purge`) removes only **our** state. `--purge` wipes the whole channel dir, forcing the user to re-pair. Preserve this distinction in any cleanup change.

## Conventions specific to this repo

- All scripts use `set -euo pipefail`. Keep it.
- `WATCHDOG=1` is the only env flag that crosses script boundaries (start script reads it to skip the dialog).
- Logs go to `~/Library/Logs/claude-telegram*.log` — six files total (runtime, launchd stdout, launchd stderr × 2 agents). Don't introduce new log destinations.
- `install.sh` must be **idempotent**: re-running it must not break a working install. Existing `config.env` is preserved with a warning.
- `uninstall.sh` uses `set -uo pipefail` (no `-e`) on purpose — cleanup must continue past individual failures.
- Telegram CIDR allowlist `149.154.|91.108.` is hardcoded in `watchdog.sh`. If Telegram's IP ranges change, update `TELEGRAM_CIDR_REGEX` there.

## Out of scope for this project

The user's global `~/.claude/CLAUDE.md` describes Python/ML standards (pydantic, loguru, pytest, layer-lint, etc.). **None of that applies here** — this repo has no Python. Don't run `/layer-lint`, don't reach for `click` or `pydantic`. The relevant portable rules are: English-only text, fix root causes instead of suppressing warnings, no dead code, no duplicate logic across files (see the orphan-sweep helper note above for the one knowing exception).
