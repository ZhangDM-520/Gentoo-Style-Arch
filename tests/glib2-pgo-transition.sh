#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-glib-pgo.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/glib"

cat >"$fixture/bin/arch-meson" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

test "${1:-}" = glib
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
        for profile in $(seq 1 50); do
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

if [[ "$*" == *instrumented/libglib.so* ]]; then
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
warning() { :; }
msg() { :; }
error() {
    printf '%s\n' "\$*" >&2
    return 1
}
source "$root/packages/core/glib2-git/PKGBUILD"
build
pkgdir="\$PWD/pkg"
mkdir -p "\$pkgdir/usr/lib"
: >"\$pkgdir/usr/lib/libglib-2.0.so.0"
verify_no_profile_instrumentation "\$pkgdir"

mkdir -p "\$PWD/instrumented"
: >"\$PWD/instrumented/libglib.so"
if verify_no_profile_instrumentation "\$PWD/instrumented" 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed\n' >&2
    exit 1
fi
EOF
chmod +x "$fixture/run-build.sh"

PATH="$fixture/bin:$PATH" \
CFLAGS='-O3' \
CXXFLAGS='-O3' \
LDFLAGS='' \
"$fixture/run-build.sh"

printf 'glib2 PGO transition fixture: PASS\n'
