#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/git/vencord-git"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'vencord-git recipe: %s\n' "$1" >&2
    exit 1
}

# Assets must exist and survive both .gitignore layers (the root rule that
# denies every subdirectory under a recipe, and any recipe-local file).
assets=(PKGBUILD .SRCINFO)
for asset in "${assets[@]}"; do
    test -f "$root/$recipe/$asset" || fail "missing asset: $recipe/$asset"
    if git -C "$root" check-ignore -q -- "$recipe/$asset"; then
        fail "asset is hidden by .gitignore: $recipe/$asset"
    fi
done

# Read the recipe the same way the builder does; the PKGBUILD overrides the
# `source` builtin, so this runs in its own shell.
vars=$(bash -c '
    source "$1" || exit 1
    printf "pkgname=%s\n" "$pkgname"
    printf "arch=%s\n" "${arch[@]}"
    printf "src=%s\n" "${source[@]}"
    printf "makedepends=%s\n" "${makedepends[@]}"
    printf "options=%s\n" "${options[@]}"
    printf "provides=%s\n" "${provides[@]}"
    printf "conflicts=%s\n" "${conflicts[@]}"
    printf "depends=%s\n" "${depends[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

has() {
    grep -Fxq "$1=$2" <<<"$vars"
}

has pkgname 'vencord-git' || fail "pkgname is not vencord-git"

# Desktop standalone scope: tracks upstream main, arch-neutral JavaScript
# payload, provides/conflicts the plain `vencord` capability.
has src 'Vencord::git+https://github.com/Vendicated/Vencord.git#branch=main' ||
    fail "does not track upstream main"
has arch 'any' || fail "payload is plain JavaScript; arch must be any"
has provides 'vencord' || fail "does not provide vencord"
has conflicts 'vencord' || fail "does not conflict with vencord"

# No hard depends: the host client is a loader choice, not a requirement of
# the payload (the AUR recipe hard-depends on vesktop; this one deliberately
# does not). Belongs in optdepends instead.
if grep -Eq '^depends=.+' <<<"$vars"; then
    fail "hard depends present: $(grep -E '^depends=.+' <<<"$vars")"
fi

# Toolchain: pnpm drives the bundle; git is the VCS source. Java must be
# requested through virtuals if it ever appears — concrete JDK/JRE names
# made pacman demand removal of a package the graph needs (2026-09-18).
for dep in git nodejs pnpm; do
    has makedepends "$dep" || fail "missing makedepend: $dep"
done
if grep -Eq "^[[:space:]]*'(jre|jdk)[a-z0-9_.+-]*'" "$pkgbuild"; then
    fail "depends on a concrete jdk/jre package instead of java-runtime"
fi

# Build stages in order: root workspace install, standalone bundle, type-check.
stages=(
    'pnpm install --frozen-lockfile'
    'pnpm buildStandalone'
    'pnpm testTsc'
)
last=0
for stage in "${stages[@]}"; do
    line=$(grep -Fn -- "$stage" "$pkgbuild" | head -1 | cut -d: -f1) || line=""
    test -n "$line" || fail "missing build stage: $stage"
    if (( line <= last )); then
        fail "build stage out of order: $stage"
    fi
    last=$line
done

# The install runs at the tree root, where pnpm-workspace.yaml applies. A
# subdirectory install would need the workspace-isolating flag (2026-09-18
# logseq incident); its absence here pins that the install is a root one.
grep -Fq -- '--ignore-workspace' "$pkgbuild" &&
    fail "install carries the subdirectory workspace guard but is a root install"

# Scope: no web bundle, no extension build.
grep -Fq 'pnpm buildWeb' "$pkgbuild" &&
    fail "builds web/extension outputs - desktop standalone only"

# Optimisation standard (docs/MEMORY.md §4, Electron/JavaScript bullet):
# no hard-coded host ISA or optimisation level, the exceptions declared
# explicitly, and the ccache + mold probe for incidental native addons.
if grep -Eq -- '-march=|-mtune=|-O[0-9]' "$pkgbuild"; then
    fail "hard-codes a host ISA or optimisation flag"
fi
for opt in '!strip' '!debug' '!lto'; do
    has options "$opt" || fail "missing option: $opt"
done
grep -Fq 'CCACHE_DIR' "$pkgbuild" ||
    fail "native addon builds do not reuse the compiler cache"
grep -Fq 'command -v mold' "$pkgbuild" ||
    fail "native addon builds are not linked through the house mold probe"

# Source verification discipline: never bypass PGP checking, never drop sums
# silently (VCS sources legitimately carry SKIP).
grep -Fq -- '--skippgpcheck' "$pkgbuild" &&
    fail "bypasses PGP checking"

# pkgver() derives from upstream tags in the house -git describe form.
grep -Fq 'git describe --long --tags' "$pkgbuild" ||
    fail "pkgver() does not derive from git describe"

# Package scope: the six desktop standalone bundles land in /usr/lib/vencord
# with the package.json loader shim, and nothing else is shipped from dist/.
grep -Fq 'dist/vencord*' "$pkgbuild" ||
    fail "does not copy the standalone bundle set from dist/"
grep -Fq '/usr/lib/vencord' "$pkgbuild" ||
    fail "payload is not installed to /usr/lib/vencord"
grep -Fq '/usr/lib/vencord/package.json' "$pkgbuild" ||
    fail "loader contract: no package.json shim beside the payloads"

# Topology: the recipe must be reachable through the map and the git group.
grep -Fxq "vencord-git|$recipe" \
    "$root/config/packages.map" || fail "not registered in config/packages.map"
grep -Fxq 'vencord-git' "$root/config/groups/git.list" ||
    fail "not a member of the git group"
grep -q '^vencord-git:' "$root/config/dependencies.conf" ||
    fail "not registered in config/dependencies.conf"

# .SRCINFO must match the recipe.
if ! GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$root/$recipe" |
    diff -q - "$root/$recipe/.SRCINFO" >/dev/null; then
    fail ".SRCINFO is out of sync with the PKGBUILD"
fi

printf 'vencord-git recipe fixture: PASS\n'
