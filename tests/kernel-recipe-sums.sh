#!/usr/bin/env bash
set -euo pipefail

# packages/misc/linux-cachyos assembles source[] from four knobs (_cpusched,
# _build_zfs, _build_nvidia_open, _build_r8125) while b2sums is one flat literal,
# so the sums can only ever match a single combination: the one the recipe's
# defaults select. Measured, not assumed: cachyos/eevdf/rt drop one patch, zfs
# and r8125 add one source each, nvidia-open adds four, and _use_llvm_lto,
# _build_debug, _autofdo, _propeller, _capture_chain, _hardened and _host_tune
# change nothing.
#
# That invariant is load-bearing and was previously only a comment. It breaks
# two ways, and makepkg reports neither usefully:
#
#   * the shipped default drifts away from the shipped sums (a knob edit or a
#     version bump that forgets updpkgsums), so every build of the default set
#     dies in the integrity check - the 7.3 move dropped misc/0001-rt-i915.patch
#     and only a hand edit kept the pair aligned;
#   * a source-affecting knob is switched, and makepkg's "Integrity checks (b2)
#     differ in size from the source array" arrives after "Retrieving sources",
#     naming neither the knob nor the remedy.
#
# The PKGBUILD now checks the pair itself at parse time and names both. This
# fixture pins that contract, including the exemption that keeps the remedy
# usable: `updpkgsums` runs `makepkg -g`, which has to source the PKGBUILD to do
# its job, and the whole point of running it is that the sums do not match yet.
# Read-only: the recipe is never written to - the drift case works on a copy in
# $TMPDIR.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=packages/misc/linux-cachyos
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-kernel-sums-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'kernel recipe sums fixture: %s\n' "$1" >&2
    exit 1
}

# Source the PKGBUILD the way makepkg does: makepkg's own globals (`startdir`,
# `CARCH`) are supplied, the recipe's knobs come from the environment, and
# `_die` needs no helper from makepkg (it falls back to plain stderr). Sets
# probe_out to everything the recipe printed and probe_rc to its exit status, so
# a refusal can be told apart from a clean parse by message and status.
probe_out=
probe_rc=0
probe() { # dir [KEY=VAL...]
    local dir=$1
    shift
    set +e
    probe_out=$( ( cd "$dir" && env startdir="$PWD" "$@" bash -c '
        set +u
        source ./PKGBUILD >/dev/null
        printf "COUNTS %s %s\n" "${#source[@]}" "${#b2sums[@]}"' ) 2>&1 )
    probe_rc=$?
    set -e
}

# --- the shipped default set and the shipped sums must agree ---------------
srcinfo=$tmp/.SRCINFO
GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$root/$recipe" >"$srcinfo" 2>"$tmp/err" ||
    fail "makepkg --printsrcinfo failed for $recipe (the default knob set must parse): $(head -1 "$tmp/err")"

info_sources=$(grep -c '^[[:space:]]*source = ' "$srcinfo")
info_sums=$(grep -c '^[[:space:]]*b2sums = ' "$srcinfo")
[[ $info_sources -gt 0 ]] || fail "the generated .SRCINFO lists no sources"
[[ $info_sources -eq $info_sums ]] ||
    fail "the committed default set is inconsistent: $info_sources source(s) but $info_sums b2sums entry/entries in .SRCINFO"

probe "$root/$recipe"
[[ $probe_rc -eq 0 ]] ||
    fail "the default knob set was refused: $probe_out"
[[ $probe_out == "COUNTS $info_sources $info_sums" ]] ||
    fail "source[]/b2sums at parse time ($probe_out) disagree with .SRCINFO ($info_sources/$info_sums)"

# --- a source-affecting knob is refused, and the refusal names the remedy ---
probe "$root/$recipe" _cpusched=cachyos
[[ $probe_rc -ne 0 ]] ||
    fail "_cpusched=cachyos was accepted with sums sized for the default set ($probe_out)"
for want in 'b2sums' 'source[]' '_cpusched=cachyos' 'updpkgsums'; do
    [[ $probe_out == *"$want"* ]] ||
        fail "the refusal for _cpusched=cachyos does not mention '$want': $probe_out"
done

# ... and the guard is not scheduler-specific: every source-affecting knob counts
probe "$root/$recipe" _build_nvidia_open=yes
[[ $probe_rc -ne 0 ]] ||
    fail "_build_nvidia_open=yes was accepted with sums sized for the default set ($probe_out)"

# --- knobs that do NOT change the source set must stay accepted ------------
# This is the other half of the contract: the guard has to be exact, or it would
# start refusing builds the recipe supports.
for knobs in '_use_llvm_lto=none' '_build_debug=no' '_autofdo=yes _propeller=yes' '_capture_chain=yes' '_hardened=yes' '_host_tune=no'; do
    # shellcheck disable=SC2086 # the values are literal KEY=VAL pairs
    probe "$root/$recipe" $knobs
    [[ $probe_rc -eq 0 ]] ||
        fail "'$knobs' changes no source but was refused: $probe_out"
    [[ $probe_out == "COUNTS $info_sources $info_sums" ]] ||
        fail "'$knobs' changed the source set to $probe_out - b2sums is sized for $info_sources"
done

# --- the remedy must stay runnable ----------------------------------------
# `makepkg -g` (which is what updpkgsums calls) sources the PKGBUILD with
# GENINTEG=1 and the mismatched sums still in place. It must parse, or a
# mismatch would be unrepairable.
probe "$root/$recipe" GENINTEG=1 _cpusched=cachyos
[[ $probe_rc -eq 0 ]] ||
    fail "makepkg -g (GENINTEG=1) was refused, so updpkgsums cannot repair the sums: $probe_out"
[[ $probe_out == COUNTS* ]] ||
    fail "makepkg -g did not reach the end of the PKGBUILD: $probe_out"

# --- drift in the shipped default is caught, not shipped ------------------
# The realistic version: the default knob set moves (a version bump dropping a
# patch, or an edited default) and the sums are not regenerated. Reproduce it on
# a copy so the tree stays read-only.
drifted=$tmp/drifted
mkdir -p "$drifted"
sed 's/^: "${_cpusched:=rt-bore}"/: "${_cpusched:=cachyos}"/' \
    "$root/$recipe/PKGBUILD" >"$drifted/PKGBUILD"
grep -q '^: "${_cpusched:=cachyos}"' "$drifted/PKGBUILD" ||
    fail "could not build the drift case (the _cpusched default line moved)"
probe "$drifted"
[[ $probe_rc -ne 0 ]] ||
    fail "a default set that disagrees with the shipped sums parsed clean ($probe_out)"

printf 'kernel recipe sums fixture: PASS (%s/%s shipped, refusals named, updpkgsums exempt)\n' \
    "$info_sources" "$info_sums"
