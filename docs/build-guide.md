# Build guide

## Prerequisites

Use an Arch-based system with `fish`, `makepkg`, `nproc`, `ps`, `awk`, `sed`,
`tail`, and `getent`. Add `ripgrep` (`rg`) for `--audit` and `git` for
`--link-sources`. Building and installing also needs `pacman` (adding `flock`,
plus `sudo` unless you run as root supervisor) and `base-devel` for the
recipes themselves. A working compiler, enough disk space, and the package
dependencies named by the selected recipes are also required.

`--audit` and `--link-sources` are the only modes that need `rg`/`git`, so a
minimal system can still build and install without them.

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

`--installall` (`-ia`) installs every archive in the workspace in **one**
pacman transaction, so it cannot honour the install-before-dependents rule:
use it only to re-install a set that does not depend on each other (for
example after `--cleanup`, or with `--overwrite`), never as a substitute for
`--install` in a run that builds a dependency chain.

Root-supervisor mode is:

```sh
sudo fish build-all.fish --group core
```

The supervisor installs as root but runs `makepkg` as the invoking user and
resolves that user's real home directory. A bare root shell without an
invoking user is rejected.

### sudo during `--install`

Unprivileged `--install` installs happen inside lane children, which have no
terminal, so every transaction is `sudo -n`. The dispatcher keeps that
possible, and never confuses "I cannot refresh a credential" with "installs
are impossible":

- Before dispatch it probes what sudo can actually do, and **refuses to
  start** when installs could not succeed — rather than building for an hour
  first.
- While running it refreshes the credential at `_SUDO_KEEPALIVE_S` (150 s,
  well inside the sudo timeout). If `sudo -v` is refused but a plain install
  command works — a sudoers `NOPASSWD` entry covers the installs — there is
  no credential to keep warm and it stops probing instead of stopping the
  run.
- If the credential is genuinely lost, the dispatcher asks for the password
  itself: it still owns the terminal even though its lanes never do. The
  prompt is bound by `_SUDO_PROMPT_S` (120 s) so an unattended run cannot
  hang.
- When the password cannot be entered, dispatch stops once (one message, not
  one per poll), in-flight lanes drain, and the run lists the unstarted
  packages as remaining and exits non-zero. A stopped dispatch is never
  reported as a successful build.

`sudo fish build-all.fish …` remains the option-free way to avoid credential
expiry altogether: installs run as root and `makepkg` still builds as you.

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

Per-package logs live in `.state/logs/` — Git-ignored, and removed with the
state directory. If a run may need post-mortem forensics (a long build, a
machine that stalls), put them somewhere durable first:

```sh
GSA_STATE_DIR="$HOME/.local/state/gentoo-style-arch" fish build-all.fish -g core -i
```

### When the machine freezes during a build

A hard freeze leaves nothing in the per-package log, because the log is exactly
what stops being written. Two things are worth knowing:

**The journal is persistent, so the frozen boot is still readable after the
reset.** `/var/log/journal` keeps every boot; `journalctl -b -1` shows the boot
before the reset, and a boot whose last line is ordinary activity (rather than
`Journal stopped`) is a boot that did not shut down. That is how the texlive
freeze of 2026-09-18 was localised to a single second of one phase.

**Switch the magic SysRq keys back on before you need them.** This host shipped
with `kernel.sysrq=16` (only `sync` enabled), which disables every recovery key
and makes a hard power cut the only option — after 63 of those the drive's
unsafe-shutdown counter is the record of it. `sysctl -w kernel.sysrq=1` at
runtime costs nothing and gives you, at a physical keyboard:
`Alt+SysRq+R` (unraw the keyboard), `E` (SIGTERM everything), `I` (SIGKILL
everything), `S` (sync), `U` (remount read-only), `B` (reboot). If the screen is
dead but the box is alive, `Ctrl+Alt+F3` reaches a virtual console — and the
kernel messages on it settle whether the kernel or only the display died.

`tools/texlive-split-probe.sh` measures a build step with a sampler and a
watchdog: it records PSI, D-state process counts, device utilisation and await,
zram usage and XFS metadata counters once a second, prints them live, and kills
the run when a threshold trips. It reproduces the texlive `prepare()` split loop
on a hardlink farm (the real tree is never modified) so the loop can be measured
without endangering anything, and `--watch-cmd` instruments any command instead:

```sh
tools/texlive-split-probe.sh --stage full --collections fontsrecommended   # farm, throttled
tools/texlive-split-probe.sh --watch-cmd 'makepkg -si' --cwd packages/git/texlive-texmf --unsafe --yes-unsafe
```

It is a diagnostic, not a test: it is heavy and mutating, lives outside
`tests/`, and `--unsafe` prints the SysRq runbook before it runs anything without
cgroup limits.

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
the underlying fix. All five libraries are verified clean on the maintained
host: `readelf -sW <lib> | grep -cE '__gcov_|__llvm_profile'` returns 0 for
libglib-2.0, libcairo, libgtk-3, libgtk-4 and libxwayland.

During a Meson PGO transition, the final reconfigure must replace both
compiler and linker argument caches (`c_args`, `cpp_args`, `c_link_args`, and
`cpp_link_args`). Profile-use flags also reach Meson's temporary compiler
probes, so `-Wno-error=missing-profile` is required for that reconfigure;
otherwise a missing profile for a probe can be misreported as an ABI or
feature-detection failure. Instrumentation validation is performed against
the staged package payload after `meson install`; temporary helpers under
`build/meson-private/` are not shipped and must not be treated as package
artifacts. This section is the operational reference for the PGO rules that
`CONTRIBUTING.md` states and that `MEMORY.md` §6 explains as failure modes.
