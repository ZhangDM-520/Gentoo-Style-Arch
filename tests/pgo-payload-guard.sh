#!/usr/bin/env bash
# The builder must refuse to install a PGO archive whose payload still carries
# phase-1 instrumentation. Such a binary bakes absolute `.gcda` destinations
# into .rodata and libgcov recreates that whole tree on every invocation
# (2026-09-20: five files in cmake-git and xorg-xwayland-git rebuilt 779 files
# under ~/Projects from one command each).
#
# This asserts the install gate directly, with hand-placed archives and no
# makepkg at all: the property belongs to `install_all`/`install_pkgs_now`, not
# to any one recipe. Four payloads cover the four outcomes:
#
#   pgo-bad    PGO recipe, instrumented usr/bin      -> refuse, install nothing
#   deep-bad   PGO recipe, instrumented usr/libexec   -> refuse. Completeness:
#              a leak outside usr/bin and usr/lib is still a leak
#   pgo-clean  PGO recipe, clean payload, metadata and a doc that quotes a
#              .gcda path -> install. Precision: a mere mention is not a leak
#   plain-bad  non-PGO recipe, instrumented payload   -> install. Gate: a recipe
#              that never instruments cannot leak, so it is never unrolled
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-pgo-payload.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/config/groups" "$fixture/packages" "$fixture/bin"
cp "$root/build-all.fish" "$fixture/build-all.fish"

cat >"$fixture/config/build-defaults.conf" <<'EOF'
lanes=auto
jobs=auto
intensity=xhigh
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
: >"$fixture/config/dependencies.conf"
for group in git stable core misc third-party; do
    : >"$fixture/config/groups/$group.list"
done

# A recipe counts as PGO to the gate purely by naming -fprofile-generate, so the
# gate and the payload are varied independently.
add_recipe() {
    local id="$1" instrumenting="$2"
    mkdir -p "$fixture/packages/$id"
    {
        printf 'pkgname=%s\npkgver=1.0\npkgrel=1\narch=(x86_64)\n' "$id"
        if [[ "$instrumenting" == yes ]]; then
            printf 'build() {\n  CFLAGS+=" -fprofile-generate"\n}\n'
        else
            printf 'build() {\n  :\n}\n'
        fi
    } >"$fixture/packages/$id/PKGBUILD"
    printf '%s|packages/%s\n' "$id" "$id" >>"$fixture/config/packages.map"
    printf '%s\n' "$id" >>"$fixture/config/groups/git.list"
}

leak_path() { printf '/home/someone/build/pgo-fixture/%s/src/A.dir/b.cxx.gcda' "$1"; }

# $1 recipe id, $2 "" | usr/bin | usr/libexec  (where the leak is baked)
add_archive() {
    local id="$1" where="$2" stage
    stage=$(mktemp -d "$fixture/stage.XXXXXX")
    mkdir -p "$stage/usr/bin" "$stage/usr/lib" "$stage/usr/libexec" \
        "$stage/usr/share/doc/$id"
    # Metadata is never a leak: .BUILDINFO records the build's own flags.
    printf 'format = 2\npkgname = %s\nbuildenv = CFLAGS=-O2 -fprofile-generate\n' \
        "$id" >"$stage/.BUILDINFO"
    printf 'pkgname = %s\npkgver = 1.0\n' "$id" >"$stage/.PKGINFO"
    # A doc that *quotes* a .gcda path in prose must not fail the package: the
    # predicate matches a standalone absolute path, not a mention inside a line.
    printf 'coverage notes: rebuild %s\n' "$(leak_path "$id")" \
        >"$stage/usr/share/doc/$id/notes.txt"
    printf 'code\0/usr/lib/clean.so\0code\n' >"$stage/usr/bin/$id"
    printf 'data\n' >"$stage/usr/lib/lib$id.so"
    case "$where" in
        usr/bin) printf 'code\0%s\0code\n' "$(leak_path "$id")" >"$stage/usr/bin/$id" ;;
        usr/libexec) printf 'code\0%s\0code\n' "$(leak_path "$id")" >"$stage/usr/libexec/$id-helper" ;;
    esac
    tar --zstd -cf "$fixture/packages/$id/$id-1.0-1-x86_64.pkg.tar.zst" \
        -C "$stage" .
    rm -rf -- "$stage"
}

archive_of() { printf '%s/packages/%s/%s-1.0-1-x86_64.pkg.tar.zst' "$fixture" "$1" "$1"; }

add_recipe pgo-bad yes
add_recipe deep-bad yes
add_recipe pgo-clean yes
add_recipe plain-bad no
add_archive pgo-bad usr/bin
add_archive deep-bad usr/libexec
add_archive pgo-clean ""
add_archive plain-bad usr/bin

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_PACMAN_LOG"
EOF
chmod +x "$fixture/bin/pacman"

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$fixture/bin/sudo"

: >"$fixture/pacman.log"
export GSA_FAKE_PACMAN_LOG="$fixture/pacman.log"
temp_root="${TMPDIR:-/tmp}"
leftovers_before=$(find "$temp_root" -maxdepth 1 -name 'gsa-pgo-verify.*' 2>/dev/null | wc -l)

run_builder() {
    PATH="$fixture/bin:$PATH" \
    GSA_STATE_DIR="$fixture/state" \
    fish "$fixture/build-all.fish" --installall 2>&1
}

# $1 archive basename, $2 member the refusal must name
refuses() {
    local output
    if output=$(run_builder); then
        printf 'instrumented payload in %s was installed instead of refused:\n%s\n' \
            "$1" "$output" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -F -- "$2" >/dev/null; then
        printf 'refusal for %s did not name %s:\n%s\n' "$1" "$2" "$output" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -F -- 'libgcov would recreate its build tree' >/dev/null; then
        printf 'refusal for %s did not explain the consequence:\n%s\n' "$1" "$output" >&2
        exit 1
    fi
    if [[ -s "$fixture/pacman.log" ]]; then
        printf 'pacman ran even though %s failed the payload check:\n' "$1" >&2
        cat "$fixture/pacman.log" >&2
        exit 1
    fi
}

# ── Case A: an instrumented usr/bin payload is refused, and nothing installed
refuses pgo-bad './usr/bin/pgo-bad'

# ── Case B: a leak under usr/libexec is refused too, not only usr/bin and usr/lib
rm -f "$(archive_of pgo-bad)"
refuses deep-bad './usr/libexec/deep-bad-helper'

# ── Case C: a clean PGO archive installs, and the non-PGO one is not unrolled
rm -f "$(archive_of deep-bad)"
if ! output=$(run_builder); then
    printf 'clean payloads were incorrectly refused:\n%s\n' "$output" >&2
    exit 1
fi
for expected in pgo-clean plain-bad; do
    if ! grep -F "$expected-1.0-1-x86_64.pkg.tar.zst" "$fixture/pacman.log" >/dev/null; then
        printf '%s was not installed:\n' "$expected" >&2
        cat "$fixture/pacman.log" >&2
        exit 1
    fi
done

# The check is read-only: it must not leave the payload unrolled, and must not
# consume or rewrite the archive it inspected.
leftovers_after=$(find "$temp_root" -maxdepth 1 -name 'gsa-pgo-verify.*' 2>/dev/null | wc -l)
if [[ "$leftovers_after" -ne "$leftovers_before" ]]; then
    printf 'payload check left its temp extraction behind (%s -> %s)\n' \
        "$leftovers_before" "$leftovers_after" >&2
    exit 1
fi
if [[ ! -s "$(archive_of pgo-clean)" ]]; then
    printf 'payload check consumed the archive it inspected\n' >&2
    exit 1
fi

printf 'PGO payload guard fixture: PASS\n'
