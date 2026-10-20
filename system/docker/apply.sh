#!/usr/bin/env bash
# Point Docker at the resource-capped dockerdev.slice and turn on log rotation,
# builder garbage collection and live-restore. Existing settings in
# /etc/docker/daemon.json are kept; only the keys in daemon.json here are set.
# Run `dev limits apply` first (it generates dockerdev.slice), then:
#   sudo bash <sandbox>/system/docker/apply.sh
# It restarts Docker once; containers that were running are started again.
# Undo with revert.sh in this directory.
set -euo pipefail

src=$(dirname "$(readlink -f "$0")")
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

if pgrep -f 'docker (build|buildx)' >/dev/null; then
  echo "a docker build is running; try again when it is done" >&2
  exit 1
fi

# The slice must exist before Docker is told to use it.
bash "$src/../apply-root.sh"

install -d -m 0755 /etc/docker
if [[ -e /etc/docker/daemon.json ]]; then
  cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
fi
python3 -c '
import json, os, sys
target, ours = sys.argv[1], sys.argv[2]
cfg = json.load(open(target)) if os.path.exists(target) and os.path.getsize(target) else {}
cfg.update(json.load(open(ours)))
with open(target + ".new", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(target + ".new", target)
' /etc/docker/daemon.json "$src/daemon.json"
chmod 0644 /etc/docker/daemon.json

running=$(docker ps -q)
systemctl restart docker
# restart=no containers stay stopped after the daemon restarts.
# shellcheck disable=SC2086
[[ -z $running ]] || docker start $running >/dev/null 2>&1 || true

echo
echo "Docker now uses dockerdev.slice:"
systemctl show dockerdev.slice -p MemoryHigh -p MemoryMax -p CPUQuotaPerSecUSec
