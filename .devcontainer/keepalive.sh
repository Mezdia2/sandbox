#!/usr/bin/env bash
# codespace-keepalive
# Prevents a GitHub Codespace from auto-stopping due to inactivity.
#
# Mechanism: every ~3 minutes it opens an SSH session to this codespace via
# GitHub's gateway and emits terminal output. GitHub's docs define terminal
# activity (input or output) as activity that resets the idle timeout, so the
# codespace never reaches its idle timeout.
#
# Usage:
#   keepalive.sh start   Start the keep-alive (idempotent). Runs automatically
#                        at codespace creation/start via .devcontainer/devcontainer.json.
#   keepalive.sh stop    Stop the keep-alive for the current codespace.
#   keepalive.sh status  Show whether the keep-alive is running.
#
# Disable it (until re-enabled) via either:
#   1. Terminal:  touch ~/.codespace-keepalive.disabled
#   2. GitHub web: create a file named  .devcontainer/keepalive.disabled
#      in the repository (the script polls it via the GitHub API). Deleting the
#      file and running `keepalive.sh start` re-enables it.
set -u

STATE_DIR="${KEEPALIVE_STATE_DIR:-$HOME/.cache/codespace-keepalive}"
LOG="$STATE_DIR/keepalive.log"
PIDFILE="$STATE_DIR/keepalive.pid"
MARKER="$HOME/.codespace-keepalive.disabled"
GH_DISABLE_PATH=".devcontainer/keepalive.disabled"
CS="${CODESPACE_NAME:-}"

mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

watch_pids() { pgrep -f 'keepalive\.sh watchdog' 2>/dev/null; }

running() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  [ -n "$(watch_pids)" ]
}

current_pid() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    cat "$PIDFILE"
  else
    watch_pids | head -n1
  fi
}

repo_slug() {
  local url
  url="$(git remote get-url origin 2>/dev/null)" || url="${GITHUB_REPOSITORY:-}"
  case "$url" in
    *github.com*)
      printf '%s' "$url" | sed -E 's#.*github\.com[:/]([^/]+)/([^ .]+)(\.git)?$#\1/\2#'
      ;;
    *) printf '%s' "${GITHUB_REPOSITORY:-}" ;;
  esac
}

disabled_local() { [ -f "$MARKER" ]; }

disabled_github() {
  local slug
  slug="$(repo_slug)"
  [ -z "$slug" ] && return 1
  timeout 10 gh api "repos/$slug/contents/$GH_DISABLE_PATH" --jq '.name' >/dev/null 2>&1
}

disabled() {
  if disabled_local; then
    log "disabled by marker: $MARKER"
    return 0
  fi
  if disabled_github; then
    log "disabled by GitHub file: $GH_DISABLE_PATH"
    return 0
  fi
  return 1
}

run() {
  trap 'rm -f "$PIDFILE"; exit 0' INT TERM
  echo "$$" >"$PIDFILE"
  if [ -z "$CS" ]; then
    log "not a codespace (CODESPACE_NAME unset), keep-alive not needed"
    rm -f "$PIDFILE"
    exit 0
  fi
  log "keep-alive started pid=$$ codespace=$CS"
  while true; do
    if disabled; then
      log "keep-alive disabled, exiting"
      break
    fi
    if timeout 300 gh cs ssh -c "$CS" -- \
      'echo ka-connect-$(date -u +%H:%M:%SZ); sleep 150; echo ka-alive-$(date -u +%H:%M:%SZ)' \
      >>"$LOG" 2>&1; then
      :
    else
      log "ssh session failed, retrying in 30s"
      sleep 30
    fi
    sleep 45
  done
  rm -f "$PIDFILE"
}

start() {
  if running; then
    echo "keep-alive already running (pid $(current_pid))"
    return 0
  fi
  if disabled; then
    echo "keep-alive is disabled (remove $MARKER or $GH_DISABLE_PATH on GitHub, then retry)"
    return 1
  fi
  setsid nohup bash "$0" watchdog >/dev/null 2>&1 &
  sleep 1
  if running; then
    echo "keep-alive started (pid $(current_pid))"
  else
    echo "keep-alive failed to start; see $LOG"
    return 1
  fi
}

stop() {
  local pid
  pid="$(current_pid)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null && echo "stopped pid $pid"
    rm -f "$PIDFILE"
    return 0
  fi
  echo "keep-alive not running"
  return 1
}

status() {
  local pid
  pid="$(current_pid)"
  if [ -n "$pid" ]; then
    echo "running (pid $pid)"
    return 0
  fi
  echo "not running"
  return 1
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  watchdog) run ;;
  *)
    echo "usage: $0 {start|stop|status}"
    exit 2
    ;;
esac