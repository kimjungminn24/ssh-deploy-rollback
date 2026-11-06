#!/usr/bin/env bash
# End-to-end test: a real sshd on localhost, a fake app, and the real deploy script.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
port=2222
app_port=18080
sudo_() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

cleanup() {
  [ -f "$work/sshd.pid" ] && sudo_ kill "$(cat "$work/sshd.pid")" 2>/dev/null || true
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# sshd that only accepts our throwaway key
ssh-keygen -q -t ed25519 -N '' -f "$work/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$work/client_key"
cp "$work/client_key.pub" "$work/authorized_keys"
chmod 600 "$work/authorized_keys"
cat > "$work/sshd_config" <<CFG
Port $port
ListenAddress 127.0.0.1
HostKey $work/host_key
PidFile $work/sshd.pid
AuthorizedKeysFile $work/authorized_keys
PasswordAuthentication no
PermitRootLogin yes
StrictModes no
UsePAM no
CFG
sudo_ mkdir -p /run/sshd
sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"
sudo_ "$sshd_bin" -f "$work/sshd_config"
known=""
for _ in $(seq 40); do
  known="$(ssh-keyscan -p $port 127.0.0.1 2>/dev/null | grep -v '^#' || true)"
  [ -n "$known" ] && break
  sleep 0.25
done
[ -n "$known" ] || { echo "sshd did not start"; exit 1; }

srv="$work/server"
mkdir -p "$srv"
target="$srv/app.jar"
python3 "$root/test/fake-app.py" "$target" $app_port &
app_pid=$!

pass=0
fail=0
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass + 1)); else echo "  FAIL $1"; fail=$((fail + 1)); printf "%s\n" "${out:-}" | sed "s/^/      /" | tail -n 15; fi; }

deploy() { # content, keep -> sets $out and $code
  printf "%s\n" "$1" > "$work/artifact.jar"; : > "$work/output"
  set +e
  out=$(
    IN_HOST=127.0.0.1 IN_USER="$(id -un)" IN_KEY="$(cat "$work/client_key")" IN_PORT=$port \
    IN_KNOWN_HOSTS="$known" \
    IN_ARTIFACT="$work/artifact.jar" IN_TARGET="$target" IN_SERVICE='' \
    IN_RESTART="echo restarted >> $srv/restarts" IN_LOGS="echo app log line" \
    IN_HEALTH_URL="http://127.0.0.1:$app_port/health" IN_HEALTH_EXPECT=UP \
    IN_HEALTH_TIMEOUT=3 IN_HEALTH_INTERVAL=1 IN_KEEP="${2:-1}" \
    GITHUB_OUTPUT="$work/output" bash "$root/scripts/deploy.sh" 2>&1
  )
  code=$?
  set -e
  result=$(sed -n 's/^result=//p' "$work/output" | tail -n 1)
  : > "$work/output"
}

echo "first deploy, nothing to roll back to"
deploy "ok v1"
check "succeeds" '[ $code = 0 ] && [ "$result" = deployed ]'
check "file is in place" 'grep -q "ok v1" "$target"'
check "no backup yet" '[ ! -f "$target.prev" ]'

echo "second deploy"
deploy "ok v2"
check "succeeds" '[ "$result" = deployed ]'
check "previous build kept" 'grep -q "ok v1" "$target.prev"'
check "upload file cleaned up" '[ ! -f "$target.new" ]'

echo "broken build rolls back"
deploy "broken v3"
check "step fails" '[ $code != 0 ]'
check "reports rolled-back" '[ "$result" = rolled-back ]'
check "previous build restored" 'grep -q "ok v2" "$target"'
check "logs shown" 'grep -q "app log line" <<<"$out"'

echo "keep=2 keeps two backups"
deploy "ok v4" 2
deploy "ok v5" 2
check "newest backup" 'grep -q "ok v4" "$target.prev"'
check "older backup" 'grep -q "ok v2" "$target.prev.2"'

echo "broken build with no backup"
rm -f "$target" "$target".prev*
deploy "broken v6" 0
check "fails without a backup" '[ $code != 0 ] && [ "$result" = failed-no-backup ]'

echo "bad input"
set +e; IN_ARTIFACT=/nope IN_KEEP=1 IN_HEALTH_TIMEOUT=1 IN_HEALTH_INTERVAL=1 bash "$root/scripts/deploy.sh" >/dev/null 2>&1; c=$?; set -e
check "missing artifact is an error" '[ $c != 0 ]'

echo "restart ran $(wc -l < "$srv/restarts") times"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
