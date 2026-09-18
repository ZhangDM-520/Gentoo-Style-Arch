# Copilot instructions — Gentoo_Style_Arch

A curated Arch Linux package set: ~126 `PKGBUILD` recipe directories plus an
automatic-parallelism build scheduler. The repo holds recipes and topology
only — never upstream sources, package archives, downloaded signatures, PGP
caches, or build output.

## Read before changing anything

| File | Role |
| --- | --- |
| `docs/MEMORY.md` | The operational contract: golden rules, current stack shape, pitfall digest. Rules cite real breakage. |
| `docs/NOTE.md` | Chronological incident journal, one `## YYYY-MM-DD` section per incident. Opens with a naming-history table — entries predating 2026-09-15 use `.Static/.Heavy/.Heavyweight/.3rdP` paths and `static/heavy/critical/rocm` group names. |
| `docs/build-guide.md` | Install modes, `--cleanup`/`--nuclear`, sudo-keepalive behaviour, PGO/Meson reconfigure procedure. |
| `docs/architecture.md` | The four-module split and the scheduler's implicit invariants. |
| `CONTRIBUTING.md` | Recipe-change checklist, trimming standard, source-verification rules. |
| `docs/portability.md` | Intensity profiles, `GSA_*` overrides, CPU-tuning policy. |

## Commands

Shells are split deliberately: **the builder and its CLI are fish**
(`build-all.fish`); **the fixtures are bash**. Tool-call shells here are bash,
so bash syntax is fine inside a call — the hazard is crossing the boundary.
A command handed to the user, or `!cmd`, runs under the login shell (fish
4.9.3), so wrap ad-hoc one-liners in `bash -c '...'`. In a fish context: no
`export`, no `[[ ]]`, arrays are 1-indexed, and an **unmatched glob is a fatal
error that `2>/dev/null` does not suppress** — use `find -name`. Host aliases
also change what a bare name does (`ls` → `eza -al`, `grep --color=auto`), so
never assume a bare `ls`/`grep` flag works there.

```sh
# Inspect (always do this before building; all four are read-only)
fish build-all.fish --help
fish build-all.fish --list
fish build-all.fish --audit          # needs ripgrep
fish build-all.fish --dry-run --group git

# Fixture battery — the project's test suite
bash tests/run-all.sh                # all fixtures, alphabetically
bash tests/run-all.sh recipe         # substring filter, e.g. 'recipe', 'pgo'
bash tests/recipe-sources.sh         # run one fixture directly
```

`tests/run-all.sh` discovers `tests/*.sh` and needs no edit for a new fixture.
Fixtures are bash scripts that exit non-zero on failure, are non-mutating
(they build scratch trees under `$TMPDIR`, diff committed metadata, and assert
on builder output), and print a reason to stderr. **Run the whole battery, not
just the fixture near your change** — a `config/packages.map` format change
was once caught by an unrelated recipe fixture.

Validation for a change:

```sh
fish -n build-all.fish                                  # parse the scheduler
bash -n packages/<category>/<pkg>/PKGBUILD              # parse a recipe
makepkg --printsrcinfo --dir packages/<category>/<pkg> > packages/<category>/<pkg>/.SRCINFO
bash tests/run-all.sh
```

Never use a real rebuild as a syntax check. For changes to scheduling,
installation, cleanup, source sharing, or signals, add a focused fixture with
fake build/install commands that asserts exit status, logs, and child-process
cleanup. There is no CI workflow and no compilable language here — fixtures and
`makepkg` are the entire verification surface.

`tools/` is deliberately outside the battery: host-side diagnostics that are
heavy and mutating (currently `tools/texlive-split-probe.sh`, a PSI/D-state/
IO sampler). Its contract is still fixture-pinned by `tests/probe-watchdog.sh`
at a reduced scale — a watch mode must never kill the process it samples, and
an abort must leave the sample log behind.

Agent shells inject git config (`safe.bareRepository=explicit`), which breaks
bare-repo and makepkg VCS operations. Prefix those with `GIT_CONFIG_COUNT=0`
(the committed fixtures that shell out to `makepkg` already do).

### Selection semantics

A bare package name is **not** a leaf build: it expands the whole transitive
dependency chain, so `build-all.fish niri-spicy-git` also rebuilds llvm, rust,
mesa and everything between. `--no-deps` is the only way to rebuild one package
whose installed dependencies are known current.

```sh
fish build-all.fish --no-deps niri-spicy-git   # leaf rebuild only
fish build-all.fish -g git 22..38              # index range from --list
fish build-all.fish -s --install -g git        # resume: skip already-built archives
```

`-i` installs each package before its dependents compile (core selection turns
it on automatically). `-ia`/`--installall` is the single-transaction escape
hatch — it installs after everything is built, so it must never stand in for
`-i` on a set whose members depend on each other. `-ccc`/`--nuclear` and
`--link-sources` ask for confirmation; `--link-sources` must be run as the
build user, not under a root supervisor. `--audit` and `--link-sources` are the
only modes needing `rg`/`git`. `--allow-broken-rustc` bypasses the rustc
sanity probe that guards against LLVM-snapshot ABI skew — it is an escape hatch
for runs that compile no Rust, not a way past a real ABI mismatch.

## Architecture

Four modules, deliberately separated (`docs/architecture.md`):

1. **Recipes** — `packages/<category>/<package-id>/` with `PKGBUILD`,
   committed `.SRCINFO`, local patches/hooks/install scripts/desktop assets,
   upstream license material, and optional `.nvchecker.toml` / `BUILDING`.
2. **Topology** — declarative, under `config/`. `packages.map` binds a package
   ID to a recipe path and is *the only* place that does so; the loader
   rejects any record that is not exactly `package-id|recipe-path`.
   `groups/{git,stable,core,misc,third-party}.list` define logical groups, and
   `dependencies.conf` records local build-order edges as
   `package-id:dependency-id,dependency-id` (a lone `package-id:` is a
   deliberate no-edge record). `build-defaults.conf` holds the GiB-per-job
   baselines (`memory_per_job_gib`, `core_memory_per_job_gib`,
   `reserved_memory_gib`) and the default `lanes`/`jobs`/`intensity`/`state_dir`.
   Only those five group names are ever read, so any other file in
   `config/groups/` is unreachable state that silently goes stale —
   `tests/project-config.sh` fails on it.
3. **Builder** — `build-all.fish` resolves IDs, expands and topologically sorts
   dependencies, dispatches isolated fish child processes as lanes, serializes
   pacman transactions, owns the dashboard, and reports per-package logs.
4. **Runtime state** — split by owner. `.state/` (or `GSA_STATE_DIR`) holds
   builder-owned logs, lane results, and the pacman mutex. makepkg's own
   mirrors, `src/`, `pkg/`, and archives land **beside each recipe**
   (`SRCDEST`/`PKGDEST` default to `$startdir`). Both are Git-ignored.

Consequences worth internalising:

- The loader validates the map, all five group files, the dependency graph, and
  a complete topological sort on **every** invocation. One malformed record
  breaks `--list`, `--help`, and every build, not just the affected package.
- Do not infer build order from directory names. `core` is a logical group that
  deliberately overlaps `packages/stable/` and `packages/git/` recipes whose
  ABI must move as one batch.
- Scheduler invariants are part of the maintainer contract: selection is
  mandatory (a bare invocation never starts a rebuild), `-i` installs each
  package before its dependents compile, core packages run alone with a
  separate memory-aware job budget, and a failure stops new dispatches while
  draining existing lanes. A run whose dispatch stopped early must exit
  non-zero.
- The source-sharing seam is between a recipe's VCS source name and its runtime
  mirror. A missing canonical mirror is valid on a clean checkout — the first
  build populates it. A populated non-Git directory is never silently
  replaced. Mirrors and symlinks are runtime state and must stay ignored.
- Resource planning is entirely host-derived; the profiles and formulas are in
  `docs/portability.md`. Never predict a plan — read the `parallelism:` line the
  builder prints. `--lanes`/`--jobs` override `--intensity`.

## Conventions

**Recipe registration.** Adding a recipe means: put it under the physical
category, add one `packages.map` record, add the ID to the right group
file(s), and add a `dependencies.conf` edge only after verifying the dependency
against package metadata and a build-order reason. Every workspace `pkgname`
must also appear in the host's `/etc/pacman.conf` `IgnorePkg` closure —
cumulative repeated `IgnorePkg =` lines, all inside `[options]` (a line inside
a repo section is silently dropped). Verify by unioning `pkgbase`+`pkgname[]`
from every recipe and diffing against `pacman-conf IgnorePkg | sort -u` with
`comm -23`; empty output means covered. A new edge's reason belongs in
`docs/NOTE.md`, and a changed operational contract in `docs/MEMORY.md`.

**Meson staleness.** Re-running `meson setup` over an existing build directory
keeps stale option values. After *any* `meson-git` upgrade, purge every build
dir whose `meson-info.json` version differs before rebuilding — build dirs sit
at arbitrary depths, so a `maxdepth` sweep misses them.

**Local assets and ignore rules.** Nine recipes default-deny with a bare `*`
plus `!` negations, so a new file without a matching negation is silently
dropped from the commit while still building locally — a clean checkout then
fails with "was not found in the build directory". Add the negation in the same
change and confirm with `git check-ignore -v <asset>` (no output = visible).
Never let a recipe `.gitignore` match itself. `tests/recipe-sources.sh` walks
every recipe and enforces this repo-wide. Preserve package-local attribution
and licence material (`LICENSE`, `LICENSES/`, `REUSE.toml`): the root MIT
licence covers the scheduler and project docs only, and does not relicense
recipes or bundled upstream material.

**Concurrency.** Check for running `makepkg` processes and for runtime log
mtime changes before rebuilding a package that may already be in flight, and
never run two heavy builds at once — the failure mode is an OOM, not a queue.

**Provides discipline.** Toolchain `-git` packages carry *versioned* provides
(`provides=("meson=${pkgver}")`) — an unversioned provide cannot satisfy a
`>=N` makedepend and pacman silently falls back to the conflicting repo
package. Every library-shipping package declares *bare* soname provides
(`libfoo.so`); makepkg then auto-versions them from the packaged ELF soname.
Request a capability through its virtual (`java-runtime`, `java-environment`,
`libgl`), never through one concrete provider — Arch's OpenJDK packages are
mutually exclusive, so naming `jre-openjdk` can make pacman demand removal of a
package the dependency graph needs. Provides live in `.PKGINFO`, so a provides
change requires a real rebuild (`makepkg -Rf` only repackages). Verify with
`tar -xOf pkg.tar.zst .PKGINFO | grep provides`.

**Optimization policy.** The host's `makepkg.conf` is the default. Do not
append hard-coded `-O3`, `-march`, or `-mtune` to a recipe; host-derived native
settings are fine, and an explicit `GSA_TARGET_CPU` must be intentional and
documented. `mold-git` does not provide `mold` for depend resolution — the
house idiom is a runtime `command -v mold` guard. Meson recipes use
`arch-meson`. LTO/PGO phases, the Meson reconfigure rules that must replace
both compiler and linker argument caches, and the symbol-level
instrumentation check (`readelf -sW <lib> | grep -E '__gcov_|__llvm_profile'`
must be empty) are documented in `docs/build-guide.md` and `MEMORY.md` §4/§6.

**Trimming.** Remove dead docs, man pages, tests, split packages, `depends`,
`makedepends`, `_pick` paths, and install/check paths *together*; a feature
disabled in `build()` must not leave a packaging step expecting its output.
Keep PGO-training suites, kmod compressors, the GTK4 Vulkan renderer, Rust
`profiler=true`, and CUPS/printing support. `!check` and `autodeps` are invalid
`options` entries in pacman 7.x and are rejected by lint. After a trim, re-grep
for removed tools in remaining `makedepends` and regenerate `.SRCINFO`.
Purged system packages (po4a, python-sphinx, python-myst-parser, cuda, gcc15, …)
must not be reintroduced via `makedepends` — makepkg reinstalls them silently.

**Source verification.** Never pass `--skippgpcheck` and never drop `#signed`.
A tag may be signed by a *subkey* while upstream `validpgpkeys` lists only the
primary fingerprint: run `git verify-tag <tag>`, confirm the reported
fingerprint against the maintainer's published key, then add it with a comment
naming the role. If it cannot be confirmed against a published key, stop and
report the mismatch.

**Documentation discipline.** `docs/MEMORY.md` holds rules and current state;
`docs/NOTE.md` holds the history. Every non-trivial packaging or scheduler
change earns a dated `NOTE.md` section: symptom → root cause → fix →
validation → durable rule. Update `MEMORY.md`'s maintainer rules when an
operational contract changes. Keep private paths, credentials, host logs, and
generated artifacts out of both.

**ABI-coupled batches.** LLVM snapshots have no stable C++ ABI: after an
`llvm-git` bump, rebuild Rust, Mesa, SPIR-V, libclc, OpenShadingLanguage and
the other consumers in the same pass (`rust-git` cannot rebuild itself — the
bootstrap *is* the broken rustc). Qt private-API-coupled modules must move
together too. `git verify`/version strings are not evidence — verify the
installed ABI, provides, and dependency closure.
