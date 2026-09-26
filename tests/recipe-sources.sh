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

# FETCHED-ONLY: a recipe may declare, in its own FETCHED-ONLY file, the source
# names it fetches at build time and deliberately keeps out of Git — one glob
# per line, matched against the source's basename; '#' lines and blank lines
# are ignored. A matching name is excused from BOTH checks below (absence is
# the normal state for a fetched-at-build-time name, and an untracked copy is
# deliberate build state), so no recipe is ever special-cased by name here.
fetched_only_excused() {
    local recipe=$1 name=$2 marker=$recipe/FETCHED-ONLY pattern
    [[ -f $marker ]] || return 1
    name=${name##*/}
    while IFS= read -r pattern; do
        [[ -n $pattern && ${pattern:0:1} != '#' ]] || continue
        # shellcheck disable=SC2254 -- the pattern is deliberately a glob.
        case $name in
        $pattern) return 0 ;;
        esac
    done <"$marker"
    return 1
}

# walk_recipe WORKSPACE RECIPE — the per-recipe walk: source-array entries
# and `install=` scripts must exist under RECIPE and be committed in WORKSPACE
# (git). Counters (checked/installs/missing/untracked) and `seen` accumulate in
# the caller; violations print to stderr. FACTORED for the FETCHED-ONLY
# machinery test below — the real walk and the test drive the same code.
walk_recipe() {
    local ws=$1 recipe=$2
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
            if fetched_only_excused "$recipe" "$src"; then
                continue
            fi
            printf 'missing local source: %s\n' "$path" >&2
            missing=$((missing + 1))
            continue
        fi
        if ! git -C "$ws" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            if fetched_only_excused "$recipe" "$src"; then
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
        git -C "$ws" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || {
            printf 'untracked install script: %s\n' "$path" >&2
            untracked=$((untracked + 1))
        }
    done < <(grep -hoP '^\s*install=\K[^\s#]+' "$recipe/PKGBUILD" 2>/dev/null |
        tr -d "\"'" | sort -u)
}

# ─── FETCHED-ONLY machinery, red/green (synthetic, $TMPDIR-scoped) ───────────
# The real walk below only exercises a marker when some recipe needs one, so
# the contract itself is pinned here against scratch recipes — the same
# walk_recipe the real walk runs. A synthetic workspace is not a git repo, so
# every present-but-untracked file takes exactly the untracked branch a local
# build-state copy does. Subshell keeps its counters and scratch out of the
# real walk.
(
    set -euo pipefail
    marker_tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-recipe-sources-marker.XXXXXX")
    trap 'rm -rf -- "$marker_tmp"' EXIT
    ws=$marker_tmp/ws

    # Good: a matching FETCHED-ONLY name is excused whether ABSENT (fetched at
    # build time) or PRESENT-untracked (deliberate build state).
    mkdir -p "$ws/packages/stable/thing"
    cat >"$ws/packages/stable/thing/PKGBUILD" <<'EOF'
source=(dl-001 dl-002)
EOF
    cat >"$ws/packages/stable/thing/FETCHED-ONLY" <<'EOF'
# comments and blank lines are not patterns

dl-[0-9]*
EOF
    : >"$ws/packages/stable/thing/dl-002"

    # Bad: no marker at all — both failure modes must still be reported.
    mkdir -p "$ws/packages/stable/bad"
    cat >"$ws/packages/stable/bad/PKGBUILD" <<'EOF'
source=(gone.txt stray.txt)
EOF
    : >"$ws/packages/stable/bad/stray.txt"

    # Mixed: only the LISTED name is excused; the commented pattern must not
    # excuse anything (other.txt is absent and must be reported).
    mkdir -p "$ws/packages/stable/mixed"
    cat >"$ws/packages/stable/mixed/PKGBUILD" <<'EOF'
source=(only-one-1 other.txt)
EOF
    cat >"$ws/packages/stable/mixed/FETCHED-ONLY" <<'EOF'
# other*
only-one-1
EOF

    checked=0 missing=0 untracked=0
    seen=()
    walk_recipe "$ws" "$ws/packages/stable/thing" 2>"$marker_tmp/thing.err"
    ((checked == 2 && missing == 0 && untracked == 0)) ||
        fail "FETCHED-ONLY: matching names must be excused (checked=$checked missing=$missing untracked=$untracked)"

    checked=0 missing=0 untracked=0
    walk_recipe "$ws" "$ws/packages/stable/bad" 2>"$marker_tmp/bad.err"
    ((missing == 1 && untracked == 1)) ||
        fail "FETCHED-ONLY: an unmarked recipe must keep both checks (missing=$missing untracked=$untracked)"
    grep -Fq "missing local source: $ws/packages/stable/bad/gone.txt" "$marker_tmp/bad.err" ||
        fail 'FETCHED-ONLY: the missing-file message must survive without a marker'
    grep -Fq "untracked local source: $ws/packages/stable/bad/stray.txt" "$marker_tmp/bad.err" ||
        fail 'FETCHED-ONLY: the untracked-file message must survive without a marker'

    checked=0 missing=0 untracked=0
    walk_recipe "$ws" "$ws/packages/stable/mixed" 2>"$marker_tmp/mixed.err"
    ((missing == 1 && untracked == 0)) ||
        fail "FETCHED-ONLY: only listed names are excused (missing=$missing untracked=$untracked)"
    grep -Fq "missing local source: $ws/packages/stable/mixed/other.txt" "$marker_tmp/mixed.err" ||
        fail 'FETCHED-ONLY: a commented pattern must not excuse a name'
    grep -Fq 'only-one-1' "$marker_tmp/mixed.err" &&
        fail 'FETCHED-ONLY: a listed name must not be reported'

    printf 'FETCHED-ONLY machinery: OK\n'
)

checked=0
installs=0
missing=0
untracked=0
seen=()
while IFS= read -r recipe; do
    walk_recipe "$root" "$recipe"
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
