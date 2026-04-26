#!/bin/bash
# uninstall.sh — remove claude-telegram-autostart from this Mac.

set -euo pipefail

PURGE=0
KEEP_CONFIG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)        PURGE=1 ;;
    --keep-config)  KEEP_CONFIG=1 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--purge] [--keep-config]

Removes claude-telegram-autostart from this Mac.

Flags:
  --purge         Remove everything without prompting (config + logs + tmux session)
  --keep-config   Keep ~/.config/claude-telegram-autostart/
  --help, -h      Show this help
EOF
      exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*"; }

confirm() {
  if [ "$PURGE" -eq 1 ]; then return 0; fi
  printf '%s [y/N] ' "$1"
  read -r ans || true
  case "$ans" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}

USER_NAME="$(id -un)"
LABEL="com.${USER_NAME}.claude-telegram"
SCRIPT_DST="$HOME/.local/bin/start-claude-telegram.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-telegram-autostart"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/claude-telegram.log"
LAUNCHD_LOG="$HOME/Library/Logs/claude-telegram-launchd.log"
LAUNCHD_ERR="$HOME/Library/Logs/claude-telegram-launchd.err.log"
TMUX_SESSION="claude-tg"
TMUX_BIN="$(command -v tmux || true)"

info "unloading LaunchAgent ($LABEL)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
  || launchctl unload "$PLIST_DST" 2>/dev/null \
  || true

[ -f "$PLIST_DST"  ] && { info "removing $PLIST_DST";  rm -f "$PLIST_DST"; }
[ -f "$SCRIPT_DST" ] && { info "removing $SCRIPT_DST"; rm -f "$SCRIPT_DST"; }

if [ -n "$TMUX_BIN" ] && "$TMUX_BIN" has-session -t "$TMUX_SESSION" 2>/dev/null; then
  if confirm "Kill running tmux session '$TMUX_SESSION' (this will end the live claude session)?"; then
    info "killing tmux session"
    "$TMUX_BIN" kill-session -t "$TMUX_SESSION" || true
  fi
fi

if [ -d "$CONFIG_DIR" ] && [ "$KEEP_CONFIG" -eq 0 ]; then
  if confirm "Remove $CONFIG_DIR?"; then
    rm -rf "$CONFIG_DIR"
    info "config removed"
  fi
fi

for f in "$LOG_FILE" "$LAUNCHD_LOG" "$LAUNCHD_ERR"; do
  if [ -f "$f" ]; then
    if confirm "Remove $f?"; then rm -f "$f"; fi
  fi
done

info "✅ uninstall complete"
