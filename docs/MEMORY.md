# MEMORY — Gentoo_Style_Arch (self-built -git package stack)

> Maintainer memory for this public project. Read this file + NOTE.md (chronological
> incident journal, one `##` section per incident) before working. Keep this
> file to rules + current state; log every non-trivial change in NOTE.md.
> Host-specific paths, credentials, downloaded sources, and build artifacts
> are intentionally excluded. Current layout and public workflows are
> documented in the files beside this one.

## 1. Golden rules (violations caused real breakage)

1. **fish shell**: wrap EVERY terminal command in `bash -c '...'`. No `export`,
   no `[[ ]]`; arrays are 1-indexed; system `ls` is NON-GNU — never rely on
   its flags; an UNMATCHED glob is a fatal fish error that `2>/dev/null` does
   NOT suppress — use `find -name`.
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
    rust-git vs minimal llvm-git bricking). `-si` is a deprecated alias.
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

## 2. Workspace overview

- The public tree is `Gentoo_Style_Arch/`; recipes live under
  `packages/{git,stable,core,misc,third-party}/`.
- `config/packages.map` maps package IDs to recipe paths. Group files and
  `config/dependencies.conf` are the scheduler's source of truth.
- `.state/` (or `GSA_STATE_DIR`) contains logs, locks, lane results, and
  builder caches. makepkg source trees and archives are ignored runtime state.
- The current logical groups are `git` (54), `stable` (29), `core` (41),
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
mutex. A system pacman database lock is never deleted automatically.

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

## 3. Stack facts (2026-09-06 evening)

- Qt dev stack COMPLETE: all Qt6/Qt5 private-API-coupled modules are rebuilt
  qt6-base-git 6.13.0-dev / qt5-base-git 5.15.19 (qt5-base rebuilt with
  `-ffat-lto-objects` for the LTO-strip issue, see §6). pyside6-git scoped
  `-DMODULES='Core;Gui;Widgets'`. Stock-only: qt6-translations, qt5ct, qt6ct.
- llvm-git is DELIBERATELY MINIMAL: `-D LLVM_TARGETS_TO_BUILD="X86;AMDGPU"`;
  rust-git is rebuilt against it (X86/AMDGPU codegen only).
- Toolchain provides versioned: meson-git 1.12.0.r178, ninja-git, cmake-git,
  doxygen-git (all installed at recent versions).
- 2026-09-06 batch BUILT + INSTALLED (house, "Unknown Packager"): gc,
  openssl, zsh (+zsh-doc, PDF dropped), bash, imagemagick, openssh, openvpn,
  networkmanager 1.58.1 + NM-openvpn + NM-vpn-plugin-openvpn, upower, git-git
  2.55.0.r787 (upstream-removed mw-to-git excised), rust-bindgen-git 0.73.1,
  flatpak-git, polkit-git, libreoffice-fresh 26.8.0-2.1, linux-tools-meta.
  gimp chain: babl-git + gegl-git installed WITH soname provides;
- gimp chain COMPLETE (2026-09-07): cairo-git rebuilt with versioned
  `cairo=1.18.4` provide; gimp-git 2:3.3.1.r1561 + krita-git 6.1.0.prealpha
  BUILT + INSTALLED (house). gimp-git ships `gimp-3.3` (dev naming, no
  `/usr/bin/gimp`) with bare `gimp` provide; krita-git provides versioned
  `krita=…`. `pacman -Dk` free of chain errors; ldd resolves babl/gegl from
  house packages.
  blender-git 5.3.r164916 + house openshadinglanguage 1.15.3.0-1.2.
- util-linux 2.42.3: python bindings + translated man off; verdef fix via
  mold `--undefined-version` (see §6).
- linux-firmware is trimmed for the maintained target set; pipewire-jack
  dropped, jack-client kept; easyeffects-git replaced jamesdsp-git.

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

## 5. Pending tasks

### Queued (claim by editing this section)

- `sudo pacman -Rns hyperv intel-speed-select x86_energy_perf_policy` (the
  trimmed linux-tools splits are still installed at 7.2.2-1) — add
  `llvm-ocaml-git` to this removal (stale pre-trim split pinning old llvm-git;
  verified no reverse deps during the 2026-09-07 post-trim audit).
- **seatd-git**: PKGBUILD now declares `libseat.so` soname provide (trim-audit
  fix, wlroots0.20's `libseat.so=1-64` dep) — rebuild+install pending.
- **llvm-git**: `LLVM_TARGETS_TO_BUILD` now `X86;AMDGPU;BPF` (scx-scheds-git
  BPF skeletons need `clang -target bpf`) — full rebuild pending; after it
  lands, rebuild scx-scheds-git.
- **ROCm decision** (heavy/critical audit 09-07 pm): hsa-rocr, hip-runtime,
  rocm-llvm, comgr were uninstalled 2026-09-06 (one pacman transaction) —
  system consistent without them, but HIP compute/Blender-HIP is gone.
  Either `-g core` rebuild or prune the 4 workspace dirs and ROCm group
  membership + rocm-core.
- **Stale gcc-snapshot splits**: gcc-{ada,d,ga68,gcobol,go,m2,objc,rust}-
  snapshot installed from the pre-trim full-suite build; PKGBUILD now
  c,c++,fortran,lto only. Add to the queued `-Rns` batch (or restore languages).
- **dbus-broker redundancy**: the rolling and stable recipes build the same
  packages — pick one before expanding the public set.
- **Optional purge** (user decision): `doxygen-git` + `xapian-core` (no
  workspace consumer left).
- Small: gtk4-git demo trim; libadwaita-git optional check()+weston drop;
  linux-firmware legacy-removal line at next refresh; mesa-git PGO
  0-gcda warn -> abort.
- systemd is a separately coupled effort when its recipe changes.

## 6. Pitfall digest (full details: NOTE.md sections of same dates)

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
  9); keep the closure diff empty after adding packages (3 cumulative lines
  as of 2026-09-06; backups /etc/pacman.conf.bak-20260906*).
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
