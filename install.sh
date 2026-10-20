#!/usr/bin/env bash
# Install the dev sandbox from this directory. Safe to run again.
# Never uses sudo: root-level steps are printed at the end for you to run.
#
#   ./install.sh [--no-docker] [--no-caches] [--no-skill] [--ballast GB]
#
#   --no-docker   do not create the resource-capped Docker builder
#   --no-caches   do not point npm, pnpm, uv and Go caches into the sandbox
#   --no-skill    do not link the Claude Code skill into ~/.claude/skills
#   --ballast GB  reserve GB of disk in a file you can delete in an emergency
set -euo pipefail

sb=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
docker=1 caches=1 skill=1 ballast=0
while (($#)); do
  case $1 in
    --no-docker) docker=0 ;;
    --no-caches) caches=0 ;;
    --no-skill) skill=0 ;;
    --ballast) ballast=${2:?--ballast needs a size in GB}; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option '$1'" >&2; exit 1 ;;
  esac
  shift
done

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B="" G="" Y="" R="" N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
skip() { printf '  %s-%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
dev()  { DEV_SANDBOX=$sb "$sb/bin/dev" "$@"; }

step "Checking requirements"
[[ $(uname -s) == Linux ]] || die "Linux only (systemd and cgroup v2 do the limiting)"
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) || die "bash 4.3 or newer is needed"
[[ -f /sys/fs/cgroup/cgroup.controllers ]] || die "cgroup v2 is needed (unified hierarchy)"
systemctl --user show-environment >/dev/null 2>&1 || die "no systemd user manager is running for $USER"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root"
ok "Linux, bash $BASH_VERSION, cgroup v2, systemd user manager"

step "Sandbox at $sb"
mkdir -p "$sb/projects" "$sb/cache" "$sb/state"
touch "$sb/state/projects.tsv"
chmod +x "$sb/bin/dev" "$sb"/system/*.sh "$sb"/system/*/*.sh "$sb"/*.sh
if [[ -f $sb/limits.conf ]]; then
  ok "limits.conf exists; kept as it is"
else
  cp "$sb/limits.conf.example" "$sb/limits.conf"
  n=$(nproc)
  mem_gb=$(awk '/^MemTotal:/ {print int($2 / 1024 / 1024)}' /proc/meminfo)
  build_mem=$((mem_gb / 4 > 2 ? mem_gb / 4 : 2))
  set_args=(
    "TERM_CPU_CORES=$((n > 2 ? n - 2 : 1))"
    "DOCKER_CPU_CORES=$((n > 4 ? n - 4 : (n > 1 ? n - 1 : 1)))"
    "BUILD_CPU_CORES=$((n / 2 > 0 ? n / 2 : 1))"
    "BUILD_MEMORY=${build_mem}G" "BUILD_MEMORY_SWAP=$((build_mem + 2))G"
  )
  # The terminal's own slice, e.g. app-org.gnome.Terminal.slice or app-kitty.slice.
  parent=$(basename "$(dirname "$(sed -n 's/^0:://p' /proc/self/cgroup)")")
  if [[ $parent == app-*.slice ]]; then
    set_args+=("TERM_SLICE=$parent")
  else
    skip "could not detect your terminal's slice (got '$parent'); set TERM_SLICE in limits.conf"
  fi
  dev limits set "${set_args[@]}" >/dev/null
  ok "limits.conf created for $n cores and ${mem_gb} GB RAM"
fi

step "Command"
mkdir -p "$HOME/.local/bin"
link=$HOME/.local/bin/dev
if [[ -e $link && ! -L $link ]]; then
  die "$link exists and is not a symlink; move it away first"
fi
ln -sfn "$sb/bin/dev" "$link"
ok "$link -> $sb/bin/dev"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) skip "add ~/.local/bin to your PATH" ;; esac

step "Shell setup"
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f $rc || $rc == "$HOME/.bashrc" ]] || continue
  if grep -qs '>>> dev sandbox >>>' "$rc"; then
    ok "${rc/#"$HOME"/\~} already sources env.sh"
    continue
  fi
  printf '\n%s\n%s\n%s\n%s\n' "# >>> dev sandbox >>>" \
    "export DEV_SANDBOX=\"$sb\"" \
    "[ -f \"\$DEV_SANDBOX/env.sh\" ] && . \"\$DEV_SANDBOX/env.sh\"" \
    "# <<< dev sandbox <<<" >> "$rc"
  ok "${rc/#"$HOME"/\~} sources env.sh"
done

step "Package caches"
if ((caches)); then
  if have npm; then npm config set cache "$sb/cache/npm" && ok "npm cache"; fi
  if have pnpm; then pnpm config set store-dir "$sb/cache/pnpm-store" --global && ok "pnpm store"; fi
  if have go; then go env -w GOMODCACHE="$sb/cache/go-mod" GOCACHE="$sb/cache/go-build" && ok "Go caches"; fi
  if have uv; then
    uvconf=$HOME/.config/uv/uv.toml
    if grep -qs '^cache-dir' "$uvconf"; then
      grep -qF "\"$sb/cache/uv\"" "$uvconf" && ok "uv cache" ||
        skip "uv: $uvconf already sets cache-dir; change it to \"$sb/cache/uv\" yourself"
    else
      mkdir -p "$(dirname "$uvconf")"
      printf 'cache-dir = "%s"\n' "$sb/cache/uv" >> "$uvconf"
      ok "uv cache"
    fi
  fi
  ok "Gradle uses GRADLE_USER_HOME from env.sh"
else
  skip "skipped (--no-caches)"
fi

step "Disk watchdog"
units=$HOME/.config/systemd/user
mkdir -p "$units"
sed "s#@SANDBOX@#$sb#g" "$sb/systemd/dev-watchdog.service" > "$units/dev-watchdog.service"
cp "$sb/systemd/dev-watchdog.timer" "$units/dev-watchdog.timer"
systemctl --user daemon-reload
systemctl --user enable --now dev-watchdog.timer >/dev/null 2>&1
ok "dev-watchdog.timer checks free space every 2 minutes"
if ((ballast)); then
  bfile=$HOME/.local/share/dev-ballast
  if [[ -f $bfile ]]; then ok "ballast exists"
  else
    mkdir -p "$(dirname "$bfile")"
    fallocate -l "${ballast}G" "$bfile"
    ok "${ballast} GB ballast at ${bfile/#"$HOME"/\~} (delete it if the disk ever fills up)"
  fi
fi

step "Docker build limits"
if ((!docker)); then
  skip "skipped (--no-docker)"
elif ! have docker || ! docker info >/dev/null 2>&1; then
  skip "Docker is not installed or not usable without sudo; run system/docker/setup-builder.sh later"
else
  bash "$sb/system/docker/setup-builder.sh" >/dev/null
  ok "capped buildx builder created (open a new shell so BUILDX_BUILDER=capped is set)"
fi

step "Applying limits"
dev limits apply

if ((skill)) && [[ -d $HOME/.claude ]]; then
  step "Claude Code skill"
  mkdir -p "$HOME/.claude/skills"
  target=$HOME/.claude/skills/dev-sandbox
  if [[ -L $target || ! -e $target ]]; then
    ln -sfn "$sb/skill/dev-sandbox" "$target"
    ok "${target/#"$HOME"/\~} -> skill/dev-sandbox"
  else
    skip "$target exists and is not a symlink; left alone"
  fi
fi

printf '\n%sDone.%s Open a new terminal, then run: dev doctor\n\n' "$B" "$N"
printf 'Root-level limits are optional; run these yourself:\n'
if have docker; then
  printf '  sudo bash %s/system/docker/apply.sh     # Docker slice + user slice (restarts Docker once)\n' "$sb"
else
  printf '  sudo bash %s/system/apply-root.sh       # user-session memory backstop\n' "$sb"
fi
printf '  cd ~ && sudo bash %s/system/image/migrate.sh   # hard disk cap: move the sandbox onto its own image\n' "$sb"
