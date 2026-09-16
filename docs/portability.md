# Portability and machine adaptation

The recipes are Arch/x86_64-oriented, but the builder no longer assumes the
author's CPU count, memory size, home path, or Zen 5 target.

## Parallelism

`--intensity xhigh` is the default automatic profile. It uses CPU threads and
available memory to choose bounded lanes and a global normal-lane job budget.
The named profiles are:

- `low`: one conservative lane with maximum headroom;
- `medium`: balanced baseline;
- `high`: more lanes and a lower per-job memory estimate;
- `xhigh`: aggressive default;
- `max`: highest automatic utilization, with the greatest OOM risk.

A core package receives a separate memory-aware job count and runs alone. The
resolved profile and plan are printed before dispatch.

Use explicit overrides when benchmarking or when a machine has unusual
resource limits:

```sh
fish build-all.fish --group git --lanes 1 --jobs 4
fish build-all.fish --group git --intensity medium
GSA_LANES=2 GSA_JOBS=1 fish build-all.fish --group git
GSA_INTENSITY=low fish build-all.fish --group git
```

`GSA_CPU_THREADS` and `GSA_MEMORY_GIB` override resource discovery for a
container or a deterministic scheduler fixture. Leave them unset on a normal
host. Explicit `--lanes` and `--jobs` values override the selected profile.

The numeric defaults in `config/build-defaults.conf` are the medium-profile
GiB-per-job baseline. Change them in a local branch or use an explicit
intensity/CLI override; do not encode one host's RAM size in a recipe.

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
