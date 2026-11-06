#!/usr/bin/env bash
# Runs on the GitHub runner. Uploads the build and hands the rest to remote.sh on the server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output() { echo "result=$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }
fail() { echo "::error::$*"; output error; exit 1; }

whole() { [[ "$1" =~ ^[0-9]+$ ]]; }
[ -f "$IN_ARTIFACT" ] || fail "artifact not found: $IN_ARTIFACT"
whole "$IN_PORT" || fail "port must be a number"
whole "$IN_KEEP" || fail "keep must be a whole number"
whole "$IN_HEALTH_TIMEOUT" && [ "$IN_HEALTH_TIMEOUT" -ge 1 ] || fail "health-timeout must be at least 1 second"
whole "$IN_HEALTH_INTERVAL" && [ "$IN_HEALTH_INTERVAL" -ge 1 ] || fail "health-interval must be at least 1 second"
[ -n "$IN_TARGET" ] || fail "target is empty"

restart_cmd="$IN_RESTART"
logs_cmd="$IN_LOGS"
if [ -n "$IN_SERVICE" ]; then
  [ -n "$restart_cmd" ] || restart_cmd="sudo systemctl restart $IN_SERVICE"
  [ -n "$logs_cmd" ] || logs_cmd="sudo journalctl -u $IN_SERVICE -n 80 --no-pager"
fi
[ -n "$restart_cmd" ] || fail "set either service or restart"

# SSH setup in a private temp dir that is removed on exit
dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ssh-deploy.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
# Keys pasted from Windows can carry \r line endings, which ssh rejects.
printf '%s\n' "$IN_KEY" | tr -d '\r' > "$dir/key"
chmod 600 "$dir/key"
if [ -n "$IN_KNOWN_HOSTS" ]; then
  printf '%s\n' "$IN_KNOWN_HOSTS" | tr -d '\r' > "$dir/known_hosts"
else
  echo "::warning::known-hosts is empty, trusting the host key from ssh-keyscan"
  ssh-keyscan -p "$IN_PORT" -H "$IN_HOST" > "$dir/known_hosts" 2>/dev/null || fail "could not reach $IN_HOST:$IN_PORT"
fi
opts=(-p "$IN_PORT" -i "$dir/key" -o "UserKnownHostsFile=$dir/known_hosts" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15)
dest="$IN_USER@$IN_HOST"

# Single quotes work in every POSIX login shell, unlike bash's printf %q.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Upload next to the target, so the swap on the server is a rename on the same disk.
# The name is unique per run, so two deploys at once cannot write the same file.
new="$IN_TARGET.new.${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$$}"
echo "[deploy] uploading $IN_ARTIFACT to $dest:$new"
# Streamed over the SSH connection itself, so the server needs neither scp nor sftp.
ssh "${opts[@]}" "$dest" "cat > $(sq "$new")" < "$IN_ARTIFACT" || fail "upload to $dest failed"

# The settings travel inside the script as bash assignments, so the login shell only sees "bash -s".
{
  printf 'TARGET=%q\nNEW=%q\nKEEP=%q\nRESTART=%q\nLOGS=%q\nHEALTH_URL=%q\nEXPECT=%q\nTIMEOUT=%q\nINTERVAL=%q\n' \
    "$IN_TARGET" "$new" "$IN_KEEP" "$restart_cmd" "$logs_cmd" \
    "$IN_HEALTH_URL" "$IN_HEALTH_EXPECT" "$IN_HEALTH_TIMEOUT" "$IN_HEALTH_INTERVAL"
  cat "$here/remote.sh"
} > "$dir/run.sh"

set +e
ssh "${opts[@]}" "$dest" "bash -s" < "$dir/run.sh" | tee "$dir/out"
status=${PIPESTATUS[0]}
set -e

result="$(sed -n 's/^::result:://p' "$dir/out" | tail -n 1)"
[ -n "$result" ] || result=error
output "$result"

case "$result" in
  deployed) echo "[deploy] done" ;;
  rolled-back) echo "::error::the new build failed its health check; the previous build was restored" ;;
  *) echo "::error::deploy failed ($result)" ;;
esac
[ "$result" = deployed ] || [ "$status" != 0 ] || status=1
exit "$status"
