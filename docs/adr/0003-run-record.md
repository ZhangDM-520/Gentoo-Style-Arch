# Run record: builder-internal data, default-on machine block

Plan and outcome knowledge was re-derived in three places (dispatch
accounting, `_RL_*` globals, the summary) and two hand-maintained
continuation-flag mirrors drifted repeatedly (including the 2026-09-26
failed-package drop). We decided: one **run record** — plan + per-package
outcome rows + continuation — computed once inside the builder and rendered
three ways (streaming dashboard, prose, and an additive machine-checkable
block on stdout, default-on, also emitted on the interrupt path). The record
is not persisted to `.state/` (that would blur the Builder/Runtime-state
split), and there is no opt-in flag (unassertable behaviour stays
unassertable). Continuation arguments come from one flag-rule table with an
explicit not-mirrored list; ambient env knobs (`GSA_TARGET_CPU`,
`GSA_STATE_DIR`) are warned about, not mirrored.

## Considered options

- Persisting the record under `.state/`.
- Opt-in machine output via a flag.
- Splitting outcome and presentation into two modules — unstable seam;
  presentation would own continuation-flag semantics again.

## Consequences

Prose fixtures migrate to the record except one rendering test; the rc-99
deferral becomes a named outcome, amending the "failure stops dispatches"
invariant in `docs/architecture.md`; interrupted runs finally emit a summary
and continuation.
