# Architecture

Gentoo_Style_Arch has four deliberately separate modules:

1. **Recipes** under `packages/<category>/<package-id>/` are the package-facing
   interface: a `PKGBUILD`, its `.SRCINFO`, the local files `makepkg` needs
   (patches, hooks, install scripts, desktop/asset files), the package's
   upstream attribution and license material (`LICENSE`, `LICENSES/`,
   `REUSE.toml` where upstream provides it), and optional maintenance metadata
   (`.nvchecker.toml`, `BUILDING`). A new local asset must survive the recipe's
   ignore rules — most recipes default-deny, see `CONTRIBUTING.md`.
2. **Topology** under `config/` maps package IDs to recipe paths
   (`packages.map`, exactly `package-id|recipe-path` per record), defines
   logical groups (`groups/{git,stable,core,misc,third-party,app}.list`), and
   records local dependency edges (`dependencies.conf`). It is declarative so
   maintainers can review graph changes without editing scheduler
   implementation.
3. **Builder** in `build-all.fish` is the operational interface. It resolves
   package IDs, expands and sorts dependencies, dispatches isolated lanes,
   serializes pacman transactions, owns the interactive dashboard, and
   reports failures through per-package logs.
4. **Runtime state** is split in two by who owns it. Under `.state/` (or
   `GSA_STATE_DIR`) the builder keeps its own state: `logs/`, the pacman
   mutex, and the lane result files. `makepkg` state — source mirrors, `src/`,
   `pkg/`, and package archives — lands **beside each recipe**, because
   `SRCDEST`/`PKGDEST` default to `$startdir`. Both classes are ignored by Git
   and are absent from a clean checkout.

The source-sharing seam is intentionally between a recipe's VCS source name
and its runtime mirror. A missing canonical mirror is valid on a clean
checkout; the first build populates it. A populated non-Git directory is never
silently replaced.

The scheduler's interface includes more than its flags: package selection is
mandatory, dependency order is meaningful, `--install` installs before a
dependent build starts, core packages run alone, and failures stop new
dispatches while draining existing lanes. These invariants are part of the
maintainer contract.

The install path also owns one payload invariant: a package built from a
recipe that instruments with `-fprofile-generate` is refused if its archive
still carries an absolute `.gcda` destination. The verification *code*
belongs in one module (`lib/pgo.sh`), because verification copy-pasted into
individual recipes is the failure mode that produced two separate recurrences
in 2026-09-16 and 2026-09-19; the per-recipe *calls* remain, because the
`readelf`/symbol predicate is only reachable before makepkg strips. The
builder's payload verification is the fail-closed whole-set backstop, and it
must hold for every PGO recipe, including ones that have not been written
yet. The check sits on the runtime state seam as well: it is the last point
before files are written into `/usr`.
