#!/usr/bin/env bash
# codespace-keepalive  — keep a GitHub Codespace alive past its idle timeout.
#
# GitHub stops a codespace after ~30 minutes of inactivity, and closing the
# browser tab does not stop that clock. Per GitHub's docs, terminal activity
# (input or output) on the codespace resets the idle timeout, so this script
# keeps opening an SSH session into its own codespace through GitHub's gateway
# and emits terminal output on a fixed schedule. The codespace therefore never
# goes idle and keeps running even with no client connected.
#
# Architecture: a "supervise" guard (session leader, owns the pidfile) which
# restarts the "worker" if it dies, plus the "worker" that runs the SSH cycles.
#
# Usage:
#   keepalive.sh start    Start (idempotent). Auto-run at codespace
#                         create/start via .devcontainer/devcontainer.json.
#   keepalive.sh stop     Stop completely (kills the whole process group).
#   keepalive.sh status   Show state and last activity.
#
# Disable (until re-enabled) via either:
#   1. Terminal: touch ~/.codespace-keepalive.disabled
#   2. GitHub web: create the file .devcontainer/keepalive.disabled in the
#      repository (polled via the GitHub API). Re-enable: delete the file,
#      then run `keepalive.sh start`.
set -u

STATE_DIR="${KEEPALIVE_STATE_DIR:-$HOME/.cache/codespace-keepalive}"
LOG="$STATE_DIR/keepalive.log"
PIDFILE="$STATE_DIR/keepalive.pid"
MARKER="$HOME/.codespace-keepalive.disabled"
GH_DISABLE_PATH=".devcontainer/keepalive.disabled"
WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo)"
CS="${CODESPACE_NAME:-}"
SSH_TIMEOUT=300
GAP_SLEEP=45
CHECK_INTERVAL=60
OUT_CHANNEL='echo ka-connect-$(date -u +%H:%M:%SZ); sleep 150; echo ka-alive-$(date -u +%H:%M:%SZ)'

mkdir -p "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"
  if [ "$(wc -c <"$LOG")" -gt 5242880 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

pid_is_ours() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  ps -o cmd= -p "$p" 2>/dev/null | grep -q 'keepalive\.sh' || return 1
}

watch_pids() { pgrep -f 'keepalive\.sh (supervise|worker|watchdog)' 2>/dev/null; }

running() {
  pid_is_ours "$(cat "$PIDFILE" 2>/dev/null)" && return 0
  [ -n "$(watch_pids)" ]
}

current_pid() {
  local p
  p="$(cat "$PIDFILE" 2>/dev/null)"
  pid_is_ours "$p" && { printf '%s' "$p"; return 0; }
  watch_pids | head -n1
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

disabled_local() {
  [ -f "$MARKER" ] || { [ -n "$WORKTREE_ROOT" ] && [ -f "$WORKTREE_ROOT/$GH_DISABLE_PATH" ]; }
}

disabled_github() {
  local slug
  slug="$(repo_slug)"
  [ -z "$slug" ] && return 1
  timeout 10 gh api "repos/$slug/contents/$GH_DISABLE_PATH" --jq '.name' >/dev/null 2>&1
}

worker() {
  local fails=0 skip=0
  while :; do
    if [ -f "$MARKER" ]; then
      log "disabled by marker: $MARKER"
      exit 0
    fi
    if timeout "$SSH_TIMEOUT" gh cs ssh -c "$CS" -- "$OUT_CHANNEL" >>"$LOG" 2>&1; then
      fails=0
    else
      fails=$((fails + 1))
      log "SSH session failed (attempt $fails)"
      sleep 30
    fi
    if [ "$fails" -ge 5 ]; then
      log "5 consecutive SSH failures, backing off 5 min"
      sleep 300
      fails=0
      continue
    fi
    sleep "$GAP_SLEEP"
  done
}

supervise() {
  trap 'rm -f "$PIDFILE"; exit 0' INT TERM
  echo "$$" >"$PIDFILE"
  if [ -z "$CS" ]; then
    log "not a codespace (CODESPACE_NAME unset), keep-alive not needed"
    rm -f "$PIDFILE"
    exit 0
  fi
  log "keep-alive started pid=$$ codespace=$CS"
  local worker_pid="" i=0
  while :; do
    if [ -n "$worker_pid" ] && ! kill -0 "$worker_pid" 2>/dev/null; then
      log "worker $worker_pid died; restarting"
      worker_pid=""
    fi
    if [ -z "$worker_pid" ]; then
      bash "$0" worker >>"$LOG" 2>&1 &
      worker_pid=$!
      disown "$worker_pid" 2>/dev/null ||:
    fi
    i=$((i + 1))
    if [ -f "$MARKER" ] || { [ -n "$WORKTREE_ROOT" ] && [ -f "$WORKTREE_ROOT/$GH_DISABLE_PATH" ]; }; then
      log "disabled by marker: $MARKER"
      [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null
      break
    fi
    if [ $((i % 6)) -eq 0 ] && disabled_github; then
      log "disabled by GitHub file: $GH_DISABLE_PATH"
      [ -n "$worker_pid" ] && kill "$worker_pid" 2>/dev/null
      break
    fi
    sleep "$CHECK_INTERVAL"
  done
  rm -f "$PIDFILE"
  exit 0
}

start() {
  if running; then
    echo "keep-alive already running (pid $(current_pid))"
    return 0
  fi
  if disabled_local || disabled_github; then
    echo "keep-alive is disabled (remove $MARKER or $GH_DISABLE_PATH on GitHub, then retry)"
    return 1
  fi
  setsid nohup bash "$0" supervise >/dev/null 2>&1 &
  sleep 1
  if running; then
    echo "keep-alive started (pid $(current_pid))"
  else
    echo "keep-alive failed to start; see $LOG"
    return 1
  fi
}

stop() {
  local pid pgid t
  pid="$(current_pid)"
  if [ -z "$pid" ]; then
    echo "keep-alive not running"
    return 1
  fi
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  log "stopping keep-alive pid=$pid pgid=$pgid"
  if [ -n "$pgid" ] && [ "$pgid" -gt 1 ]; then
    kill -TERM -- "-$pgid" 2>/dev/null
  fi
  kill "$pid" 2>/dev/null
  t=0
  while [ "$t" -lt 8 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    t=$((t + 1))
  done
  if [ "$t" -ge 8 ] && kill -0 "$pid" 2>/dev/null; then
    log "force killing keep-alive pid=$pid"
    kill -KILL -- "-$pgid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
  fi
  rm -f "$PIDFILE"
  echo "stopped keep-alive (pid $pid)"
  return 0
}

status() {
  local pid last
  pid="$(current_pid)"
  if [ -z "$pid" ]; then
    echo "not running"
    return 1
  fi
  echo "running (pid $pid)"
  last="$(grep -E 'ka-(connect|alive)' "$LOG" 2>/dev/null | tail -n1)"
  [ -n "$last" ] && echo "last activity: $last"
  echo "log: $LOG"
  return 0
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  supervise) supervise ;;
  worker|watchdog) worker ;;
  *)
    echo "usage: $0 {start|stop|status}"
    exit 2
    ;;
esac