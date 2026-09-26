# PGO verification: one shared gate, per-recipe calls, both seams stay

The seven per-recipe copies of `verify_no_profile_instrumentation` had already
drifted (mold-git carries stricter predicates) and the mandated copy-paste was
itself the recurrence engine of the 2026-09-20 instrumented-archive incident.
We decided: one shared implementation (`lib/pgo.sh`) sourced from each recipe
via a `$startdir`-relative path, with **fatal-gate semantics** (`exit 1` on
failure) because bash's mid-function call-status discard can silently pass a
failed check; per-recipe **calls** remain because the symbol predicate is only
reachable before makepkg strips; the builder's `verify_pgo_payload` stays as
the fail-closed, whole-set backstop (strings-only, post-strip).

## Considered options

- Builder-exported functions injected into the makepkg environment — breaks
  `makepkg` from a clean checkout (unrecorded state).
- Checksum-pinned copies with no runtime sharing — kills drift but leaves
  seven edit sites and the code-shape lint.
- Moving verification entirely into the builder — provably weaker: symbol
  leaks are invisible post-strip.

## Consequences

`docs/architecture.md`'s stance is amended (verification *code* belongs in one
module; per-recipe *calls* remain); `CONTRIBUTING.md`'s per-recipe mandate
becomes "call the shared gate"; the `|| return 1` call-site lint is deleted.
