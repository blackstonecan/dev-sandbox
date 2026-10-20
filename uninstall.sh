#!/usr/bin/env bash
# Remove what install.sh set up for your user. Projects, caches and this
# directory are left in place. Root-level steps are printed for you to run.
#
#   ./uninstall.sh [--force]    --force: even with active projects
set -euo pipefail

sb=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
force=0
[[ ${1:-} == --force ]] && force=1

if [[ -s $sb/state/projects.tsv ]] && ((!force)); then
  echo "These projects are still active; deactivate them first (or use --force):" >&2
  cut -f1 "$sb/state/projects.tsv" | sed 's/^/  dev deactivate /' >&2
  exit 1
fi

systemctl --user disable --now dev-watchdog.timer >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/dev-watchdog.service" "$HOME/.config/systemd/user/dev-watchdog.timer"

TERM_SLICE=$(sed -nE 's/^TERM_SLICE=([A-Za-z0-9@._-]+\.slice)$/\1/p' "$sb/limits.conf" 2>/dev/null | tail -1)
if [[ -n $TERM_SLICE ]]; then
  rm -f "$HOME/.config/systemd/user/$TERM_SLICE.d/10-dev-limits.conf"
  rmdir "$HOME/.config/systemd/user/$TERM_SLICE.d" 2>/dev/null || true
fi
systemctl --user daemon-reload
echo "removed the watchdog timer and terminal limits (open terminals keep them until closed)"

link=$HOME/.local/bin/dev
if [[ -L $link && $(readlink "$link") == "$sb/bin/dev" ]]; then rm "$link"; echo "removed $link"; fi
skill=$HOME/.claude/skills/dev-sandbox
if [[ -L $skill && $(readlink "$skill") == "$sb/skill/dev-sandbox" ]]; then rm "$skill"; echo "removed $skill"; fi

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  grep -qs '>>> dev sandbox >>>' "$rc" || continue
  cp -a "$rc" "$rc.bak.$(date +%s)"
  sed -i '/# >>> dev sandbox >>>/,/# <<< dev sandbox <<</d' "$rc"
  echo "removed the env.sh block from $rc"
done

if command -v docker >/dev/null 2>&1 && docker buildx inspect capped >/dev/null 2>&1; then
  docker buildx use default && docker buildx rm capped && echo "removed the capped Docker builder"
fi
rm -f "$sb/state/builder.applied"

cat <<EOF

Left for you to do, if you want:
  sudo bash $sb/system/docker/revert.sh                       # Docker settings and slice
  sudo systemctl set-property user-$(id -u).slice MemoryHigh=infinity MemoryMax=infinity
  cd ~ && sudo bash $sb/system/image/revert.sh                # only if you ran migrate.sh
  npm config delete cache; pnpm config delete store-dir --global; go env -u GOMODCACHE GOCACHE
  (and remove cache-dir from ~/.config/uv/uv.toml)
EOF
