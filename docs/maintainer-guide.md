# Maintainer guide

## Adding a recipe

Place a clean recipe directory under the physical category that best describes
it, add an entry to `config/packages.map`, and add its package ID to one or
more logical group files. If it has local build-order coupling, add one
record to `config/dependencies.conf`. The map is the only place that binds a
package ID to a filesystem path.

Keep `.SRCINFO` synchronized:

```sh
makepkg --printsrcinfo --dir packages/<category>/<package> \
  > packages/<category>/<package>/.SRCINFO
```

Do not copy the upstream Git checkout into the project. A VCS `source=`
entry, a pinned tag/commit, and a local patch are enough to reproduce the
recipe.

`b2sums` is a flat list with one entry per source, so it can only match one
combination of a recipe's knobs. Keep the source set knob-independent where you
can. Where you cannot, make the recipe refuse the combinations it cannot serve
*and* keep the sum-generation path runnable — `packages/misc/linux-cachyos`
does both, and `tests/kernel-recipes.sh` pins it. Never grow `b2sums` with
per-knob `b2sums+=(…)` appends next to each `source+=(…)`: `updpkgsums`
rewrites the whole assignment as a literal on every version bump, so the
appends double-count at the first bump.

## Updating coupled stacks

LLVM snapshots have no stable C++ ABI. Rebuild Rust, Mesa, SPIR-V, libclc,
OpenShadingLanguage, and other consumers in the same documented pass after a
snapshot change. Qt private APIs similarly require the matching Qt module
batch. ROCm and stock-name replacement packages may require immediate
installation before the next consumer starts. Verify the installed ABI,
provides, and dependency closure rather than trusting version strings alone.

## Documentation history

`docs/MEMORY.md` is the compact operational contract. `docs/NOTE.md` is the
chronological incident journal retained from the original workspace. Add a
dated note for every non-trivial packaging or scheduler change:

1. symptom;
2. root cause;
3. fix;
4. validation;
5. durable rule for the next maintainer.

Keep private paths, credentials, host logs, and generated artifacts out of
both files.
