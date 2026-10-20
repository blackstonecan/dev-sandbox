#!/usr/bin/env bash
# Tests for bin/dev. Everything runs in a throwaway HOME and sandbox with a
# minimal PATH, so real projects and caches are never touched.
#
#   bash tests/run.sh
set -uo pipefail

repo=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/home/projects" "$T/sb"
cp "$repo/limits.conf.example" "$T/sb/limits.conf"
sed -i 's/^MIN_FREE_GB=.*/MIN_FREE_GB=0/' "$T/sb/limits.conf"

pass=0 fail=0
dev() {
  env -i HOME="$T/home" PATH=/usr/bin:/bin DEV_SANDBOX="$T/sb" \
    DEV_PROJECT_ROOTS="$T/home/projects" bash "$repo/bin/dev" "$@" </dev/null
}
check() {
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else fail=$((fail + 1)); printf '  FAIL  %s\n' "$name"; fi
}
mkproj() {
  mkdir -p "$1/src" "$1/node_modules/pkg" "$1/dist"
  printf '{}\n' > "$1/package.json"
  printf 'x\n' > "$1/src/index.js"
  printf 'x\n' > "$1/node_modules/pkg/index.js"
  printf 'x\n' > "$1/dist/out.js"
}

echo "basics"
check "--version prints the version" bash -c "$(declare -f dev); T='$T' repo='$repo'; dev --version | grep -q '^dev [0-9]'"
check "--help shows the limits command" bash -c "$(declare -f dev); T='$T' repo='$repo'; dev --help | grep -q 'limits \['"
check "unknown command fails" bash -c "$(declare -f dev); T='$T' repo='$repo'; ! dev nope 2>/dev/null"

echo "limits"
dev limits set LIMIT_PROJECT_GB=12 TERM_MEMORY_MAX=70% >/dev/null
check "set changes the values" grep -qx 'LIMIT_PROJECT_GB=12' "$T/sb/limits.conf"
check "set takes percentages" grep -qx 'TERM_MEMORY_MAX=70%' "$T/sb/limits.conf"
cp "$T/sb/limits.conf" "$T/before"
dev limits set NOPE=1 2>/dev/null
dev limits set TERM_MEMORY_MAX=lots 2>/dev/null
dev limits set 'TERM_SLICE=x;rm -rf ~' 2>/dev/null
dev limits set TERM_SWAP_MAX=50% 2>/dev/null
dev limits set "BUILD_CPU_CORES=$(( $(nproc) + 1 ))" 2>/dev/null
dev limits set WARN_FREE_GB=1 2>/dev/null
check "invalid values leave limits.conf unchanged" cmp -s "$T/before" "$T/sb/limits.conf"
check "invalid value exits non-zero" bash -c "$(declare -f dev); T='$T' repo='$repo'; ! dev limits set TERM_TASKS_MAX=-1 2>/dev/null"

echo "activate / deactivate"
mkproj "$T/home/projects/app"
dev activate "$T/home/projects/app" --no-install >/dev/null 2>&1
check "activate moves the project in" test -f "$T/sb/projects/app/src/index.js"
check "activate removes the original path" test ! -e "$T/home/projects/app"
check "activate records the origin" grep -q "^app	$T/home/projects/app	" "$T/sb/state/projects.tsv"
check "path prints the sandbox path" test "$(dev path app)" = "$T/sb/projects/app"
mkproj "$T/home/projects/other/app"
check "activate refuses a duplicate name" bash -c "$(declare -f dev); T='$T' repo='$repo'; ! dev activate '$T/home/projects/other/app' --no-install 2>/dev/null"
dev deactivate app >/dev/null 2>&1
check "deactivate moves the project back" test -f "$T/home/projects/app/src/index.js"
check "deactivate deletes node_modules" test ! -e "$T/home/projects/app/node_modules"
check "deactivate deletes dist next to package.json" test ! -e "$T/home/projects/app/dist"
check "deactivate clears the state" test ! -s "$T/sb/state/projects.tsv"

echo "clean"
mkproj "$T/home/projects/b"
mkdir -p "$T/home/projects/notes/dist"
dev clean "$T/home/projects" --dry-run >/dev/null
check "clean --dry-run deletes nothing" test -d "$T/home/projects/b/node_modules"
dev clean "$T/home/projects" --yes >/dev/null
check "clean --yes deletes artifacts" test ! -e "$T/home/projects/b/node_modules"
check "clean keeps dist without a build file" test -d "$T/home/projects/notes/dist"
check "clean keeps source" test -f "$T/home/projects/b/src/index.js"

echo ".devkeep"
mkproj "$T/home/projects/kept"
touch "$T/home/projects/kept/.devkeep"
check "activate refuses a protected directory" bash -c "$(declare -f dev); T='$T' repo='$repo'; ! dev activate '$T/home/projects/kept' --no-install 2>/dev/null"
dev clean "$T/home/projects" --yes >/dev/null
check "clean skips a protected directory" test -d "$T/home/projects/kept/node_modules"

echo
echo "$pass passed, $fail failed"
((fail == 0))
