# Gentoo_Style_Arch

Gentoo_Style_Arch is a curated Arch Linux package set for rebuilding a
large, dependency-coupled desktop and toolchain stack from `PKGBUILD`
recipes. It contains the recipes and the scheduler; it does **not** vendor
upstream source trees, package archives, build outputs, or downloaded
signatures.

The project is intentionally Arch-specific. Every `PKGBUILD` is executable
shell code and may fetch and build software with the privileges and network
access available to `makepkg`. Read the recipe and the security guidance
before building or installing anything.

## What is included

The current set has 125 recipes:

| Group | Count | Purpose |
| --- | ---: | --- |
| `git` | 55 | Top-level development and rolling packages |
| `stable` | 29 | Stock-name packages synchronized with Arch repositories |
| `core` | 41 | Heavy, ABI-coupled, source-heavy, and ROCm packages |
| `misc` | 1 | Optional CachyOS kernel recipe |
| `third-party` | 2 | Additional application recipes |

`core` is a logical build group and overlaps some physically stable recipes.
The package map, group membership, and local dependency graph are declarative
files under `config/`; do not infer build order from directory names.

## Fresh checkout

On an Arch-based system, install the normal packaging tools first:

```sh
sudo pacman -S --needed base-devel fish git
```

Then inspect the project before building:

```sh
fish build-all.fish --help
fish build-all.fish --list
fish build-all.fish --audit
fish build-all.fish --dry-run --group git
```

Build a selected group or package. Selection is mandatory; a bare invocation
never starts an unattended full rebuild:

```sh
fish build-all.fish --group git
fish build-all.fish --group core
fish build-all.fish --no-deps niri-spicy-git
```

Use `--install` only when the immediately installed package state is desired.
Unprivileged runs use `sudo` for each transaction; long runs are generally more
reliable when the supervisor is started as:

```sh
sudo fish build-all.fish --group core
```

The builder still runs `makepkg` as the invoking user in root-supervisor mode.
See `docs/build-guide.md` before using installation or cleanup modes.

## Adaptive parallelism

The default `--intensity xhigh` profile derives concurrency from available CPU
threads and `MemAvailable`. It budgets normal-lane jobs globally, rather than
granting every lane an independent memory allowance. Heavy `core` recipes run
alone with a separate memory-aware job limit.

Choose a named effort profile when automatic scheduling should be less or more
aggressive:

| Profile | Intent |
| --- | --- |
| `low` | One conservative lane; maximize memory headroom |
| `medium` | Balanced baseline for long-running hosts |
| `high` | More independent lanes and lower per-job memory budget |
| `xhigh` | Default; aggressive utilization with bounded automatic lanes |
| `max` | Highest automatic utilization; use only when OOM risk is acceptable |

Override the plan explicitly when needed:

```sh
fish build-all.fish --group git --intensity medium
fish build-all.fish --group git --lanes 1 --jobs 2
GSA_INTENSITY=low fish build-all.fish --group git
```

`GSA_CPU_THREADS` and `GSA_MEMORY_GIB` are also available for constrained
containers and deterministic scheduler fixtures. Normally they should be
left unset so the host's `/proc` and `nproc` values are used. Explicit
`--lanes` and `--jobs` values take precedence over the profile.

Runtime logs, lane results, and locks are written under
`.state/` by default and are ignored by Git. makepkg source trees and package
archives remain beside their recipe unless your makepkg configuration directs
them elsewhere; those classes are also ignored. Set `GSA_STATE_DIR` to keep
builder state outside the checkout.

## Source policy

Remote Git repositories, release archives, PGP key caches, and build trees are
deliberately absent. A clean checkout fetches them through the `source=()`
entries in each recipe. Local patches, hooks, install scripts, desktop files,
configuration inputs, licenses, and `.SRCINFO` files are retained because
they are part of the packaging work.

`--link-sources` can deduplicate compatible VCS mirrors after sources have
been fetched. Shared mirrors are runtime state and must not be committed.

## Licensing

`LICENSE` applies only to the original scheduler and project documentation.
Recipes contain upstream/AUR material with their own copyright, license,
maintainer, checksum, and source terms. Preserve the package-local metadata
when redistributing or modifying a recipe.

See:

- `docs/build-guide.md` for operations and cleanup;
- `docs/portability.md` for CPU, RAM, ISA, and profile controls;
- `docs/maintainer-guide.md` for recipe and dependency maintenance;
- `docs/MEMORY.md` and `docs/NOTE.md` for the retained operational history;
- `SECURITY.md` before running a new or changed recipe.
