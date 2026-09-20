#!/usr/bin/env bash
# Aggregate the per-recipe .nvchecker.toml files and report outdated packages.
#
# Usage:
#   tools/nvcheck.sh                 check every recipe, write the report
#   tools/nvcheck.sh --list          list the configs that would be checked
#   tools/nvcheck.sh --only PATTERN  check only configs whose path matches
#   tools/nvcheck.sh --print-config CONFIG
#                                    print the generated config for one file
#   tools/nvcheck.sh --take NAME...  accept the current upstream versions as
#                                    known, so they stop being reported
#
# Why this exists at all: nvchecker has no multi-file mode. It reads one config
# with -c, so 51 scattered recipe configs need 51 invocations. And it persists
# nothing unless the config names an oldver AND a newver file - with both absent
# its state is silently discarded, `nvcmp` has nothing to compare, and every
# entry reads as never-seen. See nvchecker's core.py:
#
#     if 'oldver' in c and 'newver' in c:
#
# The recipe configs are shared with the rest of the repository and must not
# grow build-host paths, so the oldver/newver pair is injected here instead. The
# generated config is the original file with a [__config__] table prepended,
# byte for byte, which keeps multi-section configs (bash has three, with a
# combiner) working without any TOML re-serialisation.
#
# State lives outside the repository: it is machine state, not recipe content.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=${NVCHECK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gsa-nvcheck}
report=$state_dir/outdated.txt

die() { printf 'nvcheck: %s\n' "$*" >&2; exit 2; }

# Every config, sorted, so the report is stable between runs.
mapfile -t configs < <(
    find "$root/packages" -mindepth 3 -maxdepth 3 -name .nvchecker.toml -print | sort
)
((${#configs[@]})) || die "no .nvchecker.toml files found under $root/packages"

# The id is the recipe path with the filename dropped: packages/<group>/<id>.
config_id() {
    local cfg=$1
    cfg=${cfg#"$root"/packages/}
    printf '%s' "${cfg%/.nvchecker.toml}"
}

merged_config() { printf '%s/configs/%s.toml' "$state_dir" "$(config_id "$1")"; }
state_subdir() { printf '%s/state/%s' "$state_dir" "$(config_id "$1")"; }

# The original file must not already carry the table we inject: prepending a
# second [__config__] would be a duplicate key and nvchecker would refuse it.
write_merged() {
    local cfg=$1 out
    out=$(merged_config "$cfg")
    grep -q '^\[__config__\]' "$cfg" &&
        die "$(config_id "$cfg") already defines [__config__]; the injector would clash"

    local sub
    sub=$(state_subdir "$cfg")
    mkdir -p "$sub" "$(dirname "$out")"
    {
        printf '[__config__]\n'
        printf 'oldver = "%s/old_ver.json"\n' "$sub"
        printf 'newver = "%s/new_ver.json"\n' "$sub"
        printf '\n'
        cat "$cfg"
    } >"$out"
    printf '%s' "$out"
}

case ${1:-} in
    -h | --help)
        sed -n '2,25p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    --list)
        for cfg in "${configs[@]}"; do
            printf '%s\t%s\n' "$(config_id "$cfg")" "${cfg#"$root"/}"
        done
        exit 0
        ;;
    --print-config)
        [[ -n ${2:-} ]] || die '--print-config needs a config path'
        cfg=$2
        [[ $cfg == /* ]] || cfg="$root/$cfg"
        [[ -f $cfg ]] || die "no such config: $cfg"
        # Printed to stdout so a fixture can assert on it without touching the
        # state directory.
        grep -q '^\[__config__\]' "$cfg" &&
            die "$(config_id "$cfg") already defines [__config__]"
        sub=$(state_subdir "$cfg")
        printf '[__config__]\n'
        printf 'oldver = "%s/old_ver.json"\n' "$sub"
        printf 'newver = "%s/new_ver.json"\n' "$sub"
        printf '\n'
        cat "$cfg"
        exit 0
        ;;
    --take)
        shift
        (($#)) || die '--take needs at least one NAME, or --all'
        mkdir -p "$state_dir"
        for cfg in "${configs[@]}"; do
            merged=$(write_merged "$cfg")
            # A name that this config does not define is expected: --take is
            # normally called with one name across every config.
            nvtake -c "$merged" --ignore-nonexistent "$@" >/dev/null 2>&1 || true
        done
        printf 'nvcheck: accepted upstream versions as known\n'
        exit 0
        ;;
    --only)
        [[ -n ${2:-} ]] || die '--only needs a pattern'
        pattern=$2
        mapfile -t configs < <(printf '%s\n' "${configs[@]}" | grep -F "$pattern" || true)
        ((${#configs[@]})) || die "no config matches: $pattern"
        ;;
    '') ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

mkdir -p "$state_dir"
: >"$report"

failed=0
outdated=0
checked=0

for cfg in "${configs[@]}"; do
    id=$(config_id "$cfg")
    merged=$(write_merged "$cfg")
    checked=$((checked + 1))

    if ! nvchecker -c "$merged" >/dev/null 2>"$state_dir/last-error.log"; then
        printf 'ERROR  %s (see %s)\n' "$id" "$state_dir/last-error.log"
        failed=$((failed + 1))
        continue
    fi

    # nvcmp prints only genuine differences, so empty output means up to date.
    if out=$(nvcmp -c "$merged" 2>/dev/null) && [[ -n $out ]]; then
        printf '%s\n' "$out" >>"$report"
        outdated=$((outdated + 1))
        printf 'UPDATE %s\n' "$id"
    fi
done

printf '\nnvcheck: %d checked, %d outdated, %d failed\n' "$checked" "$outdated" "$failed"
if ((failed)); then
    printf 'report: %s\n' "$report"
    exit 3
fi
if ((outdated)); then
    printf 'outdated packages are listed in %s\n' "$report"
    exit 1
fi
printf 'all recipes are current\n'
