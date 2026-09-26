# Topology: one record per package

Topology facts were split across four syntaxes (`packages.map`,
`groups/*.list`, `dependencies.conf`, `build-defaults.conf`), so stating one
fact about a package took up to four edits and coupled-stack changes
scattered. We decided: one declarative record per package in
`config/topology.conf` (`id|path|groups|edges` with optional coupled-batch
tags), explicit id→path binding retained even though ids equal directory
basenames today, batch membership as per-package `must`/`should` tags with the
reverse closure computed by the builder, and a record that always exists
(edges may be empty — the old map↔deps check was one-directional and four
packages had no dep record).

## Considered options

- Per-package records beside the recipes — best edit locality, but 128 reads
  per invocation and fixture synthesis spread across N dirs.
- Keeping four files plus a synthesized canonical view — two truths drift by
  construction.
- A separate `batches.conf` relation file — a third syntax in the same module.

## Consequences

The loader keeps one reader/validator; the six-group roster is declared once;
`docs/architecture.md`'s Topology description and the
maintainer/CONTRIBUTING checklists collapse accordingly; the hard-coded
llvm↔rust refusal gate generalizes into a batch gate driven by the tags.
