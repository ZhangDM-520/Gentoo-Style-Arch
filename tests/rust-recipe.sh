#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/core/rust-git"
pkgbuild="$root/$recipe/PKGBUILD"
srcinfo="$root/$recipe/.SRCINFO"

fail() {
    printf 'rust-git recipe: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing PKGBUILD"
test -f "$srcinfo" || fail "missing .SRCINFO"

# Read the recipe the way the builder does, in a subshell so sourcing cannot
# disturb this fixture's own state.
vars=$(bash -c '
    set -e
    source "$1"
    printf "options=%s\n" "${options[@]}"
    printf "pkgver=%s\n" "${pkgver}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

options=$(sed -n 's/^options=//p' <<<"$vars")

# makepkg's `lto` option appends LTOFLAGS (-flto=auto) to CXXFLAGS, and
# rustc_llvm/build.rs compiles the C++ llvm-wrapper with those flags. The
# resulting GIMPLE objects cannot be materialised by lld — rustc's default
# linker is gnu-lld-cc — so librustc_driver.so would ship undefined LLVMRust*
# symbols and the stage1 rustc_main link would fail with
# --no-allow-shlib-undefined. Explicit !lto is required: the host's global
# OPTIONS already enables `lto`, so merely omitting the line is not enough.
grep -Fqx '!lto' <<<"$options" ||
    fail "options must contain !lto (got: $(tr '\n' ' ' <<<"$options"))"
grep -Eq '^lto$' <<<"$options" &&
    fail "options must not enable bare lto alongside !lto"

# .SRCINFO is committed and must mirror the options array.
grep -Eq '^[[:space:]]*options = !lto$' "$srcinfo" ||
    fail ".SRCINFO lacks 'options = !lto'"
grep -Eq '^[[:space:]]*options = lto$' "$srcinfo" &&
    fail ".SRCINFO still carries 'options = lto'"

# The host must never leak -flto=auto back into this recipe through the
# global OPTIONS: a bare `lto` anywhere in the options array would do it.
test "$(grep -cxF 'lto' <<<"$options")" -eq 0 ||
    fail "bare lto present in options"

# Upstream abcb9780d6d4 (2026-09-07) renamed x.py's `src` install step to
# `rust-src` and gates its default run on [build] extended — which this
# config never sets — so the recipe must invoke the step explicitly.
# Otherwise _pick fails on missing usr/lib/rustlib/src and the whole
# build aborts after 35 minutes of compilation.
grep -Fq 'x.py install rust-src' "$pkgbuild" ||
    fail "PKGBUILD must invoke 'x.py install rust-src' explicitly"

template="$root/$recipe/bootstrap.x86_64.toml"
grep -Eq '^[[:space:]]*"rust-src",$' "$template" ||
    fail "bootstrap template tools must list \"rust-src\" (upstream rename)"
grep -Eq '^[[:space:]]*"src",$' "$template" &&
    fail "bootstrap template still lists the renamed \"src\" tools entry"

# A previously failed build() leaves DESTDIR half-mutated (deleted
# manifests, dangling tool symlinks); build() must wipe it first or the
# next install.sh dies on `cp: not writing through dangling symlink`.
grep -Fq 'rm -rf "$srcdir/dest-rust" "$srcdir/dest-src"' "$pkgbuild" ||
    fail "PKGBUILD must wipe dest-rust/dest-src before installing"

# The template checksum in b2sums must track the file.
grep -Fq "$(b2sum "$template" | cut -d' ' -f1)" "$pkgbuild" ||
    fail "PKGBUILD b2sums does not match bootstrap.x86_64.toml"

printf 'rust-git recipe: ok\n'
