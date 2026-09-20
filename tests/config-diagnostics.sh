#!/usr/bin/env bash
set -euo pipefail

# load_project_config returns 1 from about a dozen places. Before the
# 2026-09-20 audit most of them returned silently, and the only thing the user
# ever saw was the caller's generic "project configuration is invalid under
# <dir>" — which says nothing about *which* record is wrong. This fixture
# breaks one thing at a time in a sandbox and requires the builder to name the
# offender.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-config-diag.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

# A minimal but fully valid workspace: two packages, both grouped.
make_workspace() {
    local dir=$1
    mkdir -p "$dir/config/groups" "$dir/packages/p1" "$dir/packages/p2"
    cp "$root/build-all.fish" "$dir/build-all.fish"

    cat >"$dir/config/build-defaults.conf" <<'EOF'
lanes=1
jobs=2
intensity=low
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
    : >"$dir/config/dependencies.conf"
    for group in git stable core misc third-party; do
        : >"$dir/config/groups/$group.list"
    done
    printf 'p1\np2\n' >"$dir/config/groups/git.list"
    cat >"$dir/config/packages.map" <<'EOF'
p1|packages/p1
p2|packages/p2
EOF
    printf 'pkgname=p1\npkgver=1\npkgrel=1\narch=(any)\n' >"$dir/packages/p1/PKGBUILD"
    printf 'pkgname=p2\npkgver=1\npkgrel=1\narch=(any)\n' >"$dir/packages/p2/PKGBUILD"
}

# Runs --list (which still loads the whole config) and captures status+output.
# Returns the builder's status; sets CONFIG_OUTPUT.
run_builder() {
    local dir=$1
    set +e
    CONFIG_OUTPUT=$(fish "$dir/build-all.fish" --list 2>&1)
    local rc=$?
    set -e
    return $rc
}

# assert_rejected <case> <dir> <expected substring>
assert_rejected() {
    local case_name=$1 dir=$2 expected=$3
    if run_builder "$dir"; then
        printf '%s: invalid configuration was ACCEPTED:\n%s\n' "$case_name" "$CONFIG_OUTPUT" >&2
        exit 1
    fi
    if ! grep -F "$expected" <<<"$CONFIG_OUTPUT" >/dev/null; then
        printf '%s: error did not name the offender (wanted %q):\n%s\n' \
            "$case_name" "$expected" "$CONFIG_OUTPUT" >&2
        exit 1
    fi
}

# Sanity: the baseline must be accepted, or every case below passes for the
# wrong reason.
baseline="$fixture/baseline"
make_workspace "$baseline"
if ! run_builder "$baseline"; then
    printf 'baseline workspace is not valid — the fixture itself is broken:\n%s\n' \
        "$CONFIG_OUTPUT" >&2
    exit 1
fi

# ─── A package present in packages.map but in no group list ──────────────────
dir="$fixture/ungrouped"
make_workspace "$dir"
printf 'p1\n' >"$dir/config/groups/git.list" # p2 dropped from every group
assert_rejected 'ungrouped package' "$dir" 'p2 is listed in'

# ─── A dependency record naming a package that does not exist ───────────────
dir="$fixture/unknown-dep"
make_workspace "$dir"
printf 'p1:ghost\n' >"$dir/config/dependencies.conf"
assert_rejected 'unknown dependency' "$dir" 'unknown dependency: ghost'

# ─── A dependency record naming an unknown package ──────────────────────────
dir="$fixture/unknown-pkg"
make_workspace "$dir"
printf 'ghost:p1\n' >"$dir/config/dependencies.conf"
assert_rejected 'unknown package' "$dir" 'unknown package: ghost'

# ─── A dependency record with no separator ──────────────────────────────────
dir="$fixture/malformed-dep"
make_workspace "$dir"
printf 'p1\n' >"$dir/config/dependencies.conf"
assert_rejected 'malformed dependency record' "$dir" "invalid dependency record (expected"

# ─── Missing config files are named, not just "invalid" ─────────────────────
dir="$fixture/no-packages-map"
make_workspace "$dir"
rm -f "$dir/config/packages.map"
assert_rejected 'missing package map' "$dir" 'package map not found:'

dir="$fixture/no-dependencies-conf"
make_workspace "$dir"
rm -f "$dir/config/dependencies.conf"
assert_rejected 'missing dependency config' "$dir" 'dependency config not found:'

# ─── An invalid build default still names its key (pre-existing behaviour) ──
dir="$fixture/bad-default"
make_workspace "$dir"
sed -i 's/^memory_per_job_gib=.*/memory_per_job_gib=0/' "$dir/config/build-defaults.conf"
assert_rejected 'invalid numeric default' "$dir" 'memory_per_job_gib=0'

# ─── Group-list problems name the line, not just the group ──────────────────
dir="$fixture/group-duplicate"
make_workspace "$dir"
printf 'p1\np1\np2\n' >"$dir/config/groups/git.list"
assert_rejected 'duplicate group entry' "$dir" 'p1 appears twice in'

dir="$fixture/group-unknown"
make_workspace "$dir"
printf 'p1\np2\nghost\n' >"$dir/config/groups/git.list"
assert_rejected 'unknown group entry' "$dir" 'names no package: ghost'

dir="$fixture/group-missing"
make_workspace "$dir"
rm -f "$dir/config/groups/git.list"
assert_rejected 'missing group list' "$dir" 'group list not found:'

printf 'config diagnostics fixture: PASS\n'
