#!/usr/bin/env bash
set -euo pipefail

# packages/misc/linux-cachyos/verify-config.sh exists because `scripts/config`
# is blind: it writes `CONFIG_FOO=y` without consulting Kconfig, so an unknown
# symbol is a silent no-op and a symbol whose `depends on` is unmet is written
# and then deleted by the next `olddefconfig`. The recipe's own `_hugepage` knob
# was dead that way for its whole life - `mm/Kconfig` gates the THP menu on
# `!PREEMPT_RT` and `_cpusched=rt-bore` sets `PREEMPT_RT=y`.
#
# This fixture pins two things:
#
#   1. the engine's contract - every expectation form, and in particular that a
#      *vanished* symbol is reported as `absent`, not as `n`. That distinction
#      is the whole value of the tool: `n` means "fix the dependency", `absent`
#      means "the symbol was renamed or removed, fix the name".
#   2. the PKGBUILD's structure - the base-config selection (`_use_current`,
#      `_localmodcfg`) must run *before* the first `scripts/config` write, or it
#      silently discards the entire toggle block; and every `_cpusched` value
#      the header documents must be handled by the variant gate, the source-patch
#      case and the prepare() scheduler case, or the build fails halfway through
#      `prepare()` on a patch that does not exist for this `_major`.
#
# Read-only: scratch lives in $TMPDIR, the recipe is never written to.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=$root/packages/misc/linux-cachyos
verify=$recipe/verify-config.sh
pkgbuild=$recipe/PKGBUILD
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-kernel-config-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'kernel config verify fixture: %s\n' "$1" >&2
    exit 1
}

[[ -f $verify ]] || fail "missing $verify"
[[ -x $verify ]] || fail "$verify is not executable (needs mode 755 to be callable from prepare())"

# ---------------------------------------------------------------------------
# 1. the engine
# ---------------------------------------------------------------------------
cfg=$tmp/.config
cat >"$cfg" <<'EOF'
CONFIG_A=y
CONFIG_B=m
# CONFIG_C is not set
CONFIG_D=300
CONFIG_S="bbr"
CONFIG_E=64
EOF
# CONFIG_F is deliberately absent from the file: the vanished-symbol case.

# Expectations that must hold.
pass=(
    A=y A B C=n '!C' '!F' D=300 'D>=300' 'D>=64' S=bbr 'E>=64' 'A!=n' B=m F=absent
)
out=$("$verify" "$cfg" "${pass[@]}" 2>"$tmp/err") ||
    fail "expectations that should hold did not: $(cat "$tmp/err")"
[[ -n $out ]] || fail "a passing run printed no summary line"
grep -q "${#pass[@]} expectation" <<<"$out" ||
    fail "the summary line does not report the expectation count: $out"

# Each of these must fail, name the symbol, and report the actual value.
expect_fail() {
    local want=$1 sym=$2 text=$3 rc=0
    set +e
    "$verify" "$cfg" "$want" >/dev/null 2>"$tmp/err"
    rc=$?
    set -e
    [[ $rc -eq 1 ]] || fail "'$want' exited $rc, expected 1"
    grep -q "^$sym: " "$tmp/err" || fail "'$want' did not report $sym: $(cat "$tmp/err")"
    grep -qF "$text" "$tmp/err" || fail "'$want' reported the wrong value: $(cat "$tmp/err")"
}

expect_fail A=n          A 'expected n, got y'
expect_fail '!A'         A 'expected not set, got y'
expect_fail C            C 'expected y or m, got n'
expect_fail 'D>=301'     D 'expected an integer >= 301, got 300'
expect_fail S=fq         S 'expected fq, got bbr'
# The point of the whole exercise: absent must not be reported as n.
expect_fail F            F 'expected y or m, got absent'
expect_fail 'F!=absent'  F 'expected anything but absent, got absent'

# Every failure is reported, not just the first, and the count is honest.
set +e
"$verify" "$cfg" A=n F H=1 >/dev/null 2>"$tmp/err"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "a multi-failure run exited $rc, expected 1"
[[ $(grep -c '^[A-Z]*: ' "$tmp/err") -eq 3 ]] ||
    fail "a multi-failure run reported $(grep -c '^[A-Z]*: ' "$tmp/err") of 3 failures"
grep -q '3 of 3 expectation' "$tmp/err" ||
    fail "the failure summary does not report the count: $(cat "$tmp/err")"

# Misuse is a distinct exit status from a failed expectation.
set +e
"$verify" >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "no arguments should exit 2"
"$verify" "$tmp/missing" A=y >/dev/null 2>&1; [[ $? -eq 2 ]] ||
    fail "an unreadable config should exit 2"
"$verify" "$cfg" 'A>=x' >/dev/null 2>&1; [[ $? -eq 2 ]] ||
    fail "a non-numeric bound should exit 2"
set -e

# ---------------------------------------------------------------------------
# 2. the PKGBUILD
# ---------------------------------------------------------------------------
# The recipe must actually call the engine, or none of the above matters.
grep -q 'verify-config.sh' "$pkgbuild" ||
    fail "PKGBUILD never invokes verify-config.sh"
grep -q '_config_wants' "$pkgbuild" ||
    fail "PKGBUILD builds no expectation list to hand to verify-config.sh"

# Ordering: the base config must be chosen before the first toggle is written.
# Only count real invocations - a comment mentioning scripts/config is not one.
first_toggle=$(grep -nE '^[[:space:]]*scripts/config' "$pkgbuild" | head -1 | cut -d: -f1)
use_current=$(grep -n '^[[:space:]]*if \[ "\$_use_current" = "yes" \]' "$pkgbuild" | head -1 | cut -d: -f1)
localmodcfg=$(grep -n '^[[:space:]]*if \[ "\$_localmodcfg" = "yes" \]' "$pkgbuild" | head -1 | cut -d: -f1)
[[ -n $first_toggle ]] || fail "PKGBUILD writes no config at all"
[[ -n $use_current ]] || fail "PKGBUILD has no _use_current block"
[[ -n $localmodcfg ]] || fail "PKGBUILD has no _localmodcfg block"
[[ $use_current -lt $first_toggle ]] ||
    fail "_use_current (line $use_current) runs after the first toggle (line $first_toggle): it would discard the whole toggle block"
[[ $localmodcfg -lt $first_toggle ]] ||
    fail "_localmodcfg (line $localmodcfg) runs after the first toggle (line $first_toggle): it would discard the whole toggle block"

# Every scheduler the header documents must be handled everywhere the recipe
# branches on _cpusched.
documented=$(sed -n "s/^# '\([a-z-]*\)' - select .*/\1/p" "$pkgbuild" | sort -u)
[[ -n $documented ]] || fail "could not read the documented _cpusched values from the header"

# Prints the `case "$_cpusched" in ... esac` block that contains $1.
case_block() {
    awk -v marker="$1" '
        index($0, "case \"$_cpusched\" in") > 0 { inblk=1; buf=""; hit=0 }
        inblk { buf = buf $0 ORS; if (index($0, marker) > 0) hit=1 }
        inblk && index($0, "esac") > 0 { if (hit) printf "%s", buf; inblk=0 }
    ' "$pkgbuild"
}

gate=$(case_block '_die "The value')
[[ -n $gate ]] || fail "PKGBUILD has no _cpusched variant gate (a case that _dies on an unsupported value)"
for value in $documented; do
    grep -qE "^[[:space:]]*(\*\|)?[a-z|*-]*\b${value}\b[a-z|*-]*\)" <<<"$gate" ||
        fail "_cpusched=$value is documented but the variant gate does not handle it"
done
# ... and the two cannot drift apart in the other direction either.
for value in $(grep -oE '^[[:space:]]*[a-z|*-]+\)' <<<"$gate" |
               sed 's/[[:space:]]//g; s/)//' | tr '|' '\n' | grep -v '^\*$' | sort -u); do
    grep -qx "$value" <<<"$documented" ||
        fail "the variant gate handles _cpusched=$value but the header does not document it"
done

# The source-patch case and the prepare() scheduler case must cover every
# documented value too: a value the header advertises but the patch list does
# not fetch would fail mid-prepare on a missing patch.
src_case=$(case_block '_patchsource')
prep_case=$(case_block 'SCHED_MUQSS')
[[ -n $src_case ]] || fail "could not find the _cpusched source-patch case"
[[ -n $prep_case ]] || fail "could not find the _cpusched prepare() case"
for value in $documented; do
    grep -qE "^[[:space:]]*(\*\|)?[a-z|*-]*\b${value}\b[a-z|*-]*\)" <<<"$src_case" ||
        fail "_cpusched=$value is documented but the source-patch case does not fetch its patches"
    grep -qE "^[[:space:]]*(\*\|)?[a-z|*-]*\b${value}\b[a-z|*-]*\)" <<<"$prep_case" ||
        fail "_cpusched=$value is documented but the prepare() scheduler case does not handle it"
done

# An invariant must not contradict a toggle. The invariants array is applied
# unconditionally, so a `!SYM` in it can never hold at the same time as a
# toggle's `scripts/config -e SYM`: the build would fail in prepare() on a
# configuration the recipe itself declares supported. (This is not hypothetical
# - `!AUTOFDO_CLANG` sat in the invariants array while `_autofdo=yes` wrote
# `-e AUTOFDO_CLANG`, which made the AutoFDO path unbuildable.) Such an
# assertion belongs outside the array, guarded on the knob.
invariants=$(awk '/^[[:space:]]*### Invariants/{f=1} f{print} f&&/^[[:space:]]*\)$/{exit}' "$pkgbuild" | sed 's/#.*//')
[[ -n $invariants ]] || fail "could not find the invariants block in the PKGBUILD"
# Comments describe toggles ("-e CFI") without applying them, so match code only.
code=$(sed 's/#.*//' "$pkgbuild")
conflict=0
for sym in $(grep -oE '![A-Z0-9_]+' <<<"$invariants" | tr -d '!' | sort -u); do
    if grep -qE "(^|[[:space:]])-e[[:space:]]+${sym}([[:space:]]|$)" <<<"$code"; then
        printf 'kernel config verify fixture: invariant !%s is unconditional but a toggle writes -e %s; move the assertion out of the invariants array and guard it on that knob\n' \
            "$sym" "$sym" >&2
        conflict=1
    fi
done
[[ $conflict -eq 0 ]] || exit 1

printf 'kernel config verify fixture: ok\n'

# ==== kernel-recipe-sums.sh ====
(

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
)

# ==== kernel-recipe-version.sh ====
(

# packages/misc/linux-cachyos tracks an upstream kernel channel, and its version
# scheme has two forms plus a version-scoped patch set:
#
#   stable: _major=7.2 _minor=6    -> pkgver 7.2.6   -> cachyos-7.2.6-<tagrel>
#   RC:     _major=7.3 _rcver=rc3  -> pkgver 7.3.rc3 -> cachyos-7.3-rc3-<tagrel>
#
# and `_patchsource` is .../kernel-patches/master/<major>, so bumping the kernel
# changes the patch directory as well as every patch filename under it.
#
# A partial bump is a silent break with two distinct faces. The source URL comes
# out plausible but wrong, which makepkg reports only as a 404 - and if the
# previous tarball is still in SRCDEST (which is $startdir here) makepkg finds it
# and builds the *old* kernel instead. Separately, a patch fetched from the wrong
# `master/<major>` directory either 404s or, worse, applies against a tree it was
# not written for.
#
# This is the invariant that had to hold by hand during the 7.3-rc3 move, and it
# is exactly what repeated RC tracking will get wrong again: assert the tarball
# URL agrees with `pkgver`, and that every patch URL is scoped to the same major.
# Read-only: the recipe is generated into $TMPDIR, never written to.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=packages/misc/linux-cachyos
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-kernel-version-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'kernel recipe version fixture: %s\n' "$1" >&2
    exit 1
}

srcinfo=$tmp/.SRCINFO
GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$root/$recipe" >"$srcinfo" 2>"$tmp/err" ||
    fail "makepkg --printsrcinfo failed for $recipe: $(head -1 "$tmp/err")"

sources=$(sed -n 's/^[[:space:]]*source = //p' "$srcinfo")
[[ -n $sources ]] || fail "the generated .SRCINFO lists no sources"

# --- pkgver -> the expected source-tag stem -------------------------------
pkgver=$(sed -n 's/^[[:space:]]*pkgver = //p' "$srcinfo" | head -1)
[[ -n $pkgver ]] || fail "no pkgver in the generated .SRCINFO"

if [[ $pkgver =~ ^([0-9]+\.[0-9]+)\.rc([0-9]+)$ ]]; then
    major=${BASH_REMATCH[1]}
    tag="cachyos-${major}-rc${BASH_REMATCH[2]}"
elif [[ $pkgver =~ ^([0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
    major=${BASH_REMATCH[1]}
    tag="cachyos-${major}.${BASH_REMATCH[2]}"
else
    fail "unrecognised pkgver '$pkgver' (expected X.Y.Z or X.Y.rcN)"
fi

# --- the tarball must be the one pkgver names -----------------------------
tarball=$(grep -E '\.tar\.(gz|xz|zst)$' <<<"$sources" | head -1)
[[ -n $tarball ]] || fail "no tarball source in the generated .SRCINFO"

base=$(basename "$tarball")
base=${base%.tar.*}
[[ $base == "$tag"-* ]] ||
    fail "tarball '$base' does not match pkgver $pkgver (expected '${tag}-<tagrel>')"

[[ $tarball == */download/"$base"/"$base".tar.* ]] ||
    fail "tarball URL directory and filename disagree: $tarball"

# --- every patch must come from the pkgver's major ------------------------
mapfile -t patches < <(grep 'kernel-patches/master/' <<<"$sources" || true)
((${#patches[@]} > 0)) ||
    fail "no kernel-patches sources: the patch set is unpopulated"

for patch_url in "${patches[@]}"; do
    [[ $patch_url == *"/master/$major/"* ]] ||
        fail "patch URL is not scoped to kernel major $major: $patch_url"
done

# The config is a local source, so a lost one shows up only at build time.
grep -qx 'config' <<<"$sources" || fail "the local 'config' source is missing"

printf 'kernel recipe version fixture: PASS (%s -> %s, %d patch sources)\n' \
    "$pkgver" "$base" "${#patches[@]}"
)
