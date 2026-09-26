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
expected[low]='1 lane(s), normal -j3, core -j3'
expected[medium]='2 lane(s), normal -j3, core -j4'
expected[high]='3 lane(s), normal -j3, core -j6'
expected[xhigh]='4 lane(s), normal -j3, core -j7'
expected[max]='6 lane(s), normal -j3, core -j9'

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
    plan=$(printf '%s\n' "$output" | grep 'parallelism:' | head -1)
    if [[ "$plan" != *"intensity $level, ${expected[$level]}"* ]]; then
        printf 'unexpected %s plan: %s\n' "$level" "$plan" >&2
        exit 1
    fi
    plan_jobs=$(printf '%s\n' "$plan" | sed -E 's/.*normal -j([0-9]+).*/\1/')
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
if ! printf '%s\n' "$failing_output" | grep -F -- '--intensity xhigh' >/dev/null; then
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
