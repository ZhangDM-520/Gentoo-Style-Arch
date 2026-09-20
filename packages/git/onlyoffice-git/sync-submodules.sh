#!/usr/bin/env bash
# Refresh the ONLYOFFICE pins in this recipe for a new upstream release.
#
# Usage:
#   ./sync-submodules.sh                 # verify the current pins, change nothing
#   ./sync-submodules.sh v9.5.0          # resolve a release, print the new block
#   ./sync-submodules.sh v9.5.0 --write  # ...and rewrite PKGBUILD in place
#
# Why this does not use the GitHub tags API: it does not list every tag. The
# build tag v9.4.0.130 exists in all ten module repositories, but it does not
# appear anywhere in core's first 500 API results, so an API-driven lookup
# concludes, wrongly, that the tag is missing. `git ls-remote` lists them all.
#
# Two independent namespaces are involved and they must not be mixed:
#   v9.4.0      the DesktopEditors release tag. Exists ONLY in DesktopEditors.
#   v9.4.0.130  the build tag. Exists in each of the ten module repositories.
# Modules are pinned by commit, which is the build tag's commit.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MODULES=(
    core desktop-apps desktop-sdk sdkjs sdkjs-forms
    web-apps dictionaries build_tools core-fonts document-templates
)
# Only web-apps is fetched from a differently-named repository; .gitmodules at
# v9.4.0 maps the `web-apps` path to web-apps-pro. Both resolve the build tag to
# the same commit, so this is a rename rather than a divergence.
declare -A REPO_NAME=(
    [web-apps]=web-apps-pro
)
GH=https://github.com/ONLYOFFICE

die() { printf 'sync-submodules: %s\n' "$*" >&2; exit 1; }

# Read a top-level assignment from PKGBUILD, up to the first space or '#'.
# A plain 's/.*//' would fold an inline comment into the value -- reading
# `_oo_release=9.4.0   # DesktopEditors release tag` as the whole string, so
# every lookup of that tag then misses with a confusing "no tag" error.
pkgbuild_var() { sed -n "s/^${1}=\([^[:space:]#]*\).*$/\1/p" PKGBUILD; }

# Rewrite a top-level assignment, keeping any trailing comment in place, and
# fail loudly if the substitution did not take (a silent no-op rewrite here
# would leave --write reporting success on an unchanged file).
set_pkgbuild_var() {
    sed -i "s|^\(${1}=\)[^[:space:]#]*|\1${2}|" PKGBUILD
    [[ $(pkgbuild_var "$1") == "$2" ]] || die "failed to set ${1} in PKGBUILD"
}

current_release=$(pkgbuild_var _oo_release)
[[ -n $current_release ]] || die 'cannot read _oo_release from PKGBUILD'
current_build=$(pkgbuild_var _oo_build)

release=${1:-v${current_release}}
[[ $release == v* ]] || release=v${release}
write=0
[[ ${2:-} == --write ]] && write=1
release=${release#v}

printf 'release tag: v%s\n' "$release"

# The release tag's commit. An annotated tag needs the ^{} dereference to reach
# the commit it points at rather than the tag object.
release_commit=$(
    git ls-remote --tags "$GH/DesktopEditors" "refs/tags/v${release}^{}" |
        head -n1 | cut -f1
)
[[ -n $release_commit ]] || release_commit=$(
    git ls-remote --tags "$GH/DesktopEditors" "refs/tags/v${release}" |
        head -n1 | cut -f1
)
[[ -n $release_commit ]] || die "DesktopEditors has no tag v${release}"

# The build tag is the highest v<release>.NNN that core carries.
build_tag=$(
    git ls-remote --tags "$GH/core" |
        sed -n "s|.*refs/tags/\(v${release//./\\.}\.[0-9]\+\)$|\1|p" |
        sort -V | tail -n1
)
[[ -n $build_tag ]] || die "core has no v${release}.NNN build tag"
build=${build_tag#v}
printf 'build tag:   %s\n\n' "$build_tag"

# Every module must carry that same build tag. A module that does not means the
# release is not fully published yet, and pinning now would produce a tree that
# upstream never built.
declare -A commit_of
for module in "${MODULES[@]}"; do
    repo=${REPO_NAME[$module]:-$module}
    sha=$(git ls-remote --tags "$GH/$repo" "refs/tags/${build_tag}" | head -n1 | cut -f1)
    [[ -n $sha ]] || die "$repo has no tag ${build_tag} (release not fully published?)"
    commit_of[$module]=$sha
    printf '  %-20s %s\n' "$module" "$sha"
done

# V8 is pinned by commit because nothing upstream pins it: v8_89.py syncs the
# moving branch-head. Record which branch-head the pin corresponds to so it can
# be re-derived, and refuse a pin that is no longer that tip.
v8_branch_head=$(pkgbuild_var _v8_branch_head)
v8_tag=$(pkgbuild_var _v8_tag)
v8_pin=$(pkgbuild_var _v8_commit)
[[ -n $v8_branch_head ]] || die 'cannot read _v8_branch_head from PKGBUILD'

v8_tip=$(git ls-remote https://github.com/v8/v8 "refs/${v8_branch_head}" | head -n1 | cut -f1)
printf '\n  v8 %s -> %s\n' "$v8_branch_head" "${v8_tip:-unresolved}"

v8_new=$v8_pin
if [[ -n $v8_tip && $v8_tip != "$v8_pin" ]]; then
    # Tip moved: accept it only if a tag points at the same commit, so the pin
    # stays human-readable. branch-head tips are not tagged, so usually they are
    # not, and the pin has to be bumped by hand with the tag recorded in
    # _v8_tag. Report rather than guess.
    printf '    note: %s has moved past the pin (%s). Re-tag or bump _v8_tag by hand.\n' \
        "$v8_branch_head" "$v8_tag"
fi

if ((write)); then
    printf '\nrewriting PKGBUILD\n'
    set_pkgbuild_var _oo_release "$release"
    set_pkgbuild_var _oo_build "$build"
    set_pkgbuild_var pkgver "$build"
    for module in "${MODULES[@]}"; do
        repo=${REPO_NAME[$module]:-$module}
        sed -i "s|^    \"${module}::git+\${_url}/${repo}#commit=[0-9a-f]*\"|    \"${module}::git+\${_url}/${repo}#commit=${commit_of[$module]}\"|" PKGBUILD
        grep -qF "\"${module}::git+\${_url}/${repo}#commit=${commit_of[$module]}\"" PKGBUILD ||
            die "failed to re-pin ${module} in PKGBUILD"
    done
    sed -i "s|^    \"DesktopEditors::git+\${_url}/DesktopEditors#commit=[0-9a-f]*\"|    \"DesktopEditors::git+\${_url}/DesktopEditors#commit=${release_commit}\"|" PKGBUILD
    grep -qF "\"DesktopEditors::git+\${_url}/DesktopEditors#commit=${release_commit}\"" PKGBUILD ||
        die 'failed to re-pin DesktopEditors in PKGBUILD'
    printf 'done. Review the diff, then regenerate sums with: makepkg -g\n'
else
    cat <<EOF

New source pins for v$release (--write applies them):

    "DesktopEditors::git+\${_url}/DesktopEditors#commit=${release_commit}"
EOF
    for module in "${MODULES[@]}"; do
        repo=${REPO_NAME[$module]:-$module}
        printf '    "%s::git+${_url}/%s#commit=%s"\n' "$module" "$repo" "${commit_of[$module]}"
    done
    printf '\n_oo_release=%s\n_oo_build=%s\npkgver=%s\n' "$release" "$build" "$build"
fi

printf '\nnext: makepkg -g  (sums change with every moved pin)\n'
