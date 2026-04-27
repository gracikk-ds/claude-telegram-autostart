# claude-telegram-autostart

Auto-start the [Claude Code](https://claude.ai/code) Telegram channel listener
at macOS login — no terminal window, just a native confirmation dialog.

![macOS](https://img.shields.io/badge/macOS-13%2B-black) ![License](https://img.shields.io/badge/license-MIT-blue)

## What it does

- A `LaunchAgent` fires when you log in.
- A native macOS dialog asks **"Ready to start Claude Telegram session?"** (auto-dismisses after 30s).
- On confirm, it spawns `claude --channels plugin:telegram@claude-plugins-official` inside a **detached `tmux` session** — no visible window.
- You can `tmux attach -t claude-tg` any time to inspect or interact.
- A second LaunchAgent runs a **watchdog every 60s** that detects silent
  hangs (e.g. half-open TCP after a VPN re-handshake) and recovers the
  session — SIGHUP first, full restart as fallback.

## Why not just run claude in the background?

Claude Code is interactive and needs a TTY. `nohup` / plain `&` won't work.
Running inside a detached `tmux` gives it a virtual PTY, keeps it alive across
sleep/wake, and lets you peek into the session whenever you want.

The Telegram channel itself spawns a long-lived `bun` MCP server
(`~/.claude/channels/telegram/bot.pid`) that lives as long as the parent claude
process — so killing claude kills the Telegram listener. Hence the need to
keep the claude session running somewhere.

## Requirements

- macOS 13+
- [`tmux`](https://github.com/tmux/tmux) — `brew install tmux`
- [Claude Code CLI](https://claude.ai/code) with the `claude-plugins-official`
  marketplace installed and the `telegram` channel configured (run
  `/telegram:configure` inside a claude session first).

## Quick start

```sh
git clone https://github.com/gracikk-ds/claude-telegram-autostart.git
cd claude-telegram-autostart
./install.sh
```

The installer will:

1. Detect `tmux` and `claude` paths.
2. Ask for your `PROJECT_DIR` (the directory the claude session will run in).
3. Drop config at `~/.config/claude-telegram-autostart/config.env`.
4. Install the runtime script at `~/.local/bin/start-claude-telegram.sh`.
5. Render and load the LaunchAgent at `~/Library/LaunchAgents/com.<user>.claude-telegram.plist`.

To test without waiting for next login:

```sh
~/.local/bin/start-claude-telegram.sh
```

## How it works

```
login
  └─ launchd (RunAtLoad, Aqua-only)
       └─ ~/.local/bin/start-claude-telegram.sh
            ├─ guards: deps present? tmux session already up? bot.pid alive?
            ├─ sweep stray bun server.ts orphans (prior-session zombies)
            ├─ osascript display dialog ───── user clicks Start ─┐
            └─ tmux new-session -d -s claude-tg ────────────────┘
                 └─ claude --channels plugin:telegram@claude-plugins-official
                      └─ spawns bun MCP server (Telegram bot)

every 60s
  └─ launchd (StartInterval=60)
       └─ ~/.local/bin/claude-telegram-watchdog.sh
            ├─ skip if no tmux session (user-initiated stop)
            ├─ skip if api.telegram.org unreachable (real network outage)
            ├─ skip if bot.pid points to a foreign bun (parallel MCP
            │   runner like Cursor's mcp.json racing for getUpdates)
            ├─ check: bot pid is descendant of our tmux claude
            │         + ESTABLISHED TCP to telegram CIDR
            └─ on 2nd consecutive failure: SIGHUP bot → if no recovery,
               kill tmux + re-run start script with WATCHDOG=1
```

### When does this fire?

The most common silent failure mode for the Telegram bridge is a
half-open TCP socket after the underlying VPN/WireGuard tunnel
re-handshakes (NAT mapping changes, peer rotates). The plugin's
long-poll `getUpdates` blocks forever on the dead socket because the
TCP stack never sees a FIN/RST. The watchdog detects this in <2 minutes
and restarts cleanly.

## Configuration

Edit `~/.config/claude-telegram-autostart/config.env`:

| Variable          | Default                                       | Description                                            |
|-------------------|-----------------------------------------------|--------------------------------------------------------|
| `PROJECT_DIR`     | `$HOME`                                       | Working directory for the claude session.              |
| `TMUX_SESSION`    | `claude-tg`                                   | tmux session name.                                     |
| `TMUX_BIN`        | auto-detected                                 | Absolute path to `tmux`.                               |
| `CLAUDE_BIN`      | auto-detected                                 | Absolute path to `claude`.                             |
| `CHANNELS_SPEC`   | `plugin:telegram@claude-plugins-official`     | Value passed to `claude --channels`.                   |
| `DIALOG_TIMEOUT`  | `30`                                          | Seconds before the dialog auto-skips.                  |
| `LOG_FILE`        | `~/Library/Logs/claude-telegram.log`          | Where the runtime script appends its log.              |

Changes take effect on next launch (no need to reload the LaunchAgent).

## Logs & debugging

| File                                                       | What it contains                                       |
|------------------------------------------------------------|--------------------------------------------------------|
| `~/Library/Logs/claude-telegram.log`                       | Runtime script log (timestamps, decisions).            |
| `~/Library/Logs/claude-telegram-launchd.log`               | LaunchAgent stdout (script output).                    |
| `~/Library/Logs/claude-telegram-launchd.err.log`           | LaunchAgent stderr.                                    |
| `~/Library/Logs/claude-telegram-watchdog.log`              | Watchdog probe results, strikes, recovery actions.     |
| `~/Library/Logs/claude-telegram-watchdog-launchd.log`      | Watchdog LaunchAgent stdout.                           |
| `~/Library/Logs/claude-telegram-watchdog-launchd.err.log`  | Watchdog LaunchAgent stderr.                           |

Inspect the live session:

```sh
tmux ls
tmux attach -t claude-tg     # detach with Ctrl-b d
```

LaunchAgent status:

```sh
launchctl print "gui/$(id -u)/com.$(id -un).claude-telegram"
```

## Uninstall

```sh
./uninstall.sh           # interactive, asks before deleting config & logs
./uninstall.sh --purge   # remove everything, no prompts
```

## Troubleshooting

**Dialog never appears.** macOS may need to grant `osascript` permission to
display notifications/dialogs the first time. Approve the prompt in System
Settings → Privacy & Security → Automation.

**`tmux: command not found` in the launchd log.** LaunchAgents run with a
minimal `PATH`. The installer hard-codes Homebrew paths; if your `tmux` lives
elsewhere, set `TMUX_BIN` explicitly in `config.env`.

**"already running" notification but I see no window.** That's by design — the
session is detached. Use `tmux attach -t claude-tg` to see it.

**Stale `bot.pid` after a crash.** The script detects this via `kill -0` and
proceeds anyway. If anything looks off, `rm ~/.claude/channels/telegram/bot.pid`.

**Bot stops responding but watchdog log says `foreign bun in bot.pid=…`.**
Another app on the same machine has its own copy of the telegram MCP
plugin running and is winning the `getUpdates` race for your bot token.
The most common source is Cursor with the plugin wired into
`~/.cursor/mcp.json` — close Cursor (or remove the entry), then
`rm ~/.claude/channels/telegram/bot.pid` and the watchdog will rebuild
our session on its next tick. To find which app spawned the foreign bun:
`ps -p $(cat ~/.claude/channels/telegram/bot.pid) -o pid,ppid,command=`,
then walk the ppid chain.

**Bot stops responding even though tmux is alive.** Almost always a half-
open TCP socket after a VPN re-handshake. The watchdog auto-recovers
within ~2 minutes; tail `~/Library/Logs/claude-telegram-watchdog.log` to
confirm. If you're on **WireGuard / AmneziaWG / OpenVPN over UDP**, the
single highest-leverage prevention is to set
`PersistentKeepalive = 25` under the relevant `[Peer]` in your tunnel
config — this keeps the UDP NAT mapping warm and prevents the silent
re-NAT that breaks tunnelled TCP in the first place. The watchdog is
the safety net for everything else (Wi-Fi roams, Sleep/Wake, ISP blips).

**Watchdog keeps thrashing the session.** Check the log: if every probe
fails with "no ESTABLISHED TCP to telegram CIDR":

- **WireGuard / AmneziaWG tunnel?** A too-high MTU (default 1420) causes
  PMTU blackholing — large TLS server certificates are silently dropped,
  making every HTTPS handshake hang until timeout. Fix: set `MTU = 1280`
  in the `[Interface]` section of your tunnel config and reconnect.

- **Bot genuinely broken?** Capture a stack trace before the next restart
  (`sample <pid> 5 -file /tmp/bun.sample`) and file an upstream issue.
