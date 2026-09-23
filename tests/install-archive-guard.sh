#!/usr/bin/env bash
set -euo pipefail

# Regression fixture for the 2026-09-20 `-i` defects (see docs/MEMORY.md):
#
#  1. list_split_pkgs read `pkgver=` with `grep | cut`, which keeps a trailing
#     PKGBUILD comment. The value then matched no archive, so the find returned
#     nothing — and install_pkgs_now treated "no arguments" as success.
#  2. install_pkgs_now returned 0 for an empty package list, so `-i` reported
#     "All builds succeeded!" without pacman ever being invoked.
#
# The invariant this fixture enforces is behavioural, not textual: a run that
# reports success under `-i` must have actually installed something. Case B
# pins the second half — when the archive genuinely cannot be found the run
# must FAIL, because silence is what hid the bug for so long.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-install-guard.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

make_workspace() { # $1 = sandbox dir, $2 = pkgver line in the PKGBUILD
    local dir=$1 pkgver_line=$2
    mkdir -p "$dir/config/groups" "$dir/packages/p1" "$dir/bin"

    # Fixtures run the copied script from $dir, exactly like the real checkout.
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
    : >"$dir/config/dependencies.conf"
    for group in git stable core misc third-party app; do
        : >"$dir/config/groups/$group.list"
    done
    printf 'p1\n' >>"$dir/config/groups/git.list"
    printf 'p1|packages/p1\n' >"$dir/config/packages.map"

    # The trailing comment is the whole point of case A: it is legal PKGBUILD
    # syntax and the builder must read the VALUE, not the line.
    cat >"$dir/packages/p1/PKGBUILD" <<EOF
pkgname=p1
$pkgver_line
pkgrel=1
arch=(any)
EOF

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
# A real makepkg writes $pkgname-$pkgver-$pkgrel-$arch.pkg.tar.zst into
# $startdir. GSA_FIXTURE_NO_ARCHIVE models "build succeeded, archive absent".
if [[ "${GSA_FIXTURE_NO_ARCHIVE:-0}" != 1 ]]; then
    : >"$PWD/p1-1.0.0-1-any.pkg.tar.zst"
fi
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    # sudo is faked so the fixture never depends on the host's timestamp: the
    # builder's install path is `run_pacman_locked ... sudo pacman -U ...`.
    cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
args=()
for a in "$@"; do
    case $a in
    -n | -v | --) ;;
    *) args+=("$a") ;;
    esac
done
((${#args[@]})) || exit 0
exec "${args[@]}"
EOF
    chmod +x "$dir/bin/sudo"

    # Records every install attempt, so the assertion is "pacman ran with this
    # archive" rather than "the output looked encouraging".
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FIXTURE_PACMAN_LOG:?}"
exit "${GSA_FIXTURE_PACMAN_RC:-0}"
EOF
    chmod +x "$dir/bin/pacman"
}

# Runs the builder against one sandbox; leaves output in $FIXTURE_OUTPUT and
# returns the builder's exit status.
run_builder() { # $1 = dir, $2 = extra env NAME=VALUE ...
    local dir=$1
    shift
    FIXTURE_OUTPUT=$(
        env "$@" \
            PATH="$dir/bin:$PATH" \
            GSA_STATE_DIR="$dir/state" \
            GSA_FIXTURE_PACMAN_LOG="$dir/pacman.log" \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir/build-all.fish" \
            --allow-broken-rustc --no-deps --no-sync -i p1 2>&1
    ) || return $?
    return 0
}

# ─── Case A: trailing comment on pkgver= must not hide the archive ───────────
dir_a="$fixture/case-a"
make_workspace "$dir_a" "pkgver=1.0.0 # bump me"
if ! run_builder "$dir_a"; then
    printf 'case A: builder failed on a valid PKGBUILD with a commented pkgver:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case A: success was not reported at all:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ ! -s "$dir_a/pacman.log" ]]; then
    printf 'case A: reported success without ever invoking pacman — the archive\n' >&2
    printf 'was not found (trailing comment kept in pkgver) and the empty\n' >&2
    printf 'install was swallowed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -F 'p1-1.0.0-1-any.pkg.tar.zst' "$dir_a/pacman.log" >/dev/null; then
    printf 'case A: pacman ran without the built archive: %s\n' \
        "$(cat "$dir_a/pacman.log")" >&2
    exit 1
fi

# ─── Case B: no archive at all must FAIL, never report success ───────────────
dir_b="$fixture/case-b"
make_workspace "$dir_b" "pkgver=1.0.0"
if run_builder "$dir_b" GSA_FIXTURE_NO_ARCHIVE=1; then
    printf 'case B: `-i` succeeded with no package archive to install:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case B: reported "All builds succeeded!" while failing:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ -s "$dir_b/pacman.log" ]]; then
    printf 'case B: pacman ran with nothing to install: %s\n' \
        "$(cat "$dir_b/pacman.log")" >&2
    exit 1
fi

printf 'install archive guard fixture: PASS\n'
