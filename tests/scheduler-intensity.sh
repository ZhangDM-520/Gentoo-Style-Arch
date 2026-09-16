#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-intensity-fixture.XXXXXX")
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
for group in git stable core misc third-party; do
    : >"$fixture/config/groups/$group.list"
done

ids=()
for i in $(seq 1 8); do
    id="p$i"
    ids+=("$id")
    mkdir -p "$fixture/packages/$id"
    printf 'pkgname=%s\n' "$id" >"$fixture/packages/$id/PKGBUILD"
    printf '%s|packages/%s|%s\n' "$id" "$id" "$id" >>"$fixture/config/packages.map"
    printf '%s\n' "$id" >>"$fixture/config/groups/git.list"
done

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${GSA_FAIL_PACKAGE:-}" == "$(basename "$PWD")" ]]; then
    exit 1
fi
sleep 0.05
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
done

if failing_output=$(
    PATH="$fixture/bin:$PATH" \
    GSA_STATE_DIR="$fixture/state-failure" \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAIL_PACKAGE=p1 \
    fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --intensity low "${ids[@]}" 2>&1
); then
    printf 'failure fixture unexpectedly succeeded\n' >&2
    exit 1
fi
if ! printf '%s\n' "$failing_output" | grep -F -- '--intensity low' >/dev/null; then
    printf 'resume command did not preserve intensity:\\n%s\\n' "$failing_output" >&2
    exit 1
fi

printf 'scheduler intensity fixture: PASS\n'
