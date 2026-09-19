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

The old automatic output reported `-j` per lane, so `2 lanes × -j6` could
represent twelve normal job slots while each lane independently received the
same memory allowance. The profiles now budget normal jobs globally, and each
profile scales all three inputs together (`threads` = `nproc`, `memory_gib` =
`MemAvailable` unless overridden):

```
normal_memory         = max(1, memory_gib - RESERVED_MEMORY_GIB)
normal_memory_per_job = MEMORY_PER_JOB_GIB * INTENSITY_NORMAL_MEMORY_FACTOR
normal_job_budget     = max(1, floor(normal_memory / normal_memory_per_job))

lanes (auto)          = max(1, min(INTENSITY_LANE_CAP,
                                   floor(threads / INTENSITY_CPU_PER_LANE),
                                   floor(memory_gib / INTENSITY_MEMORY_PER_LANE),
                                   normal_job_budget, package_count))
lane_jobs (auto)      = max(1, min(floor(threads / lanes),
                                   floor(normal_job_budget / lanes)))

core_memory_per_job   = CORE_MEMORY_PER_JOB_GIB * INTENSITY_CORE_MEMORY_FACTOR
core_jobs             = max(1, min(threads, floor(normal_memory / core_memory_per_job)))
```

The `INTENSITY_*` constants live in `configure_intensity` in `build-all.fish`;
the three GiB baselines (`memory_per_job_gib`, `core_memory_per_job_gib`,
`reserved_memory_gib`) are in `config/build-defaults.conf`. Because every term
is host-derived, do not predict the plan — read the line the builder prints
(`parallelism: N CPU threads, M GiB available, intensity …, K lane(s),
normal -j…, core -j…`). The same profile on a 24-thread/29-GiB workstation and
on an 8-thread/16-GiB laptop yields different lane and job counts by design.
The intent is to raise independent package throughput without multiplying the
memory allowance by the lane count.

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

That last point separates two things that are easy to conflate:

* **A recipe is portable.** No recipe here pins one machine's ISA. Every
  native-flag injection is conditional on the environment not already setting a
  target, and says so (`niri-spicy-git`, `rust-bindgen-git`,
  `xwayland-satellite-git`); no recipe narrows `arch` below `x86_64`; and the
  kernel's `_processor_opt` is a knob with `zen4` and `generic` alternatives
  beside its `native` default. Copy those patterns rather than adding a new
  hard-coded `-march`.
* **An artifact is not.** `makepkg.conf` supplies `-march=native`, so a package
  built from this tree is tuned to the building machine and is not a
  redistributable binary. Hard-coding a target in a recipe would only move that
  problem from the build host to the reader.

The set is maintained against AMD laptop hardware (see `README.md`), and the
hardware-support trims are validated on one such model. The recipes build on
any Arch x86_64 host; it is the trims that a second, non-AMD model would be
needed to re-verify.

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
