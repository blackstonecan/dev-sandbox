---
name: dev-sandbox
description: Rules for installing dependencies and managing projects on this machine through the `dev` sandbox CLI. Use whenever a task involves installing or adding packages (npm, pnpm, yarn, pip, uv, conda, go, gradle), creating a Python environment, running a one-off script that needs libraries, installing a global CLI tool, starting work on a project that has no node_modules/.venv, freeing disk space, changing resource limits, or when the user mentions the sandbox, activating or deactivating a project, or `dev`.
---

# Development sandbox

This machine keeps dependencies only for projects that are actively being
worked on, and caps the disk, memory and CPU that development work can use.
The sandbox lives in `$DEV_SANDBOX` (default `~/dev-sandbox`).

- **Active projects** live in `$DEV_SANDBOX/projects/<name>` and keep their
  dependencies and build outputs.
- **Inactive projects** live anywhere else and contain only source code. Their
  `node_modules`, `.venv`, `build`, `dist`, etc. were deleted on purpose.
- **Shared caches** (npm, pnpm store, uv, Go, Gradle) live in
  `$DEV_SANDBOX/cache` and are pruned when a project is deactivated.

The `dev` CLI manages all of this. Run `dev --help` for full usage.

## Commands

- `dev activate <path>`: moves the project into the sandbox, then installs
  dependencies in every sub-directory that has a lockfile (`pnpm install`,
  `uv sync` or `uv pip install -r requirements.txt`, `go mod download`).
  npm/yarn lockfiles are converted with `pnpm import` and deleted.
  - `--name NAME`: name used in the sandbox (default: last path component).
    Needed when two projects share a folder name.
  - `--no-install`: only move, install nothing.
  - `--force`: proceed even if processes are running inside the project.
- `dev deactivate <name>`: stops Gradle daemons, deletes artifacts, moves the
  project back to its original path and prunes caches.
- `dev path <name>`: prints the sandbox path (`cd "$(dev path NAME)"`).
- `dev list`: active projects with sandbox path, original path, date.
- `dev status`: active projects, cache sizes, limits, global tools, free disk.
- `dev clean <path>`: deletes artifacts under an inactive directory; lists them
  and asks first. `--dry-run`: only list. `--yes`: do not ask.
- `dev prune`: runs only the cache pruning step.
- `dev doctor`: checks cache configuration, legacy caches outside the sandbox,
  stray venvs, inactive projects that still hold artifacts, and limits.
- `dev limits [show | set KEY=VALUE ... | edit | apply]`: every limit (disk,
  RAM/swap/CPU for terminals, Docker containers, Docker builds, the user slice,
  the sandbox image size) lives in `$DEV_SANDBOX/limits.conf`. `apply` applies
  the user-level ones and prints a `sudo bash .../system/apply-root.sh` command
  when root-level ones changed.

## Rules

### Projects
- Before installing dependencies or building a project that is **not** under
  `$DEV_SANDBOX/projects`, stop and suggest `dev activate <path>` instead of
  installing in place. Do not run the command yourself: it moves the directory,
  so ask the user first.
- Once a project is active, work from its sandbox path; the original path does
  not exist while the project is active.
- Prefer activating the smallest unit being worked on (usually one git repo).
  Activating a folder with many sub-projects installs all of them.
- Code that reaches outside the project with relative paths (`../secrets.json`)
  breaks while the project is in the sandbox; check for this before activating.
- The pnpm migration shows up in git as a deleted `package-lock.json` and a new
  `pnpm-lock.yaml`; that is expected.
- Never run `dev deactivate` or `dev clean` without the user's explicit request;
  show `dev clean --dry-run` output first when cleaning.
- Directories containing a `.devkeep` file are never moved or cleaned by `dev`.
- Never edit `$DEV_SANDBOX/state/projects.tsv` or move projects inside the
  sandbox by hand.

### Limits
- Change limits only with `dev limits set` / `dev limits apply`, never by
  editing systemd units or Docker config directly.
- Never run `sudo`. When `dev limits apply` prints a sudo command, give it to
  the user to run.
- A build or test killed by the OOM killer inside the terminal slice means the
  limit was hit; tell the user instead of retrying in a loop.

### Node.js
- Use **pnpm**: `pnpm install`, `pnpm add <pkg>`, `pnpm add -D <pkg>`,
  `pnpm remove <pkg>`. Never `npm install` or `yarn`.
- Never leave both `package-lock.json` and `pnpm-lock.yaml` in a project.
- React Native / Expo projects need `node-linker=hoisted` in their `.npmrc`
  (`dev activate` adds it automatically).
- Avoid `npm i -g`; prefer `npx <tool>` or `pnpm dlx <tool>`.

### Python
- **uv is the Python tool.** `pip install` outside a venv is blocked by
  `PIP_REQUIRE_VIRTUALENV=true`; do not use conda.
- Project dependencies: `uv init`, `uv add <pkg>`, `uv sync`, `uv run <cmd>`.
- Legacy `requirements.txt` projects: `uv venv && uv pip install -r requirements.txt`.
- One-off scripts: `uv run --with <pkg> script.py`, or PEP 723 inline metadata
  (`uv add --script script.py <pkg>`). Do not create throwaway venvs.
- CLI tools: `uv tool install <pkg>`.
- Only if a package exists solely on conda-forge, use **pixi** (project-local
  `.pixi/` environment).
- Never install packages into the system Python.

### Caches
- Never move cache locations away from `$DEV_SANDBOX/cache` (npm `cache`, pnpm
  `store-dir`, uv `cache-dir`, `go env GOMODCACHE/GOCACHE`, `GRADLE_USER_HOME`).

## Troubleshooting
- "Cannot find module" / missing `.venv` in a project outside the sandbox: the
  project is inactive; suggest `dev activate`.
- Caches written to `~/.npm`, `~/.gradle`, `~/.cache/uv`, etc.: run
  `dev doctor`, which reports misconfiguration and legacy caches.
- `dev deactivate` refuses because processes are running inside the project:
  stop dev servers/terminals there, or use `--force` only if the user agrees.
