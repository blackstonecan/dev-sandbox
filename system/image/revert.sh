#!/usr/bin/env bash
# Put the sandbox back on the normal disk (undo migrate.sh), keeping all
# changes made since. Needs free space for a full copy. The image file is not
# deleted.
#
# Close everything that uses the sandbox first, then run from home:
#   cd ~ && sudo bash <sandbox>/system/image/revert.sh
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
user=${SUDO_USER:?run with sudo, not as root}
home=$(getent passwd "$user" | cut -d: -f6)
sb=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)

# This script lives inside the mount it removes; run a copy from outside it.
if [[ ${DEV_REVERT_COPY:-} != 1 ]]; then
  copy=$(mktemp /tmp/dev-revert.XXXXXX.sh)
  cp "$0" "$copy"
  DEV_REVERT_COPY=1 DEV_REVERT_SB=$sb exec bash "$copy" "$@"
fi
sb=${DEV_REVERT_SB:?}
trap 'rm -f "$0"' EXIT

img=${DEV_SANDBOX_IMAGE:-$home/.local/share/dev-sandbox/sandbox.img}
tmp=/mnt/devsandbox-tmp

mountpoint -q "$sb" || die "$sb is not a mount point; nothing to undo"
[[ ! -e $tmp ]] || die "$tmp already exists; remove it first"

used=$(du -sb "$sb" | cut -f1)
avail=$(df --output=avail -B1 "$home" | tail -1 | tr -d ' ')
(( avail > used + 3 * 1024 * 1024 * 1024 )) || die "not enough free disk space for a full copy"

mkdir -p "$tmp"
mount --bind "$sb" "$tmp"
umount "$sb" || { umount "$tmp"; rmdir "$tmp"; die "cannot unmount $sb; something is still using it"; }
# $tmp now shows the image content; $sb is the empty directory under the mount.
rsync -aH --numeric-ids --info=progress2 "$tmp"/ "$sb"/
umount "$tmp"
rmdir "$tmp"

cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
grep -vF "$img" /etc/fstab > /etc/fstab.new
cat /etc/fstab.new > /etc/fstab
rm /etc/fstab.new
systemctl daemon-reload

echo "reverted. $img is still there; delete it when you no longer need it."
