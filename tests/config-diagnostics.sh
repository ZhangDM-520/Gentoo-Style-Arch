#!/usr/bin/env bash
set -euo pipefail

# load_project_config returns 1 from about a dozen places. Before the
# 2026-09-20 audit most of them returned silently, and the only thing the user
# ever saw was the caller's generic "project configuration is invalid under
# <dir>" — which says nothing about *which* record is wrong. This fixture
# breaks one thing at a time in a sandbox and requires the builder to name the
# offender.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-config-diag.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

# A minimal but fully valid workspace: two packages, both grouped. The skeleton
# and the packages come from the fixture-lib helper; the per-case tweaks below
# stay inline because each breakage IS the case.
make_case_workspace() {
    local dir=$1
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 $'pkgver=1\npkgrel=1\narch=(any)'
    add_package "$dir" p2 $'pkgver=1\npkgrel=1\narch=(any)'
}

# Runs --list (which still loads the whole config) through the helper's capture;
# returns the builder's status, output in FIXTURE_OUTPUT.
run_list() {
    local dir=$1
    run_builder fish "$dir/build-all.fish" --list
    return "$FIXTURE_RC"
}

# assert_rejected <case> <dir> <expected substring>
assert_rejected() {
    local case_name=$1 dir=$2 expected=$3
    if run_list "$dir"; then
        printf '%s: invalid configuration was ACCEPTED:\n%s\n' "$case_name" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if ! grep -F "$expected" <<<"$FIXTURE_OUTPUT" >/dev/null; then
        printf '%s: error did not name the offender (wanted %q):\n%s\n' \
            "$case_name" "$expected" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
}

# Sanity: the baseline must be accepted, or every case below passes for the
# wrong reason.
baseline="$fixture/baseline"
make_case_workspace "$baseline"
if ! run_list "$baseline"; then
    printf 'baseline workspace is not valid — the fixture itself is broken:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── A package present in packages.map but in no group list ──────────────────
dir="$fixture/ungrouped"
make_case_workspace "$dir"
printf 'p1\n' >"$dir/config/groups/git.list" # p2 dropped from every group
assert_rejected 'ungrouped package' "$dir" 'p2 is listed in'

# ─── A dependency record naming a package that does not exist ───────────────
dir="$fixture/unknown-dep"
make_case_workspace "$dir"
printf 'p1:ghost\n' >"$dir/config/dependencies.conf"
assert_rejected 'unknown dependency' "$dir" 'unknown dependency: ghost'

# ─── A dependency record naming an unknown package ──────────────────────────
dir="$fixture/unknown-pkg"
make_case_workspace "$dir"
printf 'ghost:p1\n' >"$dir/config/dependencies.conf"
assert_rejected 'unknown package' "$dir" 'unknown package: ghost'

# ─── A dependency record with no separator ──────────────────────────────────
dir="$fixture/malformed-dep"
make_case_workspace "$dir"
printf 'p1\n' >"$dir/config/dependencies.conf"
assert_rejected 'malformed dependency record' "$dir" "invalid dependency record (expected"

# ─── Missing config files are named, not just "invalid" ─────────────────────
dir="$fixture/no-packages-map"
make_case_workspace "$dir"
rm -f "$dir/config/packages.map"
assert_rejected 'missing package map' "$dir" 'package map not found:'

dir="$fixture/no-dependencies-conf"
make_case_workspace "$dir"
rm -f "$dir/config/dependencies.conf"
assert_rejected 'missing dependency config' "$dir" 'dependency config not found:'

# ─── An invalid build default still names its key (pre-existing behaviour) ──
dir="$fixture/bad-default"
make_case_workspace "$dir"
sed -i 's/^memory_per_job_gib=.*/memory_per_job_gib=0/' "$dir/config/build-defaults.conf"
assert_rejected 'invalid numeric default' "$dir" 'memory_per_job_gib=0'

# ─── Group-list problems name the line, not just the group ──────────────────
dir="$fixture/group-duplicate"
make_case_workspace "$dir"
printf 'p1\np1\np2\n' >"$dir/config/groups/git.list"
assert_rejected 'duplicate group entry' "$dir" 'p1 appears twice in'

dir="$fixture/group-unknown"
make_case_workspace "$dir"
printf 'p1\np2\nghost\n' >"$dir/config/groups/git.list"
assert_rejected 'unknown group entry' "$dir" 'names no package: ghost'

dir="$fixture/group-missing"
make_case_workspace "$dir"
rm -f "$dir/config/groups/git.list"
assert_rejected 'missing group list' "$dir" 'group list not found:'

# ─── fixture-lib smoke: a helper-built workspace satisfies the loader ────────
# The synthesis helper's contract is that its skeletons are valid OUT OF THE
# BOX — every migrated fixture rests on that. Wrapped in a subshell so the
# helper's redefinitions, trap and variables stay out of the cases above.
(
    set -euo pipefail
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    smoke=$(mktemp -d "${TMPDIR:-/tmp}/gsa-fixture-lib.XXXXXX")
    trap 'rm -rf -- "$smoke"' EXIT

    ws="$smoke/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" p1 "$gsa_meta_any"
    add_package "$ws" p2 "$gsa_meta_any" core

    run_builder fish "$ws/build-all.fish" --list
    if ((FIXTURE_RC != 0)) || [[ $FIXTURE_OUTPUT != *p1* ]]; then
        printf 'fixture-lib smoke: --list rejects a helper-built workspace (rc=%d):\n%s\n' \
            "$FIXTURE_RC" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi

    run_builder fish "$ws/build-all.fish" --audit
    if ((FIXTURE_RC != 0)); then
        printf 'fixture-lib smoke: --audit rejects a helper-built workspace (rc=%d):\n%s\n' \
            "$FIXTURE_RC" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi

    printf 'fixture-lib smoke: OK\n'
)

printf 'config diagnostics fixture: PASS\n'
