#!/bin/bash
# start-claude-telegram.sh — launch a detached tmux session running
# `claude --channels <spec>` after a native macOS confirmation dialog.
# Sourced configuration: ${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME}"
TMUX_SESSION="${TMUX_SESSION:-claude-tg}"
TMUX_BIN="${TMUX_BIN:-}"
CLAUDE_BIN="${CLAUDE_BIN:-}"
CHANNELS_SPEC="${CHANNELS_SPEC:-plugin:telegram@claude-plugins-official}"
DIALOG_TIMEOUT="${DIALOG_TIMEOUT:-30}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/claude-telegram.log}"

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"

mkdir -p "$(dirname "$LOG_FILE")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Claude Telegram\"" >/dev/null 2>&1 || true
}

log "=== invoked ==="
log "PROJECT_DIR=$PROJECT_DIR TMUX_SESSION=$TMUX_SESSION CHANNELS_SPEC=$CHANNELS_SPEC"

if [ -z "$TMUX_BIN" ] || [ ! -x "$TMUX_BIN" ]; then
  log "FAIL: tmux not found (TMUX_BIN='$TMUX_BIN')"
  notify "tmux missing — brew install tmux"
  exit 1
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  log "FAIL: claude not found (CLAUDE_BIN='$CLAUDE_BIN')"
  notify "claude missing — install Claude Code"
  exit 1
fi
if [ ! -d "$PROJECT_DIR" ]; then
  log "FAIL: PROJECT_DIR does not exist: $PROJECT_DIR"
  notify "project dir not found: $PROJECT_DIR"
  exit 1
fi

if "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "tmux session '$TMUX_SESSION' already exists — exiting"
  notify "already running (tmux: $TMUX_SESSION)"
  exit 0
fi

BOT_PID_FILE="$HOME/.claude/channels/telegram/bot.pid"
if [ -f "$BOT_PID_FILE" ]; then
  PID=$(cat "$BOT_PID_FILE" 2>/dev/null || true)
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    log "bot.pid $PID alive — claude session already running, exiting"
    notify "already running (PID $PID)"
    exit 0
  else
    log "stale bot.pid (${PID:-empty}) — proceeding"
  fi
fi

log "showing dialog (timeout ${DIALOG_TIMEOUT}s)"
RESPONSE=$(/usr/bin/osascript <<APPLESCRIPT 2>/dev/null || echo "error"
try
  tell application "System Events" to activate
  set r to display dialog "Ready to start Claude Telegram session?" buttons {"Skip", "Start"} default button "Start" with title "Claude Telegram" giving up after ${DIALOG_TIMEOUT}
  if button returned of r is "Start" then
    return "start"
  else
    return "skip"
  end if
on error
  return "error"
end try
APPLESCRIPT
)

if [ "$RESPONSE" != "start" ]; then
  log "user response: '$RESPONSE' — not starting"
  exit 0
fi

log "starting tmux session '$TMUX_SESSION' in $PROJECT_DIR"
"$TMUX_BIN" new-session -d -s "$TMUX_SESSION" -c "$PROJECT_DIR" \
  "exec '$CLAUDE_BIN' --channels '$CHANNELS_SPEC'"

sleep 2
if "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "session '$TMUX_SESSION' started"
  notify "session started — tmux attach -t $TMUX_SESSION"
else
  log "FAIL: session did not start"
  notify "failed to start (see $LOG_FILE)"
  exit 1
fi
