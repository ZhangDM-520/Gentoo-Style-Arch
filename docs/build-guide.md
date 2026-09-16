# Build guide

## Prerequisites

Use an Arch-based system with `fish`, `base-devel`, `git`, `makepkg`,
`pacman`, `awk`, `sed`, `nproc`, `flock`, and `getent`. Add `sudo` for
unprivileged immediate installs. A working compiler, enough disk space, and
the package dependencies named by the selected recipes are also required.

## Inspect, dry-run, then build

```sh
fish build-all.fish --help
fish build-all.fish --audit
fish build-all.fish --list
fish build-all.fish --dry-run --group core
fish build-all.fish --group git --lanes auto --jobs auto
```

The builder refuses an empty selection. `--no-deps` is for a deliberately
scoped leaf rebuild whose installed dependencies are already known to be
current; ordinary package arguments expand the local dependency graph.

## Installation modes

Without `--install`, a successful build leaves package archives for later
review or `--installall`. With `--install`, each split package is installed
immediately after its build, before dependents are dispatched. This avoids
compiling against an older ABI. Core selection automatically enables
immediate installation because its ABI coupling makes a collective install
unsafe.

Root-supervisor mode is:

```sh
sudo fish build-all.fish --group core
```

The supervisor installs as root but runs `makepkg` as the invoking user and
resolves that user's real home directory. A bare root shell without an
invoking user is rejected.

## Runtime state and cleanup

Builder state is under `.state/` by default. Set `GSA_STATE_DIR` to put logs,
lane results, and lock files elsewhere. makepkg source mirrors and
archives follow its `SRCDEST`/`PKGDEST` configuration:

```sh
GSA_STATE_DIR="$HOME/.local/state/gentoo-style-arch" \
  fish build-all.fish --group git
```

`--cleanup` removes package archives. `--nuclear` interactively removes
downloaded sources, VCS clones, and makepkg staging directories while keeping
recipe-local patches and intentional symlinks. Review its target list before
confirming. Ctrl-C terminates isolated lane process groups and restores the
terminal dashboard.

## Troubleshooting

Read the per-package log named in a failure message. A stale system pacman
lock is not removed automatically. Resume with the remaining package IDs
printed by the failure summary, usually adding `--skip --install` after
checking whether the archive was already produced.
