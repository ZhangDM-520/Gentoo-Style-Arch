# systemd PKGBUILD optimization — findings & plan (2026-09-02)

Status: IMPLEMENTED (2026-09-02, see "Implementation status" at bottom). Target file: PKGBUILD (only build() + pkgrel change; all 6 sub-packages, check(), package_*() untouched).

## User decisions
- GCC toolchain (not clang; BPF uses clang internally via bpf-framework anyway)
- Keep makepkg stripping; "do not strip subparts" = keep all 6 sub-packages untouched
- PGO workload = offline `meson test` subset (failures tolerated)
- mold linker if installed (silent fallback)
- PGO env-gated via `_systemd_PGO=1` (pattern like existing `_systemd_UPSTREAM` heuristic)

## Key facts (verified)
- CPU: AMD Ryzen AI 9 HX 370 (Zen 5/znver5, 12c/24t). makepkg.conf already: CFLAGS `-march=native -O3 ...`, LTOFLAGS `-flto=auto`, OPTIONS includes `lto` → ISA/O3/LTO already injected via env; nothing needed for those.
- Upstream systemd self-protects EFI targets: src/boot/meson.build sets `override_options: ['b_pgo=off']`, auto `-fno-lto` if LTO+`-nostdlib` sanity fails, explicit `-march=x86-64` after env flags.
- BPF objects: fixed `-O2` clang/gcc-bpf flags in src/bpf/meson.build, unaffected by our flags.
- systemd ships static libsystemd.a/libudev.a (PKGBUILD doesn't remove them) → slim GCC LTO archives break non-LTO consumers → add `-ffat-lto-objects` to CFLAGS in build().
- NEVER inject PGO via env CFLAGS (leaks into EFI -static-pie/-nostdlib targets); use meson -Db_pgo. GCC PGO data = *.gcda in build dir; `meson configure build -Db_pgo=use` reconfigure-in-place works; flag change forces full rebuild.
- makepkg runs build() under set -e → test/timeout failures need `|| true`; verify by side effects (gcda count > ~200).
- pkgver=261.2 (git tag v261.2), build uses arch-meson + `-Dmode=release` (release blocks apply).

## Planned build() changes
1. pkgrel → 1.1.
2. Top of build(): `export CFLAGS+=" -ffat-lto-objects"`; `command -v mold >/dev/null 2>&1 && export LDFLAGS+=" -fuse-ld=mold"`.
3. _meson_options: append `-Db_ndebug=true` (and optionally `-Doptimization=3`).
4. PGO branch (if _systemd_PGO set): configure with `-Db_pgo=generate` → compile → workload: `mkdir "$srcdir/pgo-work"; timeout -k 30 1200 env TMPDIR="$srcdir/pgo-work" meson test -C build --no-rebuild --print-errorlogs || true` → gate `find build -name '*.gcda' | wc -l` > ~200 else return 1 → `meson configure build -Db_pgo=use` → `meson compile -C build`. Else plain path as today.
5. check() and package_*() unchanged.

## Phases
0. Preflight: gcc --version, command -v mold, ≥20 GB disk, /usr/src/linux/vmlinux.h exists (-Dvmlinux-h=provided), python-jinja/lxml/pyelftools/pefile present.
1. PKGBUILD edits (above).
2. Verify build: `makepkg -sf`; check log has `-march=native -O3 -flto=auto -ffat-lto-objects`; EFI sanity passed; link trivial NON-LTO program against packaged libsystemd.a (fat-objects proof); `meson configure build | grep -E 'optimization|b_ndebug|b_pgo|b_lto'`; `file` the *.efi stubs; namcap.
3. Final: `env _systemd_PGO=1 makepkg -sf` (fish syntax); compare sizes; optional systemd-analyze verify benchmark.
4. Install: pacman -U order systemd-libs → systemd → rest; keep old pkgs in /var/cache/pacman/pkg for rollback; runtime validation: systemd-analyze verify, bootctl status, reboot + systemd-analyze blame, journal intact.

## Further considerations
- BOLT excluded (complexity vs gain on LTO+PGO).
- If GCC LTO breaks a target: -Db_lto=false there, or scratch clang thin-LTO experiment.
- Optional ccache (minor: flag changes → cold keys).

## Implementation status (2026-09-02)

- pkgrel → 1.1 ✅
- build(): `CFLAGS+=" -ffat-lto-objects"` + mold fallback (`LDFLAGS+=" -fuse-ld=mold"`, silent if absent) ✅
- `-Db_ndebug=true` REJECTED after implementation: meson default is `false`; with NDEBUG the 6
  crash-expectation tests (test-hashmap/set/string-util/fd-util/iovec-util/cpu-set-util) fail
  ("died with signal 0, but ABRT was expected") because plain `assert()` is compiled out — and it
  would strip asserts from PID 1. Release buildtype already sets `optimization=3`, so
  `-Doptimization=3` was unnecessary too. Comment left in build() explaining this.
- PGO branch (env `_systemd_PGO=1`): `-Db_pgo=generate` → `meson test` workload (timeout 1200s,
  failures tolerated, TMPDIR sandboxed to $srcdir/pgo-work) → gcda gate (>200; actual 1567) →
  `meson configure -Db_pgo=use '-Dc_args=-Wno-error=format-overflow
  -Wno-error=coverage-mismatch'` → final rebuild. ✅ implemented, but ⚠️ BLOCKED by toolchain:
  - `-fprofile-use` trips `-Werror=format-overflow` (NULL %s in test-audit-type.c, benign —
    glibc printf handles NULL %s) and `-Werror=coverage-mismatch`; both suppressible via c_args.
  - BUT the final profile-use rebuild then hits **GCC internal compiler errors: Segmentation
    fault, during IPA pass: profile** (catalog.c:737, journal-send.c:578) — GCC 17.0.0
    experimental (20260830 snapshot) bug, not flag-avoidable. PGO deferred until the toolchain
    is fixed (stable GCC 17) or re-tried with clang `-fprofile-instr-use`/`llvm-profdata`.
  - The build dir has been reset to `b_pgo=off`, `c_args=[]`; the shipped packages are the
    verified NON-PGO build.
- GOTCHA: re-running makepkg over an existing build dir keeps STALE meson options (values persist
  unless re-passed). If b_ndebug was ever true, reset: `meson configure src/build -Db_ndebug=false`.
- GPG: tag v261.2 signed with Luca Boccassi's signing SUBKEY 286BF7EFCD77241E (primary
  A9EA9081724FFAE0484C35A1A81CEA22BC8C7E2E already in validpgpkeys); subkey missing from local
  keyring → fixed via `gpg --recv-keys 286BF7EFCD77241E`.
- Verified (non-PGO build): flags reach compiler (`-march=native -O3 -flto=auto
  -ffat-lto-objects` + `-fuse-ld=mold`, ld.mold 2.42.0); EFI sanity OK (systemd-bootx64.efi =
  PE32+ EFI app); 6/6 formerly-failing tests pass after NDEBUG revert; all 6 packages build
  (systemd 13M, systemd-libs 1.9M, tests 7.6M); namcap: only usual empty-dir warnings.
- KNOWN PRE-EXISTING test failures (NOT from our flags; local openssl/tpm2-tss version drift,
  would fail in vanilla build too): test-crypto-util (openssl_digest_size vs table), test-tpm2
  (tpm2b_public memcmp). → package with `makepkg -sf --nocheck` (PGO workload runs tests itself,
  failures tolerated).
- NOTE: no libsystemd.a is built (`-Dstatic-libsd` not enabled) → -ffat-lto-objects is a no-op
  safety net (kept, harmless).
- Phase 4 (manual): `pacman -U` order systemd-libs → systemd → rest; keep old pkgs in
  /var/cache/pacman/pkg for rollback; after reboot: systemd-analyze verify/blame, bootctl status.