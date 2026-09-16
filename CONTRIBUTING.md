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
4. Update `config/packages.map` only when adding or relocating a recipe.
5. Update the appropriate group file and `config/dependencies.conf` only after
   verifying the dependency with the package metadata and a build-order
   reason.
6. Regenerate `.SRCINFO`:

   ```sh
   makepkg --printsrcinfo > .SRCINFO
   ```

## Validation

Before submitting a change, run:

```sh
fish -n build-all.fish
bash -n packages/path/to/PKGBUILD
makepkg --printsrcinfo --dir packages/path/to
fish build-all.fish --audit
fish build-all.fish --list
fish build-all.fish --dry-run --group git
fish build-all.fish --dry-run --group stable
fish build-all.fish --dry-run --group core
```

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
