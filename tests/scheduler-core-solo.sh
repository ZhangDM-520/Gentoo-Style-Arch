#!/usr/bin/env bash
set -euo pipefail

# "Core runs solo" is a scheduler invariant the docs state three times
# (README, docs/architecture.md, docs/MEMORY.md): a core member builds alone
# with its own, larger job budget, because its full -j is the memory peak the
# guard exists for. Nothing asserted it. `tests/scheduler-intensity.sh` pins
# the *plan numbers* (the parallelism: line) but not that the dispatcher
# actually withholds other work while a core member runs, and
# `GSA_CPU_THREADS`/`GSA_MEMORY_GIB` only pin the formula that prints them.
#
# The stub makepkg timestamps its own lifetime, so the assertion is about
# observed concurrency rather than about the shape of the code. The invariant
# has two directions, and they need separate scenarios because each passes
# while the other's guard is removed:
#
#   Phase A — the core member is not *dispatched* into a busy pool:
#     1. BASELINE — at least two non-core packages overlapped. Without this,
#        "the core member never overlapped" could be true merely because
#        nothing in the run ever overlapped, which is how such an assertion
#        rots. The durations are staggered so lanes keep freeing while long
#        packages run; with uniform ones every lane frees in the same poll and
#        the guard is never reached.
#     2. the core member had to wait for other work (held back), and no
#        non-core package's interval overlaps the core member's;
#     3. the core member's lane carried the core job budget, and every
#        non-core package's lane carried the normal one — in
#        MAKEFLAGS/GSA_BUILD_JOBS, through the same stub variables the other
#        fixtures use.
#
#   Phase B — nothing is *started* alongside a running core member: with two
#     lanes and the core member first, the second lane stays idle although a
#     normal package is ready.
#
# Both phases were falsified before they were trusted: disabling the solo
# fallback fails phase A, removing the running-core guard fails phase B, and
# handing core the normal budget fails phase A's budget assertion.
#
# The core member is deliberately mid-list in phase A, after three normal
# packages that fill every lane, so the "wait until all lanes are idle" path is
# exercised rather than the trivial case where core happens to be dispatched
# first.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-core-solo.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/config/groups" "$fixture/packages" "$fixture/bin"
cp "$root/build-all.fish" "$fixture/build-all.fish"

cat >"$fixture/config/build-defaults.conf" <<'EOF'
lanes=auto
jobs=auto
intensity=xhigh
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
: >"$fixture/config/dependencies.conf"
for group in git stable core misc third-party app; do
    : >"$fixture/config/groups/$group.list"
done

# n1..n4 are ordinary members; c1 is a core member that is also in git, which
# mirrors the real vocabulary (autofdo-git and libclc-git are packages/git
# recipes that are core members).
normal_ids=(n1 n2 n3 n4)
core_id=c1
selection=(n1 n2 n3 c1 n4)
for id in "${normal_ids[@]}" "$core_id"; do
    mkdir -p "$fixture/packages/$id"
    printf 'pkgname=%s\npkgver=1.0.0\npkgrel=1\narch=(any)\n' "$id" \
        >"$fixture/packages/$id/PKGBUILD"
    printf '%s|packages/%s\n' "$id" "$id" >>"$fixture/config/packages.map"
    printf '%s\n' "$id" >>"$fixture/config/groups/git.list"
done
printf '%s\n' "$core_id" >>"$fixture/config/groups/core.list"

# Each stub records when it started and stopped, plus the per-lane budget it
# was handed, so concurrency can be reconstructed afterwards.
cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'START %s %s %s %s\n' \
    "$id" "$(date +%s%N)" "${MAKEFLAGS:-unset}" "${GSA_BUILD_JOBS:-unset}" \
    >>"$GSA_FAKE_LANE_INTERVALS"
# Staggered on purpose: the two long packages keep lanes busy while the short
# ones end, which is the only situation in which the core member can be
# dispatched too early. With uniform durations every lane frees in the same
# poll and the core member is dispatched into an already-idle pool, so the
# guard is never exercised and the fixture passes for the wrong reason.
duration=$(awk -v want="$id" '$1 == want { print $2 }' "$GSA_FAKE_DURATIONS")
sleep "${duration:-1}"
printf 'END %s %s\n' "$id" "$(date +%s%N)" >>"$GSA_FAKE_LANE_INTERVALS"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$fixture/bin/makepkg"

durations="$fixture/durations"
cat >"$durations" <<'EOF'
n1 0.5
n2 2.5
n3 2.5
n4 0.5
c1 0.5
EOF

# Reconstructs concurrency from the stub's own timestamps. RECORDED is how
# many packages the run actually started; HELD_BACK counts non-core packages
# that had already started when the core member did (the precondition for the
# solo assertion to mean anything); the overlap counts are the invariant.
analyse() { # $1 = marker file
    awk -v core="$core_id" '
        $1 == "START" { start[$2] = $3; flags[$2] = $4; jobs[$2] = $5; seen[$2] = 1 }
        $1 == "END"   { stop[$2] = $3 }
        END {
            for (id in seen) {
                count++
                if (id != core) order[n++] = id
            }
            for (i = 0; i < n; i++) {
                a = order[i]
                for (j = i + 1; j < n; j++) {
                    b = order[j]
                    if (start[a] < stop[b] && start[b] < stop[a]) noncore++
                }
                if (start[a] < stop[core] && start[core] < stop[a]) overlapping++
            }
            held = 0
            for (i = 0; i < n; i++)
                if (start[order[i]] < start[core]) held++
            first = 1
            for (i = 0; i < n; i++)
                if (start[order[i]] < start[core]) first = 0
            printf "RECORDED %d\n", count
            printf "HELD_BACK %d\n", held
            printf "CORE_FIRST %d\n", first
            printf "NONCORE_OVERLAPS %d\n", noncore + 0
            printf "CORE_OVERLAPS %d\n", overlapping + 0
            for (id in seen) printf "FLAGS %s %s %s\n", id, flags[id], jobs[id]
        }
    ' "$1"
}

marker="$fixture/marker"
: >"$marker"

output=$(
    PATH="$fixture/bin:$PATH" \
    GSA_STATE_DIR="$fixture/state" \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAKE_DURATIONS="$durations" \
    GSA_FAKE_LANE_INTERVALS="$marker" \
    fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --lanes 3 --intensity xhigh "${selection[@]}" 2>&1
) || {
    printf 'the scheduler run failed:\n%s\n' "$output" >&2
    exit 1
}

plan=$(printf '%s\n' "$output" | grep 'parallelism:' | head -1)
normal_jobs=$(printf '%s\n' "$plan" | sed -E 's/.*normal -j([0-9]+).*/\1/')
core_jobs=$(printf '%s\n' "$plan" | sed -E 's/.*core -j([0-9]+).*/\1/')
if [[ -z $normal_jobs || -z $core_jobs || $normal_jobs == "$core_jobs" ]]; then
    printf 'the xhigh plan does not separate the two budgets, so the budget\n' >&2
    printf 'assertion below could not tell them apart: %s\n' "$plan" >&2
    exit 1
fi

report=$(
    analyse "$marker"
)

read_value() { # $1 = key
    printf '%s\n' "$report" | awk -v k="$1" '$1 == k { print $2 }'
}

recorded=$(read_value RECORDED)
if [[ $recorded != 5 ]]; then
    printf 'only %s of 5 packages ran; the run did not exercise the dispatcher:\n%s\n' \
        "$recorded" "$output" >&2
    exit 1
fi

# (1) Baseline: the run must be capable of overlap before "no overlap" means
# anything. Three normal packages with three lanes must overlap each other.
noncore_overlaps=$(read_value NONCORE_OVERLAPS)
if ((noncore_overlaps < 1)); then
    printf 'no two non-core packages overlapped, so this run cannot show\n' >&2
    printf 'whether the core member was held solo:\n%s\n' "$marker" >&2
    exit 1
fi

# (2) Precondition: the core member must have waited for other work, or the
# solo assertion is vacuous — a core member dispatched first overlaps nothing
# however broken the guard is.
held_back=$(read_value HELD_BACK)
if ((held_back < 1)); then
    printf 'no package had started before the core member, so nothing was\n' >&2
    printf 'held back and the solo assertion below proves nothing:\n%s\n' "$marker" >&2
    exit 1
fi

# (3) The invariant.
core_overlaps=$(read_value CORE_OVERLAPS)
if ((core_overlaps != 0)); then
    printf '%s package(s) ran alongside the core member %s:\n' \
        "$core_overlaps" "$core_id" >&2
    printf '%s\n' "$report" | grep -E 'CORE_OVERLAPS' >&2
    exit 1
fi

# (4) Core carried the core budget, everything else the normal one.
while read -r tag id flags jobs; do
    [[ $tag == FLAGS ]] || continue
    if [[ $id == "$core_id" ]]; then
        want=$core_jobs
    else
        want=$normal_jobs
    fi
    if [[ $flags != *"-j$want"* ]]; then
        printf '%s ran with MAKEFLAGS=%s, expected -j%s\n' "$id" "$flags" "$want" >&2
        exit 1
    fi
    if [[ $jobs != "$want" ]]; then
        printf '%s ran with GSA_BUILD_JOBS=%s, expected %s\n' "$id" "$jobs" "$want" >&2
        exit 1
    fi
done <<<"$report"

# ─── Phase B: nothing may be *started* alongside a running core member ──────
# Phase A covers one direction: the core member is not dispatched into a busy
# pool. This phase covers the other, which is the guard that actually holds
# work back — with two lanes and the core member first in the list, lane 1
# takes core and lane 2 must stay idle although a normal package is ready.
# The two must be separate scenarios: removing this guard leaves phase A
# passing, because by the time the core member gets a lane in phase A every
# normal package has already been started.
durations_b="$fixture/durations-b"
marker_b="$fixture/marker-b"
cat >"$durations_b" <<'EOF'
c1 1.5
n1 0.5
EOF
: >"$marker_b"

output_b=$(
    PATH="$fixture/bin:$PATH" \
    GSA_STATE_DIR="$fixture/state-b" \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAKE_DURATIONS="$durations_b" \
    GSA_FAKE_LANE_INTERVALS="$marker_b" \
    fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --lanes 2 --intensity xhigh "$core_id" n1 2>&1
) || {
    printf 'the two-lane core run failed:\n%s\n' "$output_b" >&2
    exit 1
}
report_b=$(analyse "$marker_b")
value_b() { # $1 = key
    printf '%s\n' "$report_b" | awk -v k="$1" '$1 == k { print $2 }'
}
if [[ $(value_b RECORDED) != 2 ]]; then
    printf 'the two-lane run started %s of 2 packages:\n%s\n' \
        "$(value_b RECORDED)" "$output_b" >&2
    exit 1
fi
if [[ $(value_b CORE_FIRST) != 1 ]]; then
    printf 'the core member was not dispatched first, so the guard under test\n' >&2
    printf 'was never reached:\n%s\n' "$marker_b" >&2
    exit 1
fi
if [[ $(value_b CORE_OVERLAPS) != 0 ]]; then
    printf 'a package was started alongside the running core member %s:\n' \
        "$core_id" >&2
    printf '%s\n' "$marker_b" >&2
    exit 1
fi

printf 'core-solo fixture: PASS\n'
