#!/usr/bin/env bash
# Apply the root-level limits from limits.conf. `dev limits apply` says when
# this is needed. Run it yourself:
#   sudo bash <sandbox>/system/apply-root.sh
#
# - installs dockerdev.slice (Docker containers and builds), which
#   `dev limits apply` generates from DOCKER_*, when Docker runs as root
#   (docker.service is enabled, or --docker). Rootless Docker uses a
#   user-level slice that `dev limits apply` sets up without sudo.
# - sets the user-<uid>.slice backstop from USER_*
# - grows the sandbox image to SANDBOX_IMAGE_GB (never shrinks it)
# Values are parsed, not sourced, so nothing in limits.conf runs as root.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
user=${SUDO_USER:?run with sudo, not as root}
uid=$(id -u "$user")
home=$(getent passwd "$user" | cut -d: -f6)
sb=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
conf=$sb/limits.conf
slice=$sb/system/docker/dockerdev.slice
img=${DEV_SANDBOX_IMAGE:-$home/.local/share/dev-sandbox/sandbox.img}

[[ -f $conf ]] || die "$conf is missing; run install.sh first"

# Prints the last value of $1 in limits.conf if it matches regex $2.
val() {
  local v
  v=$(sed -nE "s/^$1=([^ #]*).*/\1/p" "$conf" | tail -1)
  [[ $v =~ $2 ]] || die "$1 in $conf is missing or invalid: '$v'"
  printf '%s\n' "$v"
}
mem='^([0-9]+[KMGT]?|[1-9][0-9]?%)$'
user_high=$(val USER_MEMORY_HIGH "$mem")
user_max=$(val USER_MEMORY_MAX "$mem")
image_gb=$(val SANDBOX_IMAGE_GB '^[1-9][0-9]*$')

rootful=0
if [[ ${1:-} == --docker ]] || systemctl is-enabled --quiet docker.service 2>/dev/null; then
  rootful=1
fi

# Docker slice: only the settings `dev` generates may be in the file.
if ((rootful)); then
  [[ -f $slice ]] || die "$slice is missing; run 'dev limits apply' first"
  if grep -vqE '^(#.*|\[Unit\]|\[Slice\]|Description=[^$`]*|Before=slices\.target|Memory(High|Max|SwapMax)=[0-9]+[KMGT%]?|TasksMax=[0-9]+|CPUWeight=[0-9]+|CPUQuota=[0-9]+%|)$' "$slice"; then
    die "$slice has unexpected lines; regenerate it with 'dev limits apply'"
  fi
  if ! cmp -s "$slice" /etc/systemd/system/dockerdev.slice; then
    install -m 0644 "$slice" /etc/systemd/system/dockerdev.slice
    systemctl daemon-reload
    echo "dockerdev.slice installed"
  fi
else
  echo "rootful Docker is not enabled; system dockerdev.slice skipped"
fi

# User slice: set-property persists in /etc/systemd/system.control.
systemctl set-property "user-$uid.slice" "MemoryHigh=$user_high" "MemoryMax=$user_max"
install -o "$user" -g "$(id -g "$user")" -m 0644 /dev/null "$sb/state/user-slice.applied"
printf '%s %s\n' "$user_high" "$user_max" > "$sb/state/user-slice.applied"
echo "user-$uid.slice: MemoryHigh=$user_high MemoryMax=$user_max"

# Sandbox image: grow the file, the loop device and the filesystem, online.
if [[ -f $img ]]; then
  size=$(stat -c %s "$img") want=$((image_gb * 1024 * 1024 * 1024))
  if ((want > size)); then
    loop=$(losetup -j "$img" | cut -d: -f1 | head -1)
    [[ -n $loop ]] || die "$img is not mounted; mount it (mount $sb) and run again"
    truncate -s "$want" "$img"
    losetup -c "$loop"
    resize2fs "$loop"
    echo "sandbox image grown to ${image_gb}GB"
  elif ((want < size)); then
    echo "warning: SANDBOX_IMAGE_GB is smaller than the image; shrinking is not supported" >&2
  fi
fi

echo
if ((rootful)); then
  systemctl show dockerdev.slice -p MemoryHigh -p MemoryMax -p MemorySwapMax -p TasksMax -p CPUWeight -p CPUQuotaPerSecUSec
fi
df -h "$sb" | tail -1
