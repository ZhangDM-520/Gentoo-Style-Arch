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
