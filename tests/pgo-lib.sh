#!/usr/bin/env bash
# tests/pgo-lib.sh — lib/pgo.sh, the shared PGO payload gate.
#
# Two sections:
#   1. module behaviour — subshell exit-status assertions over synthetic
#      payloads. The gate is FATAL by design (`exit 1` on any leak), so every
#      assertion runs it in a subshell and checks the subshell's status.
#   2. resolution — every consuming recipe sources the module through a
#      `$startdir`-relative path that is TRACKED in git, and sourcing its
#      PKGBUILD defines the interface. This is the clean-checkout test that
#      tests/recipe-sources.sh cannot make: a helper sourced from a PKGBUILD
#      is invisible to it.
#
# Non-mutating and $TMPDIR-scoped like every fixture.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/gsa-pgo-lib.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

fail() {
    printf 'pgo-lib: %s\n' "$*" >&2
    exit 1
}

module="$root/lib/pgo.sh"
test -f "$module" || fail "lib/pgo.sh is missing"

# Stub readelf: the symbol predicate is only reachable on ELF files before
# makepkg strips, so the fixture fakes its output for the leak marker
# directory and defers everything else to the real readelf.
mkdir -p "$work/bin"
cat >"$work/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *leaky-symbols* ]]; then
    printf '0000000000000000 g    DF .text  0000000000000000 __gcov_init\n'
    exit 0
fi
exec /usr/bin/readelf "$@"
EOF
chmod +x "$work/bin/readelf"
export PATH="$work/bin:$PATH"

# run_gate ROOT [extra-literal...] — the gate's exit status. The gate calls
# `exit 1` on a leak, so it must never run in the fixture's own shell.
run_gate() {
    (
        pkgbase=pgo-lib-fixture
        error() { printf '%s\n' "$*" >&2; return 1; }
        source "$module"
        verify_no_profile_instrumentation "$@"
    )
}

# --- 1. module behaviour ----------------------------------------------------

# A clean payload passes. Prose may *mention* a .gcda path in shipped text:
# the predicate matches a standalone absolute path, not any mention of
# `.gcda`.
mkdir -p "$work/clean"
printf 'coverage notes: rebuild /tmp/x/src/A.dir/b.cxx.gcda\n' \
    >"$work/clean/libclean.so"
run_gate "$work/clean" || fail "clean payload rejected"

# ctest ships the glob literal `/*.gcda` as its own string in its GCOV
# support; a glob is not a baked destination. This is why the path predicate's
# second character class excludes `*` (rationale lives once, in lib/pgo.sh).
mkdir -p "$work/glob"
printf 'code\0/*.gcda\0code' >"$work/glob/ctest"
chmod +x "$work/glob/ctest"
run_gate "$work/glob" || fail "ctest /*.gcda glob literal rejected"

# The glob exclusion must not open a hole: a real baked .gcda destination
# still fails (strings path predicate).
mkdir -p "$work/gcda-path"
printf 'code\0/home/someone/build/pgo-fixture/src/A.dir/b.cxx.gcda\0code' \
    >"$work/gcda-path/libleak.so"
if run_gate "$work/gcda-path" 2>/dev/null; then
    fail ".gcda destination leak passed"
fi

# A symbol-only leak fails (readelf predicate — the pre-strip seam).
mkdir -p "$work/leaky-symbols"
: >"$work/leaky-symbols/libleak.so"
if run_gate "$work/leaky-symbols" 2>/dev/null; then
    fail "profile instrumentation symbols passed"
fi

# A baked .profraw destination fails: the merged predicate is mold-git's
# strictness, and every consumer gets it.
mkdir -p "$work/profraw-path"
printf 'code\0/home/someone/build/pgo-fixture/target/release/mold.profraw\0code' \
    >"$work/profraw-path/libleak.so"
if run_gate "$work/profraw-path" 2>/dev/null; then
    fail ".profraw destination leak passed"
fi

# Extra literal arguments: `pgo-data` (mold-git's profile work directory) is
# not a path and carries no suffix, so only the literal predicate sees it —
# and only when the caller passes it.
mkdir -p "$work/extra-literal"
printf 'code\0pgo-data\0code' >"$work/extra-literal/mold"
chmod +x "$work/extra-literal/mold"
run_gate "$work/extra-literal" || fail "extra-literal payload rejected without the literal argument"
if run_gate "$work/extra-literal" pgo-data 2>/dev/null; then
    fail "extra literal leak passed"
fi

# Fatal semantics: the gate must abort its CALLER, not merely return a status.
# A return-based gate is silently discarded when a later command in the same
# function succeeds — the 2026-09-20 incident's exact mechanism.
if (
    pkgbase=pgo-lib-fixture
    error() { printf '%s\n' "$*" >&2; return 1; }
    source "$module"
    fake_package() {
        verify_no_profile_instrumentation "$work/gcda-path"
        : # a later success must not mask the gate's failure
    }
    fake_package
) 2>/dev/null; then
    fail "a mid-body gate call was masked by a later command"
fi

# --- 2. resolution: consumers source the TRACKED module ---------------------

mapfile -t consumers < <(grep -l 'lib/pgo\.sh' "$root"/packages/*/*/PKGBUILD | sort)
test "${#consumers[@]}" -gt 0 || fail "no recipe consumes lib/pgo.sh"

for pkgbuild in "${consumers[@]}"; do
    rel=${pkgbuild#"$root"/}

    mapfile -t src_lines < <(grep -E '^[[:space:]]*source "\$startdir/' "$pkgbuild")
    test "${#src_lines[@]}" -eq 1 ||
        fail "$rel: expected exactly one source \"\$startdir/...\" line, got ${#src_lines[@]}"
    relpath=$(sed -E 's/.*\$startdir\/([^"]+)".*/\1/' <<<"${src_lines[0]}")
    case "$relpath" in
        *lib/pgo.sh) ;;
        *) fail "$rel: source line does not name lib/pgo.sh: ${src_lines[0]}" ;;
    esac

    # Resolve exactly as makepkg does: $startdir is the recipe directory.
    # git must be able to carry the resolved file into a clean checkout: it
    # has to exist, escape both ignore layers, and be TRACKED. An untracked
    # (even if added-pending) helper hard-fails: the module is committed, and
    # a helper only staged in the working tree would leave every clean
    # checkout broken.
    recipe_dir=$(dirname "$pkgbuild")
    target=$(realpath -m "$recipe_dir/$relpath")
    rel_target=${target#"$root"/}
    test -f "$target" ||
        fail "$rel: $rel_target does not resolve — a clean checkout would fail to build"
    if git -C "$root" check-ignore -q -- "$rel_target"; then
        fail "$rel: $rel_target is git-ignored — a clean checkout would fail to build"
    fi
    git -C "$root" ls-files --error-unmatch -- "$rel_target" >/dev/null 2>&1 ||
        fail "$rel: $rel_target is not tracked — a clean checkout would fail to build"

    # Sourcing the PKGBUILD must define the interface through the module.
    (
        set +eu
        set +o pipefail
        cd "$recipe_dir"
        startdir=$recipe_dir
        source ./PKGBUILD >/dev/null 2>&1
        declare -F verify_no_profile_instrumentation >/dev/null
    ) || fail "$rel: sourcing the PKGBUILD does not define verify_no_profile_instrumentation"

    # And the recipe must actually call the gate, not just source the module.
    grep -qE '^[[:space:]]*verify_no_profile_instrumentation[[:space:]]' "$pkgbuild" ||
        fail "$rel: sources lib/pgo.sh but never calls verify_no_profile_instrumentation"
done

# One implementation: recipes call the module, they never copy it.
while IFS= read -r pkgbuild; do
    fail "${pkgbuild#"$root"/}: defines verify_no_profile_instrumentation inline — source lib/pgo.sh instead"
done < <(grep -lE '^[[:space:]]*verify_no_profile_instrumentation\(\)' "$root"/packages/*/*/PKGBUILD)

printf 'PGO shared gate fixture: PASS (%d consuming recipe(s))\n' "${#consumers[@]}"
