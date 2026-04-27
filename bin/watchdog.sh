#!/bin/bash
# watchdog.sh — periodic health probe for the Claude Telegram bridge.
#
# Detects two failure modes that the plugin/grammy do not recover from
# on their own:
#   1. WireGuard NAT-rebind leaves the long-poll TCP socket half-open
#      (sockets visible in netstat but no traffic; getUpdates hangs).
#   2. The plugin's own process dies but the tmux session and parent
#      claude process stay up — no MCP child means no Telegram traffic.
#
# Strategy: 2-strike rule with network preflight, SIGHUP-first recovery,
# fall back to a full tmux restart if SIGHUP doesn't bring the bot back.
#
# Designed to be invoked every 60s by launchd.
# Sourced configuration: ${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env
# (uses TMUX_SESSION, TMUX_BIN — same as start-claude-telegram.sh)

set -euo pipefail

# Source the shared config FIRST so that variables it sets (TMUX_SESSION,
# TMUX_BIN) are available. Then drop the start-script's LOG_FILE so we
# can never accidentally write watchdog history into it — our own log
# lives at WATCHDOG_LOG below.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
unset LOG_FILE

TMUX_SESSION="${TMUX_SESSION:-claude-tg}"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"
START_SCRIPT="${START_SCRIPT:-$HOME/.local/bin/start-claude-telegram.sh}"
# Watchdog-specific paths: the WATCHDOG_-prefixed names below are
# intentionally distinct from the start-script's LOG_FILE so a mistaken
# entry in config.env cannot redirect us. Edit this script if you need
# to relocate them.
WATCHDOG_LOG="$HOME/Library/Logs/claude-telegram-watchdog.log"
STATE_FILE="$HOME/.claude/channels/telegram/watchdog.state"
LOCK_DIR="$HOME/.claude/channels/telegram/watchdog.lock.d"
BOT_PID_FILE="$HOME/.claude/channels/telegram/bot.pid"

# Two consecutive bad probes (~120s, assuming the launchd StartInterval=60
# in the watchdog plist) before we act — gives grammy a chance to
# reconnect on its own during transient blips.
STRIKE_THRESHOLD=2
SIGHUP_GRACE_SECONDS=10
PROBE_TIMEOUT_SECONDS=5
STALE_LOCK_SECONDS=600
TELEGRAM_CIDR_REGEX='149\.154\.|91\.108\.'
PLUGIN_CWD_SUBSTR='claude-plugins-official/telegram'

mkdir -p "$(dirname "$WATCHDOG_LOG")" "$(dirname "$STATE_FILE")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WATCHDOG_LOG"; }

# Single-flight via mkdir (atomic on macOS, no flock needed). If a stale
# lock dir is left behind by a crashed run older than STALE_LOCK_SECONDS,
# claim it.
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  local age_secs
  age_secs=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [ "$age_secs" -gt "$STALE_LOCK_SECONDS" ]; then
    log "stale lock dir ($age_secs s) — reclaiming"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    return 0
  fi
  return 1
}
if ! acquire_lock; then
  log "previous watchdog run still active — skipping"
  exit 0
fi
# Cover SIGTERM/SIGINT/SIGHUP too so a launchd-killed run doesn't leak
# the lock dir until the stale-lock window expires.
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM HUP

read_strikes() {
  cat "$STATE_FILE" 2>/dev/null || echo 0
}

write_strikes() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

reset_strikes() {
  write_strikes 0
}

pid_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}'
}

tmux_pane_pid() {
  [ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] || return 1
  local pid
  pid=$("$TMUX_BIN" list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -n1)
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
}

# Walk the ppid chain from $1 upward looking for $2.
# Depth-bounded so a stat error or unexpected loop can't hang us.
is_descendant() {
  local pid=$1 ancestor=$2 depth=0
  [ -n "$pid" ] && [ -n "$ancestor" ] || return 1
  while [ "$depth" -lt 20 ]; do
    if [ "$pid" = "$ancestor" ]; then
      return 0
    fi
    if [ "$pid" = "1" ] || [ "$pid" = "0" ] || [ -z "$pid" ]; then
      return 1
    fi
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  return 1
}

# Inspect bot.pid and decide which of three states we're in. Sets the
# globals BOT_PID and BOT_STATUS:
#   ours    — live plugin bun, descendant of our tmux pane's claude
#   foreign — live plugin bun, but spawned by a different app (e.g.
#             Cursor with telegram in ~/.cursor/mcp.json) — racing us
#             for getUpdates; we must NOT SIGHUP or kill it
#   absent  — file missing, contents invalid, process dead, or wrong cwd
classify_bot() {
  BOT_PID=""
  BOT_STATUS="absent"
  [ -f "$BOT_PID_FILE" ] || return 0
  local pid cwd pane_pid
  pid=$(cat "$BOT_PID_FILE" 2>/dev/null || true)
  # Treat anything that isn't a positive integer as absent — never pass
  # garbage (or 0/-1, which would target the process group) to kill.
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  cwd=$(pid_cwd "$pid")
  case "$cwd" in
    *"$PLUGIN_CWD_SUBSTR"*) ;;
    *) return 0 ;;
  esac
  pane_pid=$(tmux_pane_pid) || return 0
  BOT_PID="$pid"
  if is_descendant "$pid" "$pane_pid"; then
    BOT_STATUS="ours"
  else
    BOT_STATUS="foreign"
  fi
}

has_established_to_telegram() {
  # lsof reports bun's Telegram sockets as CLOSED even when they are
  # ESTABLISHED — Kaspersky Web Protection intercepts TLS at the kernel
  # network-extension layer, so the file-descriptor state diverges from
  # the real TCP state. netstat reads the kernel TCP table directly and
  # is not affected by this interception, so use it instead.
  netstat -an -p tcp 2>/dev/null \
    | grep ESTABLISHED \
    | grep -qE "$TELEGRAM_CIDR_REGEX"
}

network_can_reach_telegram() {
  curl -s -o /dev/null -m "$PROBE_TIMEOUT_SECONDS" \
    -w '%{http_code}' https://api.telegram.org/ >/dev/null 2>&1
}

tmux_session_alive() {
  [ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] || return 1
  "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null
}

probe() {
  classify_bot
  if [ "$BOT_STATUS" != "ours" ]; then
    log "probe: no live bot process"
    return 1
  fi
  if ! has_established_to_telegram; then
    log "probe: bot pid=$BOT_PID has no ESTABLISHED TCP to telegram CIDR"
    return 1
  fi
  log "probe: ok (pid=$BOT_PID, telegram socket established)"
  return 0
}

soft_restart() {
  if [ "$BOT_STATUS" != "ours" ] || [ -z "$BOT_PID" ]; then
    log "soft_restart: no bot pid to SIGHUP, escalating"
    return 1
  fi
  log "soft_restart: SIGHUP → pid=$BOT_PID"
  local err
  if ! err=$(kill -HUP "$BOT_PID" 2>&1); then
    log "soft_restart: SIGHUP failed: ${err:-unknown error}"
    return 1
  fi
  sleep "$SIGHUP_GRACE_SECONDS"
  if probe; then
    log "soft_restart: succeeded after SIGHUP"
    return 0
  fi
  log "soft_restart: bot did not recover within ${SIGHUP_GRACE_SECONDS}s"
  return 1
}

hard_restart() {
  log "hard_restart: kill tmux session '$TMUX_SESSION' and re-run start script"
  if [ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ]; then
    local kill_err
    if ! kill_err=$("$TMUX_BIN" kill-session -t "$TMUX_SESSION" 2>&1); then
      case "$kill_err" in
        *"can't find session"*|*"no server"*|"") ;;
        *) log "hard_restart: tmux kill-session warning: $kill_err" ;;
      esac
    fi
  fi
  # start-claude-telegram.sh's find_plugin_bun_pids() sweeps stray plugin
  # bun processes (matched by cwd) when invoked, so we just ensure
  # bot.pid is gone and call it.
  rm -f "$BOT_PID_FILE"
  if [ ! -x "$START_SCRIPT" ]; then
    log "hard_restart: FAIL — start script not executable: $START_SCRIPT"
    return 1
  fi
  WATCHDOG=1 "$START_SCRIPT" >> "$WATCHDOG_LOG" 2>&1 || {
    log "hard_restart: start script exited non-zero"
    return 1
  }
  log "hard_restart: start script returned"
}

main() {
  if ! tmux_session_alive; then
    log "no live tmux session '$TMUX_SESSION' — idle (user-initiated stop?)"
    reset_strikes
    exit 0
  fi
  if ! network_can_reach_telegram; then
    log "network can't reach api.telegram.org — VPN/ISP down, skipping"
    # Do not increment strikes during a real network outage.
    exit 0
  fi
  classify_bot
  if [ "$BOT_STATUS" = "foreign" ]; then
    log "foreign bun in bot.pid=$BOT_PID — not a descendant of our tmux pane. Likely a parallel MCP runner (Cursor's ~/.cursor/mcp.json telegram entry?) racing for getUpdates. Refusing to recover (would either no-op or kill another app's process); close the other instance."
    reset_strikes
    exit 0
  fi
  if probe; then
    reset_strikes
    exit 0
  fi
  local strikes
  strikes=$(read_strikes)
  # Clamp: an empty or corrupt state file would crash $(()) under set -e.
  [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0
  strikes=$((strikes + 1))
  if [ "$strikes" -lt "$STRIKE_THRESHOLD" ]; then
    log "probe failed — strike $strikes/$STRIKE_THRESHOLD, waiting"
    write_strikes "$strikes"
    exit 0
  fi
  log "probe failed — strike $strikes/$STRIKE_THRESHOLD, recovering"
  if soft_restart; then
    reset_strikes
    exit 0
  fi
  if hard_restart; then
    reset_strikes
    exit 0
  fi
  log "recovery failed — leaving strike counter at $strikes for next probe"
  write_strikes "$strikes"
  exit 1
}

main "$@"
