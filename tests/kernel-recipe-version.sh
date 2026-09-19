#!/usr/bin/env bash
set -euo pipefail

# packages/misc/linux-cachyos tracks an upstream kernel channel, and its version
# scheme has two forms plus a version-scoped patch set:
#
#   stable: _major=7.2 _minor=6    -> pkgver 7.2.6   -> cachyos-7.2.6-<tagrel>
#   RC:     _major=7.3 _rcver=rc3  -> pkgver 7.3.rc3 -> cachyos-7.3-rc3-<tagrel>
#
# and `_patchsource` is .../kernel-patches/master/<major>, so bumping the kernel
# changes the patch directory as well as every patch filename under it.
#
# A partial bump is a silent break with two distinct faces. The source URL comes
# out plausible but wrong, which makepkg reports only as a 404 - and if the
# previous tarball is still in SRCDEST (which is $startdir here) makepkg finds it
# and builds the *old* kernel instead. Separately, a patch fetched from the wrong
# `master/<major>` directory either 404s or, worse, applies against a tree it was
# not written for.
#
# This is the invariant that had to hold by hand during the 7.3-rc3 move, and it
# is exactly what repeated RC tracking will get wrong again: assert the tarball
# URL agrees with `pkgver`, and that every patch URL is scoped to the same major.
# Read-only: the recipe is generated into $TMPDIR, never written to.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=packages/misc/linux-cachyos
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-kernel-version-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'kernel recipe version fixture: %s\n' "$1" >&2
    exit 1
}

srcinfo=$tmp/.SRCINFO
GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$root/$recipe" >"$srcinfo" 2>"$tmp/err" ||
    fail "makepkg --printsrcinfo failed for $recipe: $(head -1 "$tmp/err")"

sources=$(sed -n 's/^[[:space:]]*source = //p' "$srcinfo")
[[ -n $sources ]] || fail "the generated .SRCINFO lists no sources"

# --- pkgver -> the expected source-tag stem -------------------------------
pkgver=$(sed -n 's/^[[:space:]]*pkgver = //p' "$srcinfo" | head -1)
[[ -n $pkgver ]] || fail "no pkgver in the generated .SRCINFO"

if [[ $pkgver =~ ^([0-9]+\.[0-9]+)\.rc([0-9]+)$ ]]; then
    major=${BASH_REMATCH[1]}
    tag="cachyos-${major}-rc${BASH_REMATCH[2]}"
elif [[ $pkgver =~ ^([0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
    major=${BASH_REMATCH[1]}
    tag="cachyos-${major}.${BASH_REMATCH[2]}"
else
    fail "unrecognised pkgver '$pkgver' (expected X.Y.Z or X.Y.rcN)"
fi

# --- the tarball must be the one pkgver names -----------------------------
tarball=$(grep -E '\.tar\.(gz|xz|zst)$' <<<"$sources" | head -1)
[[ -n $tarball ]] || fail "no tarball source in the generated .SRCINFO"

base=$(basename "$tarball")
base=${base%.tar.*}
[[ $base == "$tag"-* ]] ||
    fail "tarball '$base' does not match pkgver $pkgver (expected '${tag}-<tagrel>')"

[[ $tarball == */download/"$base"/"$base".tar.* ]] ||
    fail "tarball URL directory and filename disagree: $tarball"

# --- every patch must come from the pkgver's major ------------------------
mapfile -t patches < <(grep 'kernel-patches/master/' <<<"$sources" || true)
((${#patches[@]} > 0)) ||
    fail "no kernel-patches sources: the patch set is unpopulated"

for patch_url in "${patches[@]}"; do
    [[ $patch_url == *"/master/$major/"* ]] ||
        fail "patch URL is not scoped to kernel major $major: $patch_url"
done

# The config is a local source, so a lost one shows up only at build time.
grep -qx 'config' <<<"$sources" || fail "the local 'config' source is missing"

printf 'kernel recipe version fixture: PASS (%s -> %s, %d patch sources)\n' \
    "$pkgver" "$base" "${#patches[@]}"
