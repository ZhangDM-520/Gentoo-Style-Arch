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
        exit 0
        ;;
    test)
        mkdir -p build
        for profile in $(seq 1 120); do
            : >"build/profile-$profile.gcda"
        done
        exit 0
        ;;
    configure)
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
            if ! grep -Eq '^c_args=.*-fprofile-use=' "$cache" ||
                ! grep -Eq '^cpp_args=.*-fprofile-use=' "$cache"; then
                printf 'final reconfigure did not enable profile-use\n' >&2
                exit 1
            fi
            if ! grep -Eq '^c_args=.*-Wno-error=missing-profile' "$cache" ||
                ! grep -Eq '^cpp_args=.*-Wno-error=missing-profile' "$cache"; then
                printf 'final reconfigure did not exempt missing-profile probes\n' >&2
                exit 1
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

cat >"$fixture/run-build.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$fixture"
package_id="$package_id"
export CARCH="${CARCH:-x86_64}"
warning() { :; }
msg() { :; }
error() {
    printf '%s\n' "\$*" >&2
    return 1
}
source "$root/$recipe_path/PKGBUILD"
build
pkgdir="\$PWD/pkg"
mkdir -p "\$pkgdir/usr/lib"
# A clean payload may still *mention* a .gcda path in shipped text: the
# predicate matches a standalone absolute path, so prose must not fail it.
printf 'coverage notes: rebuild /tmp/x/src/A.dir/b.cxx.gcda\n' \
    >"\$pkgdir/usr/lib/\$package_id.so"
verify_no_profile_instrumentation "\$pkgdir"

# Two shapes of leak, so both detectors stay load-bearing:
#  - symbols: what readelf finds, and only before makepkg strips
#  - paths:   what survives stripping, so only the .gcda predicate sees it
mkdir -p "\$PWD/instrumented-symbols" "\$PWD/instrumented-paths"
: >"\$PWD/instrumented-symbols/\$package_id.so"
printf 'code\0/home/someone/build/pgo-fixture/%s/src/A.dir/b.cxx.gcda\0code\n' \
    "\$package_id" >"\$PWD/instrumented-paths/\$package_id.so"

if verify_no_profile_instrumentation "\$PWD/instrumented-symbols" 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed (coverage symbols)\n' >&2
    exit 1
fi
if verify_no_profile_instrumentation "\$PWD/instrumented-paths" 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed (.gcda paths)\n' >&2
    exit 1
fi
EOF
chmod +x "$fixture/run-build.sh"

PATH="$fixture/bin:$PATH" \
CFLAGS='-O3' \
CXXFLAGS='-O3' \
LDFLAGS='' \
"$fixture/run-build.sh"

# Repo-wide: a recipe-level check that cannot fail the build is decorative.
# bash returns the status of the LAST command in a function, so a call placed
# mid-`package()` without `|| return 1` is discarded and makepkg packages the
# instrumented payload anyway — the check prints its ERROR and exits 0. That is
# how four recipes carried a "guard" that never guarded anything.
call_site_failures=0
while IFS= read -r recipe; do
    mapfile -t lines <"$recipe"
    for i in "${!lines[@]}"; do
        line=${lines[$i]}
        # The definition is `verify_...() {`; only calls have a space after the
        # name, so this cannot mistake one for the other.
        [[ $line =~ ^[[:space:]]*verify_no_profile_instrumentation[[:space:]] ]] || continue
        [[ $line == *'|| return 1'* ]] && continue
        j=$((i + 1))
        while :; do
            next=${lines[$j]:-}
            next=${next#"${next%%[![:space:]]*}"}
            if [[ -z $next || $next == \#* ]]; then
                j=$((j + 1))
                continue
            fi
            break
        done
        if [[ $next != '}' ]]; then
            printf 'pgo-transition: %s:%s discards the check result — add `|| return 1` or make it the last command\n' \
                "${recipe#"$root"/}" "$((i + 1))" >&2
            call_site_failures=1
        fi
    done
done < <(grep -rl 'verify_no_profile_instrumentation()' "$root"/packages/*/*/PKGBUILD)
if ((call_site_failures != 0)); then
    exit 1
fi

printf 'PGO transition fixture (%s): PASS\n' "$package_id"
