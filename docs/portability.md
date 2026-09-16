# Portability and machine adaptation

The recipes are Arch/x86_64-oriented, but the builder no longer assumes the
author's CPU count, memory size, home path, or Zen 5 target.

## Parallelism

`--lanes auto` uses CPU threads and available memory to choose a conservative
number of independent lanes. `--jobs auto` divides the same resources between
normal lanes. A core package receives a separate memory-aware job count and
runs alone. The resolved plan is printed before dispatch.

Use explicit overrides when benchmarking or when a machine has unusual
resource limits:

```sh
fish build-all.fish --group git --lanes 1 --jobs 4
GSA_LANES=2 GSA_JOBS=1 fish build-all.fish --group git
```

`GSA_CPU_THREADS` and `GSA_MEMORY_GIB` override resource discovery for a
container or a deterministic scheduler fixture. Leave them unset on a normal
host.

The numeric defaults in `config/build-defaults.conf` are conservative
GiB-per-job budgets. Change them in a local branch or use explicit CLI
overrides; do not encode one host's RAM size in a recipe.

The builder exports `GSA_BUILD_JOBS` to each lane and updates `MAKEFLAGS` and
`NINJAFLAGS` without discarding the caller's other flags. Recipes that invoke
`nproc` directly should use this value.

## CPU optimization

The default optimization policy comes from the host's `makepkg.conf`. Set
`GSA_TARGET_CPU` only when intentionally producing packages for a known
target CPU; the Rust snapshot recipe uses it instead of a hard-coded
`znver5`. Native optimizations in selected recipes are host-derived and
should not be redistributed as portable binary artifacts.

## Host-specific profiles

The CachyOS kernel recipe keeps its baseline `config` because it is a
required packaging input, but AutoFDO and Propeller profiles are disabled by
default. Generate matching profiles on the target host, place them beside
the recipe, and opt in through the documented recipe variables only for that
host. Generated profiles are ignored by Git.

## Architecture limits

Some recipes are intentionally limited by upstream or package design to
`x86_64`, AMD ROCm, or a specific Arch ABI. Those constraints belong in the
recipe's `arch`, dependencies, and documentation; the scheduler should not
pretend that a non-supported architecture is portable.
