# Contributing

Contributions should improve a recipe or the builder for a clean Arch
checkout. Do not submit upstream source clones, generated build trees,
package archives, downloaded signatures, local PGP key caches, or host-specific
logs and profiles.

## Recipe changes

1. Work in the relevant directory under `packages/`.
2. Keep upstream attribution, package-local license files, checksums, and
   source URLs intact.
3. Put necessary local patches, hooks, install files, and desktop assets next
   to the recipe. Explain non-obvious compatibility patches in the recipe.
   **A new local asset must survive `.gitignore`.** Nine recipes default-deny
   with a bare `*` (or `/*`) plus `!` negations, so a file added without a
   matching negation is silently dropped from the commit while still building
   locally — a clean checkout then fails with "was not found in the build
   directory" (2026-09-16). Add the negation in the same change and confirm
   with `git check-ignore -v <asset>` (no output = visible). Never let a recipe
   `.gitignore` match itself: an ignore file that hides itself cannot be
   committed, so on a clean checkout the rule is simply absent.
4. Update `config/packages.map` only when adding or relocating a recipe. The
   format is exactly two fields, `package-id|recipe-path`; the loader rejects
   any other field count, and the map is the only place that binds an ID to a
   path.
5. Update the appropriate group file and `config/dependencies.conf` only after
   verifying the dependency with the package metadata and a build-order
   reason.
6. Regenerate `.SRCINFO`:

   ```sh
   makepkg --printsrcinfo > .SRCINFO
   ```

### Source verification and signing keys

1. Never disable verification with `--skippgpcheck` or remove `#signed` from a
   source to work around a failure.
2. A tag can be signed by a signing **subkey**, while the upstream
   `validpgpkeys` array lists only the **primary** fingerprint. Compare
   `git verify-tag <tag>` (or `gpg --verify`) against the maintainer's
   published key:

   ```sh
   git verify-tag v42            # reports the key that made the signature
   gpg --list-keys --with-subkey-fingerprint <primary-fingerprint>
   ```

3. Confirm the reported fingerprint belongs to a UID and subkey published by
   the maintainer (for example `https://github.com/<maintainer>.gpg`), then add
   that fingerprint to `validpgpkeys` with a comment naming the role. Import
   the verified key locally so the build can check the signature.
4. If a fingerprint cannot be confirmed against a published key, stop and
   report the mismatch instead of trusting it.

## Optimization and trimming standard

Use the host's `makepkg.conf` as the default optimization policy. Do not
append hard-coded `-O3`, `-march`, `-mtune`, or other host-specific ISA flags
to a recipe. Use host-derived native settings only when they are already
provided by the build environment; an explicit target such as
`GSA_TARGET_CPU` must be intentional and documented.

Trim packaging to the maintained target:

- remove dead documentation, man pages, examples, tests, split packages,
  `depends`, `makedepends`, `_pick` paths, install paths, and check paths
  together;
- keep PGO-training test suites, kmod compressors, the GTK4 Vulkan renderer,
  Rust `profiler=true`, the `clang-opencl-headers` split, and CUPS/printing
  support when they are part of the maintained feature set;
- keep mold, LTO, and PGO phases aligned with the package's documented
  exception. For a Meson PGO transition, replace `c_args`, `cpp_args`,
  `c_link_args`, and `cpp_link_args` together, and exempt only
  `missing-profile` warnings during profile-use configure probes; and
- never use invalid `options` such as `!check` or `autodeps` to paper over a
  recipe problem.

After a trim, verify that disabled features have no remaining packaging
paths, removed tools are absent from `makedepends`, and the resulting
`.SRCINFO` matches the recipe. Do not remove a test or feature merely because
it is not installed at runtime if it trains PGO or protects a maintained
capability.

## Validation

Before submitting a change, run:

```sh
fish -n build-all.fish
fish build-all.fish --audit
fish build-all.fish --list
fish build-all.fish --dry-run --group git
fish build-all.fish --dry-run --group stable
fish build-all.fish --dry-run --group core
bash -n packages/path/to/PKGBUILD
makepkg --printsrcinfo --dir packages/path/to
bash tests/run-all.sh
```

`tests/run-all.sh` runs every fixture (discovered, so new ones need no edit
here); pass a substring to narrow it, e.g. `bash tests/run-all.sh recipe`. The
fixtures are non-mutating and cover the project configuration, recipe
registration and assets, source sharing, PGO transitions, and the scheduler's
resource profiles, so run the whole battery rather than only the file matching
the recipe you touched — the map-format change of 2026-09-17 was caught by two
unrelated recipe fixtures.

Do not use a full real rebuild as a syntax check. For changes to scheduling,
installation, cleanup, source sharing, or signals, add or run a focused
fixture with fake build/install commands and verify exit status, logs, and
child-process cleanup.

## Topology and ABI coupling

Keep ABI-coupled packages in the same documented batch. LLVM consumers,
Rust, Qt private-API modules, ROCm, and the system replacement packages are
not ordinary independent leaf updates. Record the reason for a new edge in
`docs/NOTE.md` and update the maintainer rules in `docs/MEMORY.md` when the
operational contract changes.
