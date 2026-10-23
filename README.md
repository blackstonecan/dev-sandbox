# dev-sandbox

A development sandbox for Linux laptops and workstations: dependencies only for
the projects you are working on, and hard caps on the disk, memory and CPU that
development work can use. A runaway build, a dependency install that explodes,
or an AI coding agent stuck in a loop cannot freeze the desktop or fill the
disk.

Plain bash on top of systemd and cgroup v2; no daemon, no containers needed.

## What it does

**Projects.** `dev activate ~/projects/app` moves a project into
`~/dev-sandbox/projects/app` and installs its dependencies. `dev deactivate app`
deletes `node_modules`, `.venv`, `dist`, `target` and friends, moves the
project back and prunes the shared caches. Inactive projects keep only source
code, so dozens of them cost almost no disk.

**Shared caches.** npm, pnpm, uv, Go and Gradle caches all live in
`~/dev-sandbox/cache`, so they are counted, capped and pruned together.

**Limits, all in one file.** `limits.conf` sets:

| Scope | What | How |
| --- | --- | --- |
| Terminal windows | RAM, swap, tasks, CPU | systemd user slice of your terminal |
| Docker containers | RAM, swap, tasks, CPU | `dockerdev.slice` via `cgroup-parent` (a user slice for rootless Docker) |
| Docker builds | RAM, swap, CPU, build cache | a `docker-container` buildx builder |
| Your whole session | RAM backstop | `user-<uid>.slice` |
| Sandbox disk | hard cap | ext4 image file mounted on `~/dev-sandbox` |
| Sandbox disk | soft caps per project / total | checked by `dev activate`, `status`, `doctor` |
| Host disk | free-space alerts | user timer + desktop notification |

Memory limits use `MemoryHigh` (throttle and reclaim) below `MemoryMax`
(OOM-kill inside the slice), so a runaway process slows down first and is then
killed alone, instead of the kernel picking a victim on your desktop.

## Requirements

- Linux with systemd and cgroup v2 (any current Ubuntu, Fedora, Debian, Arch)
- bash 4.3+, coreutils, findutils, python3 (only for the Docker step)
- Optional: pnpm, uv, Go, Gradle, Docker (rootless recommended; see below)

## Install

```sh
git clone https://github.com/<you>/dev-sandbox.git ~/dev-sandbox
~/dev-sandbox/install.sh
```

The installer never uses `sudo`. It:

- creates `limits.conf` sized for your CPU count and RAM, and detects the
  systemd slice your terminal runs in (run it from the terminal you develop in)
- links `dev` into `~/.local/bin` and sources `env.sh` from `~/.bashrc`/`~/.zshrc`
- points npm, pnpm, uv and Go caches into `~/dev-sandbox/cache` (pnpm: `storeDir`
  in `~/.config/pnpm/config.yaml` for pnpm 11, `store-dir` in
  `~/.config/pnpm/rc` for pnpm 10)
- enables the disk watchdog timer
- creates the capped Docker builder and applies the terminal limits (and,
  for rootless Docker, the container limits)
- links the Claude Code skill into `~/.claude/skills` if `~/.claude` exists

Options: `--no-docker`, `--no-caches`, `--no-skill`, `--ballast GB` (a file you
can delete to get space back when the disk is full).

It then prints the optional root-level steps, which you run yourself:

```sh
sudo bash ~/dev-sandbox/system/apply-root.sh            # session backstop
cd ~ && sudo bash ~/dev-sandbox/system/image/migrate.sh # hard disk cap
```

With rootful Docker it prints `system/docker/apply.sh` instead of
`apply-root.sh` (Docker slice + session backstop), and suggests rootless
Docker.

`migrate.sh` creates a sparse ext4 image of `SANDBOX_IMAGE_GB`, copies the
sandbox into it (keeping pnpm hard links), adds it to `/etc/fstab` and mounts
it over `~/dev-sandbox`. The old tree is kept as `~/dev-sandbox.old` until you delete
it. `system/image/revert.sh` undoes it.

## Usage

```
dev activate <path> [--name NAME] [--no-install] [--force]
dev deactivate <name> [--force]
dev list | path <name> | status
dev clean <path> [--dry-run] [--yes]   delete artifacts under inactive projects
dev prune                              prune shared caches
dev doctor                             find misconfiguration and leftovers
dev limits                             show every limit, configured vs. live
dev limits set KEY=VALUE ...           change limits (validated, atomic)
dev limits edit                        open limits.conf in $EDITOR
dev limits apply                       apply them
```

`dev limits apply` applies the user-level limits immediately (open terminals
included) and, when a root-level limit changed, prints the one command to run:

```
$ dev limits set TERM_MEMORY_MAX=24G DOCKER_CPU_CORES=6
$ dev limits apply
-> terminal sessions: app-org.gnome.Terminal.slice updated
-> docker containers: dockerdev.slice updated (containers made before the cap: see dev doctor)
-> docker builds: unchanged
-> root-level limits: unchanged
```

With rootful Docker the container limits are root-level instead, and the last
line becomes `needs root (Docker slice); run it yourself: sudo bash
~/dev-sandbox/system/apply-root.sh`.

`apply-root.sh` parses `limits.conf` instead of sourcing it, so nothing in that
file ever runs as root. It only ever grows the disk image.

## Rootless Docker

Use Docker in rootless mode. With the usual rootful setup, the `docker` group
is root without a password: `docker run -v /:/host ...` gives any process of
yours, an AI agent included, every file on the machine, such as the store and
key of a secret broker like secretd. Rootless Docker runs the daemon as your
user, so a container can reach nothing you cannot.

It also keeps all limits user-level: containers run under your systemd user
manager, and `dev limits apply` writes `~/.config/systemd/user/dockerdev.slice`
and merges `cgroup-parent`, log rotation and builder GC into
`~/.config/docker/daemon.json` (other keys are kept), with no sudo. It
restarts Docker once when that file changes. A container keeps the cgroup it
was created with, so recreate the ones made before
(`docker compose up -d --force-recreate`); `dev doctor` lists them.

Switching from rootful Docker (Ubuntu; images and volumes do not carry over,
so dump the databases you need first):

```sh
sudo apt install uidmap                                  # newuidmap, newgidmap
docker buildx use default && docker buildx rm capped
sudo systemctl disable --now docker.service docker.socket containerd.service
sudo rm /var/run/docker.sock
dockerd-rootless-setuptool.sh install                    # as your user
sudo loginctl enable-linger $USER                        # start it at boot
sudo gpasswd -d $USER docker
dev limits apply && bash ~/dev-sandbox/system/docker/setup-builder.sh
```

Then **reboot**: with lingering on, your systemd user manager survives a
logout and keeps the old groups, and terminals started from it inherit them.
`id | grep -c docker` must print 0. `dev doctor` warns while you are in the
`docker` group or rootful Docker is reachable.

Rootless limits: ports below 1024 need extra setup, and `live-restore` is not
used (containers restart with the daemon).

## Safety

`dev` moves and deletes directories, so it is conservative:

- Only well-known artifact directories are deleted, and `build`, `dist`,
  `target`, `coverage`, `.gradle` only next to a matching build file
  (`package.json`, `Cargo.toml`, `build.gradle`, ...).
- Anything tracked by git, `.git` itself, `.env` and `secrets.yaml` files are
  never touched. When secretd's `secret` CLI is installed, `activate` lists credential-like keys in a plain
  `.env` (names only) and suggests `secret import`; `doctor` checks that secretd
  is reachable.
- A directory containing a `.devkeep` file is never moved or cleaned.
- `activate`/`deactivate` refuse when a process (dev server, editor, shell) is
  running inside the project, when the name or original path is taken, or when
  there is not enough room.
- `clean` lists what it will delete and asks first.

## AI coding agents

`skill/dev-sandbox/SKILL.md` is a [Claude Code](https://claude.com/claude-code)
skill that teaches the agent the rules: install through `dev`, use pnpm and
uv, never move caches, never run `sudo`, and hand root-level commands to you.
Agents run inside your terminal slice, so the limits apply to them too.

## Tests

```sh
bash tests/run.sh
```

The tests run `dev` against a throwaway HOME and sandbox with a minimal PATH,
so they never touch real projects or caches.

## Uninstall

```sh
~/dev-sandbox/uninstall.sh
```

Removes the watchdog, terminal limits, `dev` link, shell block, skill link and
Docker builder, and prints the root-level undo commands. Projects and caches
stay in place.

## License

MIT
