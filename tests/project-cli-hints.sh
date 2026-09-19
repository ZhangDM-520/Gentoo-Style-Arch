#!/usr/bin/env bash
set -euo pipefail

# The builder's package-reference resolution and its two read-only listings.
#
# Resolution accepts four forms, and the two new ones are exact lookups against
# the committed .SRCINFO index (218 distinct pacman names, none shared by two
# recipes), never guesses: a case-variant recipe ID and a pacman package name -
# including a split output - resolve to the recipe that builds them, and each
# substitution is announced. A typo is deliberately NOT auto-corrected: a wrong
# guess would build a whole dependency chain, so it is reported with the nearest
# candidates instead. Measured before the change: `mesa-gti` said only "package
# recipe not found", `zen-browser` (an installed package name) was refused, and
# `-g gti` printed NOTHING at all - resolve_group wrote its diagnostic to a
# stdout the caller was capturing with a command substitution.
#
# The listings are the other half. A range indexes the SELECTION in dependency
# order, but `--list` printed the whole-set order, so `-l` index 22
# (vscodium-insiders-git) and `-g git 22..24` (ninja-git, mesa-git,
# niri-spicy-git) were different packages with nothing saying so. `-l` now
# honours the selection, and `-n` with no selection covers the whole set, which
# is what --help has always claimed for it.
#
# Read-only: every invocation below is a listing or a dry run.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
builder=$root/build-all.fish
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-cli-hints-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'cli hints fixture: %s\n' "$1" >&2
    exit 1
}

out=
rc=0
run() { # [args...]
    set +e
    out=$(fish "$builder" "$@" 2>&1)
    rc=$?
    set -e
}

out_stdout=
out_stderr=
run_split() { # [args...]
    local err
    err=$(mktemp "$tmp/err.XXXXXX")
    set +e
    out_stdout=$(fish "$builder" "$@" 2>"$err")
    rc=$?
    set -e
    out_stderr=$(cat "$err")
    rm -f "$err"
}

require_ok() { # description
    [[ $rc -eq 0 ]] || fail "$1 exited $rc: $out"
}
require_fail() { # description
    [[ $rc -ne 0 ]] || fail "$1 was accepted (it should be refused): $out"
}
require_in() { # description needle
    [[ $out == *"$2"* ]] || fail "$1 does not mention '$2': $out"
}
require_not_in() { # description needle
    [[ $out != *"$2"* ]] || fail "$1 unexpectedly mentions '$2': $out"
}
rows() { # print the numbered rows of $out, as bare package names
    sed -n 's/^ *[0-9][0-9]*\. //p' <<<"$out"
}

# --- unresolved references: refused, with the nearest candidates ------------
run -n --no-deps mesa-gti
require_fail 'the typo mesa-gti'
require_in 'the typo mesa-gti' 'mesa-git'
require_in 'the typo mesa-gti' "build-all.fish -l"

run -n --no-deps mesa
require_fail 'the partial name mesa'
require_in 'the partial name mesa' 'mesa-git'

# A hint is a hint: an unrelated name must not collect one, or the suggestions
# become noise.
run -n --no-deps zzzz
require_fail 'the unrelated name zzzz'
require_not_in 'the unrelated name zzzz' 'Did you mean'

# --- exact extra forms resolve, and say so ---------------------------------
run -n --no-deps MESA-GIT
require_ok 'the case-variant ID MESA-GIT'
require_in 'the case-variant ID MESA-GIT' 'case-sensitive'
[[ $(rows) == 'mesa-git' ]] || fail "MESA-GIT resolved to '$(rows)', not mesa-git"

run -n --no-deps zen-browser
require_ok 'the pacman name zen-browser'
require_in 'the pacman name zen-browser' 'zen-browser-pgo'
[[ $(rows) == 'zen-browser-pgo' ]] ||
    fail "zen-browser resolved to '$(rows)', not zen-browser-pgo"

# A split output must reach its recipe too - this is the case that would be
# dangerous to guess at, so it is worth pinning.
run -n --no-deps libstdc++-snapshot
require_ok 'the split output libstdc++-snapshot'
require_in 'the split output libstdc++-snapshot' 'gcc-snapshot'

# --- the two original forms still resolve, and stay silent -----------------
run -n --no-deps mesa-git
require_ok 'the recipe ID mesa-git'
[[ $(rows) == 'mesa-git' ]] || fail "mesa-git resolved to '$(rows)'"
require_not_in 'the recipe ID mesa-git' 'matched recipe'

run -n --no-deps packages/git/mesa-git
require_ok 'the recipe path packages/git/mesa-git'
[[ $(rows) == 'mesa-git' ]] || fail "the recipe path resolved to '$(rows)'"
require_not_in 'the recipe path packages/git/mesa-git' 'matched recipe'

# --- group and option lookups get the same treatment -----------------------
# The group diagnostic is checked per channel, not just merged: resolve_group's
# stdout is a data channel (the caller captures it with a command
# substitution), so a diagnostic written there is swallowed and the run exits 1
# having said nothing - which is what `-g gti` did before this change. Merging
# the streams would hide that, because the swallowed text leaks into the output
# by another route.
run_split -n -g gti
[[ $rc -ne 0 ]] || fail 'the unknown group gti was accepted (it should be refused)'
[[ $out_stderr == *"unknown group 'gti'"* ]] ||
    fail "the unknown group diagnostic is not on stderr: stdout=[$out_stdout] stderr=[$out_stderr]"
[[ $out_stderr == *"Did you mean 'git'"* ]] ||
    fail "the unknown group diagnostic offers no hint: [$out_stderr]"
[[ $out_stdout != *'unknown group'* ]] ||
    fail "the unknown group diagnostic leaked into stdout: [$out_stdout]"

run --intenstiy max -g git
require_fail 'the mistyped option --intenstiy'
require_in 'the mistyped option --intenstiy' "'--intensity'"

# --- a range indexes the selection, and the listing says which -------------
recipes=$(find "$root/packages" -mindepth 3 -maxdepth 3 -name .SRCINFO | wc -l)
[[ $recipes -gt 0 ]] || fail "no recipe .SRCINFO files found under $root/packages"

run -l
require_ok 'the whole-set listing'
all_rows=$(rows | wc -l)
[[ $all_rows -eq $recipes ]] ||
    fail "the whole-set listing has $all_rows rows but there are $recipes recipes"

run -n
require_ok 'a bare -n'
dry_rows=$(rows | wc -l)
[[ $dry_rows -eq $all_rows ]] ||
    fail "-n with no selection lists $dry_rows packages, --list lists $all_rows"

run -l -g git
require_ok 'the git listing'
git_rows=$(rows | wc -l)
[[ $git_rows -lt $all_rows ]] ||
    fail "-l -g git listed $git_rows packages - the selection was ignored"
[[ $out == *"Ranges index this list"* ]] ||
    fail "the selection listing does not say what its indices are for: $out"
listed_22=$(rows | sed -n '22p')

run -n -g git 22..22
require_ok 'the range -g git 22..22'
[[ $(rows) == "$listed_22" ]] ||
    fail "range index 22 selects '$(rows)' but the listing shows '$listed_22'"

# --- range mistakes are named ---------------------------------------------
run -n -g git 900..950
require_fail 'the out-of-bounds range 900..950'
require_in 'the out-of-bounds range 900..950' "$git_rows-package selection"
require_in 'the out-of-bounds range 900..950' "build-all.fish -l -g git"

run -n -g git 1..999
require_ok 'the over-long range 1..999'
require_in 'the over-long range 1..999' 'clamped'
[[ $(rows | wc -l) -eq $git_rows ]] ||
    fail "1..999 built $(rows | wc -l) packages, not the whole $git_rows-package selection"

run -n -g git ..
require_fail 'the empty range ..'
require_in 'the empty range ..' 'invalid range'

run -n -g git 38..22
require_fail 'the reversed range 38..22'
require_in 'the reversed range 38..22' 'empty'

# --- a bare name that grows into a dependency chain says so ----------------
run -n niri-spicy-git
require_ok 'the bare name niri-spicy-git'
require_in 'the bare name niri-spicy-git' 'dependency expansion added'

run -n --no-deps niri-spicy-git
require_ok 'the bare name with --no-deps'
require_not_in 'the bare name with --no-deps' 'dependency expansion'

printf 'cli hints fixture: PASS (%s recipes, %s-row selection indexed, extra forms announced)\n' \
    "$recipes" "$git_rows"
