#!/usr/bin/env bash
set -euo pipefail

# Every local file a recipe asks makepkg for must exist AND be committed.
#
# Why repo-wide: a recipe can be published with a missing asset in two ways
# that are both silent at build-authorship time —
#   1. the file was never created/committed, and
#   2. the file exists locally but an ignore rule (the `*`-with-negations
#      allowlist pattern 9 recipes use, or a root rule) keeps it out of Git, so
#      a clean checkout is missing it. That is the 2026-09-16 incident class.
# The per-recipe fixtures only cover the recipes someone remembered to write
# one for; this walks all of them.
#
# Local sources are listed by sourcing each PKGBUILD in a subshell, which is how
# build-all.fish itself resolves them (git+ URLs, name::URL prefixes,
# `#fragment`s and shell variables all resolve the same way makepkg sees them).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

fail() {
    printf 'recipe sources fixture: %s\n' "$1" >&2
    exit 1
}

declare -A seen
checked=0
installs=0
missing=0
untracked=0

while IFS= read -r recipe; do
    # A PKGBUILD that cannot be sourced cannot be audited — fail loudly rather
    # than silently skipping the recipe.
    if ! mapfile -t sources < <(
        cd "$recipe" &&
            bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s\n" "${source[@]}"'
    ); then
        fail "cannot source $recipe/PKGBUILD"
    fi

    for src in "${sources[@]}"; do
        [[ -n $src ]] || continue
        # Remote entries are fetched at build time; .sig/.asc companions of a
        # remote entry carry the upstream signature and are fetched with it.
        case "$src" in
            *://* | *::*) continue ;;
            *.sig | *.asc) continue ;;
        esac

        checked=$((checked + 1))
        path="$recipe/$src"
        if [[ ! -e $path ]]; then
            printf 'missing local source: %s\n' "$path" >&2
            missing=$((missing + 1))
            continue
        fi
        if ! git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            # Downloaded GNU patch files: fetched by source URLs and deliberately
            # kept out of the tree (packages/stable/bash/.gitignore).
            if [[ $src == bash[0-9]*-[0-9]* ]]; then
                continue
            fi
            printf 'untracked local source: %s\n' "$path" >&2
            untracked=$((untracked + 1))
            continue
        fi
        seen["$path"]=1
    done

    # `install=` scripts are packaging inputs too, and are not part of source=(),
    # so a missing or uncommitted one only shows up at `makepkg --install` time.
    # `install=` inside package_*() overrides the top-level value (pipewire), and
    # recipes may reference ${pkgbase} (gtk3-git), so resolve that one variable
    # and skip anything still unexpanded (a computed name cannot be checked).
    pkgbase=$(cd "$recipe" &&
        bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s" "${pkgbase:-}"' 2>/dev/null)
    [[ -n $pkgbase ]] || pkgbase=$(basename "$recipe")
    while IFS= read -r install_file; do
        install_file=${install_file//'${pkgbase}'/$pkgbase}
        install_file=${install_file//'$pkgbase'/$pkgbase}
        [[ -n $install_file ]] || continue
        [[ $install_file != *'$'* ]] || continue
        path="$recipe/$install_file"
        [[ -e $path ]] || {
            printf 'missing install script: %s\n' "$path" >&2
            missing=$((missing + 1))
            continue
        }
        installs=$((installs + 1))
        git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || {
            printf 'untracked install script: %s\n' "$path" >&2
            untracked=$((untracked + 1))
        }
    done < <(grep -hoP '^\s*install=\K[^\s#]+' "$recipe/PKGBUILD" 2>/dev/null |
        tr -d "\"'" | sort -u)
done < <(find packages -mindepth 3 -maxdepth 3 -name PKGBUILD -printf '%h\n' | sort)

((missing == 0)) || fail "$missing local source(s) do not exist"
((untracked == 0)) || fail "$untracked local source(s) are not committed"

# An ignore file that hides itself cannot be committed, so on a clean checkout
# the rule is simply gone and the recipe's own hygiene is untestable — the
# shape packages/git/xorg-xwayland-git had (a bare `*` with no negations).
while IFS= read -r ignore_file; do
    git -C "$root" ls-files --error-unmatch -- "$ignore_file" >/dev/null 2>&1 ||
        fail "recipe ignore file is not committed (it hides itself): $ignore_file"
done < <(find packages -mindepth 3 -maxdepth 3 -name .gitignore | sort)

# Tracked files that the ignore rules would exclude: either a rule was added
# after the file was committed, or a rule is broader than anyone intended.
ignored_tracked=$(git -C "$root" ls-files -i -c --exclude-standard)
if [[ -n $ignored_tracked ]]; then
    printf 'tracked files matched by ignore rules:\n%s\n' "$ignored_tracked" >&2
    fail 'ignore rules exclude files that are already tracked'
fi

# A recipe directory whose only tracked file is the PKGBUILD is fine (all of its
# sources are remote), but every recipe must at least be committed in full:
# a clean checkout has to be able to build what the map advertises.
if ! git -C "$root" ls-files --error-unmatch -- packages/*/*/PKGBUILD >/dev/null 2>&1; then
    fail 'one or more PKGBUILDs are not committed'
fi

printf 'recipe sources fixture: PASS (%d local sources and %d install script(s) across %d recipes, all tracked)\n' \
    "$checked" "$installs" "$(find packages -mindepth 3 -maxdepth 3 -name PKGBUILD | wc -l)"
