#!/usr/bin/env bash
set -euo pipefail

# Pin the noctalia-git PGO fallback contract, from the 2026-09-23 incident:
#
#  1. Meson's b_pgo enum is off/generate/use. The incomplete-profile fallback
#     used `-Db_pgo=none`, which meson rejects outright ("Value \"none\" ...
#     not one of the choices") and the whole build() died after training.
#  2. sway's IPC socket lives under XDG_RUNTIME_DIR as
#     sway-ipc.<pid>.<rand>.sock and the full path must fit the 108-byte Unix
#     sun_path. The deep $srcdir sandbox (~93 chars before the socket name)
#     overflowed it, the training sway SEGVed, and the run fell back with
#     exactly 1 .gcda. The runtime dir therefore comes from a short private
#     /tmp dir and is removed on teardown.
#
# Static inspection only — this never runs a build.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/git/noctalia-git"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'noctalia-pgo: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing PKGBUILD: $recipe/PKGBUILD"

# The incomplete-profile fallback must be exactly -Db_pgo=off ...
grep -Eq 'meson configure build-release -Db_pgo=off -Db_lto=true' "$pkgbuild" ||
    fail "incomplete-profile fallback is not 'meson configure build-release -Db_pgo=off -Db_lto=true'"
# ... and the invalid enum value must appear nowhere in the recipe.
if grep -Fq -- '-Db_pgo=none' "$pkgbuild"; then
    fail "-Db_pgo=none appears in the PKGBUILD; meson accepts only off/generate/use"
fi

# The incomplete-profile guard itself (threshold + warning) is part of the
# contract: without it an empty profile would be used and pessimize the build.
grep -Fq '(( gcda_count > 100 ))' "$pkgbuild" ||
    fail "incomplete-profile threshold (>100 .gcda) is missing"
grep -Fq 'PGO profile incomplete' "$pkgbuild" ||
    fail "incomplete-profile warning is missing"

# Short XDG_RUNTIME_DIR: assigned from mktemp -d under /tmp (not from $work,
# whose deep path overflows sway's 108-byte sun_path), exported from that
# variable, and rm -rf'd by the teardown.
grep -Eq 'rt_dir="\$\(mktemp -d /tmp/' "$pkgbuild" ||
    fail "XDG runtime dir is not created from a short mktemp -d /tmp/ path"
grep -Fq 'export XDG_RUNTIME_DIR="$rt_dir"' "$pkgbuild" ||
    fail "XDG_RUNTIME_DIR is not exported from the short /tmp dir"
grep -Eq 'rm -rf "\$rt_dir"' "$pkgbuild" ||
    fail "teardown does not rm -rf the short runtime dir"

# The rest of the sandboxed XDG state stays under $work (only the runtime dir
# moved to /tmp, so the sun_path fix did not silently relocate everything).
grep -Fq 'export XDG_CONFIG_HOME="$work/config"' "$pkgbuild" ||
    fail "XDG_CONFIG_HOME is no longer sandboxed under \$work"
grep -Fq 'export XDG_DATA_HOME="$work/data"' "$pkgbuild" ||
    fail "XDG_DATA_HOME is no longer sandboxed under \$work"

printf 'noctalia-pgo fixture: PASS\n'
