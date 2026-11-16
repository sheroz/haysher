#!/usr/bin/env bash
# Builds the release binary and deploys it to the server deploy.env names. The running binary is kept as
# haysher.prev, and restored if the new one does not come up ready. The config is not copied.
set -euo pipefail

cd "$(dirname "$0")"

# Settings come from the environment, then from deploy.env beside this script (see deploy.env.example).
if [[ -f deploy.env ]]; then
  given=()
  for name in ${!HAYSHER_@}; do
    given+=("$(declare -p "$name")")
  done
  source deploy.env
  for setting in "${given[@]}"; do
    eval "$setting"
  done
fi

# Where to deploy.
host=${HAYSHER_HOST:?set it in deploy.env or the environment (see deploy.env.example)}
dir=${HAYSHER_DIR:-/opt/haysher}

cargo build --release --locked
version=$(target/release/haysher --version)
echo "deploying $version to $host:$dir"
if [[ $version == *-dirty ]]; then
  echo "warning: built from uncommitted sources" >&2
fi

scp -q target/release/haysher "$host:$dir/haysher.new"
ssh "$host" "bash -s -- $(printf %q "$dir")" <<'EOF'
set -euo pipefail
cd "$1"
chmod 755 haysher.new
cp -p haysher haysher.prev
mv haysher.new haysher
systemctl restart haysher

# Ready once the service is active and its metrics, bound on loopback port 9100, say so.
# Quiet curl: the first tries refuse while the new process is still starting.
ready() {
  systemctl is-active --quiet haysher &&
    curl -fs --max-time 2 http://127.0.0.1:9100/metrics | grep -qx 'haysher_ready 1'
}
for _ in $(seq 30); do
  if ready; then
    echo "running $(./haysher --version)"
    exit 0
  fi
  sleep 1
done

echo "error: the new binary did not come up ready within 30 s; restoring haysher.prev" >&2
journalctl -u haysher -n 20 --no-pager -o cat >&2 || true
cp -p haysher.prev haysher
systemctl restart haysher
exit 1
EOF
