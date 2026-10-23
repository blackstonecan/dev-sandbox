#!/usr/bin/env bash
# Remove what apply.sh set in /etc/docker/daemon.json, remove dockerdev.slice
# and restart Docker. Run it yourself:
#   sudo bash <sandbox>/system/docker/revert.sh
# Rootful Docker only; uninstall.sh undoes the rootless settings.
set -euo pipefail

src=$(dirname "$(readlink -f "$0")")
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

if [[ -f /etc/docker/daemon.json ]]; then
  cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
  python3 -c '
import json, os, sys
target, ours = sys.argv[1], sys.argv[2]
cfg = json.load(open(target))
for key in json.load(open(ours)):
    cfg.pop(key, None)
if cfg:
    with open(target + ".new", "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(target + ".new", target)
else:
    os.remove(target)
' /etc/docker/daemon.json "$src/daemon.json"
fi

running=$(docker ps -q)
rm -f /etc/systemd/system/dockerdev.slice
systemctl daemon-reload
systemctl restart docker
# shellcheck disable=SC2086
[[ -z $running ]] || docker start $running >/dev/null 2>&1 || true
echo "reverted; Docker runs without the dev sandbox settings again"
