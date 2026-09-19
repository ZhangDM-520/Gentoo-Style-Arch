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
# The recipe list comes from config/packages.map, which is the only place that
# binds a package id to a recipe path, so a new recipe is covered without
# touching this file. Read-only: each recipe is generated into $TMPDIR and
# diffed, never written to.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
jobs=${GSA_SRCINFO_JOBS:-8}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-srcinfo-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# One recipe: print "<path>\t<reason>" when it is stale, nothing when it is not.
check_recipe() {
    local rel=$1 dir=$root/$1 out=$tmp/out.$$
    if [[ ! -f $dir/.SRCINFO ]]; then
        printf '%s\tno .SRCINFO committed\n' "$rel"
        return 0
    fi
    if ! GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$dir" >"$out" 2>"$tmp/err.$$"; then
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
export root tmp

mapfile -t recipes < <(awk -F'|' '!/^#/ && NF==2 {print $2}' "$root/config/packages.map")
((${#recipes[@]} > 0)) || {
    printf 'srcinfo freshness fixture: config/packages.map listed no recipes\n' >&2
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
