#!/usr/bin/env bash
# Runs on the server. Swaps in the new build, restarts, checks health, rolls back if needed.
# deploy.sh prepends the settings (TARGET, NEW, KEEP, ...) as bash assignments.
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

give_up() { # result, message
  rm -f "$NEW"
  log "$2"
  result "$1"
  exit 1
}

command -v curl >/dev/null || give_up error "curl is needed on the server for the health check"
[ -f "$NEW" ] || give_up error "uploaded file $NEW is missing"

# 1. keep the current build as the newest backup, shifting older ones down.
#    The chain is one longer while the deploy runs, so a rollback can put it back exactly;
#    the extra one is dropped once the new build is healthy.
#    Only a backup made in this run is used for rollback, never a stale one.
backed_up=0
if [ -f "$TARGET" ] && [ "$KEEP" -gt 0 ]; then
  for ((i = KEEP + 1; i >= 2; i--)); do
    if [ -f "$(prev_path $((i - 1)))" ]; then mv -f "$(prev_path $((i - 1)))" "$(prev_path "$i")"; fi
  done
  cp -p "$TARGET" "$(prev_path 1)" || give_up error "could not back up $TARGET"
  backed_up=1
  log "kept the current build as $(prev_path 1)"
fi

# 2. swap in the new build in one step
mv -f "$NEW" "$TARGET" || give_up error "could not move the new build into place"
log "installed the new build at $TARGET"

# 3. restart and wait for it to come up
if restart && healthy; then
  log "healthy: $HEALTH_URL"
  [ "$backed_up" = 1 ] && rm -f "$(prev_path $((KEEP + 1)))"
  result deployed
  exit 0
fi

log "not healthy after ${TIMEOUT}s"
show_logs

if [ "$backed_up" != 1 ]; then
  log "no previous build from this run to roll back to"
  result failed-no-backup
  exit 1
fi

# 4. roll back: keep the failed build for a look, put the backup back,
#    and shift the older backups up again so the chain is as it was before this run.
mv -f "$TARGET" "$TARGET.failed"
mv -f "$(prev_path 1)" "$TARGET"
for ((i = 2; i <= KEEP + 1; i++)); do
  if [ -f "$(prev_path "$i")" ]; then mv -f "$(prev_path "$i")" "$(prev_path $((i - 1)))"; fi
done
log "rolled back; the failed build is at $TARGET.failed"

if restart && healthy; then
  log "the previous build is healthy again"
  result rolled-back
else
  log "the previous build did not come up either"
  show_logs
  result rollback-failed
fi
exit 1
