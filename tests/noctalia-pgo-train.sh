#!/usr/bin/env bash
set -euo pipefail

# Pin the noctalia-git PGO training-hygiene contract, from the 2026-09-23
# incident:
#
#  1. The training tree (dbus-run-session -> sway -> children) must run in its
#     own session/process group, so teardown can signal the *group*. The old
#     code TERMed only dbus-run-session and let sway stray past the build.
#  2. Teardown must be bounded: TERM, a grace window, then a KILL escalation —
#     never a bare TERM and never an unbounded wait.
#  3. CLI subcommands must run with WAYLAND_DISPLAY unset (env -u): with it
#     exported against a dead/foreign socket they probe IPC instead of taking
#     the CLI path that is guaranteed to exit through main() and flush .gcda.
#  4. The 2026-09-23 fix bumped pkgrel, and .SRCINFO must stay in sync.
#
# Static inspection only — this never runs a build.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/git/noctalia-git"
pkgbuild="$root/$recipe/PKGBUILD"
srcinfo="$root/$recipe/.SRCINFO"

fail() {
    printf 'noctalia-pgo-train: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing PKGBUILD: $recipe/PKGBUILD"
test -f "$srcinfo" || fail "missing .SRCINFO: $recipe/.SRCINFO"

# 1. Own session/group: setsid at launch, or an explicit kill -- -PGID group
#    teardown — either construct proves the tree is group-addressable.
if ! grep -Eq 'setsid|kill .+-- -' "$pkgbuild"; then
    fail "training tree has no setsid launch and no kill -- -PGID group teardown"
fi
grep -Fq 'setsid env WLR_BACKENDS=headless' "$pkgbuild" ||
    fail "sway training tree is not launched under setsid"

# 2. Bounded TERM -> KILL group teardown: group TERM, a grace loop, a KILL
#    escalation, and the reaping wait for the recorded leader pid.
grep -Eq 'kill -TERM -- "-\$pgid"' "$pkgbuild" ||
    fail "no group kill -TERM -- -PGID teardown"
grep -Eq 'kill -KILL -- "-\$pgid"' "$pkgbuild" ||
    fail "no KILL escalation after the TERM grace"
grep -Eq 'seq 1 50' "$pkgbuild" ||
    fail "teardown grace window is not bounded (no 50 x 0.1 s loop)"
grep -Eq 'wait "\$sway_pid"' "$pkgbuild" ||
    fail "training leader pid is not reaped with wait"

# 3. CLI subcommands run with WAYLAND_DISPLAY unset.
grep -Fq 'env -u WAYLAND_DISPLAY' "$pkgbuild" ||
    fail "CLI subcommands do not unset WAYLAND_DISPLAY"
grep -Eq 'env -u WAYLAND_DISPLAY "\$bin" --help' "$pkgbuild" ||
    fail "the --help CLI probe does not carry env -u WAYLAND_DISPLAY"

# 4. pkgrel bumped past the pre-incident value, and .SRCINFO in sync with the
#    PKGBUILD on the version fields (--printsrcinfo does not re-run pkgver(),
#    so the static values are what both files must carry).
# shellcheck disable=SC1090
read -r pkgver_src pkgrel_src < <(bash -c '
    source "$1" >/dev/null || exit 1
    printf "%s %s\n" "$pkgver" "$pkgrel"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"
pkgver_info=$(sed -n 's/^[[:space:]]*pkgver = //p' "$srcinfo" | head -1)
pkgrel_info=$(sed -n 's/^[[:space:]]*pkgrel = //p' "$srcinfo" | head -1)
test -n "$pkgver_src" && test -n "$pkgrel_src" ||
    fail "PKGBUILD did not yield pkgver/pkgrel"
test -n "$pkgver_info" && test -n "$pkgrel_info" ||
    fail ".SRCINFO did not yield pkgver/pkgrel"
[[ $pkgrel_src =~ ^[0-9]+$ ]] || fail "pkgrel is not an integer: $pkgrel_src"
(( pkgrel_src >= 2 )) ||
    fail "pkgrel was not bumped for the 2026-09-23 PGO fix (pkgrel=$pkgrel_src)"
[[ $pkgver_src == "$pkgver_info" ]] ||
    fail "pkgver out of sync: PKGBUILD=$pkgver_src .SRCINFO=$pkgver_info"
[[ $pkgrel_src == "$pkgrel_info" ]] ||
    fail "pkgrel out of sync: PKGBUILD=$pkgrel_src .SRCINFO=$pkgrel_info"

printf 'noctalia-pgo-train fixture: PASS\n'
