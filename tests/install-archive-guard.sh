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
# Invocation counter: the -s cases must observe that a SKIPPED build never
# reaches makepkg — the lane's "already built" line is silent in quiet mode.
if [[ -n ${GSA_FIXTURE_MAKEPKG_COUNT:-} ]]; then
    printf 'run\n' >>"$GSA_FIXTURE_MAKEPKG_COUNT"
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
    # archive" rather than "the output looked encouraging". The same-version
    # check's queries (-Qp/-Qi) are answered from GSA_FIXTURE_QP/QI; unset,
    # they print nothing and fail — the builder's conservative
    # "no answer → install" fallback, which is what keeps cases A/B honest.
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FIXTURE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    [[ -n ${GSA_FIXTURE_QP:-} ]] || exit 1
    printf '%s\n' "$GSA_FIXTURE_QP"
    ;;
-Qi)
    [[ -n ${GSA_FIXTURE_QI:-} ]] || exit 1
    printf '%s\n' "$GSA_FIXTURE_QI"
    ;;
esac
exit "${GSA_FIXTURE_PACMAN_RC:-0}"
EOF
    chmod +x "$dir/bin/pacman"
}

# Builder flags for the NEXT run_builder call; cases override this instead of
# duplicating the fixed --allow-broken-rustc/--no-deps/--no-sync preamble.
builder_args=(-i p1)

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
            GSA_FIXTURE_MAKEPKG_COUNT="$dir/makepkg.count" \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir/build-all.fish" \
            --allow-broken-rustc --no-deps --no-sync "${builder_args[@]}" 2>&1
    ) || return $?
    return 0
}

# ─── Case A: trailing comment on pkgver= must not hide the archive ───────────
# Also pins the conservative fallback of the same-version check: the stub
# answers neither -Qp nor -Qi here, and the run must still reach pacman -U.
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

# ─── The same-version sanity check (-i) and its force bypass (-fi) ───────────
# 2026-09-25: the resume idiom -s -i re-ran pacman -U for every already-built
# package even when its exact version was already installed. The builder now
# skips an install only on POSITIVE evidence: version match AND an install
# date not older than the archive (a same-version rebuild still installs).
# Every doubt — no query answer, an unparseable date — must still install.
# -fi implies -i and bypasses the check entirely.

fresh_qi() { # Install Date one day AFTER the archive about to be built
    printf 'Version : %s\nInstall Date : %s\n' "$1" \
        "$(date -d '+1 day' '+%Y-%m-%d %H:%M:%S')"
}

stale_qi() { # Install Date one day BEFORE the archive — same version, old payload
    printf 'Version : %s\nInstall Date : %s\n' "$1" \
        "$(date -d '-1 day' '+%Y-%m-%d %H:%M:%S')"
}

assert_no_u() { # $1 = dir, $2 = label
    if grep -q -- 'pacman -U' "$1/pacman.log" 2>/dev/null; then
        printf '%s: pacman -U ran although the install should have been skipped:\n' "$2" >&2
        cat "$1/pacman.log" >&2
        exit 1
    fi
}

assert_u() { # $1 = dir, $2 = label
    if ! grep -q -- 'pacman -U' "$1/pacman.log" 2>/dev/null; then
        printf '%s: pacman -U never ran:\n' "$2" >&2
        cat "$1/pacman.log" 2>/dev/null >&2 || true
        exit 1
    fi
    if ! grep -F 'p1-1.0.0-1-any.pkg.tar.zst' "$1/pacman.log" >/dev/null; then
        printf '%s: pacman -U ran without the built archive: %s\n' "$2" \
            "$(cat "$1/pacman.log")" >&2
        exit 1
    fi
}

assert_skip_message() { # $1 = dir, $2 = label — quiet lane logs go to state/
    if grep -rq 'already installed' "$1/state" 2>/dev/null ||
        grep -q 'already installed' <<<"$FIXTURE_OUTPUT"; then
        return 0
    fi
    printf '%s: skip-install message missing from log and output:\n%s\n' "$2" \
        "$FIXTURE_OUTPUT" >&2
    exit 1
}

# Case C: exact version already installed, install fresher than the archive
# → no transaction, success still reported.
dir_c="$fixture/case-c"
make_workspace "$dir_c" "pkgver=1.0.0"
builder_args=(-i p1)
if ! run_builder "$dir_c" GSA_FIXTURE_QP='p1 1.0.0-1' \
    "GSA_FIXTURE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case C: run failed although the exact version was installed:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case C: skip was not reported as success:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_c" 'case C'
assert_skip_message "$dir_c" 'case C'

# Case D: a DIFFERENT installed version must install.
dir_d="$fixture/case-d"
make_workspace "$dir_d" "pkgver=1.0.0"
builder_args=(-i p1)
if ! run_builder "$dir_d" GSA_FIXTURE_QP='p1 1.0.0-1' \
    "GSA_FIXTURE_QI=$(fresh_qi 0.9.0-1)"; then
    printf 'case D: run failed on a version difference:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_d" 'case D'

# Case E: same version, but the install PREDATES the archive — a rebuild that
# never reached the system. The freshness guard must install it.
dir_e="$fixture/case-e"
make_workspace "$dir_e" "pkgver=1.0.0"
builder_args=(-i p1)
if ! run_builder "$dir_e" GSA_FIXTURE_QP='p1 1.0.0-1' \
    "GSA_FIXTURE_QI=$(stale_qi 1.0.0-1)"; then
    printf 'case E: run failed on a stale install date:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_e" 'case E'

# Case F: -fi ALONE (no -i) implies install and bypasses the check that
# cases C would apply — same fresh same-version state, but -U must run.
dir_f="$fixture/case-f"
make_workspace "$dir_f" "pkgver=1.0.0"
builder_args=(-fi p1)
if ! run_builder "$dir_f" GSA_FIXTURE_QP='p1 1.0.0-1' \
    "GSA_FIXTURE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case F: -fi run failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case F: -fi did not run as an install run:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'Install:  yes (forced)' <<<"$FIXTURE_OUTPUT"; then
    printf 'case F: run summary does not report a forced install:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_f" 'case F'

# Case G: the original complaint — resume with -s -i: the build is skipped
# AND the already-installed package is not reinstalled.
dir_g="$fixture/case-g"
make_workspace "$dir_g" "pkgver=1.0.0"
builder_args=(p1)
if ! run_builder "$dir_g"; then # first run: build only (no -i)
    printf 'case G: initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-s -i p1)
if ! run_builder "$dir_g" GSA_FIXTURE_QP='p1 1.0.0-1' \
    "GSA_FIXTURE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case G: -s -i resume failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
# makepkg ran exactly ONCE across both runs: run 2 skipped the build. (The
# lane's "already built" ui_info is gated to interactive mode, so the build
# side is observed at the stub, not at the terminal.)
g_runs=$(grep -c '^run$' "$dir_g/makepkg.count" 2>/dev/null || true)
if [[ "$g_runs" != 1 ]]; then
    printf 'case G: -s did not skip the build (makepkg ran %s times):\n%s\n' \
        "$g_runs" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_g" 'case G'
assert_skip_message "$dir_g" 'case G'

# Case H: -s -fi — the build is still skipped, but the install is forced.
dir_h="$fixture/case-h"
make_workspace "$dir_h" "pkgver=1.0.0"
builder_args=(p1)
if ! run_builder "$dir_h"; then # first run: build only (no -i)
    printf 'case H: initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-s -fi p1)
if ! run_builder "$dir_h" GSA_FIXTURE_QP='p1 1.0.0-1' \
    "GSA_FIXTURE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case H: -s -fi resume failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
h_runs=$(grep -c '^run$' "$dir_h/makepkg.count" 2>/dev/null || true)
if [[ "$h_runs" != 1 ]]; then
    printf 'case H: -s did not skip the build (makepkg ran %s times):\n%s\n' \
        "$h_runs" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_h" 'case H'

printf 'install archive guard fixture: PASS\n'
