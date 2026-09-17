# NOTE — Gentoo_Style_Arch maintainer incident journal

Historical journal for the self-built `-git` Arch package set. The current
project stores one clean recipe per package and keeps runtime `src/`, `pkg/`,
logs, caches, and source mirrors outside the publishable interface.
Chronological incident log below (symptom -> root cause -> fix -> rule);
current consolidated state lives in `MEMORY.md`.

Older entries retain historical directory names where they explain an
incident. They are not active configuration. Do not add private paths,
credentials, downloaded sources, or generated build output to this journal.

## 2026-09-17 — mkinitcpio optional NvPCR glob failure

- **Symptom**: `mkinitcpio -P` failed for every kernel with
  `file not found: '/usr/lib/nvpcr/*.nvpcr'`; the generated image was
  reported as potentially incomplete.
- **Cause**: the Projects systemd recipe intentionally sets
  `-Dbootloader=disabled` for Limine, so it does not install systemd's
  optional NvPCR definition files. Stock `mkinitcpio 42-1` added an
  unguarded glob to its systemd and `sd-encrypt` install hooks.
- **Fix**: added a `mkinitcpio` stable recipe at `pkgrel=2` with a minimal
  patch that skips absent optional `.nvpcr` files, plus a regression fixture.
  The systemd bootloader choice remains unchanged.
- **Validation**: the hook fixture passes with no `/usr/lib/nvpcr` directory;
  the patched package metadata, project audit, and full recipe checks pass.
  The patched package must be installed before regenerating the real Limine
  initramfs images.
- **Rule**: optional initramfs payloads must be guarded at the hook boundary;
  do not make an unrelated bootloader feature mandatory to satisfy an
  optional glob.

## 2026-09-16 — Published recipe omitted by local ignore rule

- **Symptom**: a fresh checkout rejected `xorg-xwayland-git` during
  `build-all.fish --list` with `invalid package map path`, even though the
  package was listed in `config/packages.map` and `config/groups/git.list`.
- **Cause**: the source workspace's package-local `.gitignore` contained `*`.
  The migration copied the map entry but a normal `git add` skipped the
  recipe directory, leaving a mapped package with no published `PKGBUILD`.
- **Fix**: restored the recipe and `.SRCINFO` to the public tree without the
  wildcard ignore file, and added `tests/project-config.sh` to exercise the
  real listing path.
- **Rule**: after a package migration, run `build-all.fish --audit` and
  `build-all.fish --list`; every map entry must have a tracked `PKGBUILD`.
  Do not publish package-local wildcard ignore files that can hide recipe
  changes.

## 2026-09-17 — GTK4 local packaging assets omitted

- **Symptom**: a clean checkout failed before building GTK4 because
  `gtk-update-icon-cache.hook` was declared in `source=()` but was not found
  in the recipe directory.
- **Cause**: the four GTK4 hooks/scripts existed only as ignored working-tree
  files; the package-local wildcard `.gitignore` hid them from the public
  repository.
- **Fix**: publish all four local assets, remove the GTK4 wildcard ignore, and
  add `tests/gtk4-recipe-assets.sh` to require every asset to be present and
  tracked.
- **Rule**: every non-URL `source=()` asset is essential recipe input and must
  be tracked; package-local wildcard ignore files are not an acceptable way to
  hide generated build state.

## 2026-09-16 — GLib and Cairo PGO reconfigure probe failure

- **Symptom**: after GLib or Cairo's PGO training pass, the final Meson
  reconfigure failed in compiler feature probes.
- **Cause**: Meson retained phase-1 `-fprofile-generate` in cached linker
  arguments while the recipe added `-fprofile-use` to compiler arguments.
  Meson's temporary `-Werror` probes then emitted `-Wmissing-profile` for
  untrained probe files and were reported as failed type-detection checks.
- **Fix**: both recipes now replace compiler and linker argument caches
  together and add `-Wno-error=missing-profile` only to the profile-use
  transition.
- **Validation**: shared fake-Meson fixtures reproduce the stale-cache
  failure for both recipes and pass after the fix; a real temporary Meson
  project confirms the four option sets are replaced and compiles successfully.
- **Rule**: treat Meson PGO transitions as a cache migration, not an
  environment-variable update; clear both compile/link instrumentation and
  tolerate missing profiles in configure probes.

## 2026-09-16 — GLib/Cairo PGO verifier false positive

- **Symptom**: the final GLib or Cairo build was rejected because
  `build/meson-private/sanity_check_for_c.exe` still exported profile
  instrumentation.
- **Cause**: the verifier scanned every executable in the Meson build tree,
  including temporary configure helpers left from the training phase. That
  helper is not installed into either GLib package.
- **Fix**: moved instrumentation verification to each staged package payload
  after `meson install`, while retaining rejection of instrumented shared
  libraries and executables that would ship.
- **Validation**: shared GLib/Cairo fixtures create the exact
  `meson-private` helper, confirm it is ignored, and confirm an instrumented
  staged library still fails validation.
- **Rule**: validate properties at the package boundary; do not reject
  temporary build helpers that cannot reach the installed artifact.

## 2026-09-16 — GTK PGO coverage symbols leaked into installed libraries

- **Symptom**: after a full group build, `nautilus` and Electron failed at
  load time with undefined `__gcov_indirect_call` from `libgtk-4.so.1` and
  `libgdk-3.so.0`. Replacing the custom GTK and libadwaita packages with
  repository builds restored linkage.
- **Cause**: `gtk3-git` and `gtk4-git` changed shell `CFLAGS`/`CXXFLAGS`
  after the initial Meson setup but did not replace Meson's cached linker
  arguments. They also had no package-boundary check, so coverage-instrumented
  GTK libraries could be installed.
- **Fix**: GTK3, GTK4, and the same-pattern `xorg-xwayland-git` recipe now
  replace all four Meson compiler/linker argument caches, exempt only
  missing-profile configure probes, and reject instrumentation in the staged
  payload. GTK3/GTK4 releases were bumped to `pkgrel=2`; Xwayland to `pkgrel=2`.
- **Validation**: shared fake-Meson fixtures cover GLib, Cairo, GTK3, GTK4,
  and Xwayland transitions, temporary Meson helpers, and contaminated staged
  libraries. All pass after the fix.
- **Rule**: never install a manual Meson PGO result until the final staged
  package is checked for `__gcov_*` and `__llvm_profile`; rebuild all
  consumers after replacing an instrumented GUI stack.

## 2026-09-16 — Full PKGBUILD optimization audit

- **Scope**: all 122 tracked `PKGBUILD` recipes in the public Projects
  checkout; every recipe passed `bash -n` and `.SRCINFO` generation.
- **Findings**: WirePlumber appended unconditional `-march=native -O3` flags
  and installed dead NEWS/README documentation. GTK4 demos and libadwaita's
  optional `weston`/check path remain documented cleanup candidates, not
  automatic removals.
- **Fix**: removed WirePlumber's host-specific flag override and dead
  documentation install, then added the optimization and trimming contract to
  `CONTRIBUTING.md`.
- **Rule**: use host `makepkg.conf` defaults, trim dead packaging inputs only
  with their dependent paths, and preserve PGO workloads and maintained
  features explicitly called out by `MEMORY.md`.

## 2026-09-04 — PKGBUILD trim audit (full workspace)

Standard: trim docs/man/examples/tests/dead splits/dead makedeps; keep
PGO-relevant test suites, all kmod compressors, gtk4 Vulkan renderer, rust
`profiler=true`, clang-opencl-headers split, cups (printing).

Applied (all `bash -n` + `makepkg --printsrcinfo` validated):

- **hip-runtime**: nvidia split + cuda makedep + HIPNV_DIR removed (AMD-only).
  cuda 13.3.1 & gcc15 now orphans — `pacman -Rns cuda gcc15` when convenient.
- **rocm-llvm**: projects `clang;lld` only (mlir/flang/flang-rt dropped — was
  ~30–40% of build time; clang-tools-extra dropped), targets `AMDGPU;Native`
  (NVPTX dropped), `CLANG_ENABLE_AMDCLANG=OFF` (no amdflang), FFLAGS sed block,
  HLFIRDialect workaround and clang-tidy build removed.
- **llvm-git**: targets `X86;AMDGPU`, no lldb/polly/ocaml split/docs/check().
- **gcc-snapshot** (IS system gcc): languages c,c++,fortran,lto (fortran kept —
  hdf5/scipy); no GPU offload/vtv/doxygen docs/16 dead lib splits; multilib and
  libgccjit KEPT (lib32-gcc-libs-snapshot installed / emacs).
- **rust-git**: sanitizers=false, debuginfo=1, dead checkdepends dropped.
- **mesa-git**: directx-headers/cbindgen/python-packaging makedeps, NVK crate
  block, venus-protocol source, bogus opencl-driver provide removed.
- **libclc-git**: amdgcn-only target; polly/spirv-llvm-translator makedeps gone
  (no OpenCL consumers anywhere — delete candidate if ever confirmed dead).
- **libdrm-git**: 8 driver libs disabled, install-test-programs=false.
- **polkit-git**: examples/docs/man/tests off.
- **gtk3-git/gtk4-git**: broadway/cloudproviders/man/docs off (+_pick fixes).
- **cmake-git**: no qt-gui/sphinx-html/emacs. **doxygen-git**: no wizard/search
  (drops qt6-base+xapian runtime deps!). **mold-git**: check() removed.
- **kmod/jemalloc/xz/libunwind/meson-git/libinput**: dead doc/test deps dropped
  (libinput keeps tests — PGO trains via meson test).
- **systemd**: install-tests=false (+tests split gone), homed=false,
  bootloader=false, intltool/kexec-tools dropped.
- **dbus-broker (both copies)**: docs=false, console-users line dropped.
  REDUNDANCY: top-level dbus-broker-git vs .Static/dbus-broker both build the
  same pkgs — resolve which one stays.
- **seatd-git**: server=disabled (seatd daemon not enabled; logind backend).
- **ccache/vulkan-icd-loader/libva/libdex**: docs/GIR/intel-optdepends trims.
- **util-linux**: python bindings + write/mesg off. **udisks2**: lvm2 split off.
- **pipewire**: ffado/onnx/roc/gst-plugin/zeroconf/v4l2/x11-bell splits removed
  - matching meson features disabled (names verified vs upstream 1.6.8).
- **wireplumber**: introspection=disabled. **scx-scheds**: layered/rustland/
  rusty/flatcg/chaos excluded.
- **qt6-base-git/qt5-base-git**: SQL drivers → sqlite-only, gtk3 makedep dropped
  (heavy rebuild — batch with next qtbase bump).
- **linux-tools**: hyperv/intel-speed-select/x86_energy_perf_policy splits off
  (usbip kept — explicitly installed).
- **dbus-c++ deleted** from workspace + uninstalled (only fed libffado →
  pipewire-ffado, both gone). Also uninstalled: pipewire-{onnx,roc,zeroconf,
  v4l2,x11-bell}, gst-plugin-pipewire, udisks2-lvm2.
- build-all.fish: new `-ccc/--nuclear` option — finds all pulled source
  clones/tarballs across the workspace and offers deletion (dry-run prints
  sizes, prompts before rm).

Clean/no-action: rocm-core, hsa-rocr, vulkan-headers, glib2/pango/cairo/pixman,
wayland, niri-spicy, noctalia, fish, zram-generator, pyside6, qt6ct/qt5ct,
xdg-desktop-portal-{gtk,gnome}, xorg-xwayland, xwayland-satellite,
easyeffects, scx-tools, liburing, lz4, mimalloc, zstd, zlib-ng*, ninja,
meson-git, libadwaita (check()+weston optional), linux-firmware (extra legacy
rm line deferred to next refresh).

- Qt verdicts after consumer check: qt6-webchannel/positioning/serialport KEEP
  (stock qt6-webengine ← fcitx5-chinese-addons), qt6-speech/multimedia KEEP
  (bibletime), whole Qt5 stack KEEP (kvantum/pyqt5/qt5-wayland).

## 2026-09-02 — Qt private-API skew (root incident)

`qt6-base-git` is Qt 6.13.0-dev internally and exports private symbols tagged
`QtPrivate_6_13_0`; stock 6.11.2 modules reference `QtPrivate_6_11_2` which no
longer exists → dlopen failure. Qt private API is version-locked per minor
release.

- Diagnose: `nm -D --undefined-only <lib> | grep QtPrivate_6_`. Acceptance test
  after every Qt rebuild: every installed qt6 lib must tag == qt6-base-git.
- Decision: maintain the full dev stack — all needed qt6 modules as -git
  builds with the SAME stock package names. Only `qt6-translations` (data),
  `qt6ct`/`qt5ct` (public API) may stay stock; qt6-webengine never attempted.
- pyside6-git: source `code.qt.io/pyside/pyside-setup` branch `dev`; single
  package provides/conflicts/replaces `pyside6` + `shiboken6` (+ provides
  `qt6-python-bindings` for blender/usd). Scope via `-DMODULES=...`
  (official override in `sources/pyside6/cmake/PySideSetup.cmake`); expand the
  list ONLY as matching module -git builds land. Its pkgver reads
  `sources/shiboken6/.cmake.conf` — git describe on dev resolves to an ancient
  tag (5.11.2) and must NOT be used.
- **Rebuild trigger: ANY qt6-base-git update ⇒ rebuild EVERY `.Heavyweight/qt6-*` in
  the same pass.** Never run `pacman -Syu` with a fresh qt6-base-git installed
  while stock modules are still 6.11.x.

## 2026-09-03 — batch expansion + pacman episode

- Wired 14+ packages (scx pair, fish, zram-generator, dbus/dbus-c++, pipewire,
  wireplumber, udisks2, linux-api-headers, linux-tools, linux-firmware,
  fcitx5). All built and installed. linux-firmware = trimmed Strix Halo set;
  **cirrus split re-added** (CS35L41 smart-amp + cs42l43 codec — this laptop),
  `other` picks it plus `cs42l43*`. **pipewire-jack split DROPPED** (conflicts
  jack/jack2 AND jack-client — a collective `pacman -U` of all splits would
  fail); `pipewire-jack-client` kept. GOTCHA: cleanup glob `pipewire-jack-*`
  also matched `-client` — re-run `makepkg -Rf` after glob-based cleanup.
- rust-git + mold-git live in `.Heavy/` (heavy = gtk4, libadwaita,
  gcc-snapshot, llvm-git, spirv-llvm-translator-git, mold, rust = 7).
- Docs/demos trimmed per package with ALL dependent `_pick` lines removed —
  audit `_pick` targets against disabled features (makepkg `set -e` aborts
  packaging on a `_pick` of a file that was never built).
- PGO with LTO-only fallback where yield was poor: pacman (sandboxed
  `-Q/-T/-Sp` training), dbus (`meson test`), pipewire (headless daemon +
  pw-cat sine + pw-cli, sandboxed XDG_RUNTIME_DIR), fish (mixed C+Rust:
  0 gcda / 9 profraw → Rust PGO ok, C fell back to LTO-only — accepted, Rust
  is fish 4.x bulk).
- **pacman permanently removed from the workspace**: self-built pacman
  corrupted the local db; user reverted to CachyOS pacman (verified clean),
  `.Static/pacman` deleted, un-ignored in pacman.conf. The
  `Architecture = auto x86_64_v3 x86_64_v4` line stays — harmless.
- Root-owned gcda: instrumented daemons installed mid-iteration wrote
  root-owned gcda into PGO dirs → needed `sudo rm -rf src`. Avoid installing
  mid-iteration.
- build-all.fish resilience: sync_static_version has epoch split
  (`epoch=`) + vercmp never-downgrade guard; **after ANY revert/desync,
  dry-run all groups (`-n -g git|static|heavy`) before building** — stale
  dirs in a group listing break the whole group. Fish: an UNMATCHED glob is a
  fatal runtime error `2>/dev/null` does NOT suppress — use `find -name`.

### 2026-09-04 — Qt dev-stack rebuild (20 modules), stale-meson purge, easyeffects

- All 20 `.Static/qt*` built and installed (qt6: shadertools/languageserver/
  svg/serialport/declarative/quick3d/tools/webchannel/positioning/speech/
  qt6ct/graphs/multimedia; qt5: declarative/multimedia/tools/speech/svg/
  webchannel/x11extras). qt6-graphs added for easyeffects (stock 6.11.2 =
  `QtPrivate_6_11_2` skew vs our 6.13-dev stack → QML UI abort).
- **pkgver() MUST grep `QT_REPO_MODULE_VERSION` from `.cmake.conf`** — git
  describe is unusable on Qt dev branches (release tags live on `release`
  branches, not dev ancestry; describe returned 6.7.0 for shadertools).
  pacman 7 makepkg also requires a non-empty static `pkgver=` placeholder.
- qtlanguageserver pin: mirror dev @ d845a85 (LSP 3.17 types) because
  qtdeclarative still uses 3.17 names — see
  `.Static/qt6-languageserver/PINNED-README.md`; unpin per TODO above.
- qt6-tools: `llvm22.patch` DROPPED — dev qttools tracks new clang natively
  (built clean against llvm-git 24).
- qt6-speech hollow-guard: built without Multimedia it packages EMPTY —
  always rebuild speech AFTER multimedia.
- gtk3-git replaces stock gtk3: `provides=`/`conflicts=` must go in the
  **package()-scoped arrays** (they OVERRIDE globals in split-style
  PKGBUILDs — a global-only edit silently does nothing).
- qt5ct deferred (see TODO); qt5 tags verified consistent
  (`Qt_5_PRIVATE_API`, 5.15.19 both sides).
- Mirror strategy (worked well): bare mirrors seeded at pkg dir root with
  retry + GitHub fallback (code.qt.io TLS flakes), then repo-local
  `url.<mirror>.insteadOf <upstream>` so makepkg fetches LOCALLY (silent
  self-fetch → update mirrors manually:
  `git fetch https://github.com/qt/<repo>.git dev:dev`).
- PGO trainers (Qt apps/modules): run against BUILD-TREE libs via
  LD_LIBRARY_PATH + QT_PLUGIN_PATH + `QT_QPA_PLATFORM=offscreen`; Arch ships
  NO Qt6 .pc files → pkg-config returns nothing, pass explicit `-I/-l`;
  trainer MUST self-quit (`QTimer::singleShot(8000, quit)`) — SIGINT/SIGTERM
  kills skip the atexit gcda flush → 0 profile files. `-Wmissing-profile`
  spam in phase 2 is normal (cold TUs). declarative 259 gcda, multimedia 170.
- **Stale-meson purge** (meson-git 1.12.0→1.12.99): 26 workspace build dirs
  configured by 1.12.0 fail on rebuild. Build dirs live at arbitrary
  depths/names (`xserver/build`, `pixman/_build`, `build-release`) — a
  maxdepth sweep MISSES them. Working audit: `find . -name meson-info.json`
  - check version ≠ installed meson-git; purge (`rm -rf <builddir>`), then
  rebuild a canary. Re-run this audit after EVERY meson-git upgrade.
- build-all.fish: `sync_static_version` skips pkgver()-driven PKGBUILDs; all
  pacman installs use `--ask 4` (conflict-replace: `-U --noconfirm` answers
  N to the removal prompt); sepinstall needs `-f` kept or makepkg skips
  build() when archives exist.

## 2026-09-04 — doxygen-git: upstream missing `<fstream>` include

- **Upstream regression**: `src/util.h` declares `openOutputFile(...,
  std::ofstream &)` but includes only `<cctype>/<functional>/<variant>` —
  relied on a transitive libstdc++ include that GCC 17 no longer provides
  (GCC even prints the fix as a `+#include <fstream>` diff note). No upstream
  fix yet.
- **Fix**: guarded `sed` in `prepare()` — idempotent, self-noops once upstream
  adds the include. Verified: 1.19.0.r99, PGO 167 gcda.
- build-all.fish takes only its own single-letter flags (`-si`, `-s`, ...);
  makepkg args like `-sif` must NOT be passed to build-all.fish itself.

## 2026-09-04 — jamesdsp-git → easyeffects-git

- jamesdsp-git removed (dir + package + script refs); easyeffects-git added
  (dep edge + git group). PGO: 224 gcda via a trainer that spawns private
  `pipewire` + `wireplumber` inside `dbus-run-session` with sandboxed XDG
  dirs — **easyeffects ABORTS at startup without a live PipeWire**; clean
  self-quit via `easyeffects --quit` (secondary → primary's QLocalServer →
  QApplication::quit() → gcda flush). NEVER pkill daemon names (user session!)
  — PID-scoped cleanup only.
- **GCC 17.0.0 experimental lto1 ICE** (`IPA pass: cp`, `-fprofile-use`,
  final link) — TRANSIENT here (retry succeeded once the box was no longer
  OOM-stressed; the systemd ICE was deterministic). Retry once before
  dropping PGO.
- OOM event ~10:45: closure build + an unrelated compile together OOMed the
  box (IDE included). Never run two heavy builds concurrently; sccache makes
  the replay cheap.
- Verified: QML UI loads headless (offscreen, private pipewire, 15 s run —
  only benign missing-lsp-plugins warnings); `nm`: easyeffects itself uses
  public Qt API only; qt6-graphs refs `QtPrivate_6_13` == base.

## 2026-09-04 — shared-source symlinks (-ccc preservatives + source dedup)

- **Root cause of "symlink feature not working"**: there never was symlink
  sharing — llvm-git mirror had `url.<libclc-path>.insteadOf=<github-url>` in
  its LOCAL config (origin LOOKED like GitHub so makepkg URL check passed,
  but fetches went to libclc clone) AND its `remote.origin.fetch` refspec was
  MISSING (fetch --all only got HEAD → llvm mirror stale at 1380 refs).
- **New layout** (canonical .Heavy clone + symlinks; makepkg SRCDEST mirrors
  are bare + full-ref, working copies in src/ use `git clone -s` alternates
  through the symlink — verified end-to-end with `makepkg -o`):
  - `.Heavy/llvm-git/llvm-project` ← `libclc-git/llvm-project-git` (canonical
    fixed: insteadOf removed, refspec +refs/*:refs/* restored, full 132k-ref
    fetch from real GitHub)
  - `.Heavy/rocm-llvm/rocm-llvm` ← `.Static/hip-runtime/hip-runtime-hipcc`
    (both pinned #tag=rocm-7.2.4)
  - `zlib-ng-git/zlib-ng` ← `zlib-ng-compat-git/zlib-ng`
  - `.Heavy/gtk4-git/gtk` ← `gtk3-git/gtk` (mirror holds gtk-3-24 branch;
    gtk3 checks out origin/gtk-3-24, gtk4 main — one mirror serves both)
  - Deleted with the clones: each twin src/ (its alternates pointed at the
    deleted clone → would dangle). ~14.5 G freed.
- Rules: canonical origin URL must equal the PKGBUILD source URL (minus .git)
  — makepkg aborts "is not a clone of" otherwise. When a mirror moves tag/URL,
  BOTH PKGBUILDs of a pair must change together (rocm 7.2.x). build-all.fish
  -ccc never touches symlinks (validated); nuclear of the CANONICAL dir
  deletes the real clone — twins dangle until the canonical rebuilds.
- build-all.fish `-ln / --link-sources` (2026-09-04): automates the above —
  groups all PKGBUILD git+ sources by effective URL (fragments stripped, so
  #tag/#branch variants share one mirror), picks canonical (real clone first,
  then .Heavy/), symlinks twins (incl. dangling links to not-yet-cloned
  canonicals — makepkg clones THROUGH the symlink into the canonical on first
  build), repairs canonical origin-URL mismatch + missing fetch refspec,
  warns on non-mirror refspecs/insteadOf redirects, deletes duplicate clones
  - their src/ (alternates!) after one y/N prompt. Fake-scenario tested
  (origin fix / refspec / destructive dedup / relink); real run: 4 groups,
  4 links verified, 0 changes.

## 2026-09-04 — .Static self-sync bug (hip-runtime replaced by stock after -Syu)

- **Root cause**: `sync_static_version` queried ONLY `pacman -Si $pkgbase`;
  hip-runtime builds `pkgname=(hip-runtime-amd)` (nvidia split dropped
  2026-09-04), repo only knows `hip-runtime-amd` (cachyos-extra-znver4) →
  silent early-return → custom 7.2.4-1 stayed < stock 7.2.4-1.1 → -Syu
  legitimately replaced the custom build (package now ships as -amd only).
- **Fix**: candidate list = pkgbase + every sourced pkgname; first repo hit
  wins. Validated: hip-runtime PKGBUILD auto-bumped 7.2.4-1 → 7.2.4-1.1,
  SRCINFO OK. Equal-version custom beats stock on next -Syu (no replacement).
- Group-wide read-only audit (pkgname-fallback sim): 5 more pending syncs
  found (ccache -1→-1.1, dbus-broker 37-3→37-3.1, linux-tools 7.2.2→7.2.3,
  qt5-webchannel 18→19, util-linux 2.42.2→2.42.3) — they resolve via pkgbase
  fine, will sync on next -s build. Guards verified: never-downgrade holds
  (linux-api-headers 7.2-1 > repo 1:7.1-1; qt6 dev builds > repo 6.11.2).
- Known gap: `libisl-git` never syncs — repo package is `libisl` (no -git
  stripping, intentionally). Manual pkgver bumps there.
- (2026-09-06 evening: obsolete — the ROCm runtime stack is no longer
  installed system-wide, only stock rocm-core 7.2.4-1.1 remains. The
  .Static/hip-runtime rebuild below is workspace-only now.)

## 2026-09-05 — meson/meson-git conflict: unversioned provides trap

- Symptom: dbus-broker-git build failed at "Installing missing dependencies" — pacman wanted repo `meson` (satisfying `meson>=0.60.0`), conflicting with installed `meson-git`.
- Root cause: `meson-git` (and ninja-git/cmake-git/doxygen-git) used UNVERSIONED `provides=(meson)`. An unversioned provide can NOT satisfy a versioned dep (`meson>=0.60.0`) — pacman ignores the provider and reaches for the repo package.
- Fix: versioned provides everywhere: `provides=("meson=${pkgver}")` (mold-git already did this correctly). Rebuilt+installed meson-git 1.12.0.r175 (Provides: meson=1.12.0.r175…), then dbus-broker-git built + both splits installed cleanly.
- Rule: every toolchain -git pkg that other PKGBUILDs makedepend on with `>=N` must carry a versioned provide; a provides-only fix needs a real rebuild (provides live in .PKGINFO).

## 2026-09-05 — xz-git: po4a trim vs autogen.sh hard-fail

- Symptom: prepare() aborted — xz upstream autogen.sh unconditionally runs `po4a/update-po`, which exits non-zero when po4a is missing (we dropped po4a makedep 2026-09-04 as docs-only).
- Fix: `./autogen.sh --no-po4a` (upstream-provided skip flag). Built 5.8.3.r85, installed; provides liblzma.so=5-64 intact. Side effect: translated man pages no longer generated (-1.4 MiB).
- Bonus hazard found in audit: .Static/util-linux still had po4a makedep → next build would silently REINSTALL the purged po4a (+ perl module deps). Dropped it (meson build treats po4a as optional, no _pick touches translated man dirs).
- Rule: when dropping a docs-only makedep, grep the package for it in prepare()/autogen paths — autogen.sh tools often need an explicit skip flag; and check remaining makedeps for tools that were purged system-wide (makepkg will reinstall them).

## 2026-09-05 — libunwind-git: two stacked failures (src pollution + missing soname provides)

- Failure 1: pkgver() → `.r0.ge76caf7` and `autoreconf: configure.ac required`. Cause: stale non-git `src/libunwind` (leftover build dirs) made makepkg skip cloning; git commands resolved UPWARD into the AUR-mirror `.git` now at `libunwind-git/` — pkgver read that repo (no tags), build ran in the wrong tree. makepkg even created a stray `makepkg` branch in the parent repo (deleted). Fix: `rm -rf src pkg`, rebuild. Rule: before rebuilding after repo restructuring, wipe `src/`; beware a parent `.git` swallowing git calls in `$srcdir`.
- Failure 2: install failed — `breaks dependency 'libunwind.so=8-64' required by gimp`. Cause: pacman 7.1 does NOT derive soname provides from package files at `-U` time; they must be in `.PKGINFO`. makepkg 7 `autodeps` would auto-add them but is disabled in makepkg.conf (`!autodeps`) and PKGBUILD lint rejects `options=(autodeps)` ("unknown option" — config-only, like `!check`). xz-git only worked because it declares `liblzma.so=5-64` explicitly. Fix: explicit provides array mirroring repo libunwind (5 sonames), pkgrel 2, installed OK, gimp happy.
- Debug path: `tar -xOf pkg.tar.zst .PKGINFO | grep provides` (PKGINFO uses singular lowercase `provides`/`conflict` — case-sensitive greps on `-Qi` style names will miss them); `pacman -U --debug` shows whether soname derivation happens (it does not).
- Rule: every self-built -git package shipping shared libs must declare versioned soname provides explicitly. Audit candidates: any workspace package whose repo counterpart has `.so=N-64` in Provides.

## 2026-09-05 — util-linux 2.42.3: three packaging traps after the trim pass

- Trap 1: `-Dpython=disabled` is WRONG — util-linux's `python` meson option is a STRING (interpreter name), so meson ran `find_installation('disabled')` → "Program disabled not found". The feature gate is `-Dbuild-python=disabled`. Rule: check option TYPES in meson_options.txt (`feature` vs `string`) before disabling; `feature` options take enabled/disabled/auto, `string` options take values.
- Trap 2: with `--auto-features enabled` (arch-meson), an auto-ENABLED feature whose tool is missing HARD-FAILS configure via `.require(tool.found())` — po-man/meson.build: "Feature translate-docs cannot be disabled" (po4a purged yesterday). Fix: `-Dtranslate-docs=disabled`. Rule: when purging a build tool (po4a), grep upstream meson for `.require(<tool>.found())` chains and explicitly disable the dependent feature — auto-enabled + missing tool = fatal, not skip.
- Trap 3: packaging mv failures — split-package STAGING dirs are created under $srcdir (makepkg runs package functions with cwd=$srcdir): stale `src/util-linux-libs/` from failed -Rf runs made `mv ... pkgconfig` nest (`pkgconfig/pkgconfig`) on repeat runs. Cleaning the PKGBUILD-root copy did nothing. Also: removing the `_python_stdlib` install -d accidentally removed the only creator of `pkgdir/usr/lib` → mv target missing. Fixes: clean `src/<pkgbase>-libs`, create `usr/lib` explicitly. Rule: staging lives in $srcdir — clean `src/<staging-name>`, never the PKGBUILD root; audit install -d lines that only "happen" to create parent dirs needed by later mv.
- Result: util-linux + util-linux-libs 2.42.3-1 built & installed; python bindings + translated man pages dropped; English man1/3/5/8 intact; pacman -Qkk clean.

## 2026-09-06 — xdg-desktop-portal: upstream meson option rename (docs → documentation)

- Symptom: build() aborted at meson setup — `xdg-desktop-portal/meson.build:4:0: ERROR: Unknown option: "docs"` (PKGBUILD passed `-D docs=disabled -D man=disabled`).
- Root cause: upstream renamed options in `meson_options.txt` → `meson.options`: `docs` → **`documentation`**, `man` → **`man-pages`**. Note upstream also switched to the new `meson.options` filename. `documentation` requires sphinx (purged) — `disabled` remains correct; man-pages likewise.
- Fix: PKGBUILD flags updated to `-D documentation=disabled -D man-pages=disabled`; wiped stale `src/build` from the failed run; rebuilt 1.22.0.r181.g86bd3e26-1 + installed clean.
- Workspace scan: every other PKGBUILD using legacy-looking flag names (`-D docs=false` dbus-broker×2/libdex, `-D man=false` polkit/gtk3, `-D docs/man=disabled` pipewire, `-Dman=enabled` systemd, wayland `-Ddocumentation=false`) built successfully on its latest run — rename is isolated to xdg-desktop-portal.
- Rule: meson option names are upstream API — a "Unknown option" error at setup means the project renamed/removed an option (check `<src>/meson.options` or `meson_options.txt`, not just git log). Add the new-name grep to the trim-audit checklist when refreshing a package after upstream moves.

## 2026-09-06 — wireplumber: trim-leftover _pick of never-built girepository dir

- Symptom: rebuild pass (first wireplumber build since the 2026-09-04 trim) failed in
  package_wireplumber(): `mv: cannot stat 'usr/lib/girepository-1.0'` right after meson
  install finished. Build + PGO itself was fine — packaging only.
- Root cause: `-D introspection=disabled` (line 48) means meson never installs
  `usr/lib/girepository-1.0`, but the trim removed only the GIR *content* picks and left
  the dir pick `_pick libw usr/lib/girepository-1.0` → `_pick`'s mv aborts under errexit.
  The Sep-4 installed package predates the trim, so the dead line survived until this
  first post-trim build.
- Fix: removed the stale pick (comment left in place: "do not re-add"); wiped stale
  `src/libw` staging + `pkg/` (split staging lives under $srcdir — util-linux trap);
  `makepkg -Rf` repackaged without rebuilding; installed both splits; wireplumber.service
  active; no `Wp` typelib left on disk (audit: no GIR consumers).
- RULE: when disabling a meson feature, grep the WHOLE package() + _pick list for every
  path that feature installs (dirs AND file globs) — content picks without dir picks is
  not a safe pattern; both must go.
- Bonus (source-verified, refines golden rule 3): makepkg `find_libprovides`
  (/usr/bin/makepkg) auto-VERSIONS any `provides=` entry ending in `.so` by readelf-ing
  the packaged lib's soname (`libwireplumber-0.5.so` → `libwireplumber-0.5.so=0-64`;
  confirmed in the fresh .PKGINFO). What it does NOT do is synthesize soname provides for
  libs that were never declared — THAT is the real libunwind-git mechanism (its provides
  array had no `*.so` entry). So: declaring a bare `libfoo.so` provide is sufficient for
  versioning; declaring nothing is fatal. `!autodeps` is irrelevant to this path. Keep
  the `tar -xOf pkg.tar.zst .PKGINFO | grep provides` check as the artifact-level audit.

## 2026-09-06 — qt5-base-git: makepkg LTO-strip hook hollows every packaged static archive (qt5ct link failure)

- Symptom: qt5ct 1.9 failed at the link of libqt5ct.so — undefined `QDBusMenuBar::*` /
  `QDBusPlatformMenu*` refs. Initial red herring: no `libQt5DBusSupport.a` exists in qtbase
  5.15; qdbusmenubar/dbusmenu/dbustray compile into `libQt5ThemeSupport.a`
  (src/platformsupport/themes/genericunix) which qt5ct links statically.
- Root cause: pacman 7.1 makepkg tidy hook `safe_strip_lto` (/usr/share/makepkg/tidy/50-strip.sh)
  runs `strip -R .gnu.lto_* -N __gnu_lto_v1` on EVERY packaged static archive. qtbase `-ltcg`
  compiles slim-LTO objects (pure IR; GCC ≥12 defaults slim even without -fno-fat-lto-objects)
  → the strip erases the entire member payload, leaving only `__gnu_lto_slim` stubs → every
  shipped `libQt5*.a` is unconditionally unlinkable for static consumers. The deterministic
  hollow md5 (ThemeSupport c661bb56 across every build) is the IR-strip of ANY slim archive
  collapsing to identical stub content.
- Verification loop: `ar p <archive> <member> > /tmp/x.o && gcc-nm /tmp/x.o | grep -v gnu_lto | wc -l`
  (0 = hollow). Traps learned: gcc-nm needs a REAL FILE — a stdin pipe silently returns nothing;
  `grep -c` exits 1 on zero, so an `|| fallback` turns a hollow result into a misleading -1.
- Wrong fix #1: deleting `-fno-fat-lto-objects` from QMAKE_CFLAGS_LTCG — GCC 17 defaults to
  slim, so the rebuilt archive stayed slim (3431430 bytes ≈ old 3431854) and packaged hollow
  again.
- Fix: prepare() sed replaces `-fno-fat-lto-objects` → `-ffat-lto-objects` in
  mkspecs/common/gcc-base.conf. Fat objects carry real machine code + IR, so the hook strips
  only the IR: qdbusmenubar.o keeps 18 defined QDBusMenuBar symbols in the packaged archive
  (new md5 f002bb99). Flag/mkspec change → full clean rebuild per golden rule 5:
  `git -C src/qtbase reset --hard && git -C src/qtbase clean -fdx` (keeps the .git clone — no
  re-clone), `rm -rf pkg`, `makepkg -f` (~13 min). Installed qt5-base-git
  5.15.2+kde_r45808.gfbed962c319-1 + qt5-xcb-private-headers-git; qt5ct 1.9-2.1 rebuilt clean
  (0 undefined refs) and installed.
- Diagnostic dead end worth remembering: `makepkg -Rf` DOES wipe pkgdir and re-run package() —
  but a repackage can never fix content mutated by tidy hooks; the hollowing happened in tidy
  (after install) every single time, so `-Rf` reproduced it byte-for-byte.
- Follow-up: qt6-base-git ships the same class of archives (libQt6BundledEmbree.a verifies
  hollow) — harmless today (bundled 3rd-party consumed only inside qt6's own .so builds). If a
  static consumer ever appears, apply the same -ffat-lto-objects treatment.

## 2026-09-06 — pacman.conf: IgnorePkg audit — 62 self-maintained names were unprotected

- User ask: make sure every self-maintained package is excluded from repo upgrades.
- Method: sourced all 94 workspace PKGBUILDs (root + .Heavy + .Static + .3rdP), unioned
  pkgbase + every pkgname token (159 names), diffed against `pacman-conf IgnorePkg | sort -u`.
- Finding: 62 names missing, 54 of them INSTALLED — .Static qt5-*/qt6-* module stack
  (qt5ct 1.9-2.1, qt6ct, all qt5-declarative…qt6-webchannel), every gcc-snapshot split
  (*-snapshot incl. lib32-gcc-libs-snapshot), pyside6-git, ccache, dbus-broker/-units +
  dbus-units (renamed split of .Static/dbus), linux-cachyos-muqss-lto{,-dbg,-headers},
  scx-scheds-git/scx-tools-git, easyeffects-git, libisl-git, spirv-llvm-translator-git,
  clang-opencl-headers-git, pipewire-libcamera, linux-firmware-cirrus, bettbox (.3rdP),
  plus not-yet-installed rocm-llvm splits (rocm-llvm, hsa-rocr, hip-runtime[-amd],
  rocm-device-libs). Single biggest latent footgun found this week: one `pacman -Syu`
  would have downgraded/clobbered the whole Qt module stack (and more).
- Fix: appended a second cumulative `IgnorePkg =` line after the existing one (pacman
  accumulates repeated IgnorePkg directives; verified by `pacman-conf IgnorePkg` count
  127→189). Backup: /etc/pacman.conf.bak-20260906. Closure re-diff now empty; stale
  entries (purged systemd-tests, udisks2-lvm2, dbus-daemon-units, disabled pipewire
  split names, …) intentionally left — IgnorePkg only affects installable/installed
  names, so they are inert.
- Traps hit during the edit: `sed "27r file"` appended the raw names WITHOUT the
  `IgnorePkg =` prefix (had to `28s/^/IgnorePkg = /` after) — always re-read the
  inserted line before trusting it. And an edit-tool slip briefly deleted the LTO-strip
  bullet's header in MEMORY.md §6 (restored) — verify file diffs after batch edits.

## 2026-09-06 — 19-package integration: gimp chain scaffolded + base-system stock rebuilds

- User added 6 root `-git` dirs (rust-bindgen-git, flatpak-git, git-git, gimp-git,
  blender-git, krita-git) + 11 `.Static/` stock rebuilds (gc, imagemagick, openssl,
  openssh, openvpn, networkmanager, networkmanager-openvpn, upower, zsh, bash,
  libreoffice-fresh) and asked for the optimization playbook + build script updates.
- **Missing prerequisite chain**: gimp-git hard-depends on `babl-git>=0.1.118` /
  `gegl-git>=0.4.66` — neither installed nor in the workspace. Scaffolded both from
  AUR (git clone) and converted to house style (arch-meson + guarded mold + meson
  compile/install). babl keeps the `ENABLE_DOC=0` env toggle; gegl keeps
  `-Dworkshop=true` + its gcc-snapshot `-Wno-error=implicit-function-declaration`.
- **`networkmanager-vpn-plugin-openvpn` mystery solved**: it is a split package of
  `networkmanager-openvpn` (meta-pkg pointing at the plugin). Split outputs also
  discovered: libnm, networkmanager-docs, nm-cloud-setup (NM); zsh-doc (zsh);
  libreoffice-fresh-sdk (LO). All 25 names → IgnorePkg.
- **Optimizations applied** (all validated `bash -n` + `makepkg --printsrcinfo`):
  - mold (guarded `command -v mold` check, house idiom): gc, imagemagick, openssh,
    openvpn, networkmanager-openvpn, openssl (its Configure consumes env LDFLAGS),
    openssh/openvpn before ./configure; networkmanager + upower before arch-meson;
    flatpak-git/gimp-git before meson; git-git via LDFLAGS export (consumed by
    `_make_options`); krita-git via the CMake 3-var linker-flags pattern;
    babl-git/gegl-git via LDFLAGS before arch-meson.
  - PGO 2-phase (house safety pattern: save orig flags, atomic profile update,
    gcda-verify before profile-use, non-PGO fallback, clean rebuild, profile wipe):
    **bash** + **zsh**, training = their `make check` suites (timeout 900, `|| true`),
    binary smoke-tested before packaging. KEY autotools detail: CFLAGS are baked in
    at ./configure time, so each phase must re-run ./configure — `make clean` alone
    is not enough (this is why meson needed the build-dir wipe in dbus).
  - rust-bindgen-git: `-C target-cpu=native` appended only if RUSTFLAGS lacks it.
  - **Deliberate no-ops**: blender-git (already `options=(!lto)` +
    `-DWITH_LINKER_MOLD=ON` + ccache), libreoffice-fresh (already `!lto` +
    `--enable-lto` + fortify 3→2 + `-g1` — gbuild linker injection skipped as
    high-risk/low-reward). No PGO for openssl/openssh/openvpn/NM (crypto-critical
    or no meaningful training workload; playbook lists nothing for them).
- **build-all.fish**: +14 `_DEPS` edges (openssl→openssh/openvpn/git-git/LO;
  babl→gegl→gimp; glib2/polkit→flatpak/NM/upower; NM→NM-openvpn;
  qt6-base+qt6-svg+qt6-tools→krita; rust-git→rust-bindgen). `_GROUP_git` 41→49,
  `_GROUP_static` 35→46. topo_sort verified: all 19 new pkgs sort with correct
  ancestry, no cycles (`-l` dry run).
- **IgnorePkg third cumulative line** (189→214): new line inserted at line 28 in
  [options]. NEW TRAP: `tee -a` put it at EOF — inside the `[extra]` repo section,
  where pacman-conf rejects the directive with a warning ("in section 'extra' not
  recognized") and silently drops it (closure check caught it). Fixed: delete the
  EOF line, `sed "27r /tmp/ignorepkg-line.txt"` with the `IgnorePkg =` prefix baked
  into the inserted file. Backup: /etc/pacman.conf.bak-20260906-newpkg.
- Update 2026-09-06 evening: the whole batch has since been BUILT + INSTALLED
  (incl. libreoffice-fresh after the util-linux verdef fix; rust-bindgen-git
  needed the rust-git rebuild first — see its own section).

## 2026-09-06 — rust-git vs minimal llvm-git: target-set skew bricks rustc

**Symptom**: `makepkg -si` in `rust-bindgen-git` died in prepare(): `rustc: symbol
lookup error: /usr/lib/librustc_driver-*.so: undefined symbol:
LLVMInitializeARMTargetInfo, version LLVM_24.0` → `error: target was empty`
(bindgen's `cargo fetch --target "$(rustc -vV ...)"` runs rustc, which is dead —
the fetch error is a downstream symptom, not the cause).

**Root cause**: rustc's driver links `LLVMInitialize*Target*` symbols for every
LLVM target present at BUILD time (`rustc_llvm` build.rs adapts via
`llvm-config --targets-built`). Rebuilding llvm-git with the deliberate minimal
target set (`-D LLVM_TARGETS_TO_BUILD="X86;AMDGPU"`) and installing it ABI-breaks
any rust-git built against a full-target llvm. Evidence: driver needs 337 LLVM
symbols; exactly 69 missing = target-init syms for the 14 removed targets
(AArch64, ARM, AVR, BPF, Hexagon, LoongArch, MSP430, Mips, NVPTX, PowerPC,
RISCV, Sparc, SystemZ, WebAssembly). pacman.log showed llvm r595038 → r595808
installed 4 s before the rust upgrade in the same batch — order was right, the
llvm *target set* changed, which no dep-edge tracks.

**Version-node red herring**: `libLLVM.so.24.0` has a single version node
(LLVM_24.0); ANY missing symbol reports "version LLVM_24.0". Use
`readelf -W --dyn-syms` diff + `llvm-config --targets-built` to identify the real
skew, not the version string.

**Fix**: rebuild rust-git against the minimal llvm (stage0 bootstrap is immune to
the broken system rustc — bootstrap.toml sed-deletes the `rustc`/`cargo` lines;
`rustfmt` line too, else the dead system rustfmt is picked up). PKGBUILD header
now carries a rebuild-order warning. Post-fix, `rustc --print target-list` still
lists all targets but codegen works only for X86/AMDGPU (fine on znver5).

**Rules**:

- rust-git must be rebuilt after EVERY llvm-git/llvm-libs-git reinstall — and
  conversely llvm-git target-set changes invalidate rust-git even when versions
  match. build-all.fish has the dep edge; manual rebuilds must follow it too.
- build-all.fish dep-chain rebuilds (`-si git-git`) may re-run already-installed
  deps (e.g. openssl) — that is normal and idempotent.
- Transient `curl 56 SSL_read unexpected eof` → `bad pack header` on the ~1.5 GB
  `src/llvm-project` submodule fetch: resume with
  `git -C src/rust submodule update src/llvm-project` (direct-fallback fetch of
  the pinned commit); src/ survives and makepkg skips completed submodules.
- zsh-doc packaging fix (same morning): trim audit removed TeX makedeps but
  package_zsh-doc() still hard-installed `Doc/zsh.pdf` → install failure. Dropped
  the PDF line (docs split now ships Info+HTML only); a hard `install` of an
  artifact nothing builds aborts the whole split build.

## 2026-09-06 (pm) — mold false-negatives meson has_link_argument → zero verdefs (libuuid/libblkid)

(Note: the meson-git r175 "regression" in the original heading was DISPROVEN —
mold was the real culprit all along; see the root cause below.)

**Symptom**: after the 09-05 20:01 util-linux 2.42.3-1 build, `/usr/lib/libuuid.so.1.3.0` and
`libblkid.so.1` carry ZERO `.gnu.version_d` verdefs, while `libmount.so.1` kept all 105 `MOUNT_*`
nodes. First victim: libreoffice-fresh configure — `-lSM` conftest link fails with
`undefined reference to uuid_unparse_lower@UUID_1.0` ("SM library not found"). Anything that
LINKS against stock libs referencing versioned uuid/blkid symbols breaks the same way (runtime
with unversioned refs is still fine — link-time is the hard failure).

**Root cause** (pinned 09-06 evening by conftest stderr + repro): util-linux wires its version
scripts two ways — libmount/libsmartcols pass `-Wl,--version-script=` **unconditionally**;
libuuid/libblkid gate it behind `cc.has_link_argument('-Wl,--version-script=…')`. Meson probes that
flag by linking a **trivial conftest** (no uuid_* symbols) with `-Wl,--fatal-warnings` + the sym
file. The house build() adds `-fuse-ld=mold` to LDFLAGS, and **mold hard-errors on version-script
entries whose symbols are absent from the link** ("cannot assign version `UUID_1.0` to symbol
`uuid_clear`: symbol not found") where GNU ld silently tolerates it → `--fatal-warnings` → check
returns NO → meson silently omits the link arg → libuuid/libblkid link WITHOUT the script → zero
verdefs. **NOT meson r175**: an earlier attribution to meson-git 1.12.0.r175 was coincidence — the
real build log still showed NO under r178, and clean-room probes passed because they lacked mold.
Repro (real sym + makepkg LDFLAGS + `-fuse-ld=mold`) fails identically. libmount/libsmartcols
escaped only because their wiring never consults the check.

**Fix**: PKGBUILD build() exports `LDFLAGS+=" -fuse-ld=mold -Wl,--undefined-version"`. mold's
`--undefined-version` restores the GNU-ld tolerance inside the probe (real library links are
unaffected — every symbol in the shipped sym files exists there). Rebuilt 2.42.3: 7 × UUID_1.0 +
43 × BLKID_ verdefs confirmed; installed 09-06 ~17:45. After any linker change (mold version bump,
mold→bfd flips), re-run: `readelf -V <lib> | grep -c VER_` for libuuid (UUID_1.0), libblkid
(BLKID_*), libmount (MOUNT_*). Meson `has_link_argument` checks that link trivial conftests are
**all suspect under mold** whenever the checked flag interacts with symbol presence.

**Collateral from the same pass, fixed 09-06 (pm)**:

- **git-git**: `make -C contrib/mw-to-git` aborted ("No such file or directory") — the MediaWiki
  contrib tooling was removed upstream (2025); excised the build()+package() lines. Rebuilt and
  installed 2.55.0.r787.g3cb9185f65-1 after rustc got fixed (libgit-rs needs a working rustc).
- **blender-git**: `Unknown download protocol: git-lfs` — the PKGBUILD correctly declares
  `makedepends+=('makepkg-git-lfs-proto')` (provides /usr/share/makepkg/source/git-lfs.sh), but the
  package itself was never installed (not in any repo). Built+installed makepkg-git-lfs-proto 3-1
  (pulls git-lfs 3.8.0). Cloning then hit repeated transient `curl 56 SSL_read unexpected eof` /
  TLS connect errors from projects.blender.org — retry loop with backoff eventually got the full
  ~2.5 GB LFS clone through (06 Sep evening). Next blocker: the house `blender-fix-oneapi-2026.patch`
  (removes `sycl::access::address_space::ext_intel_global_device_space` from Cycles atomic_ref)
  no longer applies — upstream now defines a version-gated `CYCLES_SYCL_GLOBAL_ADDRESS_SPACE`
  (libSYCL >= 9 → `global_space`, else the legacy ext_intel space), making the patch obsolete.
  Removed patch from source=()/sha256sums and deleted the file. Then the extract phase failed with
  6637 × `error transferring "<oid>": [0] remote missing object` — root cause: the agent-shell
  injected `safe.bareRepository=explicit` git config makes `git lfs install/fetch` inside the bare
  mirror exit 128 ("Not in a Git repository"), the git-lfs.sh download handler tolerates it, so the
  LFS store was never populated and the worktree `git lfs pull` (standalone file:// transfer) found
  nothing. Batch-API probe (422 "Object … is not 1 bytes", not 404) proved the objects exist
  server-side. Fix: `GIT_CONFIG_COUNT=0 makepkg` — the universal agent-shell makepkg workaround,
  now confirmed for tag verification AND git-lfs bare-repo fetches.
- **rust-bindgen-git** 0.73.1.r0.g66a1e2aa-1 built and installed once rustc worked (the `-si`
  auto-install hit the interactive pacman prompt — install manually with `pacman -U --noconfirm --ask 4`).

## 2026-09-06 (eve) — OSL vs llvm-git 24: version-node skew bricks oslc; house OSL 1.15.3.0-1.2

- Symptom: blender-git ninja failed instantly on every `.oso` shader target:
  `/usr/bin/oslc: /usr/lib/libLLVM.so.22.1: version 'LLVM_22.1' not found (required by
  /usr/lib/liboslcomp.so.1.15)`.
- Root cause: llvm-git 24.0.0 exports **only** the current version node (`LLVM_24.0`); the Sep-04
  SONAME shim `libLLVM.so.22.1 → libLLVM.so.24.0` satisfies linking but NOT versioned symbol
  lookups. Repo `openshadinglanguage 1.15.3.0-1.1` (CachyOS pkg, built vs LLVM 22.1) went dead on
  the llvm-git update. Scan for stale couplings:
  `for f in $(grep -l libLLVM.so /usr/lib/*.so.*); do readelf -V "$f" | grep -oE "LLVM_[0-9.]+"; done`
  (pattern must admit minor nodes like 22.1, not just X.0). Only the OSL libs were affected.
- Fix = house package `.Static/openshadinglanguage` 1.15.3.0-1.2. Keeping the 1.15.3.0 tarball means
  identical sonames/ABI → zero blender-side risk (OSL main wants OIIO ≥ 3.0 and carries 1.16-dev
  drift). `osl-llvm-compat.patch` = backport of upstream LLVM-23 support (commit `2e43fc367`)
  adapted to 1.15.3.0, gate bump `VERSION_MAX 22.9 → 24.9` (src/cmake/externalpackages.cmake),
  FindLLVM per-component clang libs skipped when `libclang-cpp` found, plus the LLVM-24 fallout
  found empirically on first build:
  - `llvm::PassInfoMixin` moved into `llvm::detail` in LLVM 24 → use
    `llvm::OptionalPassInfoMixin` (isRequired()==false, same as the old mixin default). Subtle
    part: OSL's `NewPreventBitMasksFromBeingLiveinsToBasicBlocks` relied on **ADL through the
    mixin base class** to resolve unqualified `createModuleToFunctionPassAdaptor(...)`; once the
    base changed namespace the call broke with "'createModuleToFunctionPassAdaptor' was not
    declared" pointing at the llvm:: one. Qualify with `llvm::` (upstream main already does).
  - `TargetOptions::{NoInfsFPMath,NoNaNsFPMath,NoSignedZerosFPMath}` removed in LLVM 23 →
    `#if OSL_LLVM_VERSION < 230` (1.15.3.0 already guards `UnsafeFPMath` the same way for 22).
  - `TargetOptions::FloatABIType` removed in LLVM 24 (float ABI now a module flag /
    triple-inferred; `FloatABI::Default` meant "infer" anyway) → `#if OSL_LLVM_VERSION < 240`.
- Verify after install: `oslc --help` runs; `readelf -V /usr/lib/liboslcomp.so.1.15 | grep -oE
  "LLVM_[0-9.]+"` → `LLVM_24.0`; `ldd /usr/bin/oslc` → `libLLVM.so.24.0`. Installed ~20:25.
- Patch authoring tip (non-git sources): extract the pristine tarball twice, edit one copy,
  `diff -ru orig patched` + sed the `a/`/`b/` path prefixes → context-exact patch, dry-run it with
  `patch -Np1 --dry-run` before wiring into source=/sha512sums.
- blender-git rebuilt cleanly through the whole oslc stage afterwards (0 shader failures).

## 2026-09-06 (eve) — blender-git 5.3: bundled extern/glog vs system libglog double-registration

- First-ever full blender run aborted instantly (exit 1, before any version output):
  `ERROR: flag 'logtostderr' was defined more than once (in files
  '/usr/src/debug/google-glog/.../flags.cc' and 'extern/glog/src/logging.cc')`.
- Anatomy: blender bundled extern/glog (compiled into the binary; its vendored CMake links SYSTEM
  libgflags → direct NEEDED libgflags.so.2.2) **and** the binary pulls system `libglog.so.2`
  transitively via `libceres.so.4`. Both register glog's flags at static-init/load → glog fatals
  on the duplicate. Never exercised before because every earlier blender build died earlier (LFS,
  oneapi patch, HIPRT, oslc).
- Fix in the blender-git PKGBUILD `_CMAKE_FLAGS`: `-DWITH_SYSTEM_GLOG=ON -DWITH_SYSTEM_GFLAGS=ON`
  (blender's own advanced options; FindGlog/FindGflags modules exist). Bundled extern/glog+gflags
  drop out; all glog/gflags registration goes through the one system libglog.so.2 → clean.
- Diagnostic path worth remembering: glog flag-duplicate errors name the two files — one under
  `/usr/src/debug/<system-pkg>` = a system lib's static init; one `extern/…` = vendored copy
  compiled in. Then `readelf -d <bin> | grep NEEDED` (direct deps) + ldd each dep lib to find who
  pulls the system copy (here: libceres).
- Verify: `blender --version` exits 0 (was exit 1); `blender -b --python-expr …` prints
  SMOKE-OK 5.3.0 Alpha. Installed 5.3.r164916.gf2261d10cdd5-1 (incremental rebuild was only 62
  ninja tasks — the glog flip doesn't touch most TUs).

## 2026-09-06 (eve II) — gegl-git mrg/maxflow auto-features + babl/gegl soname provides

**gegl-git configure hard-fail** (`mrg`, then `maxflow` not found): the arch-meson
`--auto-features enabled` pitfall again — gegl's meson_options.txt marks both `auto`, so
arch-meson turns "not found" into a fatal configure error (consumers would only be the
interactive `mrg-gegl` viewer + the matting-global op — neither ships in stock Arch gegl
0.4.70, so disabling is exact feature parity). Fix: `arch-meson … -Dmrg=disabled
-Dmaxflow=disabled`. Probe trick that found both in one pass: throwaway
`arch-meson <src> /tmp/probe` configure and read all `Dependency … not found` lines up front.

**Soname provides, the unversioned-soname variant** (broke the `gegl→gegl-git` swap: pacman
"removing gegl breaks dependency 'libgegl-npd-0.4.so=libgegl-npd-0.4.so-64' required by gimp"):

- The REQUIRED provide string for an unversioned soname is `libfoo.so=libfoo.so-64` —
  the version part is the soname itself + `-64` (pacman parseEVR: ver=`libfoo.so`,
  rel=`64`).
- That string CANNOT be written in provides= : `check_fullpkgver` lint splits at the last
  hyphen, then rejects any hyphen left in the ver part → "pkgver in provides is not
  allowed to contain … hyphens". A versioned provide like `libgegl-0.4.so=0-64` passes
  (ver=`0`, rel=`64`) — which is why libunwind-git's explicit declarations worked and this
  class looked lint-impossible.
- The clean mechanism was there all along: **declare the bare soname**
  (`provides+=('libgegl-0.4.so' 'libgegl-npd-0.4.so' 'libgegl-sc-0.4.so')`). makepkg's
  `find_libprovides` matches packaged files named `$p*`, reads the ELF soname, and
  emits `${p}=${soversion}-${soarch}` at packaging time — for a versioned soname
  (`libgegl-0.4.so.0`) that yields `0-64`; for an unversioned one the soname itself
  lands in the version slot, reproducing the repo string byte-for-byte. Lint never sees
  the derived entry. This is the standard Arch convention and survives every rebuild.
- Applied to **gegl-git** (all three sonames) and, when `pacman -Dk gimp` then flagged
  `missing 'libbabl-0.1.so=0-64'` from the earlier pass, **babl-git** (`libbabl-0.1.so`).
  Both `-Rf`-repackaged, installed; swap clean, `pacman -Dk gimp` free of gegl/babl
  errors, `ldd /usr/bin/gimp` resolves all three libs from the house packages.
- Audit habit for the rest of the gimp chain before/at gimp-git build: for each already-
  built house lib package, `tar -xOf <pkg>.pkg.tar.zst .PKGINFO | grep '^provides'` must
  show the soname lines repo consumers need.

**Bare (unversioned) name provides can't satisfy versioned depends** (2026-09-06, broke the
`gimp-git` build: makepkg tried to install repo `cairo>=1.14.0` → conflict with installed
cairo-git):

- The soname mechanism above auto-versions `*.so` entries, but plain name provides get NO
  version from anywhere. pacman/makepkg can't satisfy `dep>=X` from an unversioned provide,
  so makepkg pulls the repo package → conflict with the installed -git one.
- babl-git/gegl-git already used the correct house idiom; cairo-git and glib2-git had
  missed it. Fix (all three now): `provides+=("${pkgname%-git}=${pkgver%%.r*}")` — strip the
  `.rN.gsha` tail so the provide equals the upstream release version. glib2-git fixed in
  PKGBUILD only (PGO rebuild queued); cairo-git rebuilt + reinstalled same evening.
- Audit habit: after any new -git package, `pacman -Qi <pkg> | grep Provides` must show the
  versioned name provide if repo consumers could ever depend on `name>=X`.

**uic ≥ 6.13 rejects `class=" QWidget"` (leading space) — krita-git Assistants plugin** (2026-09-06):

- Symptom: krita-git build fails, `ui_AssistantsToolOptions.h: No such file or directory` —
  the header was never generated because uic itself failed: `Invalid class name: " QWidget"`,
  `File … AssistantsToolOptions.ui is not valid` (line `[1814/3730] Generating
  ui_AssistantsToolOptions.h` in the log; ninja moved on and the real error surfaced later
  at the dependent compile).
- Root cause: upstream krita commit `3e8c536cf3` ("Wrapped all docker tool option
  check-boxes…") shipped `<widget class=" QWidget" name="showDockerOptionsPanel">` with a
  leading space. Older uic tolerated it; the rewritten uic in qt6-base-git 6.13.0 validates
  every widget class name and rejects the entire file. Verified by direct `uic` repro +
  one-char fix repro (uic exits 0 after `class=" QWidget"` → `class="QWidget"`).
- Lesson: "smells upstream" compile errors in generated-file-includes (ui_*/moc_*) mean the
  *generator* failed earlier in the log — grep the log for the generate step before
  diagnosing the compile. Fix: `sed` in krita-git prepare() (drop when upstream fixes).

## 2026-09-07 — gimp/krita chain completed: cairo provide fix landed, gimp-git + krita-git installed

**Chain build pass (agent-executed):** cairo-git rebuilt (1.18.4.r141) with the versioned
`cairo=1.18.4` provide (fix from the eve-II section) → installed → gimp-git
(2:3.3.1.r1561, 4m52s with mold/24c) → krita-git (6.1.0.prealpha.r66655, uic sed in
prepare() worked first try). All verified: `pacman -Dk` free of gimp/babl/gegl/cairo/krita
errors, `ldd /usr/bin/gimp-3.3` resolves libgegl-0.4/libgegl-npd/libbabl-0.1 from the
house packages, `krita --version` → `6.1.0-prealpha (git d554c53)`.

**`pacman -U --noconfirm` does NOT auto-remove conflicting packages**: the
"…and X are in conflict. Remove X? [y/N]" prompt takes the DEFAULT (N) under --noconfirm
and the transaction dies with "unresolvable package conflicts". Passing `--ask 4`
(= ALPM_QUESTION_CONFLICT_PKG) auto-answers the removal. Non-interactive swaps of
stock→-git packages need `pacman -U --noconfirm --ask 4`.

**`tar -xOf` on package filenames containing an epoch colon** (`gimp-git-2:3.3.1-…`)
fails with "Cannot connect to gimp-git-2: resolve failed" — tar parses `host:file`
remote syntax. Prefix the filename with `./` (`tar -xOf ./"$P" .PKGINFO`).

**gimp-git installs `gimp-3.3`, not `gimp`**: GIMP's dev branch (odd minor) suffixes
binaries with the version (`gimp-3.3`, `gimp-console-3.3`, `gimptool-3.3`); there is no
`/usr/bin/gimp` symlink. Don't panic when `pacman -Ql | grep usr/bin/gimp$` is empty.
Provides are bare `gimp` (no version) — fine today (no versioned repo consumers), but
revisit if something ever depends on `gimp>=X`. krita-git, by contrast, declares the
versioned `krita=6.1.0.prealpha…` provide.

**Headless smoke tests of GUI apps from an agent shell**: `krita --version` initializes
the app and grabs the display — under xwayland it emits `BadWindow` noise; under
`QT_QPA_PLATFORM=offscreen` alone it still finds X. Clean form:
`env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 90 <app> --version`.

## 2026-09-07 — build-all.fish: end-install (`-i`) removed — it compiled mid-run packages against OLD installed deps

**Root cause of the 09-06 rust/llvm incident, restated** (`makepkg -si` bindgen failure,
see the rust-git section above): the user's full rebuild that day ran with the old
`-i/--install` = build-everything-then-install-collectively. `topo_sort` ordered
llvm-git before rust-git correctly, but llvm-git was only RECORDed in `_BUILT_PKGS`
— not installed. When rust-git compiled hours later, its `build.rs`/`llvm-config` saw
the OLD installed llvm-git (full target set), not the freshly built minimal one
sitting uninstalled in the workspace. The final batch transaction then swapped in the
minimal llvm under a rustc linked for full targets → bricked. **Correct build order
does not help if installation lags compilation**: ordering is only sound when every
package is INSTALLED before its dependents compile.

**Fix (2026-09-07, build-all.fish)**:

- `-i/--install` semantics changed to immediate per-package install in topo order:
  after each successful build, `install_pkgs_now` runs
  `sudo pacman -U --noconfirm --ask 4 <pkgs>` and CHECKS the rc — install failure
  returns 1 and aborts the run (a failed install means every later package would
  compile against the wrong system state). No more `makepkg -i` (it cannot forward
  `--ask 4` and its rc was previously discarded via `| tail -3`).
- `-si/--sepinstall` kept as a deprecated alias: prints a one-line warning, behaves
  identically to `-i`. `build_package` lost its sepinstall_flag parameter; the
  `-sif` makepkg special case is gone.
- All collective-install machinery deleted: `_BUILT_PKGS`, the end-of-run install
  block, the build-failure salvage block, and the signal-handler install. With
  immediate installs nothing is ever pending, so failure/interrupt leave the system
  in the best state the successful prefix allows; resume with `-s -i`.
- The `-s` skip path installs too (already-built packages still need topo-ordered
  installation) — same helper, same rc check.

**Rule**: never reintroduce build-then-install-collectively for ABI-coupled chains
(qt6-base→modules, llvm→rust/mesa, openssl→openssh, babl→gegl→gimp). A chain is only
correct if each package is installed before its dependents compile. `install_pkgs_now`
is the single install path — extend it, don't fork it.

## 2026-09-07 — build-all.fish: `-g critical` keystone group, `--no-deps`, mandatory selection

The `.Heavy/` split encoded "slow builds", but the operationally meaningful split is
"ABI-coupled keystones whose update must trigger a rebuild of everything downstream".
Three changes (same file, one pass):

1. **`-g critical`** — new `_GROUP_critical` = 6 keystone hubs (`.Heavy/llvm-git`,
   `.Heavy/rust-git`, `qt6-base-git`, `qt5-base-git`, `glib2-git`, `.Static/openssl`).
   New `expand_dependents` BFS-es the REVERSE `_DEPS` graph from the seeds and unions
   seeds + transitive dependents (61 pkgs as of 2026-09-07); topo_sort orders it
   (keystones first by construction). The run **auto-enables `-i`** with a notice —
   without immediate installs the chain rebuild is the rust/llvm bug again.
   gcc-snapshot deliberately excluded: no `_DEPS` edges, its "dependents" would be
   the whole workspace — manual rebuild only. `-g heavy` (12 slow builds) is unchanged.
2. **`--no-deps`** — explicit package args skip `expand_deps`: build exactly the named
   packages. Leaf rebuilds (niri without dragging llvm/rust/mesa). Default behavior
   WITHOUT the flag still expands the dep chain.
3. **No more default action** — bare `build-all.fish` (or a lone range) errors out:
   a selection (`-g` and/or package names) is mandatory. The interactive
   "Include heavy packages?" prompt and `--include-heavy` died with it. An unattended
   build-everything run is how the 09-06 break happened.

**Dep-edge audit (2026-09-07, verified against `pacman -Qi Depends`)** — added:
`polkit-git→glib2-git`, `.Static/wireplumber→glib2-git`, `.Static/udisks2→glib2-git`,
`.Static/openshadinglanguage→.Heavy/llvm-git,qt6-base-git` (OSL was missing from the
graph AND `_GROUP_static` entirely — yet it is the llvm-version-node-coupled package),
`blender-git→.Static/openshadinglanguage` (links libLLVM via OSL),
`mesa-git→.Heavy/llvm-git` (via the `aur-llvm-libs-git`/`llvm-libs` provider).
Rejected after verification: `noctalia-git→qt6-declarative` (no Qt in its depends —
it is not Qt-linked) and `networkmanager-openvpn→openssl` (reaches ssl only via
libnm). Rule: audit edges with pacman metadata, not assumptions; false edges cause
spurious rebuilds, missing edges cause ABI breaks.

**Ordering caveat**: closure-ordering edges (e.g. gimp→cairo) for NON-keystone
packages don't affect `-g critical` correctness (cairo isn't in the closure); add them
when/if those packages ever become keystones.

**`-g` multi-select** (same day): `-g` accepts several groups — repeat the flag
(`-g git -g heavy`) or comma-separate (`-g git,heavy`); groups may be combined with
positional packages. Resolution moved into `resolve_group`; the union is deduped
BEFORE topo_sort (rocm ⊂ static: `-g static,rocm` = 47, not 49 — a dupe would make
Kahn's queue process a package twice). Unknown group in any position errors out.

## 2026-09-07 — post-trim system audit: no missing libs (3 cleanups found)

Full-system verification that the 2026-09-04 PKGBUILD trim broke nothing:
`pacman -Dk` (dep graph), `pacman -Qkk` as root (file integrity), and a soname
audit (every ELF in /usr/{bin,sbin,lib,lib32,libexec}: DT_NEEDED vs ldconfig +
libdir listing → 60724 pairs, 1957 unique sonames, 55 unresolved → all classified
via `pacman -Qo`). Script pattern lives in the transcript; the awk one-liner that
builds the file→soname map from `readelf -d` (File: headers) is the reusable part.
**GOTCHA: never `xargs -P` parallel readelf into one pipe — outputs interleave
mid-line and corrupt the parse** (fake sonames like `libkrb5.`, `0x3e8`).

Verdict: **no required lib is missing; nothing the trim removed is needed**.

- `pacman -Qkk` hits all benign: cups runtime-rewritten configs, /boot perms
  hardening, nfs state files. (nfs-utils root-Qkk = 0 altered.)
- 48/55 unresolved sonames = optional feature libs never installed (espeak-ng,
  botan, openmpi, vtk, movit, rtaudio, sox-ng, openslide, hspell/nuspell/voikko,
  R, rrdtool, freetds, ffado, glade) consumed by dlopened plugins/bindings of
  stock packages (mlt, enchant/sonnet, opencv-viz, qca-qt6, boost-mpi,
  speech-dispatcher, vips, graphviz, sensord, arpd/apr-util, jack2-firewire,
  libhandy-glade). Pre-existing Arch optdepends behavior — leave.
- pyside6 soname skew: stock k*-bindings want `.6.11`, pyside6-git ships `.6.12`;
  PyQt5/PyQt6 binding modules for Qt libs not in our stack (qt5-serialport,
  qt5-xmlpatterns, qt6-connectivity/-remoteobjects/-sensors/-scxml/-websockets).
  Same acceptable family as the Qt private-API policy — import-time only.
- qt5-base-git still ships libqsqltds.so (needs absent freetds) — installed pkg
  predates the sqlite-only trim; resolves on the next batched qtbase rebuild.
- NM-openvpn legacy GTK3 editor needs absent libnma.so.0; the GTK4 editor plugin
  (libnma-gtk4) is installed and is the one actually used. Benign.

Three real findings (fixes):

1. **llvm-ocaml-git** stale pre-trim split pinning `llvm-git=24.0.0_r595038…`,
   Required By: None → `sudo pacman -Rns llvm-ocaml-git` (queued with the
   linux-tools splits removal).
2. **seatd-git** provided bare `seatd libseat` but no soname → wlroots0.20's
   `libseat.so=1-64` dep unsatisfied in pacman's graph (runtime was fine —
   /usr/lib/libseat.so.1 exists). PKGBUILD now declares `libseat.so` (bare
   entry → pacman 7.1 auto-derives the soname provide); rebuild pending.
3. **fastfetch** uninstalled while cachyos-fish-config depends on it — noise
   only (the fastfetch call in cachyos-config.fish is commented out). Either
   reinstall fastfetch or ignore.

- Soname-provide rule (reinforces the gimp/cairo one): a package shipping
  `lib*.so.N` that others declare as soname deps MUST list a bare `lib*.so`
  entry in provides.

## 2026-09-07 (pm) — heavy/critical group trim audit: keystones complete

Per-package verification that the trim didn't strip artifacts other packages
use (toolchain binaries, dlopened plugin sets, cmake/pkgconfig, Qt ABI tags):

- **ALL CLEAN except two decisions already pending**: llvm-git (llvm-config,
  FileCheck, ld.lld, libclang, clangd/clang-tidy via clang-tools-extra — all
  present), rust-git (rustc/cargo/clippy/std), gcc-snapshot (gfortran,
  libgccjit, multilib, gomp), qt6/qt5-base-git (moc/uic/rcc at
  `/usr/lib/qt6/{moc,uic,rcc}` and `/usr/bin/` respectively — qt5 uses flat
  /usr/bin, qt6 the libdir; sqlite-only sqldrivers already live in qt6, qt5
  still pre-trim), glib2-git, openssl, cmake/doxygen/meson/mold/spirv all
  present with consumers. Qt private-tag acceptance test: all 10 defining
  Qt6 libs tag `QtPrivate_6_13` == qt6-base-git. No ELF anywhere NEEDEDs a
  missing toolchain lib.
- **GTK4 print backends are NOT a loss**: upstream GTK4 builds them INTO
  libgtk (build log compiles into `gtk/libgtk.a.p/print_backends_*`; no
  `print-backends/*.so` exists to package — verify via `grep printbackendcups
  libgtk-4.so.1`). Don't "fix" a missing module dir for gtk4 like you would
  gtk3 (gtk3 still ships real `libprintbackend-cups.so`).
- **rocm-llvm + hsa-rocr + hip-runtime are UNINSTALLED** (pacman.log: one
  transaction 2026-09-06 10:11 removed rocm-llvm, comgr, rocm-device-libs,
  hsa-rocr, hip-runtime-amd, rocminfo, rocprofiler-register, hiprt,
  rocm-cmake). Nothing installed NEEDS any of their sonames (the libhiprtc
  grep hits are clang's compile-time HIP-driver strings, not runtime deps) —
  system is consistent, but HIP compute / Blender-HIP rendering is gone;
  `/opt/rocm/bin` holds only amd-smi + rdhc. Decision pending: rebuild via
  `-g rocm` or prune the 4 workspace dirs + group.
- **Stale pre-trim gcc-snapshot splits installed**: gcc-{ada,d,ga68,gcobol,
  go,m2,objc,rust}-snapshot still installed but the PKGBUILD now builds only
  c,c++,fortran,lto (+libgccjit-snapshot, lto-dump-snapshot splits). They
  still run (self-contained old builds) but are frozen. Remove with the
  queued `-Rns` batch or restore languages.
- rust-analyzer: not installed anywhere (no pacman pkg, no VS Code extension)
  — rust-git never shipped it; not a trim loss.
- stock qt6-webengine 6.11.2 (← fcitx5-chinese-addons) has no `QtPrivate_6_*`
  undefined refs in WebEngineCore but remains stock-on-dev — known-accepted
  per the 09-02 policy.
- libcloudproviders installed (← gtk3-git, nautilus) while gtk4-git has
  cloudproviders=disabled: only cosmetic (no cloud entries in GTK4 sidebars);
  nautilus links libcloudproviders directly.

## 2026-09-07 (pm II) — directory restructure: .Heavy → .Heavyweight, keystones moved

User directive: root dirs = git group; `.Heavy/` renamed to `.Heavyweight/`
(user confirmed spelling) holding heavy ∪ critical; `.Static/` unchanged.

- Moves: `.Heavy` → `.Heavyweight`; `qt6-base-git`, `qt5-base-git`,
  `glib2-git` moved from root into `.Heavyweight/` (critical ⊆ heavy ∪
  `.Static/openssl`). These are AUR-mirror git repos — `mv` preserves them.
- build-all.fish: every `.Heavy/` ref → `.Heavyweight/` (incl. the
  `string match -q '*/.Heavy/*'` canonical-clone ranker — a MISS here would
  silently demote heavy mirrors); keystone names prefixed `.Heavyweight/` in
  all _DEPS edges (keys AND colon-side refs — grep with a `(?<![/\w-])`
  lookbehind to catch bare refs, plain `.Heavy/` grep misses colon refs);
  `_GROUP_git` = 46 (−3), `_GROUP_heavy` = 15, `_GROUP_critical` = 6, closure
  still 61. Verified: `fish --no-execute` OK; dry-runs git 46 / static 47 /
  rocm 2 / heavy 15 / critical 61 / rocm+heavy 17 / static+rocm 47 (dedupe);
  critical topo order shows keystones first.
- **Auto version sync unaffected and proven**: `sync_static_version` gates on
  `*.Static/*` path match + static `^pkgver=` line. Sandbox-tested the
  extracted function on PKGBUILD COPIES: stale copy syncs (`↻ zsh: 5.8-1 →
  5.9.2-1.1`, epoch/pkgrel handling intact), current copy skips, libisl-git
  still never-syncs (repo pkg is `libisl`), and a `.Heavyweight/` path gates
  out — so the moved qt5/qt6-base + glib2 (pkgver()-driven -git builds) are
  correctly NOT repo-synced. All 50 .Static PKGBUILDs carry static `pkgver=`.
- Found during the move: root `cmake-git/` + `gtk4-git/` are src-only
  leftovers of the 2026-09-04 move (no PKGBUILD) — deletion candidates;
  stale `Project-structure.txt` (Sep 4) inside .Heavyweight vs the current
  root copy — artifact, ignore or delete.

## 2026-09-07 (pm III) — mold linker global + parallel build lanes

- **mold is now the system linker**: `-fuse-ld=mold` prepended to LDFLAGS in
  `/etc/makepkg.conf` (backup: `/etc/makepkg.conf.pre-mold-20260907`). Root
  cause of "link uses one core": bfd ld is single-threaded by design, and
  GCC `-flto=auto` gets no jobserver under ninja. Verified the driver passes
  `-fuse-ld=mold` through (`gcc -v` link test, binary runs).
- **build-all.fish: `--lanes N` parallel dispatcher** (default 1 = exact old
  sequential semantics). Ready-set scheduling on top of topo_sort:
  - lane refills as soon as a package's workspace deps are *installed*
    (never merely built — rule 11); lanes=1 dispatches in strict topo order
  - heavy-group packages run SOLO with full `-j$(nproc)` (LTO RAM guard);
    other lanes split `-j = max(4, nproc/N)`
  - pacman DB lock serializes concurrent `pacman -U`; dispatcher keeps the
    sudo timestamp warm (`sudo -v` every 4 min) — background lanes have no
    tty, so an expired timestamp would silently kill installs
  - failure: stop dispatching, DRAIN in-flight lanes, then summary + resume
    hint (remaining = never-started); cycle leftovers reported as "never
    became ready" instead of hanging the scheduler
  - output: makepkg fully redirected to per-pkg log (tee removed — terminal
    backpressure gone); dispatcher prints `▶/✔/✗ name (duration)` and tails
    failed logs; install output appended to the pkg log; `⏳` live status
    line every 10 s while 2+ lanes busy
- **Fish landmine**: command substitution splits on NEWLINES ONLY —
  `cat` of a one-line result file gives ONE list item; must `string split ' '`
  explicitly. Cost ~1 debug cycle in the lane reap loop.
- Validation: `fish --no-execute` OK; dry-run counts unchanged (git 46 /
  static 47 / rocm 2 / heavy 15 / critical 61 / rocm+heavy 17); 8/8 sandbox
  unit tests on pick_next_ready (ready-set, solo gate, empty-list edges);
  live 2-lane smoke (skip path) incl. stop-dispatch+drain failure drill in
  a /tmp mini-workspace. First real workload: pending llvm-git BPF rebuild.

## 2026-09-07 (pm IV) — fcitx5 chain: -git rebuild fixes Chinese IM addon skew

- **Root cause of broken Chinese addons** (user theory, inverted but right):
  `.Static/fcitx5` had built the installed core `fcitx5 5.1.21-1.1`, while
  fcitx5-chinese-addons/qt/gtk were STOCK repo builds compiled against the
  stock core ABI. Self-built -git core + stock addons = addon ABI skew.
- **Fix**: full -git chain now self-built & installed (all against the same
  fcitx5-git headers): xcb-imdkit-git, fcitx5-git (5.1.22.r0), fcitx5-lua-git,
  libime-git, fcitx5-qt-git (splits fcitx5-qt5-git + fcitx5-qt6-git),
  fcitx5-gtk-git, fcitx5-chinese-addons-git. Stock fcitx5* removed
  automatically via conflicts + `pacman -U --ask 4`. `.Static/fcitx5` dir
  deleted; git group 46→53, static 47→46.
- **Three hidden AUR deps**: the addon PKGBUILDs name `xcb-imdkit-git`,
  `libime-git`, `fcitx5-lua-git` BY PACKAGE NAME — stock xcb-imdkit/libime do
  not satisfy them. Cloned all three into root (tiny builds).
- **PKGBUILD trims/patches applied** (AUR originals were broken here):
  - fcitx5-qt-git: qt4 split removed (ENABLE_QT4=Off, no qt4 on system);
    `_mv_pkg` made tolerant of missing paths + dropped `usr/lib/fcitx5/qt5`
    (upstream no longer ships the qt5 quickphrase plugin — only qt6)
  - fcitx5-gtk-git: GTK2 module off (`-DENABLE_GTK2_IM_MODULE=OFF`, verified
    option name in fcitx5-gtk CMakeLists); make→ninja; prepare() sed inserts
    `#include <string>` into gtk{3,4}/utils.h — GCC 17 no longer provides
    <string> transitively via <memory>/<utility>
- Build ran through the new `--lanes 2` dispatcher end-to-end incl. a real
  stop-dispatch+drain failure cycle (first failure stopped dispatch, the
  in-flight package finished, tails printed, resume hint was correct).
- **Landmine (2nd occurrence)**: NEVER put a `#` comment after a `\` line
  continuation — in fish AND bash the comment swallows the rest of the logical
  command (broke _GROUP_static mid-list, parse error at the next line). Symptom:
  "Unknown command '<next-list-item>'". Comments go ABOVE the block.
- Not yet verified at runtime: restart fcitx5 and check Chinese IM in a real
  session (`fcitx5-remote`/addon list). qt6-wayland remains stock-missing —
  Qt6 apps on Wayland use the core's input-method-v2 path, im modules cover
  X11/Xwayland.

## 2026-09-07 (evening) — LLVM snapshot bump broke rustc (linux-tools build)

- **Symptom**: linux-tools build died; perf's Rust workload
  (`tests/workloads/code_with_type.rs`) → `rustc interrupted by SIGSEGV` in
  `compile_codegen_unit`, then `Error 139`. Bisect showed rustc crashes on
  EVERYTHING (hello world too) with heap corruption (`free(): invalid pointer`
  even in `env -i`). RUSTFLAGS (target-cpu=native / opt-level) NOT involved.
- **Root cause**: rust-git (built 09-06 16:16) vs llvm-libs-git rebuilt 09-07
  13:17 (the BPF build) + installed 15:48 — LLVM snapshots have NO stable C++
  ABI; rustc's driver links libLLVM directly. Victims (link libLLVM.so.24,
  built before today's snapshot): rust-git, mesa-git, spirv-llvm-translator-git,
  openshadinglanguage. linux-tools was just the first thing to compile Rust.
- **Why not just rebuild rust**: its bootstrap stage0 IS the broken rustc
  (chicken-and-egg); repo rust 1.98 links llvm-libs → also broken; stage0
  version checks would refuse stable-1.98 anyway.
- **Recovery — downgrade-rebuild llvm-libs to the rust-compatible snapshot**:
  1. Old snapshot recovered from /var/log/pacman.log: `r595808.29fda2c4ecca`
  2. PKGBUILD source pinned `#commit=<full hash>` (makepkg would otherwise
     pull origin/main back), rebuild + install as a DOWNGRADE — BPF target
     survives because it's build config, not the snapshot
  3. rustc works again; mesa/spirv/OSL consistent again (no rebuild needed);
     PKGBUILD UNPINNED with a same-pass rule comment
  4. Rebuilt+installed: linux-tools (perf 7.2.3-1, runs) + scx-scheds-git
     (1.1.3.r121, scx binaries present; clang --print-targets shows
     bpf/bpfeb/bpfel — the original scx blocker is CLOSED)
- **Lane dispatcher lesson (sudo)**: a 70-min build's background install can
  outlive the sudo timestamp; keepalive `sudo -v` in the dispatcher times out
  when nobody is at the tty. Build survives, install must be re-run manually
  (`sudo -n pacman -U ...`). Also fixed: non-heavy package could start
  alongside a running heavy solo build (RAM-guard defeat) — lanes now hold
  while a heavy is in flight.
- **Incident-response hardening (post-incident review)**: build-all.fish now
  handles this incident class end-to-end:
  - `check_rustc_sanity` preflight probe (trivial `fn main(){}` compile, ~2 s)
    aborts the run before it wastes an hour, with the recovery recipe inline;
    bypass `--allow-broken-rustc`. Sandbox-tested healthy + broken-stub paths.
  - keepalive: `sudo -n -v` (never hangs the dispatcher), 150 s interval —
    well inside the 5-min sudo timeout even under load
  - lane installs use `sudo -n` → fail fast instead of a 2-min doomed prompt
  - failure report distinguishes install-failure from build-failure (archive
    may exist → `-ia` or `-s -i` recover without rebuilding)
  - `-g critical` graph confirmed to include all incident victims (llvm →
    spirv/rust → mesa/OSL, 66-pkg closure, correct topo order)
- **Root-supervisor mode (2026-09-07 evening)**: `sudo fish build-all.fish …`
  now works cleanly — header shows `User: root (supervisor)`:
  - installs run DIRECTLY as root (sudo timestamp can no longer expire on
    multi-hour runs; keepalive/sudo -n only in unprivileged mode)
  - makepkg + ALL workspace artifacts run as the invoking user via
    `sudo -u $SUDO_USER env HOME=$HOME` — makepkg refuses root, and
    --asroot would scatter root-owned src/pkg into <project-root> plus caches
    (~/.ccache, ~/.cargo, ~/.cache/go-build) into /root
  - build_package restores user ownership (`chown -R`) after each package —
    root's clean/sync/PKGBUILD-edit touches never leave root-owned files
  - `-ln` refuses under sudo (git ops must be user-owned); `-cc`/`-ccc` rm
    only, safe either way
- **Rule-13 recurrence + rust-git self-rebuild capability (2026-09-08)**:
  llvm-libs moved twice on 09-07 (r595886 → r595945) while rust-git stayed at
  r339240 → rustc SIGSEGV on any input. Recovery: plain `makepkg` rebuild of
  rust-git — the PKGBUILD deletes `rustc = "/usr/bin/rustc"` from
  bootstrap.toml, so bootstrap uses the DOWNLOADED official stage0 (statically
  linked LLVM) and is immune to system libLLVM skew. This SUPERSEDES the
  earlier "rust-git cannot rebuild itself once broken" conclusion — that is
  no longer true with the current PKGBUILD. Rule 13 unchanged: after
  llvm-libs moves, rebuild rust-git + mesa-git + spirv-llvm-translator-git +
  openshadinglanguage in the same pass.
  - Hit during the rebuild: `*** stack smashing detected ***` in stage1 rustc
    inside libLLVM r595945 (`LLVMRustOptimize` → PassManager::run) while fat-
    LTOing rustc_driver. Nondeterministic (earlier pass over same inputs
    succeeded); cleared on retry. Diagnosis: `coredumpctl info <pid>` — the
    crashing frame named libLLVM.so + LLVMRustOptimize. If it ever becomes
    deterministic, suspect LLVM main drift (rust pins release/23.x, system
    llvm-git is 24-dev main) or a gcc17-built libLLVM miscompile.
  - ALSO found: the `<project-root>/.Heavy` → `.Heavyweight` rename had poisoned
    git internals — `src/rust/.git/objects/info/alternates` AND
    `src/rust/.git/config` remote origin still pointed at the old absolute
    path (symptom: "does not appear to be a git repository" during
    "Creating working copy"). Fixed with sed path rewrite; scanned all of
    .Heavyweight/.Static — no other affected package.
- **OLD-PATH AUDIT after .Heavy rename (2026-09-08)**: gtk3-git failed with
  `<project-root>/.Heavy/gtk4-git/gtk: Permission denied` during a
  FRESH `git clone --mirror` — the old path was referenced not by git
  internals this time but by a **share-the-mirror symlink**:
  `gtk3-git/gtk -> ../.Heavy/gtk4-git/gtk` (gtk3 and gtk4 PKGBUILDs use the
  same gitlab.gnome.org/GNOME/gtk.git URL, so the mirror was shared). The
  rename dangled it; a stray root-owned `.Heavy/gtk4-git` recreated on 09-07
  made it EACCES instead of ENOENT. Full audit (`find -type l` + target
  match, excluding src/pkg trees) found:
  - `libclc-git/llvm-project-git` → REPOINTED to ../.Heavyweight/llvm-git/
    llvm-project (target exists; still shares the giant llvm checkout)
  - `gtk3-git/gtk` → DELETED (makepkg recreates a local mirror; gtk4-git has
    no mirror yet, so repointing would dangle again)
  - `.Static/hip-runtime/hip-runtime-hipcc` → DELETED (rocm-llvm has no
    checkout in .Heavyweight yet; rocm stack still queued for restore-or-prune)
  - `.Heavyweight/rust-git/LICENSES/0BSD.txt -> <old-repository-path>` →
    upstream artifact, unused by PKGBUILD, deleted
  - stray root-owned `.Heavy/` (recreated 09-07 by builds that followed the
    dangling symlinks) → `sudo rm -rf`; nothing references it now
  - git-internals class (alternates + origin URL in src/rust/.git) was fixed
    earlier the same morning; string sweep of *.md/*.toml/*.json/*.kdl across
    Projects is clean (only stale CMakeConfigureLog.yaml in llvm-propeller/
    build — informational cache, harmless).
  LESSON: the rename damage came in THREE classes — git alternates, git
  origin URLs, and sharing symlinks; each surfaced at different times. Audit
  pattern: `find <project-root> -maxdepth 4 -type l` (+ `-xtype l` for dangles),
  grep alternates/config under .git dirs, then grep strings.
  RESOLVED same day: gtk3-git then failed in meson configure with
  "Unhandled python OSError" (no traceback) — forced with
  MESON_FORCE_BACKTRACE=1 → PermissionError EACCES on root-owned
  src/build leftovers. Root cause of the residue: build-all.fish's root-mode
  `chown -R` restore ran ONLY on the success path (`return 1` on build
  failure preceded it), so every failed root-mode run left root-owned files
  that poisoned retries (43 files found across gtk3-git, gtk4-git ×2,
  linux-cachyos). Fixed: chown now runs unconditionally (both paths);
  tree-wide `chown -R zhangdm:` applied. Diagnostic recipe for the masked
  OSError: it is always "an issue with your build environment" — force the
  traceback from INSIDE the failing context (env var via the PKGBUILD), not
  from an interactive shell, or the flakiness will look nondeterministic.
- **git-git: pod2man needed on PATH (2026-09-08)**: `all` target generates
  perl/build/man/man3/Git.3pm via pod2man → same Perl 5.42 core_perl
  relocation as openssl. Cannot trim docs like openssl (Git.3pm is part of
  the default build), so git's PKGBUILD now exports
  `PATH="/usr/bin/core_perl:$PATH"` in build().
- Fish landmines hit while implementing: `$pre cmd` with empty `$pre` =
  "expanded command was empty" (use if/else, no empty-prefix); root can't
  `>`-redirect over user-owned files in sticky /tmp (fs.protected_regular=2)
  → per-user temp names; rustc crate names come from output filenames →
  [A-Za-z0-9_] only, sanitize user suffixes.
- **`string join` + flag-leading argv (2026-09-07 evening)**: hint echo died
  with "string join: -g: unknown option" — argv elements starting with `-`
  are parsed as options; ALWAYS use `string join <delim> -- $argv`.
- **openssl 3.6.4: pod2man not found in package() (2026-09-07 evening)**:
  `install_man_docs` needs pod2man, which Perl 5.42 keeps at
  /usr/bin/core_perl — present in interactive PATH but missing inside the
  fakeroot/make context. Fixed with `no-docs` in Configure +
  `install_sw install_ssldirs` only (house style: docs trims; no pod2man
  dependency ever again). Rebuilt+installed; the fail-fast sudo path then
  worked as designed (build survived an expired timestamp, install re-run
  manually). Big 114-pkg run: resume with `-s -i --lanes 2` + remaining names.
- **bash PGO training run freeze: GNU timeout + interactive tests = SIGTTIN
  stop (2026-09-07 night)**: `timeout 900 make check` hung the bash build at
  0% CPU, ^C-immune. Cause: `timeout` runs the suite in a NEW background
  process group; the suite's interactive test (`tests/exec8.sub` runs
  `bash -i`) touches the controlling tty from a background group → kernel
  SIGTTIN → whole tree STOPped (`T` state). Stopped processes leave SIGINT
  pending, hence "won't respond to ^C"; only SIGKILL works. timeout would
  eventually SIGTERM them at 900s — a silent 15-min stall per attempt.
  Fix: `timeout --foreground 900 make check </dev/null >/dev/null 2>&1`
  (--foreground keeps the terminal's foreground pgroup; /dev/null stdin means
  interactive tests read EOF instead of the tty). Diagnosis pattern: `ps
  -eo pid,ppid,pgid,tpgid,stat,wchan` — STAT `T` + wchan `do_signal_stop` is
  the signature. Two orphan trees (lane + manual `makepkg -si`) were found
  racing on the same srcdir; killed both, partial profile (145 .gcda) let the
  phase-2 rebuild proceed normally.

## 2026-09-09 — vscodium-insiders-git optimization and scheduler wiring

- **Change**: added `ccache` and disabled package-level LTO for
  `vscodium-insiders-git`; its upstream build downloads a prebuilt Electron
  binary, so only native Node addons are locally compiled.
- **Optimization**: `build()` now uses the Arch ccache compiler wrappers and
  a persistent per-user cache, with mold selected through `LDFLAGS` when
  available. PGO was deliberately not added: VSCodium's build is primarily
  TypeScript/packaging work and has no meaningful local executable training
  phase.
- **Integration**: registered the package in `_DEPS` and `_GROUP_git` so
  dependency expansion, topological ordering, dry runs, and lane scheduling
  include it.
- **Rule**: optimize only the native compilation path; do not force LTO or
  invent a PGO phase for a prebuilt-Electron packaging workflow.
## 2026-09-15 — hsa-rocr build recovered from stale partial download

- **Symptom**: `makepkg -sif` repeatedly failed while retrieving
  `rocm-7.2.4.tar.gz`: curl attempted to resume at byte 831488, but the
  GitHub codeload endpoint rejected byte-range resume requests.
- **Root cause**: stale `rocm-7.2.4.tar.gz.part` remained after the previous
  interrupted download.
- **Fix**: removed only the resolved partial archive and reran
  `GIT_CONFIG_COUNT=0 makepkg -sif --noconfirm` under `.Static/hsa-rocr`.
  The fresh 41.3 MiB download, build, packaging, and pacman reinstall all
  completed successfully.
- **Verification**: installed `hsa-rocr 7.2.4-1.1`; `.PKGINFO` contains
  `provides = hsakmt-roct=7.2.4`. The existing `pkgrel=1.1` change was
  preserved.

## 2026-09-15 — imported PKGBUILD signing keys

- Extracted 46 unique active `validpgpkeys` fingerprints from all workspace
  `PKGBUILD` files, excluding commented-out examples.
- Imported the set in one `gpg --recv-keys` operation using
  `hkps://keyserver.ubuntu.com`; 43 fingerprints are now present in the user
  keyring.
- Three fingerprints were not retrievable from the public keyservers tried:
  `3D10AD045AB4AAFF8E8F36AF9B980AC2FB874FEB`,
  `ABAF11C65A2970B130ABE3C479BE3E4300411886`, and
  `C305FEBD4C4081119CB3C12CE640E67B2C7F96AA`.

## 2026-09-15 — linux-firmware VCN backport fixed for newer tag

- **Symptom**: `prepare()` failed at `git checkout 20260622 amdgpu/*vcn*`
  because the 20260910 source added `amdgpu/vcn_5_3_0.bin`, which does not
  exist in the 20260622 tag.
- **Root cause**: the old glob passed every current VCN path to checkout;
  Git rejects paths absent from the historical tree. Removing that firmware
  alone also left a stale `WHENCE` entry, causing `copy-firmware.sh` to fail.
- **Fix**: `prepare()` now enumerates current and historical VCN files,
  removes the current set, restores only files present in `20260622`, and
  removes manifest entries for VCN files absent from that tag.
- **Verification**: `makepkg -sif --noconfirm` completed; all seven split
  packages installed at `1:20260910-1`, initramfs regeneration succeeded,
  `makepkg --printsrcinfo` and `bash -n PKGBUILD` pass, and no packaged
  `vcn_5_3_0.bin` remains.

## 2026-09-15 — package-stack groups renamed and merged

- **Change**: renamed `.Static/` to `.Stable/` for packages whose versions
  synchronize with official repositories, and `.Heavyweight/` to `.Core/` for
  the heavyweight build area.
- **Groups**: replaced `static`, `heavy`, `critical`, and `rocm` with
  `stable` and `core`. `core` is the deduplicated union of the former
  heavyweight, ABI-critical, and ROCm memberships and automatically enables
  immediate per-package installation.
- **Script updates**: rewrote dependency paths, stable-version synchronization,
  scheduler solo-build checks, help text, group resolution, counts, and
  validation guidance in `build-all.fish`.
- **Documentation**: updated current-state descriptions in `MEMORY.md`;
  historical incident entries retain their original terminology.
- **Migration cleanup**: 5,320 preserved symlinks under the renamed trees
  referenced the old absolute or relative `.Heavyweight`/`.Static` paths;
  their targets were rewritten to `.Core`/`.Stable`. One unrelated broken
  staged dbus service symlink remains under `.Stable/dbus/pkg/` and was not
  changed.

## 2026-09-15 — legacy-leftover audit and builder audit mode

- **Change**: added `build-all.fish --audit`, a read-only report covering
  legacy directories, active control-file references, generated path
  references, package-group drift, dependency-path validity, and stale
  runtime/error artifacts.
- **Cleanup**: removed the stale `Project-structure.txt` snapshots, the
  abandoned `.build-logs/.lane1.result`, package-local `.srcinfo.err`
  remnants, and the unused `expand_dependents` helper. Historical migration
  references in this journal were retained.
- **Classification**: `.Stable/ccache`, `.Stable/dbus-broker`,
  `.Stable/systemd`, and the `.3rdP/` projects were classified as routine
  group candidates; `autofdo-git` and `bpftune-git` were added to `git`,
  while `ccache`, `dbus-broker`, and `systemd` were added to `stable`.
- **Auxiliary relocation**: moved `linux-cachyos` to `.Misc/`; `.Misc/`
  packages are excluded from audit membership and routine group discovery.
- **Outstanding**: `.Heavyweight/glib2-git/src/build` was recreated after
  the directory migration without a visible active builder. It was removed
  only after confirming no `makepkg`, `build-all.fish`, Meson, or Ninja
  process; if it reappears, trace the external creator before rebuilding.

## 2026-09-16 — OpenShadingLanguage LLVM 24 compatibility

- **Root cause**: LLVM 24 removed `TargetOptions::NoTrappingFPMath`,
  `FloatABIType`, and related legacy floating-point fields; OSL 1.15.3.0
  still referenced them, and its LLVM version ceiling rejected LLVM 24.
- **Fix**: repaired `osl-llvm-compat.patch` with valid LLVM version guards,
  removed the obsolete `UnifyFunctionExitNodes` include, updated the LLVM
  version ceiling to 24.9, and refreshed the patch checksum.
- **Validation**: the patch applies cleanly, the Ninja build completes, and
  `makepkg -sf --noconfirm` successfully creates the package.

## 2026-09-16 — legacy build-path guard

- **Cause**: old positional commands could still pass `.Heavyweight/...` or
  `.Static/...` directly to `build-all.fish`, so makepkg wrote into the
  pre-migration trees.
- **Fix**: positional paths now canonicalize to `.Core/...` or `.Stable/...`;
  `build_package` rejects any remaining legacy path. Removed the stale
  root-owned `.Heavyweight/{glib2-git,cmake-git,gtk4-git}` trees and added
  `.Heavyweight`/`.Heavy` → `.Core` plus `.Static` → `.Stable` compatibility
  aliases.
- **Validation**: legacy-path dry runs resolve to the migrated directories and
  `build-all.fish --audit` reports no legacy directory; the aliases resolve to
  the canonical trees.

## 2026-09-16 — multi-lane dispatcher made truly asynchronous

- **Symptom**: `--lanes 2` behaved like waves: the second lane started only
  after the first lane finished, and dependents waited for the whole wave
  instead of only their own dependencies.
- **Root cause**: Fish executes a backgrounded function call synchronously in
  this environment; `lane_job ... &` therefore blocked the dispatch loop.
- **Fix**: added a hidden `--lane-job` child mode and launch each lane through
  an external `fish` process. The parent now polls result files and refills an
  idle lane as soon as its dependencies finish (and install, when `-i` is set).
- **Validation**: mocked `cairo-git` (1s), `libdrm-git` (4s), and dependent
  `pango-git` (1s) ran with `--lanes 2`; `pango-git` started after `cairo-git`
  and before `libdrm-git` finished. Syntax, group dry runs, and `--audit` pass.

## 2026-09-16 — lane dashboard and process-output rendering

- **Symptom**: the interactive `--lanes 2` transcript could wrap lane events
  across terminal columns, interleave install/progress output with dispatcher
  lines, and print `Build interrupted` more than once after Ctrl-C. Piped
  output also contained ANSI color sequences.
- **Root cause**: the dispatcher emitted unbounded raw lines instead of owning
  a TTY-aware render surface; lane children inherited the parent's terminal
  and relied on inner build functions to stay quiet; and the signal handler
  was installed in the `--lane-job` children as well as the parent. Fish's
  `set_color` also emits ANSI when stdout is not a TTY.
- **Fix**: interactive runs now redraw a compact, width-capped dashboard;
  non-TTY and `TERM=dumb` runs use plain append-only output. Lane supervisors
  run under `setsid --wait` in isolated process groups, redirect their complete
  stdout/stderr stream to the package log, and are tracked for synchronous
  interruption cleanup. Child mode no longer installs the human-facing signal
  handler, and log tails strip carriage-return/escape controls before replay.
- **Validation**: a deterministic pseudo-TTY/pipe harness with long package
  names, child progress output, fake installs, a failing lane, and Ctrl-C
  passes the dashboard, no-ANSI, isolation, failure-drain, and exit-130 checks.
  `fish -n`, git/stable/core dry-run counts, legacy-path canonicalization, and
  `--audit` also pass.
- **Rule**: only the parent dispatcher may render live terminal state; all
  lane child output belongs in per-package logs, and every terminal update must
  be width-safe or use the plain non-TTY fallback.

## 2026-09-16 — LLVM source-heavy packages moved to core

- **Change**: moved `libclc-git` (the requested “linclc-git”) and
  `autofdo-git` from `git` to `core`; the routine counts are now 54 `git` and
  41 `core`. Both are serialized with other source-heavy/ABI-critical builds.
- **Source-sharing guard**: `-ln/--link-sources` now accepts only an actual Git
  mirror or working clone. It no longer mistakes an empty source directory
  inside a package repository for a valid mirror, and it can replace stale
  empty paths while preserving populated non-Git paths.
- **Current state**: the existing LLVM mirror path was empty; after confirming
  the live `-g git,stable` build did not touch these packages, the targeted
  fan-out was repaired. Both source-cache names now point at the missing
  `.Core/llvm-git/llvm-project` canonical path, which makepkg can populate on
  the first core LLVM build. Run the full unprivileged `build-all.fish -ln`
  after the active build finishes to recheck the other source groups.

## 2026-09-16 — lane dashboard log tails and activity hint

- **Symptom**: a long-running lane could appear healthy while blocked by a
  stale pacman database lock; the dashboard repeated its title and the event
  row did not visibly prove that the dispatcher was still polling.
- **Fix**: active lanes now show the last three sanitized lines from their
  per-package logs, refreshed on each 0.5-second dispatcher poll. The
  dashboard keeps only the one-time header, uses compact `✓`/`✗`/`⚠`/`·`
  markers, and prefixes the event row with a `-`/`\`/`|`/`/` spinner.
  Per-package logs are cleared at dispatch so preflight cannot expose a prior
  run's tail.
- **Boundary**: pipe and `TERM=dumb` output remains the existing plain
  append-only format; child build/install streams remain log-only.
- **Validation**: the temporary PTY/pipe fixture covers stale-lock visibility,
  exactly three tail rows, ANSI/control sanitization, title ownership,
  spinner cycling, narrow terminals, failure tails, and Ctrl-C exit 130.
  Fish syntax, group dry-runs, and workspace audit also pass.

## 2026-09-16 — builder frontend/backend hardening

- **Frontend review**: output paths had drifted between dashboard, sequential
  builds, installs, failures, maintenance commands, and argument errors
  (`✔`/`✓`, mixed headings, and duplicated ad-hoc color/icon formatting).
- **Backend review**: parallel installs could independently contend on
  pacman’s database lock; a lane supervisor that exited before writing a
  result could leave the dispatcher waiting forever; several filesystem,
  directory, ownership, dependency-expansion, and source-link failures were
  not surfaced explicitly.
- **Fix**: added shared UI helpers and status vocabulary, visible-cell
  dashboard truncation, atomic/validated lane results, supervisor liveness
  handling with fail-and-cleanup behavior, explicit blocked-selection failure,
  checked runtime/filesystem boundaries, and a builder-owned `flock` around
  pacman transactions. Stale `/var/lib/pacman/db.lck` files are never removed
  automatically.
- **Validation**: the temporary command matrix covers interactive/pipe output,
  narrow dashboards, fake pacman install serialization, dead and malformed
  lane results, failure reporting, source-link repair, Fish syntax, group
  dry-runs, and workspace audit. No live package build was used as a test.

## 2026-09-16 — root cause: PGO libraries recreated legacy paths

- **Evidence**: the installed `glib2-git` and `cairo-git` shared libraries
  exported `__gcov_*` symbols and contained absolute `.gcda` destinations
  under the old build trees. `gdbus --version` and `pango-view --help`
  refreshed those files, while `perf trace` captured `RDWR|CREAT` opens by
  the consumer process. This explains why the trees returned after deletion:
  an already-installed instrumented library writes its counters at process
  exit and recreates every missing parent directory.
- **Root cause**: the PGO recipes changed `CFLAGS`/`CXXFLAGS` before
  `meson setup --reconfigure`, but Meson retained the cached instrumented
  compiler options. The low-profile fallback also reconfigured without
  compiling the final non-instrumented build. Applications then loaded the
  instrumented libraries from `/usr/lib`.
- **Fix**: `glib2-git` and `cairo-git` now pass final flags explicitly through
  `-Dc_args`/`-Dcpp_args`, compile both PGO branches, reject final binaries
  containing coverage/profile symbols, and increment `pkgrel`. The public
  recipes must be rebuilt and installed before deleting the residual trees.
- **Verification**: after replacement, `readelf -sW` on the installed GLib and
  Cairo libraries must find no `__gcov_` or `__llvm_profile` symbols, and
  `strings` must contain no legacy `.gcda` destinations. The earlier
  `xdg-desktop-portal` `$HOME`/unknown-user warnings are a separate
  Flatpak/portal namespace issue, not the path creator.

## 2026-09-16 — selectable scheduler intensity profiles

- **Symptom**: automatic scheduling exposed only CPU/RAM-derived `lanes` and
  `jobs`, so users could not choose a documented effort level. The displayed
  `-j` value was per lane, making the old plan easy to misread as a global
  worker count.
- **Fix**: added `low`, `medium`, `high`, `xhigh`, and `max` profiles, with
  `xhigh` as the default. Automatic normal-lane memory is budgeted globally
  and divided across lanes; core packages retain a separate solo budget.
  `--intensity` and `GSA_INTENSITY` select the profile, while explicit
  `--lanes` and `--jobs` remain hard overrides.
- **Rule**: treat `max` as an intentional low-headroom mode. Keep the
  resolved intensity and plan in the startup output, and preserve both in
  failure resume commands.
- **Validation**: a temporary/future-maintainer fixture with fake `makepkg`
  runs all five profiles on a deterministic 24-thread/21-GiB host and checks
  the resolved lane/job plans without building a real package.
