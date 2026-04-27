#!/bin/bash
# start-claude-telegram.sh — launch a detached tmux session running
# `claude --channels <spec>` after a native macOS confirmation dialog.
# Sourced configuration: ${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME}"
TMUX_SESSION="${TMUX_SESSION:-claude-tg}"
CHANNELS_SPEC="${CHANNELS_SPEC:-plugin:telegram@claude-plugins-official}"
DIALOG_TIMEOUT="${DIALOG_TIMEOUT:-30}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/claude-telegram.log}"

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# WATCHDOG=1 → skip the macOS confirmation dialog (used by the watchdog
# when restarting after a detected hang).
WATCHDOG="${WATCHDOG:-0}"

# Returns PIDs of all bun processes whose cwd is inside the telegram
# plugin cache (more reliable than command-line matching, since bun's
# argv shows /private/tmp/bun-node-*/bun without the plugin path).
# Mirrors find_plugin_bun_pids() in uninstall.sh — keep both in sync.
find_plugin_bun_pids() {
  local pid cwd
  for pid in $(pgrep bun 2>/dev/null); do
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}')
    case "$cwd" in
      *claude-plugins-official/telegram*) printf '%s\n' "$pid" ;;
    esac
  done
}

TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"

mkdir -p "$(dirname "$LOG_FILE")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Claude Telegram\"" >/dev/null 2>&1 || true
}
die() {
  log "FAIL: $1"
  notify "$2"
  exit 1
}

log "=== invoked ==="
log "PROJECT_DIR=$PROJECT_DIR TMUX_SESSION=$TMUX_SESSION CHANNELS_SPEC=$CHANNELS_SPEC"

[ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] \
  || die "tmux not found (TMUX_BIN='$TMUX_BIN')" "tmux missing — brew install tmux"
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] \
  || die "claude not found (CLAUDE_BIN='$CLAUDE_BIN')" "claude missing — install Claude Code"
[ -d "$PROJECT_DIR" ] \
  || die "PROJECT_DIR does not exist: $PROJECT_DIR" "project dir not found: $PROJECT_DIR"

if "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "tmux session '$TMUX_SESSION' already exists — exiting"
  notify "already running (tmux: $TMUX_SESSION)"
  exit 0
fi

BOT_PID_FILE="$HOME/.claude/channels/telegram/bot.pid"
if [ -f "$BOT_PID_FILE" ]; then
  PID=$(cat "$BOT_PID_FILE" 2>/dev/null || true)
  # Treat anything that isn't a positive integer as stale — never pass
  # garbage (or 0/-1, which would target the process group) to kill.
  if [[ "${PID:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 "$PID" 2>/dev/null; then
    log "bot.pid $PID alive — claude session already running, exiting"
    notify "already running (PID $PID)"
    exit 0
  else
    log "stale bot.pid (${PID:-empty}) — proceeding"
  fi
fi

# Sweep stray bun processes from the telegram plugin: orphans from prior
# claude sessions race the live bot on getUpdates and can hold half-open
# sockets indefinitely. bot.pid only tracks the most recent spawn.
# macOS /bin/bash is 3.2 — no `mapfile`/`readarray`. Use a portable
# read loop so the array stays NUL-safe without the bash-4 builtin.
ORPHANS=()
while IFS= read -r pid; do
  [ -n "$pid" ] && ORPHANS+=("$pid")
done < <(find_plugin_bun_pids)
if [ "${#ORPHANS[@]}" -gt 0 ]; then
  log "killing leftover plugin bun processes: ${ORPHANS[*]}"
  kill -TERM "${ORPHANS[@]}" 2>/dev/null || true
  sleep 1
  STILL=()
  while IFS= read -r pid; do
    [ -n "$pid" ] && STILL+=("$pid")
  done < <(find_plugin_bun_pids)
  if [ "${#STILL[@]}" -gt 0 ]; then
    log "force-killing stragglers: ${STILL[*]}"
    kill -KILL "${STILL[@]}" 2>/dev/null || true
  fi
  rm -f "$BOT_PID_FILE"
fi

if [ "$WATCHDOG" = "1" ]; then
  log "WATCHDOG=1 — skipping confirmation dialog"
  RESPONSE="start"
else
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
fi

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
  die "session did not start" "failed to start (see $LOG_FILE)"
fi
