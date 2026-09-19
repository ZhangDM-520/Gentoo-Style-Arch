# MEMORY — Gentoo_Style_Arch (self-built -git package stack)

> Maintainer memory for this public project. Read this file + NOTE.md (chronological
> incident journal, one `##` section per incident) before working. Keep this
> file to rules + current state; log every non-trivial change in NOTE.md.
> NOTE.md opens with a **naming-history table** — entries written before
> 2026-09-15 use the old `.Static/.Heavy/.Heavyweight/.3rdP` paths and the
> `static/heavy/critical/rocm` group names, which map onto today's
> `packages/{git,stable,core,misc,third-party}` layout.
> Host-specific and private details — home directories, machine names,
> credentials, downloaded sources, build artifacts — are intentionally
> excluded. Standard system paths that the workflow depends on
> (`/etc/pacman.conf`, `/usr/lib/llvm*`) are part of the contract, not host
> state. Current layout and public workflows are documented in the files
> beside this one.

## 1. Golden rules (violations caused real breakage)

1. **fish shell**: wrap EVERY terminal command in `bash -c '...'`. No `export`,
   no `[[ ]]`; arrays are 1-indexed; an UNMATCHED glob is a fatal fish error
   that `2>/dev/null` does NOT suppress — use `find -name`. The host's login
   shell is fish 4.9.3, so this applies to anything routed through `$SHELL`
   (commands handed to the user, `!cmd`, pasted snippets), not just to scripts.
   Tool-call shells here are bash (`$0` = `/bin/bash`), so bash syntax is fine
   *inside* a tool call — the hazard is crossing a shell boundary.
   CachyOS additionally ships aliases that change what a name does
   (`/usr/share/cachyos-fish-config/cachyos-config.fish`): `ls` → `eza -al`,
   `grep` → `grep --color=auto`, plus `la/ll/lt/l.`, `update`, `big`, `rip`.
   GNU coreutils *is* installed — `ls` 9.11 — so the flag hazard comes from the
   `eza` alias (and from `eza`'s different flag set), never from a non-GNU
   `ls`. Never assume a bare `ls`/`grep` flag works in a fish context.
2. **Agent-shell git hardening**: agent shells inject GIT_CONFIG_PARAMETERS
   (`safe.bareRepository=explicit`) → EVERY makepkg/git-bare-repo op from an
   agent shell needs `GIT_CONFIG_COUNT=0` (user fish shell unaffected).
   Manifestations when forgotten: `?signed` tag verify → "SIGNATURE NOT
   FOUND"; git-lfs fetch in the bare mirror exits 128 (handler tolerates it)
   → empty LFS store → N × "remote missing object" at extract.
3. **Validate PKGBUILD edits**: `bash -n PKGBUILD && makepkg --printsrcinfo
   >/dev/null`before considering anything done. (`!check` and `autodeps`
   are INVALID in the options array — pacman 7.x lint rejects them.)
4. **Provides discipline** (mechanism in pitfall digest §6):
   - toolchain -git packages need VERSIONED provides
     (`provides=("meson=${pkgver}")`) — unversioned provides cannot satisfy
     `>=N` makedeps; pacman falls back to the conflicting repo package.
   - every lib-shipping package declares BARE soname provides (`libfoo.so`) —
     undeclared = repo consumers break on the stock→house swap.
   - provides live in .PKGINFO: any provides change needs a real rebuild
     (`makepkg -Rf` repackages without rebuilding).
   - verify artifacts: `tar -xOf pkg.tar.zst .PKGINFO | grep provides`.
   - the mirror image applies to dependencies: request a capability through
     its VIRTUAL, never through one concrete provider. `jre-openjdk` conflicts
     with `jdk-openjdk` (and both conflict with a headless JRE), so naming one
     can make pacman demand the removal of a package the dependency graph
     needs; `java-runtime` is provided by every JDK and every full JRE. Same
     rule for `java-environment` (JDK), `libgl` (libglvnd), `cron`, etc.
     The 2026-09-18 logseq incident is the worked example.
5. **Qt private-API coupling**: qt6/qt5-base-git update ⇒ rebuild ALL coupled
   all coupled Qt modules in the SAME pass; verify private tags
   (`nm -D --undefined-only | grep QtPrivate_`); never `-Syu` fresh base-git
   while stock modules remain.
6. **Meson staleness**: re-running meson setup over an existing build dir
   keeps stale option values. After ANY meson-git upgrade run the stale-meson
   audit: `find . -name meson-info.json`, purge build dirs whose version
   differs (build dirs live at arbitrary depths — a maxdepth sweep misses
   them), rebuild a canary.
7. **Don't touch in-progress builds**: check running makepkg processes and
   runtime log mtimes before rebuilding a package someone else is on.
   Never run two heavy builds concurrently (OOM).
8. **Purged tools stay purged** (system-wide): po4a, python-sphinx,
   python-myst-parser, lvm2, libblockdev-lvm, systemd-tests, cuda, gcc15.
   Never reintroduce via makedepends — makepkg reinstalls them silently;
   grep remaining makedeps after every trim.
9. **IgnorePkg closure**: every workspace pkgname must be in /etc/pacman.conf
   IgnorePkg (cumulative repeated `IgnorePkg =` lines, all inside
   `[options]` — a line in a repo section is silently dropped). Verify by
   sourcing each PKGBUILD, unioning pkgbase+pkgname[], `comm -23` vs
   `pacman-conf IgnorePkg | sort -u` (empty = covered).
10. **Logs**: append one `## YYYY-MM-DD — topic` section per incident to
    NOTE.md: symptom → root cause → fix → rule.
11. **Install-before-dependents-compile**: never build-then-install-collectively.
    `build-all.fish -i` installs each package IMMEDIATELY after its build, in
    topo order, via `install_pkgs_now` (pacman -U --noconfirm --ask 4, rc
    checked — install failure aborts the run). The old end-of-run collective
    install compiled mid-run packages against OLD installed deps (09-06
    rust-git vs minimal llvm-git bricking). `-si/--sepinstall` — the old
    spelling of that behaviour — was removed 2026-09-17; `-i` is the only
    immediate-install flag. `-ia/--installall` is the one-transaction escape
    hatch and deliberately bypasses this rule; never use it for a set whose
    members depend on each other.
    Those installs are background jobs with no tty, so the dispatcher owns
    sudo liveness (see build-guide.md "sudo during --install"): it must never
    infer "installs are impossible" from `sudo -v` alone — a `NOPASSWD`
    sudoers entry makes `-v` fail forever while every install succeeds — and a
    run whose dispatch stopped early must exit non-zero instead of reporting
    success (2026-09-17).
12. **Mandatory selection + keystone discipline** (2026-09-07): build-all.fish
    has NO default action — always pass `-g` and/or package names. For
    ABI-coupled core updates use `-g core` (auto-installs the merged core set);
    for leaf rebuilds use `--no-deps`. New `_DEPS` edges are
    added ONLY after verification against `pacman -Qi Depends` (noctalia has
    NO qt6-declarative dep; NM-openvpn reaches ssl only via libnm).
13. **llvm-libs-git never moves alone** (2026-09-07 incident): LLVM snapshots
    have no stable C++ ABI — after any llvm-git/llvm-libs-git bump, rebuild
    rust-git + mesa-git + spirv-llvm-translator-git + openshadinglanguage IN
    THE SAME PASS (scan victims: /tmp/llvmvictims.sh pattern — grep /usr/lib
    for libLLVM links → pacman -Qo). rustc hits heap corruption/segfault on
    ANY compile otherwise, and rust-git cannot rebuild itself (bootstrap IS
    the broken rustc). Recovery when it happens: downgrade-rebuild llvm-libs
    at the rust-compatible snapshot (old version from /var/log/pacman.log,
    pin `#commit=` in PKGBUILD source, unpin after install — BPF target is
    build config, survives the snapshot change).
14. **Qt -git private-API coupling** (2026-09-08 incident): a Qt module that
    regenerates generated headers breaks consumers built against the OLD
    headers. qtlanguageserver r650 renamed `TextDocumentContentChangeEvent
    Variant{1,2}` → `TextDocumentContentChange{Partial,WholeDocument}`,
    breaking qt6-declarative's qmlls. Rebuild coupled modules IN THE SAME
    PASS (qt6-languageserver → qt6-declarative); when upstream dev lags,
    adapt via sed in prepare() (house style — re-applies over every git
    pull). "Unhandled python OSError" from meson = masked environment error:
    force the traceback with MESON_FORCE_BACKTRACE=1 from INSIDE the
    failing context (e.g. exported in the PKGBUILD), never interactively.
15. **Never bypass source verification** (09-17 mkinitcpio incident): a signed
    tag may be signed by a SUBKEY while upstream `validpgpkeys` lists only the
    primary key. `git verify-tag <tag>` names the actual signer; confirm that
    fingerprint against the maintainer's published key, add it to
    `validpgpkeys` with a role comment, and import the key. Never pass
    `--skippgpcheck` or drop `#signed`.

16. **Bulk `prepare()` loops: batch them, and refuse incomplete inputs**
    (09-18 texlive incident): a loop that shells out per file costs process
    spawns, not bytes — the texlive split was 301k spawns and 4,115 full rescans
    of an 18.7 MB tlpdb. Cut the input once, do the work with builtins, and
    batch the syscalls per destination (`mv -t`, 500 files per call); the same
    loop then costs ~10k spawns and the recipe's total exposure drops from ~8
    minutes to under one. And a loop that *moves* its inputs must count what was
    already consumed and stop, because the alternative is a package that is
    quietly missing files. Pin both with a fixture that diffs the old and new
    implementations (`tests/texlive-split.sh`, oracle in `tests/assets/`).

17. **Recipes are public surface** (09-19 incident): a recipe comment explains
    the code, the kernel option, or the trim decision — it does not inventory
    the machine it was written on. Kernel versions, installed package versions,
    CPU thread counts, bootloader command lines and incident narratives belong
    in NOTE.md. The set is maintained for **AMD laptops** (AMD CPUs with
    amdgpu/radeon graphics): a trim that follows from that target should name
    the platform, while one that follows from a single author's environment is
    a capability absence and should say so. A recipe is portable — ISA settings
    come from the environment — but the artifact is not, because
    `makepkg.conf` supplies `-march=native`. See `portability.md`,
    `CONTRIBUTING.md` and the 2026-09-19 NOTE section.

## 2. Workspace overview

- The public tree is `Gentoo_Style_Arch/`; recipes live under
  `packages/{git,stable,core,misc,third-party}/`.
- `config/packages.map` maps package IDs to recipe paths, two fields per
  record (`package-id|recipe-path`; the loader rejects any other shape —
  2026-09-17). Group files and `config/dependencies.conf` are the scheduler's
  source of truth.
- `.state/` (or `GSA_STATE_DIR`) holds builder-owned state only: `logs/`, the
  per-package logs inside it, the pacman mutex, and the lane result files.
  `LOG_DIR` is the only path derived from `_STATE_DIR` — there are no builder
  caches there. makepkg's own source trees and archives land **beside each
  recipe** (`SRCDEST`/`PKGDEST` default to `$startdir`), which is why the
  recipe directories carry ignore rules; both classes are ignored runtime
  state.
- The current logical groups are `git` (56), `stable` (29), `core` (41),
  `misc` (1), and `third-party` (2). `core` intentionally overlaps stable
  packages whose ABI must be rebuilt and installed as one batch.
- No upstream checkout, package archive, downloaded signature, PGP cache,
  encrypted CI artifact, or host profile belongs in the public tree.

### build-all.fish

Selection is mandatory. The builder loads and validates the declarative
package map, groups, and dependency graph before handling command-line
arguments. It accepts package IDs, expands local dependencies, sorts them
topologically, and rejects cycles or missing records.

`--intensity xhigh` is the default automatic plan. It derives bounded lanes
and a global normal-lane job budget from CPU threads and available memory;
`low`, `medium`, `high`, `xhigh`, and `max` trade utilization against
headroom. Explicit `--lanes`/`--jobs` values override the profile. Core
packages run alone with a separate memory-aware job limit. Every lane is an
external Fish child with isolated output, atomic
validated results, and a log tail owned by the parent dashboard. Plain output
is append-only; interactive output is width-safe and sanitized. `-i` installs
each package before its dependents compile, under a builder-owned pacman
mutex. Those installs are non-interactive (`sudo -n`) because lane children
have no terminal, so the dispatcher probes whether an install can actually
run, refreshes the credential, asks for the password itself when a human is
attached, and stops dispatch exactly once — with a non-zero exit — when
nothing can restore it. A system pacman database lock is never deleted
automatically.

`--no-deps` is a deliberate leaf rebuild. `--audit` checks active topology and
runtime drift. `--link-sources` deduplicates compatible VCS mirrors without
publishing them. `--nuclear` removes fetched sources only after an explicit
confirmation and preserves recipe-local inputs.

### Key dependency edges

glib2 -> pango -> cairo -> gtk3/gtk4 -> libadwaita; liburing -> libdex ->
xdg-desktop-portal; qt6-base -> pyside6 and the Qt6 modules; qt5-base ->
the Qt5 modules; ninja -> meson; rocm-core -> rocm-llvm -> hsa-rocr ->
hip-runtime; llvm -> SPIR-V/libclc/rust; rust -> rust-bindgen; babl -> gegl
-> gimp; openssl -> openssh/openvpn/git/LibreOffice; LLVM ->
OpenShadingLanguage -> blender.

### Landmines / one-offs

- `libisl-git` tracks a package whose repository name differs; do not let
  automatic stable synchronization rewrite it blindly.
- Qt private APIs and LLVM snapshots require consumer rebuild batches.
- Shared mirrors must have the exact origin URL and a usable fetch refspec.
- A populated non-Git source path is never replaced automatically.
- Build in the runtime clone, never in this repository. A run started here left
  24 GB of SVN checkout, split tree and packaging state inside the published
  repository's directory (recovered by `rm -rf` on the four ignored paths). The
  recipes are ignored-safe, but nothing about a build belongs here — and
  `.state/` logs are Git-ignored too, so a run's forensics die with the clone
  unless `GSA_STATE_DIR` points somewhere durable.
- `texlive-texmf`'s `prepare()` MOVES ~150k files out of `$srcdir/texmf-dist`,
  so that tree is single-use: a resume over an already-split checkout fails on
  purpose (13,870 of 150,746 runfiles were gone in this one) and needs
  `rm -rf src`. It also needs ~38 GB on disk, not the ~3.5 GB of data, because
  each SVN working copy keeps a 9.1 GB `.svn/pristine` shadow.

## 3. Stack facts

Durable shape of the stack, re-verified 2026-09-17. Deliberately no version
numbers: they rot within days and `pacman -Q <pkg>` is authoritative. Dated
install history lives in `NOTE.md`.

- **llvm-git is DELIBERATELY MINIMAL**: `-D LLVM_TARGETS_TO_BUILD="X86;AMDGPU;BPF"`
  — the BPF backend exists so `scx-scheds-git` can build its BPF skeletons with
  `clang -target bpf`. `rust-git` is built against this llvm-git, so both move
  together (golden rule 13, §6).
- **Qt dev stack**: every Qt6/Qt5 private-API-coupled module is house-built;
  `qt5-base-git` carries `-ffat-lto-objects` for the LTO-strip hazard (§6).
  `pyside6-git` is scoped with `-DMODULES='Core;Gui;Widgets'` because the rest
  of Qt is still stock. Stock-only by design: qt6-translations, qt5ct, qt6ct.
- **Toolchain `-git` packages carry VERSIONED provides** (`meson-git` →
  `meson=<ver>`, likewise ninja-git, cmake-git, doxygen-git) — unversioned
  provides cannot satisfy `>=N` makedepends (golden rule 4).
- **GIMP/Krita chain**: `gimp-git` ships upstream's dev naming — the binary is
  `gimp-3.3`, there is no `/usr/bin/gimp` — and declares only a bare `gimp`
  provide. `krita-git` and `cairo-git` declare versioned provides
  (`krita=…`, `cairo=…`) plus bare soname provides; `babl-git`/`gegl-git`
  ship soname provides. `pacman -Dk` must stay free of chain errors and `ldd`
  must resolve babl/gegl from the house packages.
- **util-linux**: built with `-Dbuild-python=disabled` and
  `-Dtranslate-docs=disabled` (po4a was purged; the feature HARD-FAILS rather
  than skipping, §6). Its `libuuid`/`libblkid` verdefs need mold's
  `-Wl,--undefined-version` (§6).
- **linux-firmware** is trimmed to the maintained hardware set (AMD Strix Halo
  + MediaTek MT7925 + Cirrus amps). In `pipewire`, the `pipewire-jack` split is
  NOT built because it conflicts with the system's `jack2`, while
  `pipewire-jack-client` is kept. `easyeffects-git` replaced `jamesdsp-git`.
- **blender-git** pairs with house `openshadinglanguage` (same LLVM coupling as
  §6 describes).

## 4. Optimization playbook

- **mold linker**: `-fuse-ld=mold` in LDFLAGS/QMAKE_LFLAGS/meson linker args;
  mold-git does NOT provide `mold` for makedepends resolution — runtime
  `command -v mold` check instead (house guarded idiom).
- **CachyOS makepkg.conf** gives -O3/-march=native implicitly; meson packages
  use `arch-meson` (buildtype=release — upstream `if buildtype=='release'`
  blocks DO apply). Rust: append `-C target-cpu=native` ONLY if RUSTFLAGS
  lacks 'target-cpu'. ISA tuning is host-derived or explicitly configured.
- **LTO**: meson-controlled `-Db_lto=true` (mesa +allow-broken-lto,
  libadwaita, util-linux, systemd, dbus-broker, noctalia); PGO phase-1 always
  `-Db_lto=false` → flip true in phase 2 (glib2, gtk3, gtk4, wayland, cairo,
  xwayland, libinput, pixman, noctalia); manual via make/CMake (jemalloc,
  zlib-ng-compat); zstd phase-2 only; `options=(!lto)` where LTO breaks
  (llvm-git, rocm-llvm, hip-runtime, gcc-snapshot, niri-spicy-git,
  blender-git); Zen uses mozconfig thin LTO instead.
- **PGO training workloads**: mesa (vkcube on lavapipe + glxinfo/eglinfo,
  gcda in srcdir/mesa-pgo-profile, ON by default); glib2/gtk/cairo (`meson
  test`, timeouts + `|| true`); bash/zsh (`make check` timeout 900 + `|| true`
  - binary smoke test); easyeffects (private pipewire+wireplumber in
  dbus-run-session, sandboxed XDG dirs, quits via `easyeffects --quit` —
  never terminate daemon processes by name, PID-scoped cleanup only);
  wayland/libinput/util-linux/systemd OPT-IN via env vars; noctalia (headless
  sway); lz4/zstd CLI (profiles OUTSIDE build dir); mimalloc (test suite +
  `-fprofile-update=atomic`); mold (links itself); rust/niri LLVM-style
  (LLVM_PROFILE_FILE + llvm-profdata, unset sccache). Verify:
  `find <profile-dir> -name '*.gcda'` count > threshold.
- **Autotools PGO**: CFLAGS bake at ./configure time — every phase must
  re-run ./configure; `make clean` is NOT enough.
- **Special cases**: rust-git (bootstrap.toml flags, 5 patches); Zen browser
  (fortify 3→2, HOST_CFLAGS unset — cc-rs re-export hazard, 3-tier mozconfig
  PGO); gcc-snapshot (-O2 stage2–4, format-security stripped); qt5-base-git
  (cflags + nostrip patches — qmake consumes system CFLAGS); libadwaita/
  xdg-portal-gnome `--wrap-mode=default`; dbus-broker units patch; glib2
  schema/terminals patches; `options=(staticlibs)` on lz4/pixman/mimalloc/
  libunwind. Deliberate no-ops: libreoffice-fresh (already `!lto` +
  `--enable-lto` + fortify 3→2 + -g1); blender-git (mold + ccache + !lto).
- **Electron/JavaScript packages** (vscodium-insiders-git, logseq-desktop-git):
  nothing is compiler-built except the native Node addons, so the recipes are
  `!strip !debug !lto` and apply only ccache + the mold probe to those addons.
  logseq-desktop-git additionally bundles `master` (2.x) which embeds an
  OCaml/Melange CLI runtime — the opam switch lives under `$srcdir` and pins
  OCaml 5.1.1 to match upstream CI.
  Its `cli/` and `static/` installs MUST pass `--ignore-workspace`: the tree's
  root `pnpm-workspace.yaml` has no `packages:` field, so a bare `pnpm install`
  from a subdirectory resolves the ROOT project, exits 0 and creates no
  `node_modules` — `static/` then failed with
  `Command "electron-builder" not found` (2026-09-18, NOTE.md). Related: with
  the flag, pnpm also skips the allowlisted dependency build scripts and
  `shamefully-hoist`, which is harmless here only because electron-builder
  fetches the Electron distribution itself and the static `postinstall`
  rebuilds `keytar`.
  Its opam switch is created only when absent: `build()` restarts from the top
  while `$srcdir` persists, and `opam switch create` exits 2 on an installed
  switch, which errexit turns into an abort before the first bundle (same date,
  NOTE.md).
- **TeX Live data packages** (texlive-texmf): `arch=(any)`, so there is no
  compiler and no ISA/LTO/PGO phase at all. The recipe keeps upstream's
  `!strip`, which also skips the strip/debug tidy pass, and optimises by scope
  only (whole splits dropped with their depends/provides/paths). It is the only
  recipe using SVN sources; `nuclear_cleanup` treats `svn://`/`svn+` like
  `git+` and also removes downloaded `*.whl` files.

## 5. Pending tasks

Re-verified against the host on 2026-09-17. Completed items were deleted
rather than left in place — an unchecked task list reads as authority while
going stale.

### Queued (claim by editing this section)

- **ROCm is half-removed**: `hsa-rocr` 7.2.4-1.1, `rocm-llvm` 2:7.2.4-2.1 and
  `comgr` 2:7.2.4-2.1 are installed again (the 2026-09-06 collective removal was
  reversed), while `hip-runtime` is absent — so HIP compute/Blender-HIP is still
  gone. Either rebuild `hip-runtime` in the same `-g core` pass as its
  dependencies, or prune the ROCm recipe dirs, their group membership, and
  `rocm-core`.
- **dbus-broker redundancy**: `stable/dbus-broker` and `git/dbus-broker-git`
  build the same packages — pick one before expanding the public set. The
  installed system package is stock `dbus-broker` 37-3.1.
- **doxygen-git purge** (user decision): no workspace consumer left. Its other
  half, `xapian-core`, is already gone.
- **gtk4-git demo trim**: `_package_gtk4-demos` plus its `_pick demo` lines
  still ship gtk4-demo, -widget-factory, -node-editor and -print-editor.
- **libadwaita-git**: the optional `check()` and `checkdepends=(weston)` are
  still present, so building it needs weston installed. Keep, or drop both.
- **linux-firmware**: the 2026-09-04 audit deferred an extra legacy-firmware
  `rm` line and never recorded what it targeted. The current trim already drops
  pre-amdgpu `radeon` and the unused vendor directories, and upstream has no
  `legacy/` tree, so the item is either redundant or needs re-specifying.
- **Build freezes: root cause identified — CVE-2026-90432, carried by our own
  kernel recipe (2026-09-19).** `scx_hardlockup()` deferred the sched_ext abort
  to an `irq_work`; on a hard-locked CPU with IRQs off that work never runs, so
  a scheduler stall wedged the machine instead of recovering. The handler also
  returned `%true` whenever sched_ext was loaded, **suppressing the kernel's own
  hardlockup report** — which is why no journal ever held a trace. Affected
  7.1 ≤ v < 7.2.6; fixed in 7.2.6+ and 7.3-rc1+. Every crash kernel (7.2.2,
  7.2.3-ck1, 7.2.4-ck1, 7.2.5) sits inside the affected range, and the one
  kernel never booted during a crash (`linux-cachyos-lts` 6.18.52) is the one
  outside it. The trigger is a fork/exec + I/O storm — i.e. any build — which is
  why build weight never mattered; upstream's own analysis (`sched-ext/scx#3687`)
  measured 1 freeze in 30 induced stall runs on a 12-CPU guest, and this host
  has 24 threads. That also retires the 2026-09-18 texlive leads recorded here
  before (NVMe ASPM, `ananicy-cpp`, zram, a 20 GB write burst): a texlive build
  is the same fork/exec + I/O pattern, so those freezes were this fault. Fix:
  `packages/misc/linux-cachyos` moved onto the CachyOS RC channel
  (`cachyos-7.3-rc3-4`) — recipe done, build/install pending. The evidence is
  upstream-documented plus circumstantial; the confirming A/B was skipped by
  decision, so read "identified" as strong, not proven.
- **Decision needed at the next `linux-cachyos` rebuild: AutoFDO + Propeller
  (2026-09-19).** The installed 7.2.5 kernel was built with `AUTOFDO_CLANG=y`
  and `PROPELLER_CLANG=y`; the recipe defaults `_autofdo` and `_propeller` to
  `no`, so the first default rebuild replaces an AutoFDO+Propeller-optimised
  kernel with a plain one — a real optimisation loss that warns nowhere. Either
  put `afdo.prof` and the two `propeller_*.txt` profiles beside the PKGBUILD and
  set both knobs, or accept the plain kernel deliberately. `prepare()` asserts
  the off state either way, so the swap shows up in the log rather than passing
  unnoticed.
- **Capture chain armed (2026-09-19) — keep it, it is what makes a future freeze
  readable.** `/etc/sysctl.d/99-diagnostic.conf` (`watchdog_thresh=30`, watchdog
  plus both lockup detectors, `softlockup_panic`/`hardlockup_panic`/
  `softlockup_all_cpu_backtrace`/`hung_task_panic`/`panic_on_oops`=1, `panic=10`,
  `sysrq=1`, re-applied every boot); `nowatchdog` removed from
  `/etc/default/limine` with the matching `*_panic=1`/`panic=10` parameters
  added; journald `SyncIntervalSec=1s` + `SystemMaxUse=1G` in
  `/etc/systemd/journald.conf.d/10-diagnostic.conf`; and `gsa-heartbeat.service`,
  a 5 s timestamp to `/var/log/heartbeat.log` and the journal that separates a
  dead kernel from a dead display. `efi_pstore` was **disabled by default**
  (`pstore_disable=Y`), so `/sys/fs/pstore` could never have received anything;
  set to `N`, the chain was validated with a deliberate `Alt+SysRq+c` — the
  panic landed in pstore in 17 compressed records and the machine self-rebooted
  in 27 s, and **never reached the journal**. pstore is the channel for a hard
  crash, not journald; do not read an empty journal as "nothing happened".
  **Recipe side (2026-09-19):** `_capture_chain` now defaults to `no`, so a
  kernel built from the recipe no longer carries the chain itself. The two
  options that matter are **config-only** — `WQ_WATCHDOG` and `PSTORE_CONSOLE`
  cannot be set from a command line — so set `_capture_chain=yes` in the
  environment for that build (the override reaches the lane child; verified
  2026-09-19). The armed command line and the sysctl drop-in above are
  independent of the recipe and stay.
- **Still open: the 2026-09-01 cluster.** `last -x` over the whole wtmp (machine
  installed 2026-08-31 15:20) shows ~23 unclean shutdowns, but the first four
  are a separate event: inside 27 minutes, the first ten minutes after
  `ryzenadj` + `ryzen_smu-dkms-git` were installed, and **before
  `scx-scheds-git` existed** (first installed 2026-09-03 17:52) — so the CVE
  above cannot explain them. Prime suspect is the `ryzenadj` undervolt applied
  at every login: its per-core `--set-coper` half is unverifiable, because CO
  cannot be read back and the script discards `ryzenadj`'s exit status. All AER
  counters are zero on both the NVMe device and its root port, so the link-fault
  lead is still absence of evidence. One full-length 6-minute rebuild (Tctl
  91 °C) passed with no freeze — with sched_ext unloaded, so it is not a control.
- systemd is a separately coupled effort whenever its recipe changes.

Deleted as done in this pass (each was verified, not assumed): the
`-Rns hyperv intel-speed-select x86_energy_perf_policy` batch and
`llvm-ocaml-git` (none remain installed); seatd-git's `libseat.so=1-64` provide
(the installed `.PKGINFO` carries it); llvm-git's `X86;AMDGPU;BPF` rebuild and
the dependent scx-scheds-git rebuild (installed llvm-git reports all three
targets); the stale `gcc-*-snapshot` language splits (only fortran, libs and
`lib*-snapshot` remain); mesa-git's PGO zero-gcda abort (implemented in the
recipe).

## 6. Pitfall digest (full details: NOTE.md sections of same dates)

- **A comment in a tracked file is public surface** (2026-09-19, linux-cachyos):
  the debugging facts that justify a knob — the running kernel version, the CPU
  thread count, the bootloader command line, the incident that motivated it —
  are exactly what `CONTRIBUTING.md` excludes as "host-specific logs and
  profiles", and they had leaked into 16 comment sites across two commits.
  Rewriting them forced the *claim* to move, not only the wording: the AutoFDO
  drift note had rested on host state the committed `config` does not contain
  (it carries no `AUTOFDO_CLANG`/`PROPELLER_CLANG` line), and `_host_tune` had
  rested on a thread count where the committed `config` already carried
  `MAXSMP=y`, `NR_CPUS=8192` and `CPUMASK_OFFSTACK=y` server defaults. A
  claim grounded in committed files survives de-hosting; one grounded in the
  machine does not — which is the signal that it was never a recipe fact.
- **An unclean shutdown zeroes freshly written files** (2026-09-19, bettbox):
  XFS log recovery restores metadata without the data of the last seconds, so a
  file keeps its size and mtime with zeroed content — undetectable by any size
  check. It broke `go mod tidy` (`zip: not a valid zip file`) while the recipe
  was correct, and it zeroed the agent's own session `plan.md` mid-write. For a
  Go recipe the red signal is `go mod verify` in the module's directory, and the
  repair after a hard freeze is `go clean -modcache` (a targeted purge cannot see
  the size-preserving class). `tools/go-modcache-check.sh` detects the four
  detectable classes read-only; `tests/modcache-check.sh` pins it. Generally:
  after any hard power-off, verify the *consumer* of the file before blaming the
  recipe or the tool.
- **A version bump must regenerate `.SRCINFO`** (2026-09-19, bettbox): it pins
  pkgver, provides, the source URL and sha256sums, so a stale copy makes anything
  consuming the recipe build the wrong sources against the wrong sums —
  silently. bettbox's PKGBUILD was 1.19.2 while `.SRCINFO` was 1.19.1 with the
  previous hash. Only three fixtures checked `.SRCINFO` (each its own recipe);
  `tests/srcinfo-freshness.sh` now regenerates and diffs every recipe listed in
  `config/packages.map` (~32 s at `-P 8`, `GSA_SRCINFO_JOBS` to override).
- **The kernel patch set is version-scoped, and `updpkgsums` prefers a cached
  copy over the URL** (2026-09-19, `linux-cachyos`): `_patchsource` is
  `.../kernel-patches/master/${_major}`, so one version bump invalidates *every*
  patch filename at once. The 7.3 set carries only `sched/0001-bore-cachy.patch`,
  `misc/dkms-clang.patch` and `misc/nvidia/`: `misc/0001-rt-i915.patch`,
  `sched/0001-prjc-cachy.patch` and `misc/0001-hardened.patch` no longer exist,
  and the nvidia patches renumber (`0002`/`0003` → `0001`/`0002`). Worse, the
  recipe's startdir *is* `SRCDEST`, and the tracked patch files sitting there are
  the ones makepkg actually uses — so `updpkgsums` prints "Found <file>" and
  re-sums the stale local copy rather than fetching the new one. The sums stay
  green while the build applies the previous kernel's patch (7.3's
  `0001-bore-cachy.patch` is 42,503 B against 7.2's 40,750 B). Refresh the
  tracked copies by hand (or delete them) before trusting the sums, then prove
  each one with `patch -Np1 --dry-run` against the extracted tarball. Related:
  `scripts/config` sets symbols blindly and `olddefconfig` then drops the
  unknown ones, so a symbol that vanished upstream is a **silent** feature loss —
  check the ones that carry the variant's identity (`PREEMPT_RT`, `SCHED_BORE`)
  still exist in the new tree. `tests/kernel-recipe-version.sh` now pins the part
  that is checkable offline: the tarball URL must name `pkgver`, and every
  `_patchsource` URL must sit under the `pkgver`'s major.
- **A `b2sums` literal serves one knob combination, and makepkg's error for the
  rest names nothing** (2026-09-19, `linux-cachyos`): `source[]` is assembled
  from `_cpusched`, `_build_zfs`, `_build_nvidia_open` and `_build_r8125`
  (measured — `_use_llvm_lto`, `_build_debug`, `_autofdo`, `_propeller`,
  `_capture_chain`, `_hardened` and `_host_tune` change nothing), while
  `b2sums` is one flat literal sized for the defaults. Switching a
  source-affecting knob therefore aborted *after* "Retrieving sources" with
  "Integrity checks (b2) differ in size from the source array" — naming neither
  the knob nor the remedy, and reading like a bad download. The recipe now
  checks the pair at parse time, names both counts and the knob values, and
  exempts `makepkg -g` (`GENINTEG=1`): without that exemption `updpkgsums` —
  the remedy itself — could not run. Do **not** "fix" it with per-knob
  `b2sums+=(…)` next to each `source+=(…)`; `updpkgsums` rewrites the whole
  assignment on every version bump, so the appends double-count. Upstream
  sidesteps this by shipping one PKGBUILD per scheduler; a merged recipe cannot.
  `tests/kernel-recipe-sums.sh` pins the guard, its exactness and the
  exemption.
- **A diagnostic on a captured stdout is swallowed, and a range indexes the
  selection, not the whole set** (2026-09-19, `build-all.fish`): `resolve_group`
  wrote "unknown group 'gti'" to stdout while `main` read the group with a
  command substitution, so `-g gti` exited 1 having printed nothing — the exit
  status was the only evidence. Put diagnostics on stderr. The same change
  added the reference forms a user actually has in hand: recipe ID and recipe
  path always worked, and now so do a case-variant ID (`MESA-GIT`) and a pacman
  `pkgname` including a split output (`zen-browser` → `zen-browser-pgo`,
  `libstdc++-snapshot` → `gcc-snapshot`), each announced by `_ref_form_note`.
  The index comes from the committed `.SRCINFO` files (218 names, none shared by
  two recipes, no unexpanded variables), never from PKGBUILD evaluation. A
  **typo is never auto-corrected** — a wrong guess builds a whole dependency
  chain — it is reported with up to three candidates, ranked by an awk
  Levenshtein sweep (fish costs ~0.4 s per token for the same answer).
  Separately: a **range indexes the selection**, so read `-l -g GROUP` before
  choosing one — `-l` now honours the selection and `-n` with none covers the
  whole set. Out-of-bounds ranges name the selection size, clamped bounds warn,
  and `..` is refused. `tests/project-cli-hints.sh` pins all of it (red on five
  mutations, including one that reverted the `>&2` and was only caught because
  the assertion checks the *channel* rather than the merged text).
- **A `scripts/config` write is not evidence, and `!SYM` ≠ `SYM=n`**
  (2026-09-19, `linux-cachyos`): the recipe's `_hugepage` knob had never worked
  — `mm/Kconfig` gates the THP menu on `!PREEMPT_RT` and `_cpusched=rt-bore`
  sets `PREEMPT_RT=y`, so `scripts/config` wrote the symbol and the next
  `olddefconfig` deleted it without a word. Two more knobs were dead the same
  way (`_use_kcfi` wrote two names that no longer exist; `cachyos`/`eevdf` wrote
  `SCHED_BORE`, which only the BORE patch adds). The recipe now builds an
  expectation list beside each write and `prepare()` verifies the *resolved*
  `.config` against it via `packages/misc/linux-cachyos/verify-config.sh`,
  aborting with a named reason (`tests/kernel-config-verify.sh` pins it). Two
  rules fall out. (a) Only the post-`make prepare` file is evidence. (b) `!SYM`
  and `SYM=n` are different claims: a `choice` member whose prompt is hidden by
  a false `if` (`bool "Cubic" if TCP_CONG_CUBIC=y`) vanishes from `.config`
  entirely, while a merely unselected member is written `# CONFIG_X is not set`
  — in the same choice, `DEFAULT_RENO` is `n` and `DEFAULT_CUBIC` is absent, so
  assert `!SYM` for these. Related trap, found by the new fixture: an
  unconditional `!SYM` in an invariants list must not contradict a toggle's
  `-e SYM` — `!AUTOFDO_CLANG` alongside `_autofdo=yes` made the AutoFDO path
  unbuildable.
- **Soname provides — the full mechanism** (libunwind/wireplumber/gegl/babl):
  pacman 7.1 does NOT derive soname provides at `-U` time and makepkg does
  NOT synthesize them for undeclared libs (`autodeps` is config-only and
  rejected by lint). But makepkg `find_libprovides` DOES auto-version any
  `*.so`-suffixed provide entry from the packaged lib's ELF soname:
  declare the BARE `libfoo.so` in provides= → packaging emits
  `libfoo.so=<soversion>-<arch>`. Versioned sonames give `0-64`; unversioned
  sonames give `libfoo.so=libfoo.so-64` — which CANNOT be written literally
  (check_fullpkgver lint splits at the last hyphen and rejects the hyphen
  left in the ver part). Declare bare sonames; verify .PKGINFO.
- **Meson options**: (a) `--auto-features enabled` (arch-meson) turns
  missing auto deps into fatal configure errors — probe with a throwaway
  `arch-meson <src> /tmp/probe` to enumerate ALL missing deps in one pass,
  then disable explicitly (util-linux translate-docs, gegl mrg/maxflow).
  (b) `Unknown option` at setup = upstream RENAMED an option — check the
  tree's meson.options (xdg-desktop-portal: docs→documentation, man→man-pages).
  (c) Option TYPES matter: `feature` takes enabled/disabled/auto, `string`
  takes a value (util-linux `python` vs `build-python`).
- **Docs-only makedep removals have blast radius**: autogen.sh may hard-fail
  (xz → `--no-po4a`); meson `.require(tool.found())` chains hard-fail; a hard
  `install` of an artifact nothing builds anymore aborts packaging (zsh-doc
  PDF); makepkg silently reinstalls purged tools if a makedep remains.
- **LLVM coupling — two failure modes**: (1) TARGET-SET skew: rustc's driver
  links `LLVMInitialize*Target*` for targets present at BUILD time — a
  minimal-target llvm-git installed over a rust-git built against full llvm
  bricks rustc (single version node LLVM_24.0 makes ANY missing sym report
  LLVM_24.0 — diff `readelf -W --dyn-syms` sets, don't trust the version
  string). Rebuild rust-git; bootstrap is immune (bootstrap.toml sed-deletes
  rustc/cargo/rustfmt lines — keep the rustfmt deletion). (2) VERSION-NODE
  skew: llvm-git exports ONLY `LLVM_24.0`; SONAME shims satisfy linking but
  not versioned lookups → everything linking libLLVM must be rebuilt per
  major bump (scan `readelf -V` over consumers; OSL fixed via house
  1.15.3.0-1.2 + osl-llvm-compat.patch — expect re-patching when upstream
  still caps below installed llvm-git).
- **mold false-negatives `has_link_argument(-Wl,--version-script=…)` → zero
  verdefs** (util-linux libuuid/libblkid): meson probes link a trivial
  conftest with `--fatal-warnings`; mold hard-errors on version-script
  symbols absent from the conftest where GNU ld tolerates → check NO → link
  arg dropped → zero `.gnu.version_d` nodes (link-time `undefined reference
  to uuid_unparse_lower@UUID_1.0` in stock consumers). Fix: `LDFLAGS+=`
  `-fuse-ld=mold -Wl,--undefined-version`. Any has_link_argument probe whose
  flag touches symbol/version semantics is suspect under mold; re-verify
  `readelf -V | grep -c VER_` after mold bumps/linker flips. (An earlier
  meson-r175 attribution was DISPROVEN.)
- **makepkg LTO-strip hook hollows slim-LTO static archives** (qt5-base-git):
  tidy `safe_strip_lto` strips `.gnu.lto_*` from EVERY packaged `.a`; slim-LTO
  members (GCC ≥12 default) are pure IR → symbol-less stubs. Fix: force
  `-ffat-lto-objects` (removing `-fno-fat-lto-objects` is NOT enough); full
  clean rebuild after any mkspec/flag change. Verify:
  `ar p <a> <member> > f.o && gcc-nm f.o | grep -v gnu_lto | wc -l` —
  gcc-nm needs a REAL FILE (stdin pipe silently returns nothing) and never
  `|| fallback` onto `grep -c` (exit 1 on zero makes hollow look like -1).
  `-Rf` can never fix tidy-mutated content (it reproduces it byte-for-byte).
- **makepkg packaging traps**: stale `$srcdir/<dir>` + a parent AUR-mirror
  `.git` → wrong pkgver/tree (wipe `src/ pkg/`); split STAGING dirs live
  under `$srcdir` (clean `src/<pkgbase>-libs`, never the PKGBUILD root; audit
  `install -d` lines that only "happen" to create later mv targets); when
  disabling a meson feature remove EVERY `_pick` path it installed (dirs AND
  globs — a dir-only pick survives content-pick removal and aborts under
  set -e); package()-scoped provides/conflicts OVERRIDE globals in split
  PKGBUILDs (global-only edits silently do nothing).
- **glog/gflags double registration**: abort names two flag-definition files
  — one under `/usr/src/debug/<system-pkg>` = system lib's static init, one
  `extern/…` = vendored copy compiled in; find who pulls the system copy via
  per-lib `readelf -d`/ldd (blender: libceres); prefer
  `-DWITH_SYSTEM_GLOG=ON -DWITH_SYSTEM_GFLAGS=ON`-style CMake options.
- **IgnorePkg**: 62 names were once unprotected (audit method in golden rule
  9); keep the closure diff empty after adding packages. Back up
  `/etc/pacman.conf` before editing it — the file accumulates repeated
  `IgnorePkg =` lines and a mistake is silent until `-Syu` replaces a house
  package.
- **Qt pkgver()**: MUST grep `QT_REPO_MODULE_VERSION` from `.cmake.conf` —
  git describe is unusable on Qt dev branches; pacman 7 makepkg needs a
  non-empty static pkgver= placeholder. qt6-speech packages EMPTY without
  Multimedia — rebuild it AFTER multimedia.
- **PGO operational**: root-owned gcda appears if instrumented daemons are
  installed mid-iteration (→ sudo rm -rf src, avoid installing); gcda
  verification via `find <dir>`; MT trainers need `-fprofile-update=atomic`;
  a Meson PGO reconfigure must replace `c_args`, `cpp_args`, `c_link_args`,
  and `cpp_link_args` together so phase-1 `-fprofile-generate` cannot remain;
  profile-use configure probes need `-Wno-error=missing-profile`; verify the
  staged package payload rather than temporary `build/meson-private` helpers;
  GCC `-fprofile-use` may also need `-Wno-error=format-overflow
  -Wno-error=coverage-mismatch`; GCC 17 experimental ICEs on -fprofile-use
  are sometimes TRANSIENT (retry once when the box was OOM-stressed;
  systemd's was deterministic).
- **Operational**: never append commands behind a live async terminal;
  `pacman -Qdt` empty ≠ no cruft; `pacman -U --noconfirm --ask 4` for
  conflict-replace installs; transcript jsonl is a reliable crash-recovery
  source; transient `curl 56 SSL_read` on huge fetches → resume with
  `git -C src/<repo> submodule update <path>`.
