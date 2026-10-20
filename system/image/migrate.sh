#!/usr/bin/env bash
# Move the sandbox onto its own ext4 image file, so it can never use more of
# the real disk than SANDBOX_IMAGE_GB (limits.conf). The image is sparse: it
# only takes the space actually used. pnpm hard links are kept.
#
# Close everything that uses the sandbox first (dev servers, editors, AI agent
# sessions, terminals whose directory is inside it), then run from home:
#   cd ~ && sudo bash <sandbox>/system/image/migrate.sh
#
# The old tree is kept as <sandbox>.old until you delete it.
# Undo: sudo bash <sandbox>/system/image/revert.sh
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
user=${SUDO_USER:?run with sudo, not as root}
home=$(getent passwd "$user" | cut -d: -f6)
sb=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)

# This script lives inside the tree it moves; run a copy from outside it.
if [[ ${DEV_MIGRATE_COPY:-} != 1 ]]; then
  copy=$(mktemp /tmp/dev-migrate.XXXXXX.sh)
  cp "$0" "$copy"
  DEV_MIGRATE_COPY=1 DEV_MIGRATE_SB=$sb exec bash "$copy" "$@"
fi
sb=${DEV_MIGRATE_SB:?}
trap 'rm -f "$0"' EXIT

img=${DEV_SANDBOX_IMAGE:-$home/.local/share/dev-sandbox/sandbox.img}
old=$sb.old
tmp=/mnt/devsandbox-tmp
fstab_line="$img $sb ext4 loop,noatime,nofail,x-gvfs-hide 0 2"
gbs=$(sed -nE 's/^SANDBOX_IMAGE_GB=([1-9][0-9]*)$/\1/p' "$sb/limits.conf" 2>/dev/null | tail -1)
gbs=${gbs:-50}

# Lists processes whose directory or open files are inside $1.
busy() {
  local p pid t f
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [[ $pid == $$ ]] && continue
    t=$(readlink "$p/cwd" 2>/dev/null) || true
    if [[ $t == "$1" || $t == "$1"/* ]]; then
      printf '  %s %s (cwd %s)\n' "$pid" "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-60)" "$t"
      continue
    fi
    for f in "$p"/fd/*; do
      t=$(readlink "$f" 2>/dev/null) || continue
      if [[ $t == "$1"/* ]]; then
        printf '  %s %s (open %s)\n' "$pid" "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-60)" "$t"
        break
      fi
    done
  done
}

[[ -d $sb ]] || die "$sb not found"
mountpoint -q "$sb" && die "$sb is already a mount point"
[[ ! -e $old ]] || die "$old already exists; remove or rename it first"
[[ ! -e $tmp ]] || die "$tmp already exists (an earlier run?); unmount and remove it first"

procs=$(busy "$sb")
if [[ -n $procs ]]; then
  echo "These processes use $sb; close them and run this again:" >&2
  printf '%s\n' "$procs" >&2
  exit 1
fi

used=$(du -sb "$sb" | cut -f1)
avail=$(df --output=avail -B1 "$home" | tail -1 | tr -d ' ')
(( avail > used + 3 * 1024 * 1024 * 1024 )) ||
  die "not enough free disk space: $sb uses $((used >> 30)) GB and the copy needs about the same again"
(( used + 2 * 1024 * 1024 * 1024 < gbs * 1024 * 1024 * 1024 )) ||
  die "$sb uses $((used >> 30)) GB, too much for a ${gbs} GB image; raise SANDBOX_IMAGE_GB"

if [[ ! -f $img ]]; then
  echo "== 0/6 creating a sparse ${gbs} GB image at $img"
  install -d -o "$user" -g "$(id -g "$user")" "$(dirname "$img")"
  truncate -s "${gbs}G" "$img"
  chown "$user:$(id -g "$user")" "$img"
  # No reserved blocks: the whole image is for the user.
  mkfs.ext4 -q -m 0 -L devsandbox "$img"
fi

echo "== 1/6 first copy into the image (hard links preserved)"
mkdir -p "$tmp"
mount -o loop,noatime "$img" "$tmp"
trap 'umount "$tmp" 2>/dev/null || true; rmdir "$tmp" 2>/dev/null || true; rm -f "$0"' EXIT
chown "$user:$(id -g "$user")" "$tmp"
rsync -aH --numeric-ids --info=progress2 "$sb"/ "$tmp"/
umount "$tmp"
rmdir "$tmp"
trap 'rm -f "$0"' EXIT

echo "== 2/6 fstab"
if ! grep -qF "$img" /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
  printf '%s\n' "$fstab_line" >> /etc/fstab
fi
systemctl daemon-reload

echo "== 3/6 swap in the image"
mv "$sb" "$old"
mkdir "$sb"
if ! mount "$sb"; then
  rmdir "$sb"
  mv "$old" "$sb"
  die "mounting failed; the old tree was put back"
fi
mountpoint -q "$sb" || { umount "$sb" 2>/dev/null || true; rmdir "$sb"; mv "$old" "$sb"; die "not mounted; old tree put back"; }

echo "== 4/6 second copy (changes made during the first copy)"
rsync -aH --numeric-ids --delete "$old"/ "$sb"/

echo "== 5/6 check"
n_old=$(find "$old" -xdev | wc -l)
n_new=$(find "$sb" -xdev | wc -l)
echo "files: old $n_old, new $n_new"
echo "size (hard links counted once): old $(du -sh "$old" | cut -f1), new $(du -sh "$sb" | cut -f1)"
[[ $n_old == "$n_new" ]] || echo "warning: file counts differ; keep $old and check before deleting it" >&2

echo "== 6/6 done"
df -h "$sb" | tail -1
printf '%s\n' "" "Next:" \
  "  1. Close this terminal and open a new one (old shells still see the old tree)." \
  "  2. Run: dev status" \
  "  3. When everything works, delete the old copy: rm -rf $old" \
  "     (Go's module cache is read-only: chmod -R u+w $old first)" \
  "  4. Containers with bind mounts from the old tree need a restart."
