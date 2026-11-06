#!/usr/bin/env bash
# Runs on the server. Swaps in the new build, restarts, checks health, rolls back if needed.
# Everything it needs comes in as environment variables set by deploy.sh.
set -uo pipefail

log() { echo "[deploy] $*"; }
result() { echo "::result::$1"; }

prev_path() { # 1 -> app.jar.prev, 2 -> app.jar.prev.2, ...
  if [ "$1" -eq 1 ]; then echo "$TARGET.prev"; else echo "$TARGET.prev.$1"; fi
}

healthy() {
  local end=$((SECONDS + TIMEOUT)) body
  while [ "$SECONDS" -lt "$end" ]; do
    if body=$(curl -fsS --max-time 5 "$HEALTH_URL" 2>/dev/null); then
      if [ -z "$EXPECT" ] || printf '%s' "$body" | grep -qF -- "$EXPECT"; then
        return 0
      fi
    fi
    sleep "$INTERVAL"
  done
  return 1
}

restart() {
  log "restarting: $RESTART"
  bash -c "$RESTART"
}

show_logs() {
  [ -n "$LOGS" ] || return 0
  log "last logs:"
  bash -c "$LOGS" || true
}

command -v curl >/dev/null || { log "curl is needed on the server for the health check"; result failed-no-backup; exit 1; }
[ -f "$NEW" ] || { log "uploaded file $NEW is missing"; result failed-no-backup; exit 1; }

# 1. keep the current build as the newest backup, shifting older ones down
if [ -f "$TARGET" ] && [ "$KEEP" -gt 0 ]; then
  for ((i = KEEP; i >= 2; i--)); do
    [ -f "$(prev_path $((i - 1)))" ] && mv -f "$(prev_path $((i - 1)))" "$(prev_path "$i")"
  done
  cp -p "$TARGET" "$(prev_path 1)"
  log "kept the current build as $(prev_path 1)"
fi

# 2. swap in the new build in one step
mv -f "$NEW" "$TARGET"
log "installed the new build at $TARGET"

# 3. restart and wait for it to come up
if restart && healthy; then
  log "healthy: $HEALTH_URL"
  result deployed
  exit 0
fi

log "not healthy after ${TIMEOUT}s"
show_logs

# 4. roll back to the previous build
if [ ! -f "$(prev_path 1)" ]; then
  log "no previous build to roll back to"
  result failed-no-backup
  exit 1
fi

cp -p "$(prev_path 1)" "$TARGET"
log "rolled back to $(prev_path 1)"
if restart && healthy; then
  log "the previous build is healthy again"
  result rolled-back
else
  log "the previous build did not come up either"
  show_logs
  result rollback-failed
fi
exit 1
