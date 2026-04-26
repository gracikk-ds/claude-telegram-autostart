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
# TMUX_BIN) are available, but the watchdog's own paths are set AFTER —
# config.env defines a LOG_FILE for the start script, and we don't want
# to inherit it.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart/config.env"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

TMUX_SESSION="${TMUX_SESSION:-claude-tg}"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux 2>/dev/null || true)}"
START_SCRIPT="${START_SCRIPT:-$HOME/.local/bin/start-claude-telegram.sh}"
WATCHDOG_LOG="${WATCHDOG_LOG:-$HOME/Library/Logs/claude-telegram-watchdog.log}"
STATE_FILE="${WATCHDOG_STATE_FILE:-$HOME/.claude/channels/telegram/watchdog.state}"
LOCK_DIR="${WATCHDOG_LOCK_DIR:-$HOME/.claude/channels/telegram/watchdog.lock.d}"
BOT_PID_FILE="$HOME/.claude/channels/telegram/bot.pid"

# Two consecutive bad probes (~120s) before we act — gives grammy a
# chance to reconnect on its own during transient blips.
STRIKE_THRESHOLD=2
SIGHUP_GRACE_SECONDS=10
PROBE_TIMEOUT_SECONDS=5
TELEGRAM_CIDR_REGEX='149\.154\.|91\.108\.'
PLUGIN_CWD_SUBSTR='claude-plugins-official/telegram'

mkdir -p "$(dirname "$WATCHDOG_LOG")" "$(dirname "$STATE_FILE")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WATCHDOG_LOG"; }

# Single-flight via mkdir (atomic on macOS, no flock needed). If a stale
# lock dir is left behind by a crashed run older than 10 minutes, claim it.
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  local age_secs
  age_secs=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
  if [ "$age_secs" -gt 600 ]; then
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
trap 'rm -rf "$LOCK_DIR"' EXIT

read_strikes() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
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

bot_pid() {
  [ -f "$BOT_PID_FILE" ] || return 1
  local pid cwd
  pid=$(cat "$BOT_PID_FILE" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Verify the process really is our bot — guards against PID recycling.
  cwd=$(pid_cwd "$pid")
  case "$cwd" in
    *"$PLUGIN_CWD_SUBSTR"*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$pid"
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
  local pid
  if ! pid=$(bot_pid); then
    log "probe: no live bot process"
    return 1
  fi
  if ! has_established_to_telegram; then
    log "probe: bot pid=$pid has no ESTABLISHED TCP to telegram CIDR"
    return 1
  fi
  log "probe: ok (pid=$pid, telegram socket established)"
  return 0
}

soft_restart() {
  local pid
  pid=$(bot_pid) || pid=""
  if [ -z "$pid" ]; then
    log "soft_restart: no bot pid to SIGHUP, escalating"
    return 1
  fi
  log "soft_restart: SIGHUP → pid=$pid"
  kill -HUP "$pid" 2>/dev/null || true
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
    "$TMUX_BIN" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  fi
  # start-claude-telegram.sh sweeps stray bun server.ts itself when
  # invoked, so we just ensure bot.pid is gone and call it.
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
  if probe; then
    reset_strikes
    exit 0
  fi
  local strikes
  strikes=$(read_strikes)
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
