# claude-telegram-autostart

Auto-start the [Claude Code](https://claude.ai/code) Telegram channel listener
at macOS login — no terminal window, just a native confirmation dialog.

![macOS](https://img.shields.io/badge/macOS-13%2B-black) ![License](https://img.shields.io/badge/license-MIT-blue)

## What it does

- A `LaunchAgent` fires when you log in.
- A native macOS dialog asks **"Ready to start Claude Telegram session?"** (auto-dismisses after 30s).
- On confirm, it spawns `claude --channels plugin:telegram@claude-plugins-official` inside a **detached `tmux` session** — no visible window.
- You can `tmux attach -t claude-tg` any time to inspect or interact.

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
            ├─ osascript display dialog ───── user clicks Start ─┐
            └─ tmux new-session -d -s claude-tg ────────────────┘
                 └─ claude --channels plugin:telegram@claude-plugins-official
                      └─ spawns bun MCP server (Telegram bot)
```

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

| File                                            | What it contains                            |
|-------------------------------------------------|---------------------------------------------|
| `~/Library/Logs/claude-telegram.log`            | Runtime script log (timestamps, decisions). |
| `~/Library/Logs/claude-telegram-launchd.log`    | LaunchAgent stdout (script output).         |
| `~/Library/Logs/claude-telegram-launchd.err.log`| LaunchAgent stderr.                         |

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
