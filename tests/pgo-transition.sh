#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# One fixture covers every PGO-transition recipe. With no arguments it runs
# each package/project/recipe triple in turn — the five six-line
# *-pgo-transition.sh wrappers this replaces did exactly that via `exec` — and
# with the three positional arguments it runs only that pair. A failing pair
# fails the whole fixture.
if (($# == 0)); then
    status=0
    while read -r pkg proj recipe; do
        bash "${BASH_SOURCE[0]}" "$pkg" "$proj" "$recipe" || status=1
    done <<'PAIRS'
cairo-git cairo packages/git/cairo-git
glib2-git glib packages/core/glib2-git
gtk3-git gtk packages/git/gtk3-git
gtk4-git gtk packages/core/gtk4-git
xorg-xwayland-git xserver packages/git/xorg-xwayland-git
PAIRS
    exit $status
fi

package_id="${1:-glib2-git}"
project_dir="${2:-glib}"
recipe_path="${3:-packages/core/glib2-git}"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-pgo-${package_id}.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/$project_dir"

cat >"$fixture/bin/arch-meson" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

test "${2:-}" = build
mkdir -p build
{
    printf 'c_args=%s\n' "${CFLAGS:-}"
    printf 'cpp_args=%s\n' "${CXXFLAGS:-}"
    # Meson carries compiler instrumentation into its cached link options.
    printf 'c_link_args=%s\n' "${CFLAGS:-}"
    printf 'cpp_link_args=%s\n' "${CXXFLAGS:-}"
} >build/fake-meson-cache
EOF
chmod +x "$fixture/bin/arch-meson"

cat >"$fixture/bin/meson" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cache=build/fake-meson-cache

set_option() {
    local key="$1"
    local value="$2"
    local replacement
    replacement=$(mktemp)
    awk -F= -v key="$key" '$1 != key' "$cache" >"$replacement"
    printf '%s=%s\n' "$key" "$value" >>"$replacement"
    mv "$replacement" "$cache"
}

case "${1:-}" in
    compile)
        mkdir -p build/meson-private
        : >build/meson-private/sanity_check_for_c.exe
        chmod +x build/meson-private/sanity_check_for_c.exe
        grep -E '^c_args=' "$cache" >>build/compile.log
        exit 0
        ;;
    test)
        mkdir -p build
        for profile in $(seq 1 "${PGO_FIXTURE_GCDA_COUNT:-120}"); do
            : >"build/profile-$profile.gcda"
        done
        exit 0
        ;;
    configure)
        printf '%s\n' "$*" >>build/configure.log
        exit 0
        ;;
    setup)
        shift
        if test "${1:-}" = --reconfigure; then
            shift
            for argument in "$@"; do
                case "$argument" in
                    -Dc_args=*) set_option c_args "${argument#-Dc_args=}" ;;
                    -Dcpp_args=*) set_option cpp_args "${argument#-Dcpp_args=}" ;;
                    -Dc_link_args=*) set_option c_link_args "${argument#-Dc_link_args=}" ;;
                    -Dcpp_link_args=*) set_option cpp_link_args "${argument#-Dcpp_link_args=}" ;;
                esac
            done

            if grep -E '^(c_args|cpp_args|c_link_args|cpp_link_args)=' "$cache" |
                grep -F -- '-fprofile-generate' >/dev/null; then
                printf 'cached profile-generate flag survived final reconfigure\n' >&2
                exit 1
            fi
            if grep -Eq '^c_args=.*-fprofile-use=' "$cache"; then
                # Profile path: both languages carry the profile, with the
                # probe exemption that keeps feature detection honest.
                if ! grep -Eq '^cpp_args=.*-fprofile-use=' "$cache" ||
                    ! grep -Eq '^c_args=.*-Wno-error=missing-profile' "$cache" ||
                    ! grep -Eq '^cpp_args=.*-Wno-error=missing-profile' "$cache"; then
                    printf 'final reconfigure did not enable the full profile-use flag set\n' >&2
                    exit 1
                fi
                : >build/mode-profile
            else
                # Fallback path: a thin training run must land on a clean,
                # non-instrumented configuration — no generate flag may come
                # back, and no profile-use may appear either.
                if grep -E '^(c_args|cpp_args|c_link_args|cpp_link_args)=' "$cache" |
                    grep -Eq -- '-fprofile-(generate|use)'; then
                    printf 'fallback reconfigure left profile flags in the cache\n' >&2
                    exit 1
                fi
                : >build/mode-fallback
            fi
        fi
        exit 0
        ;;
    *)
        printf 'unexpected fake meson invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$fixture/bin/meson"

cat >"$fixture/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *meson-private/sanity_check_for_c.exe* ]]; then
    printf '0000000000000000 g    DF .text  0000000000000000 __gcov_init\n'
    exit 0
fi

if [[ "$*" == *instrumented-symbols/* ]]; then
    printf '0000000000000000 g    DF .text  0000000000000000 __gcov_init\n'
    exit 0
fi

exec /usr/bin/readelf "$@"
EOF
chmod +x "$fixture/bin/readelf"

cat >"$fixture/run-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$fixture"
export CARCH="${CARCH:-x86_64}"
warning() { :; }
msg() { :; }
error() {
    printf '%s\n' "$*" >&2
    return 1
}
# makepkg shim: $startdir is the recipe directory before the PKGBUILD is
# sourced — this is how the real builder resolves `source "$startdir/…"`.
startdir="$root/$recipe_path"
source "$root/$recipe_path/PKGBUILD"

rm -rf build pkg
build

pkgdir="$PWD/pkg"
mkdir -p "$pkgdir/usr/lib"
# A clean payload may still *mention* a .gcda path in shipped text: the
# predicate matches a standalone absolute path, so prose must not fail it.
printf 'coverage notes: rebuild /tmp/x/src/A.dir/b.cxx.gcda\n' \
    >"$pkgdir/usr/lib/$package_id.so"
verify_no_profile_instrumentation "$pkgdir"

# Two shapes of leak, so both detectors stay load-bearing:
#  - symbols: what readelf finds, and only before makepkg strips
#  - paths:   what survives stripping, so only the path predicate sees it
mkdir -p "$PWD/instrumented-symbols" "$PWD/instrumented-paths"
: >"$PWD/instrumented-symbols/$package_id.so"
printf 'code\0/home/someone/build/pgo-fixture/%s/src/A.dir/b.cxx.gcda\0code\n' \
    "$package_id" >"$PWD/instrumented-paths/$package_id.so"

# The shared gate (lib/pgo.sh, sourced through the PKGBUILD) is fatal by
# design — it calls `exit 1` — so the negative cases run it in subshells and
# assert the subshell's exit status.
if ( verify_no_profile_instrumentation "$PWD/instrumented-symbols" ) 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed (coverage symbols)\n' >&2
    exit 1
fi
if ( verify_no_profile_instrumentation "$PWD/instrumented-paths" ) 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed (.gcda paths)\n' >&2
    exit 1
fi

# The transition itself: phase 1 compiles instrumented; the final compile
# must be the one the threshold branch selected.
first_compile=$(head -n1 build/compile.log)
last_compile=$(tail -n1 build/compile.log)
case "${PGO_FIXTURE_EXPECT:?}" in
    profile)
        test -f build/mode-profile || {
            printf 'profile branch: no profile-use reconfigure happened\n' >&2
            exit 1
        }
        case "$last_compile" in
            *-fprofile-use*) ;;
            *)
                printf 'profile branch: final compile is not profile-use: %s\n' \
                    "$last_compile" >&2
                exit 1
                ;;
        esac
        ;;
    fallback)
        test -f build/mode-fallback || {
            printf 'fallback branch: no clean reconfigure happened\n' >&2
            exit 1
        }
        case "$first_compile" in
            *-fprofile-generate*) ;;
            *)
                printf 'fallback branch: phase-1 compile was not instrumented: %s\n' \
                    "$first_compile" >&2
                exit 1
                ;;
        esac
        # The below-threshold branch must compile a FINAL NON-INSTRUMENTED
        # build — the 2026-09-16 bug class half-reconfigured and compiled a
        # still-instrumented payload.
        case "$last_compile" in
            *-fprofile-*)
                printf 'fallback branch: final compile still carries profile flags: %s\n' \
                    "$last_compile" >&2
                exit 1
                ;;
        esac
        # ...and it re-enables LTO on the way out.
        case "$(tail -n1 build/configure.log)" in
            *b_lto=true*) ;;
            *)
                printf 'fallback branch: LTO was not re-enabled on the final configure\n' >&2
                exit 1
                ;;
        esac
        ;;
    *)
        printf 'unexpected PGO_FIXTURE_EXPECT: %s\n' "$PGO_FIXTURE_EXPECT" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$fixture/run-build.sh"

env \
    PATH="$fixture/bin:$PATH" \
    CFLAGS='-O3' \
    CXXFLAGS='-O3' \
    LDFLAGS='' \
    fixture="$fixture" \
    root="$root" \
    recipe_path="$recipe_path" \
    package_id="$package_id" \
    PGO_FIXTURE_GCDA_COUNT=120 \
    PGO_FIXTURE_EXPECT=profile \
    "$fixture/run-build.sh"

# The below-threshold branch is a real branch, not dead code: it is what a
# thin or failed training run falls back to, and it harboured the 2026-09-16
# bug class (a half-reconfigure that compiled a still-instrumented final
# build). Drive it with a stub training run that touches only 3 TUs — below
# every pair's threshold — and assert the fallback reconfigures cleanly,
# re-enables LTO and compiles a final non-instrumented build.
env \
    PATH="$fixture/bin:$PATH" \
    CFLAGS='-O3' \
    CXXFLAGS='-O3' \
    LDFLAGS='' \
    fixture="$fixture" \
    root="$root" \
    recipe_path="$recipe_path" \
    package_id="$package_id" \
    PGO_FIXTURE_GCDA_COUNT=3 \
    PGO_FIXTURE_EXPECT=fallback \
    "$fixture/run-build.sh"

printf 'PGO transition fixture (%s): PASS\n' "$package_id"
