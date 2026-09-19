#!/usr/bin/env bash
#
# verify-config.sh - assert that a kernel .config really carries the options
# this recipe asked for.
#
# Why this exists
# ---------------
# `scripts/config` is blind. It appends or sed-replaces `CONFIG_FOO=y` without
# consulting Kconfig at all, so:
#
#   * a symbol that does not exist in this tree is a silent no-op, and
#   * a symbol whose `depends on` is unmet is written and then deleted by the
#     next `olddefconfig`/`make prepare`.
#
# Both cases leave the build log claiming success. The live example that
# motivated this file: `mm/Kconfig` gates the whole THP menu on `!PREEMPT_RT`,
# and this recipe's own `_cpusched=rt-bore` sets `PREEMPT_RT=y`, so every
# `_hugepage` write was discarded and THP has never been enabled on this host.
#
# Usage
# -----
#   verify-config.sh <config-file> <expectation>...
#
# Expectation forms:
#   SYM=v     the symbol must equal v exactly (after stripping surrounding
#             double quotes, so `DEFAULT_TCP_CONG=bbr` matches `="bbr"`)
#   SYM       the symbol must be y or m
#   !SYM      the symbol must not be set (an absent symbol counts as unset)
#   SYM!=v    the symbol must not equal v
#   SYM>=N    the symbol's integer value must be >= N
#
# Every unmet expectation is reported as `SYMBOL: expected X, got Y` on stderr,
# where Y distinguishes `absent` (the symbol does not exist in this tree - i.e.
# it was renamed or removed) from `n` (it exists but is off - i.e. it was gated
# off or overridden). That distinction is the whole point: it tells you whether
# to fix the symbol name or the dependency.
#
# Exit status: 0 if every expectation holds, 1 if any does not, 2 on misuse.
#
# No writes, no temporary files, no dependencies beyond bash and coreutils.

set -uo pipefail

usage() {
    printf 'usage: %s <config-file> <expectation>...\n' "${0##*/}" >&2
    printf 'expectations: SYM=v | SYM | !SYM | SYM!=v | SYM>=N\n' >&2
}

if [ "$#" -lt 2 ]; then
    usage
    exit 2
fi

cfg="$1"; shift

if [ ! -r "$cfg" ]; then
    printf '%s: cannot read config file %s\n' "${0##*/}" "$cfg" >&2
    exit 2
fi

declare -A _value=() _state=()

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        'CONFIG_'*'='*)
            sym="${line%%=*}"
            sym="${sym#CONFIG_}"
            val="${line#*=}"
            # Kconfig quotes string values; compare unquoted.
            if [ "${val:0:1}" = '"' ] && [ "${val: -1}" = '"' ] && [ "${#val}" -ge 2 ]; then
                val="${val:1:${#val}-2}"
            fi
            _value["$sym"]="$val"
            _state["$sym"]="set"
            ;;
        '# CONFIG_'*' is not set')
            sym="${line#\# CONFIG_}"
            sym="${sym% is not set}"
            _state["$sym"]="unset"
            ;;
    esac
done < "$cfg"

_rc=0
_checked=0
_failed=0

# The symbol's effective value: `n` when the config says `# CONFIG_X is not
# set`, the value itself when set, and the literal `absent` when the symbol is
# nowhere in the file - which is how a renamed or removed symbol shows up.
_effective() {
    case "${_state[$1]:-}" in
        set)   printf '%s' "${_value[$1]}" ;;
        unset) printf 'n' ;;
        *)     printf 'absent' ;;
    esac
}

_enabled() {
    [ "$(_effective "$1")" = "y" ] || [ "$(_effective "$1")" = "m" ]
}

_fail() {
    printf '%s: expected %s, got %s\n' "$1" "$2" "$(_effective "$1")" >&2
    _rc=1
    _failed=$((_failed + 1))
}

for want in "$@"; do
    _checked=$((_checked + 1))

    case "$want" in
        '!'*)
            sym="${want#!}"
            case "$sym" in
                ''|*'='*|*'!'*)
                    printf '%s: malformed expectation %s\n' "${0##*/}" "$want" >&2
                    exit 2
                    ;;
            esac
            # An absent symbol counts as unset: `!SYM` asserts "not enabled",
            # not "exists and is off". Use `SYM=n` when existence matters.
            if _enabled "$sym"; then
                _fail "$sym" "not set"
            fi
            ;;

        *'!='*)
            sym="${want%%!=*}"
            bad="${want#*!=}"
            if [ -z "$sym" ] || [ -z "$bad" ]; then
                printf '%s: malformed expectation %s\n' "${0##*/}" "$want" >&2
                exit 2
            fi
            if [ "$(_effective "$sym")" = "$bad" ]; then
                _fail "$sym" "anything but $bad"
            fi
            ;;

        *'>='*)
            sym="${want%%>=*}"
            min="${want#*>=}"
            if [ -z "$sym" ] || ! [[ "$min" =~ ^[0-9]+$ ]]; then
                printf '%s: malformed expectation %s\n' "${0##*/}" "$want" >&2
                exit 2
            fi
            got="$(_effective "$sym")"
            if ! [[ "$got" =~ ^[0-9]+$ ]] || [ "$got" -lt "$min" ]; then
                _fail "$sym" "an integer >= $min"
            fi
            ;;

        *'='*)
            sym="${want%%=*}"
            good="${want#*=}"
            if [ -z "$sym" ]; then
                printf '%s: malformed expectation %s\n' "${0##*/}" "$want" >&2
                exit 2
            fi
            if [ "$(_effective "$sym")" != "$good" ]; then
                _fail "$sym" "$good"
            fi
            ;;

        *)
            sym="$want"
            if ! _enabled "$sym"; then
                _fail "$sym" "y or m"
            fi
            ;;
    esac
done

if [ "$_rc" -eq 0 ]; then
    printf '%s: %d expectation(s) hold in %s\n' "${0##*/}" "$_checked" "$cfg"
else
    printf '%s: %d of %d expectation(s) failed in %s\n' \
        "${0##*/}" "$_failed" "$_checked" "$cfg" >&2
fi

exit "$_rc"
