# Development sandbox environment. install.sh sources it from your shell rc
# with DEV_SANDBOX already set. npm, pnpm, uv and Go store their cache
# locations in their own config files; only settings without one live here.
export DEV_SANDBOX="${DEV_SANDBOX:-$HOME/dev-sandbox}"
export GRADLE_USER_HOME="$DEV_SANDBOX/cache/gradle"
export PIP_REQUIRE_VIRTUALENV=true
# Docker builds run in the resource-capped builder once it exists
# (system/docker/setup-builder.sh writes the stamp file).
if [ -f "$DEV_SANDBOX/state/builder.applied" ]; then
  export BUILDX_BUILDER=capped
fi
