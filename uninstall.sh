#!/bin/bash
# uninstall.sh — remove claude-telegram-autostart from this Mac.
#
# Default (interactive): one upfront confirm, then a thorough cleanup —
# unload both LaunchAgents, kill any plugin bun processes (including
# orphans from prior sessions), kill the tmux session, remove our
# installed scripts, plists, state files, and logs, and remove the
# config dir. The Telegram channel's own data (.env with the bot token,
# access.json with the allowlist, approved/) is preserved by default
# so re-installing later doesn't force you to re-pair.
#
# Flags:
#   --yes, -y       Non-interactive (skip the upfront confirm).
#   --purge         Same as --yes, AND also wipe the plugin's channel
#                   data (~/.claude/channels/telegram/), forcing a full
#                   re-pair on next install.
#   --keep-config   Keep ~/.config/claude-telegram-autostart/.
#   --keep-logs     Keep log files in ~/Library/Logs/.
#   --help, -h

set -uo pipefail

PURGE=0
NON_INTERACTIVE=0
KEEP_CONFIG=0
KEEP_LOGS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)        PURGE=1; NON_INTERACTIVE=1 ;;
    --yes|-y)       NON_INTERACTIVE=1 ;;
    --keep-config)  KEEP_CONFIG=1 ;;
    --keep-logs)    KEEP_LOGS=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: ./uninstall.sh [--yes|-y] [--purge] [--keep-config] [--keep-logs]

Removes claude-telegram-autostart from this Mac. By default, prompts
once before doing a thorough cleanup that:
  - unloads both LaunchAgents
  - kills all plugin bun processes (including orphans from prior runs)
  - kills the tmux session
  - removes installed scripts, plists, state files, logs, config dir

The Telegram channel's own data (bot token in .env, access.json,
approved/) is preserved by default — use --purge to wipe it too.

Flags:
  --yes, -y       Non-interactive (skip the upfront confirm).
  --purge         --yes plus wipe ~/.claude/channels/telegram/.
  --keep-config   Keep ~/.config/claude-telegram-autostart/.
  --keep-logs     Keep log files in ~/Library/Logs/.
  --help, -h      Show this help.
EOF
      exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*"; }

USER_NAME="$(id -un)"
LABEL="com.${USER_NAME}.claude-telegram"
WATCHDOG_LABEL="com.${USER_NAME}.claude-telegram-watchdog"
SCRIPT_DST="$HOME/.local/bin/start-claude-telegram.sh"
WATCHDOG_DST="$HOME/.local/bin/claude-telegram-watchdog.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
WATCHDOG_PLIST_DST="$HOME/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
TMUX_SESSION="claude-tg"
TMUX_BIN="$(command -v tmux || true)"
CHANNEL_DIR="$HOME/.claude/channels/telegram"
BOT_PID_FILE="$CHANNEL_DIR/bot.pid"
WATCHDOG_STATE="$CHANNEL_DIR/watchdog.state"
WATCHDOG_LOCK_DIR="$CHANNEL_DIR/watchdog.lock.d"
LOG_FILES=(
  "$HOME/Library/Logs/claude-telegram.log"
  "$HOME/Library/Logs/claude-telegram-launchd.log"
  "$HOME/Library/Logs/claude-telegram-launchd.err.log"
  "$HOME/Library/Logs/claude-telegram-watchdog.log"
  "$HOME/Library/Logs/claude-telegram-watchdog-launchd.log"
  "$HOME/Library/Logs/claude-telegram-watchdog-launchd.err.log"
)

if [ "$NON_INTERACTIVE" -eq 0 ]; then
  echo "This will:"
  echo "  - unload LaunchAgents: $LABEL, $WATCHDOG_LABEL"
  echo "  - kill all plugin bun processes (including orphans)"
  echo "  - kill tmux session: $TMUX_SESSION"
  echo "  - remove: $SCRIPT_DST"
  echo "  - remove: $WATCHDOG_DST"
  echo "  - remove: $PLIST_DST"
  echo "  - remove: $WATCHDOG_PLIST_DST"
  echo "  - remove watchdog state files in $CHANNEL_DIR"
  [ "$KEEP_CONFIG" -eq 0 ] && echo "  - remove: $CONFIG_DIR"
  [ "$KEEP_LOGS"   -eq 0 ] && echo "  - remove log files in ~/Library/Logs/"
  [ "$PURGE"       -eq 1 ] && echo "  - remove channel data: $CHANNEL_DIR (forces re-pair)"
  echo
  if [ "$PURGE" -eq 0 ]; then
    echo "Telegram bot token and allowlist in $CHANNEL_DIR are preserved (use --purge to wipe)."
  fi
  printf 'Continue? [y/N] '
  ans=""
  read -r ans || true
  case "$ans" in y|Y|yes) ;; *) info "aborted"; exit 0 ;; esac
fi

# --- 1. Unload LaunchAgents (idempotent) ---------------------------------
unload_agent() {
  local label="$1" plist="$2"
  info "unloading LaunchAgent ($label)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
    || launchctl unload "$plist" 2>/dev/null \
    || true
}
unload_agent "$WATCHDOG_LABEL" "$WATCHDOG_PLIST_DST"
unload_agent "$LABEL" "$PLIST_DST"

# --- 2. Kill plugin bun processes (orphans from any prior session) -------
# Identify by cwd, since `bun` argv shows /private/tmp/bun-node-*/bun
# without the plugin path. This catches zombies the plist guard misses.
find_plugin_bun_pids() {
  local pid cwd
  for pid in $(pgrep bun 2>/dev/null); do
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}')
    case "$cwd" in
      *claude-plugins-official/telegram*) printf '%s\n' "$pid" ;;
    esac
  done
}

ORPHANS=$(find_plugin_bun_pids | tr '\n' ' ')
if [ -n "$ORPHANS" ]; then
  info "killing plugin bun processes: $ORPHANS"
  # shellcheck disable=SC2086
  kill -TERM $ORPHANS 2>/dev/null || true
  sleep 1
  STILL=$(find_plugin_bun_pids | tr '\n' ' ')
  if [ -n "$STILL" ]; then
    warn "force-killing stragglers: $STILL"
    # shellcheck disable=SC2086
    kill -KILL $STILL 2>/dev/null || true
  fi
fi

# --- 3. Kill tmux session ------------------------------------------------
if [ -n "$TMUX_BIN" ] && "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  info "killing tmux session '$TMUX_SESSION'"
  "$TMUX_BIN" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi

# --- 4. Remove installed files -------------------------------------------
for f in "$WATCHDOG_PLIST_DST" "$WATCHDOG_DST" "$PLIST_DST" "$SCRIPT_DST"; do
  if [ -e "$f" ]; then
    info "removing $f"
    rm -f "$f"
  fi
done

# --- 5. Remove our state files (leave plugin's own .env/access.json) -----
for f in "$BOT_PID_FILE" "$WATCHDOG_STATE"; do
  if [ -e "$f" ]; then
    info "removing $f"
    rm -f "$f"
  fi
done
if [ -d "$WATCHDOG_LOCK_DIR" ]; then
  info "removing $WATCHDOG_LOCK_DIR"
  rm -rf "$WATCHDOG_LOCK_DIR"
fi

# --- 6. Remove logs ------------------------------------------------------
if [ "$KEEP_LOGS" -eq 0 ]; then
  for f in "${LOG_FILES[@]}"; do
    if [ -e "$f" ]; then
      info "removing $f"
      rm -f "$f"
    fi
  done
fi

# --- 7. Remove config dir ------------------------------------------------
if [ "$KEEP_CONFIG" -eq 0 ] && [ -d "$CONFIG_DIR" ]; then
  info "removing $CONFIG_DIR"
  rm -rf "$CONFIG_DIR"
fi

# --- 8. Purge channel data (token, allowlist) — only with --purge --------
if [ "$PURGE" -eq 1 ] && [ -d "$CHANNEL_DIR" ]; then
  warn "purging plugin channel data: $CHANNEL_DIR"
  rm -rf "$CHANNEL_DIR"
fi

info "✅ uninstall complete"
