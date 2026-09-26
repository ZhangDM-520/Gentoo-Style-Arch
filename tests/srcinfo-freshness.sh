#!/usr/bin/env bash
set -euo pipefail

# Every recipe ships a committed `.SRCINFO` next to its PKGBUILD. Three
# fixtures (logseq-desktop-recipe.sh, texlive-recipe.sh, bpftune-tuners-hook.sh)
# already assert that *their own* recipe's `.SRCINFO` matches, which leaves the
# other ~123 unchecked — and a stale `.SRCINFO` is a silent break: it pins the
# previous pkgver, provides, source URL and sha256sums, so anything consuming
# the recipe through it builds the wrong sources against the wrong sums.
#
# bettbox proved the gap: its PKGBUILD moved to 1.19.2 while `.SRCINFO` stayed
# at 1.19.1 with the previous tarball's hash. `makepkg --printsrcinfo` was
# simply never re-run when the version was bumped.
#
# The recipe list comes from the builder's --topology data channel (one
# record per package, id|path|groups|edges|tags), which resolves
# config/topology.conf — the only place that binds a package id to a recipe
# path — so a new recipe is covered without touching this file. Read-only:
# each recipe is generated into $TMPDIR and diffed, never written to.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
# Concurrency: makepkg --printsrcinfo is cheap and pure, so the whole map is
# checked at once (one job per hardware thread; override with GSA_FAKE_SRCINFO_JOBS).
jobs=${GSA_FAKE_SRCINFO_JOBS:-$(nproc 2>/dev/null || echo 8)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-srcinfo-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# One recipe: print "<path>\t<reason>" when it is stale, nothing when it is not.
check_recipe() {
    local rel=$1 dir=$root/$1 out=$tmp/out.$$
    if [[ ! -f $dir/.SRCINFO ]]; then
        printf '%s\tno .SRCINFO committed\n' "$rel"
        return 0
    fi
    if ! makepkg_printsrcinfo "$dir" >"$out" 2>"$tmp/err.$$"; then
        printf '%s\tmakepkg --printsrcinfo failed: %s\n' "$rel" \
            "$(head -1 "$tmp/err.$$" 2>/dev/null)"
        rm -f -- "$out" "$tmp/err.$$"
        return 0
    fi
    if ! diff -q "$out" "$dir/.SRCINFO" >/dev/null; then
        printf '%s\tstale (pkgver/version-pinned fields differ)\n' "$rel"
    fi
    rm -f -- "$out" "$tmp/err.$$"
    return 0
}
export -f check_recipe
# check_recipe runs in `bash -c` workers, which only see exported functions.
export -f makepkg_printsrcinfo
export root tmp

mapfile -t recipes < <(fish "$root/build-all.fish" --topology 2>/dev/null |
    awk -F'|' '!/^#/ && NF == 5 {print $2}')
((${#recipes[@]} > 0)) || {
    printf 'srcinfo freshness fixture: the --topology channel listed no recipes\n' >&2
    exit 1
}

stale=$(printf '%s\n' "${recipes[@]}" |
    xargs -P "$jobs" -I{} bash -c 'check_recipe "$1"' _ {} |
    sort)

if [[ -n $stale ]]; then
    printf 'srcinfo freshness fixture: %d recipe(s) have a stale .SRCINFO\n' \
        "$(wc -l <<<"$stale")" >&2
    printf '%s\n' "$stale" >&2
    printf 'regenerate with: cd <recipe> && GIT_CONFIG_COUNT=0 makepkg --printsrcinfo > .SRCINFO\n' >&2
    exit 1
fi

printf 'srcinfo freshness fixture: PASS (%d recipes)\n' "${#recipes[@]}"
