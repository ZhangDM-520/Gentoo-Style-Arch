#!/usr/bin/env bash
set -euo pipefail

# One unanchorable recipe must park itself, not strangle the dispatch.
#
# Before 2026-09-24 the first anchoring refusal exited the lane non-zero, the
# dispatcher treated that as a failed build, set stop_starting and drained:
# measured on a stable,core,git,third-party run, ONE recipe whose official
# .SRCINFO published no checksum for a moved source cost the other ~120
# packages their dispatch (two consecutive runs, "stopped dispatching, drained
# in-flight lanes"). Anchoring impossibility is not a failed build — it is a
# recipe that cannot be refreshed right now (no official document, network
# down, updpkgsums failed). The stance pinned here:
#
#   * a-stable (stable, official 404 → cannot anchor) is DEFERRED: named
#     marker in the summary, its log tail carries the named error AND both
#     recovery lines ('Refresh them by hand', '--no-sync'), makepkg never
#     ran for it, and the recipe is not counted as succeeded or failed;
#   * c-plain, independent of a-stable, still BUILDS — dispatch continues;
#   * b-dep (dependencies.conf: b-dep:a-stable) is never dispatched: building
#     it against a package that was never built/installed this run is the
#     rule-11 hazard -i exists to prevent. It is labelled as waiting on the
#     deferred recipe, not as a dependency cycle;
#   * the run exits non-zero (parked work needs the owner), and the resume
#     command names BOTH unbuilt packages (tests/resume-command.sh pins the
#     command's flag shape; this fixture pins its honesty about parked work).
#
# All collaborators (pacman, curl, updpkgsums, makepkg) are PATH stubs; the
# run builds nothing real and touches no network.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-anchor-defer.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'anchor defer fixture: %s\n' "$1" >&2
    exit 1
}

command -v vercmp >/dev/null || {
    printf 'vercmp is required (it ships with pacman)\n' >&2
    exit 1
}

dir="$fixture/ws"
mkdir -p "$dir/config/groups" "$dir/packages/stable/a-stable" "$dir/bin" "$dir/fake"
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
printf 'b-dep:a-stable\n' >"$dir/config/dependencies.conf"
for group in git stable core misc third-party app; do
    : >"$dir/config/groups/$group.list"
done
printf 'a-stable\n' >>"$dir/config/groups/stable.list"
printf 'b-dep\nc-plain\n' >>"$dir/config/groups/git.list"
{
    printf 'a-stable|packages/stable/a-stable\n'
    printf 'b-dep|packages/b-dep\n'
    printf 'c-plain|packages/c-plain\n'
} >"$dir/config/packages.map"

# a-stable: a stable recipe whose moved source gets NO official document (404)
# → anchor_sums_from_official refuses with rc 3, which the lane reports as the
# defer code. $pkgver must be literal: the builder expands source=() by
# sourcing the recipe.
{
    printf 'pkgname=a-stable\n'
    printf 'pkgver=1.0.0\n'
    printf 'pkgrel=1\n'
    printf 'arch=(any)\n'
    printf 'source=("https://example.invalid/a-$pkgver.tar.gz")\n'
    printf "sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')\n"
} >"$dir/packages/stable/a-stable/PKGBUILD"

# b-dep / c-plain: ordinary recipes with working builds.
for id in b-dep c-plain; do
    mkdir -p "$dir/packages/$id"
    printf 'pkgname=%s\npkgver=1.0.0\npkgrel=1\narch=(any)\n' "$id" \
        >"$dir/packages/$id/PKGBUILD"
done

printf '2.0.0-1\n' >"$dir/fake/repo_version"

cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : %s\nVersion         : %s\n' \
        "$2" "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
chmod +x "$dir/bin/pacman"

# Official packaging repo: 404 for everything → no anchor at our version.
cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/curl_calls"
exit 22
EOF
chmod +x "$dir/bin/curl"

cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GSA_FAKE_DIR/updpkgsums_calls"
exit 0
EOF
chmod +x "$dir/bin/updpkgsums"

cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf '%s\n' "$id" >>"$GSA_FAKE_DIR/makepkg_calls"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$dir/bin/makepkg"

set +e
output=$(
    PATH="$dir/bin:$PATH" \
    GSA_STATE_DIR="$dir/state" \
    GSA_FAKE_DIR="$dir/fake" \
    GSA_CPU_THREADS=4 \
    GSA_MEMORY_GIB=8 \
    fish "$dir/build-all.fish" --allow-broken-rustc --no-deps \
        --intensity low a-stable b-dep c-plain 2>&1
)
rc=$?
set -e
printf '%s' "$output" >"$dir/out.txt"

# 1. Parked work must keep the run non-zero — a silent green would hide it.
((rc != 0)) || fail "the run exited 0 although a recipe was parked:
$output"

# 2. a-stable is parked with a NAMED marker, not reported as a build failure.
grep -q 'DEFERRED' "$dir/out.txt" || fail "no DEFERRED marker for a-stable:
$output"
grep -q 'a-stable' "$dir/out.txt" || fail 'the DEFERRED marker does not name a-stable'
if grep -q 'a-stable: BUILD FAILED' "$dir/out.txt"; then
    fail "a deferral was reported as a build failure:
$output"
fi
[[ -f $dir/packages/stable/a-stable/PKGBUILD ]] || fail 'the parked recipe disappeared'

# 3. The parked recipe's summary carries the named error AND both recovery
#    lines (the deferred section tails the package log — that tail is the only
#    place a non-interactive owner can read why it parked).
grep -q 'refusing to build' "$dir/out.txt" \
    || fail "the deferred summary does not carry the named refusal:
$output"
grep -q 'Refresh them by hand' "$dir/out.txt" \
    || fail "the deferred summary lost the manual recovery line:
$output"
grep -q -- "'--no-sync' builds the committed version as-is" "$dir/out.txt" \
    || fail "the deferred summary lost the --no-sync escape:
$output"

# 4. makepkg never ran for the parked recipe…
if grep -qx 'a-stable' "$dir/fake/makepkg_calls" 2>/dev/null; then
    fail 'makepkg ran for the recipe that could not be anchored'
fi
# …but updpkgsums was never reached either: without an official document
# there is nothing to classify against, so the refusal precedes any write.
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'updpkgsums ran although no official document could be fetched'
fi

# 5. THE POINT: the rest of the dispatch continued — c-plain built.
grep -qx 'c-plain' "$dir/fake/makepkg_calls" 2>/dev/null \
    || fail "c-plain was never built — one parked recipe still stopped the dispatch:
$output"
[[ -f $dir/packages/c-plain/c-plain-1.0.0-1-any.pkg.tar.zst ]] \
    || fail 'c-plain reports built but produced no archive'

# 6. b-dep depends on the parked recipe: never dispatched, honestly labelled —
#    waiting on a deferral is not a dependency cycle.
if grep -qx 'b-dep' "$dir/fake/makepkg_calls" 2>/dev/null; then
    fail 'b-dep built although its dependency a-stable was never built'
fi
grep -q 'waits on a deferred package' "$dir/out.txt" \
    || fail "b-dep's non-dispatch is not labelled as waiting on a deferred package:
$output"

# 7. The resume command names BOTH unbuilt packages — and only those: a resume
#    must retry the parked recipe and its blocked dependent, not re-run c-plain.
resume=$(grep '^  build-all.fish ' "$dir/out.txt" | head -1) || true
[[ -n $resume ]] || fail "no resume command in the failure summary:
$output"
[[ $resume == *a-stable* ]] || fail "resume command omits the parked a-stable: $resume"
[[ $resume == *b-dep* ]] || fail "resume command omits the blocked b-dep: $resume"
[[ $resume != *c-plain* ]] || fail "resume command would rebuild the finished c-plain: $resume"
[[ $resume == *--intensity* ]] || fail "resume command lost its flags: $resume"

printf 'anchor defer fixture: PASS (parked a-stable, waited b-dep, built c-plain)\n'
