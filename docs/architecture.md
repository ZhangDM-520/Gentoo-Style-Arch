# Architecture

Gentoo_Style_Arch has four deliberately separate modules:

1. **Recipes** under `packages/` are the package-facing interface: a
   `PKGBUILD`, its `.SRCINFO`, and only the local files needed by `makepkg`.
2. **Topology** under `config/` maps stable package IDs to recipe paths,
   defines logical groups, and records local dependency edges. It is
   declarative so maintainers can review graph changes without editing
   scheduler implementation.
3. **Builder** in `build-all.fish` is the operational interface. It resolves
   package IDs, expands and sorts dependencies, dispatches isolated lanes,
   serializes pacman transactions, owns the interactive dashboard, and
   reports failures through per-package logs.
4. **Runtime state** under `.state/` by default (or `GSA_STATE_DIR`) contains
   logs, source mirrors, package outputs, lane results, and locks. It is not
   part of the source interface and is ignored by Git.

The source-sharing seam is intentionally between a recipe's VCS source name
and its runtime mirror. A missing canonical mirror is valid on a clean
checkout; the first build populates it. A populated non-Git directory is never
silently replaced.

The scheduler's interface includes more than its flags: package selection is
mandatory, dependency order is meaningful, `--install` installs before a
dependent build starts, core packages run alone, and failures stop new
dispatches while draining existing lanes. These invariants are part of the
maintainer contract.
