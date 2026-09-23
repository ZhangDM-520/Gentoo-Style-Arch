#!/usr/bin/env bash
set -euo pipefail

# Recipe hygiene for zen-browser-pgo: .SRCINFO is a byte-exact regeneration
# of the PKGBUILD, every local source exists and is visible to Git, the
# Speedometer3 workload patch carries its real sha256 (never SKIP), PGP
# checking stays on, options stay pacman-7-legal, and the patch is a valid
# single-file unified diff.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/third-party/zen-browser-pgo"
pkgbuild="$root/$recipe/PKGBUILD"
patch="$root/$recipe/0007-pgo-speedometer3.patch"

fail() {
    printf 'zen-pgo-speedometer: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing $recipe/PKGBUILD"
test -f "$patch" || fail "missing $recipe/0007-pgo-speedometer3.patch"

vars=$(bash -c '
    source "$1" || exit 1
    printf "src=%s\n" "${source[@]}"
    printf "sum=%s\n" "${sha256sums[@]}"
    printf "opt=%s\n" "${options[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

mapfile -t sources < <(grep -F 'src=' <<<"$vars" | cut -d= -f2-)
mapfile -t sums < <(grep -F 'sum=' <<<"$vars" | cut -d= -f2-)
mapfile -t opts < <(grep -F 'opt=' <<<"$vars" | cut -d= -f2-)

[[ ${#sources[@]} -eq ${#sums[@]} ]] ||
    fail "source=() (${#sources[@]}) and sha256sums=() (${#sums[@]}) differ in length"

# pkgver/pkgrel/source count/sha256 count all fall out of the full diff.
if ! GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$root/$recipe" |
    diff -q - "$root/$recipe/.SRCINFO" >/dev/null; then
    fail ".SRCINFO is out of sync with the PKGBUILD"
fi

declare -A sum_of
for i in "${!sources[@]}"; do
    src=${sources[$i]}
    case "$src" in
        *://* | *::*) continue ;;
    esac
    [[ -e $root/$recipe/$src ]] || fail "missing local source: $recipe/$src"
    git -C "$root" check-ignore -q -- "$recipe/$src" &&
        fail "local source hidden by .gitignore: $recipe/$src"
    sum_of["$src"]=${sums[$i]}
done

# The Speedometer3 workload patch: listed in source=() and pinned to the real
# digest of the file on disk; a drifted sum or SKIP silently unpins it.
recorded=${sum_of[0007-pgo-speedometer3.patch]:-}
[[ -n $recorded ]] || fail "0007-pgo-speedometer3.patch not listed in source=()"
[[ $recorded =~ ^[0-9a-f]{64}$ ]] ||
    fail "0007 checksum is not a sha256 digest: $recorded"
actual=$(sha256sum "$patch" | cut -d' ' -f1)
[[ $actual == "$recorded" ]] ||
    fail "0007 sha256sums ($recorded) != file digest ($actual)"

# Source verification discipline: never bypass PGP checking.
grep -Fq -- '--skippgpcheck' "$pkgbuild" && fail "bypasses PGP checking"

# pacman 7.x rejects !check/autodeps in options (recipe lint).
for opt in "${opts[@]}"; do
    case "$opt" in
        '!check' | 'autodeps') fail "invalid options entry: $opt" ;;
    esac
done

# Structural validity of the unified diff.
for marker in '--- a/build/pgo/index.html' '+++ b/build/pgo/index.html' '@@'; do
    grep -Fq -- "$marker" "$patch" ||
        fail "patch lacks unified-diff marker: $marker"
done
[[ $(grep -c '^diff --git' "$patch") -eq 1 ]] ||
    fail "patch must contain exactly one file diff"

printf 'zen-pgo-speedometer fixture: PASS\n'
