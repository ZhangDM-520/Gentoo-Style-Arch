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
fish build-all.fish --group git --intensity xhigh
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

### mkinitcpio and optional NvPCR definitions

The package set disables systemd's bootloader integration because this project
boots through Limine. That means systemd does not install optional
`/usr/lib/nvpcr/*.nvpcr` definitions, while stock `mkinitcpio` 42-1's systemd
hooks still try to add that glob literally. The project carries a patched
`mkinitcpio` recipe that skips absent optional definitions:

```sh
fish build-all.fish --no-deps --install mkinitcpio
sudo mkinitcpio -P
```

Do not re-enable systemd's bootloader feature just to satisfy this optional
initramfs input; the guarded hook is the intended compatibility boundary.

### PGO libraries recreating old build paths

Some recipes use a temporary GCC profile-generation build for training. The
final package must not contain that instrumentation. If an older
`glib2-git` or `cairo-git` install recreates `src/build` after cleanup, replace
the packages before removing the residual tree:

```sh
fish build-all.fish --no-deps --install glib2-git
fish build-all.fish --no-deps --install cairo-git
readelf -sW /usr/lib/libglib-2.0.so.0 | grep -E '__gcov_|__llvm_profile'
readelf -sW /usr/lib/libcairo.so.2 | grep -E '__gcov_|__llvm_profile'
```

Both symbol checks must produce no output. Restart applications that were
running against the old libraries, then remove only the now-inactive residual
build trees. Do not treat GLib warnings from a portal or sandboxed
application as evidence of a builder process; correlate them with the
installed library symbols and profile-file paths first.

The same verification applies to `gtk3-git`, `gtk4-git`, and
`xorg-xwayland-git`. If a GUI application reports an undefined `__gcov_*`
symbol, replace the affected custom package with the fixed rebuild before
rebuilding dependents; repository packages are a temporary recovery path, not
the underlying fix.

During a Meson PGO transition, the final reconfigure must replace both
compiler and linker argument caches (`c_args`, `cpp_args`, `c_link_args`, and
`cpp_link_args`). Profile-use flags also reach Meson's temporary compiler
probes, so `-Wno-error=missing-profile` is required for that reconfigure;
otherwise a missing profile for a probe can be misreported as an ABI or
feature-detection failure. Instrumentation validation is performed against
the staged package payload after `meson install`; temporary helpers under
`build/meson-private/` are not shipped and must not be treated as package
artifacts.
