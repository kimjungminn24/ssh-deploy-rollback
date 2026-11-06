#!/usr/bin/env bash
# Runs on the GitHub runner. Uploads the build and hands the rest to remote.sh on the server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "::error::$*"; exit 1; }

[ -f "$IN_ARTIFACT" ] || fail "artifact not found: $IN_ARTIFACT"
[[ "$IN_KEEP" =~ ^[0-9]+$ ]] || fail "keep must be a whole number"
[[ "$IN_HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || fail "health-timeout must be a whole number of seconds"
[[ "$IN_HEALTH_INTERVAL" =~ ^[0-9]+$ ]] || fail "health-interval must be a whole number of seconds"

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
printf '%s\n' "$IN_KEY" > "$dir/key"
chmod 600 "$dir/key"
if [ -n "$IN_KNOWN_HOSTS" ]; then
  printf '%s\n' "$IN_KNOWN_HOSTS" > "$dir/known_hosts"
else
  echo "::warning::known-hosts is empty, trusting the host key from ssh-keyscan"
  ssh-keyscan -p "$IN_PORT" -H "$IN_HOST" > "$dir/known_hosts" 2>/dev/null || fail "could not reach $IN_HOST:$IN_PORT"
fi
opts=(-i "$dir/key" -o "UserKnownHostsFile=$dir/known_hosts" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15)
dest="$IN_USER@$IN_HOST"
q() { printf '%q' "$1"; }

# Upload next to the target, so the swap on the server is a rename on the same disk
new="$IN_TARGET.new"
echo "[deploy] uploading $IN_ARTIFACT to $dest:$new"
# Streamed over the SSH connection itself, so the server needs neither scp nor sftp.
ssh -p "$IN_PORT" "${opts[@]}" "$dest" "cat > $(q "$new")" < "$IN_ARTIFACT" \
  || fail "upload to $dest failed"

remote_env="TARGET=$(q "$IN_TARGET") NEW=$(q "$new") KEEP=$(q "$IN_KEEP") RESTART=$(q "$restart_cmd") LOGS=$(q "$logs_cmd") HEALTH_URL=$(q "$IN_HEALTH_URL") EXPECT=$(q "$IN_HEALTH_EXPECT") TIMEOUT=$(q "$IN_HEALTH_TIMEOUT") INTERVAL=$(q "$IN_HEALTH_INTERVAL")"

set +e
ssh -p "$IN_PORT" "${opts[@]}" "$dest" "env $remote_env bash -s" < "$here/remote.sh" | tee "$dir/out"
status=${PIPESTATUS[0]}
set -e

result="$(sed -n 's/^::result:://p' "$dir/out" | tail -n 1)"
[ -n "$result" ] || result="failed-no-backup"
echo "result=$result" >> "${GITHUB_OUTPUT:-/dev/null}"

case "$result" in
  deployed) echo "[deploy] done" ;;
  rolled-back) echo "::error::the new build failed its health check; the previous build was restored" ;;
  *) echo "::error::deploy failed ($result)" ;;
esac
exit "$status"
