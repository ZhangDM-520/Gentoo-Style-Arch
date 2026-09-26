#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-intensity-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

make_workspace "$fixture" auto auto xhigh

ids=()
for i in $(seq 1 8); do
    id="p$i"
    ids+=("$id")
    add_package "$fixture" "$id"
done

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${GSA_FAKE_FAIL_PACKAGE:-}" == "$(basename "$PWD")" ]]; then
    exit 1
fi
printf 'fake makepkg %s\n' "$PWD"
# The lane must hand its per-lane job budget to the build system: MAKEFLAGS and
# NINJAFLAGS are what upstream Makefiles/Ninja honour, GSA_BUILD_JOBS is what
# this workspace's PKGBUILDs read.
printf 'job flags: MAKEFLAGS=%s NINJAFLAGS=%s GSA_BUILD_JOBS=%s\n' \
    "${MAKEFLAGS:-unset}" "${NINJAFLAGS:-unset}" "${GSA_BUILD_JOBS:-unset}"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
EOF
chmod +x "$fixture/bin/makepkg"

declare -A expected
# lanes / normal-jobs / core-jobs as the run record reports them (the
# 'parallelism:' sentence is rendering; its wording is pinned once in
# tests/dashboard.sh's prose section).
expected[low]='1 3 3'
expected[medium]='2 3 4'
expected[high]='3 3 6'
expected[xhigh]='4 3 7'
expected[max]='6 3 9'

for level in low medium high xhigh max; do
    output=$(
        PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$fixture/state-$level" \
        GSA_CPU_THREADS=24 \
        GSA_MEMORY_GIB=21 \
        fish "$fixture/build-all.fish" \
            --allow-broken-rustc --no-deps --no-sync \
            --intensity "$level" "${ids[@]}" 2>&1
    )
    read -r want_lanes want_normal want_core <<<"${expected[$level]}"
    got="$(rr_scalar lanes <<<"$output") $(rr_scalar normal-jobs <<<"$output") $(rr_scalar core-jobs <<<"$output")"
    want="$want_lanes $want_normal $want_core"
    if [[ $got != "$want" ]]; then
        printf 'unexpected %s plan (lanes normal-jobs core-jobs): got %s want %s\n' \
            "$level" "$got" "$want" >&2
        exit 1
    fi
    if [[ $(rr_scalar intensity <<<"$output") != "$level" ]]; then
        printf 'the %s run recorded intensity %s\n' \
            "$level" "$(rr_scalar intensity <<<"$output")" >&2
        exit 1
    fi
    plan_jobs=$(rr_scalar normal-jobs <<<"$output")
    for id in "${ids[@]}"; do
        grep -F "fake makepkg $fixture/packages/$id" \
            "$fixture/state-$level/logs/$id.log" >/dev/null
        if ! grep -F "MAKEFLAGS=-j$plan_jobs NINJAFLAGS=-j$plan_jobs GSA_BUILD_JOBS=$plan_jobs" \
            "$fixture/state-$level/logs/$id.log" >/dev/null; then
            printf 'lane %s did not export its -j%s budget under %s:\n' \
                "$id" "$plan_jobs" "$level" >&2
            cat "$fixture/state-$level/logs/$id.log" >&2
            exit 1
        fi
    done
    if find "$fixture/state-$level/logs" -maxdepth 1 -name '.lane*.result*' -print -quit | grep -q .; then
        printf 'lane result artifact remained for %s\n' "$level" >&2
        exit 1
    fi
done

if failing_output=$(
    PATH="$fixture/bin:$PATH" \
    GSA_STATE_DIR="$fixture/state-failure" \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAKE_FAIL_PACKAGE=p1 \
    GSA_FAKE_BUILD_SECONDS=0.2 \
    fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --intensity xhigh "${ids[@]}" 2>&1
); then
    printf 'failure fixture unexpectedly succeeded\n' >&2
    exit 1
fi
if ! rr_scalar outcome <<<"$failing_output" | grep -qx failed; then
    printf 'failure run recorded outcome %s:\n%s\n' \
        "$(rr_scalar outcome <<<"$failing_output")" "$failing_output" >&2
    exit 1
fi
if [[ $(rr_row p1 status <<<"$failing_output") != failed ]]; then
    printf 'p1 row wrong in the failure run: %s\n' \
        "$(rr_row p1 <<<"$failing_output")" >&2
    exit 1
fi
# The resume set is exactly the non-succeeded rows in row order: p1 (failed —
# it must rebuild before its dependents) first, and the lanes that were
# already in flight drain to their own row outcomes, so the set's size is
# deterministic even though which siblings finished is not.
mapfile -t remaining < <(rr_remaining <<<"$failing_output")
if [[ ${remaining[0]:-} != p1 ]]; then
    printf 'the failed package is not first in the resume set: %s\n' \
        "$(rr_remaining <<<"$failing_output" | tr '\n' ' ')" >&2
    exit 1
fi
succeeded=$(rr_rows <<<"$failing_output" | awk '$2 == "succeeded"' | wc -l)
if [[ ${#remaining[@]} -ne $((${#ids[@]} - succeeded)) ]]; then
    printf 'resume set does not cover every non-succeeded row: %s\n' \
        "$(rr_remaining <<<"$failing_output" | tr '\n' ' ')" >&2
    exit 1
fi
# The continuation suggestion must preserve the plan flavour (continuation
# rule: --intensity is mirrored as a value flag).
suggest=$(printf '%s\n' "$failing_output" | grep '^  build-all\.fish ' | head -1)
if [[ $suggest != *'--intensity xhigh'* ]]; then
    printf 'resume command did not preserve intensity:\n%s\n' "$failing_output" >&2
    exit 1
fi
if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    printf 'lane child remained after failure drain\n' >&2
    exit 1
fi
if find "$fixture/state-failure/logs" -maxdepth 1 -name '.lane*.result*' -print -quit | grep -q .; then
    printf 'lane result artifact remained after failure drain\n' >&2
    exit 1
fi

printf 'scheduler intensity fixture: PASS\n'
