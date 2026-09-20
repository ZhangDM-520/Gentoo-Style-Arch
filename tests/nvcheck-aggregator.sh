#!/usr/bin/env bash
# Reduced-scale contract for tools/nvcheck.sh.
#
# The aggregator itself needs the network and 51 nvchecker runs, so it is not in
# the battery. This pins the parts that decide whether it can work at all, using
# only its offline modes. The invariant worth protecting is the merge: the
# generated config must be the recipe's file with a [__config__] table prepended
# and nothing else touched, because a re-serialised TOML would quietly drop or
# reorder what a recipe author wrote.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/tools/nvcheck.sh"

fail() {
    printf 'nvcheck aggregator: %s\n' "$1" >&2
    exit 1
}

test -x "$tool" || fail "tools/nvcheck.sh is not present and executable"
bash -n "$tool" || fail "tools/nvcheck.sh does not parse"

# --list must see every config the repository has, not a remembered inventory.
listed=$("$tool" --list)
configured=$(find "$root/packages" -mindepth 3 -maxdepth 3 -name .nvchecker.toml | wc -l)
((configured > 0)) || fail "no .nvchecker.toml files found at all"
[[ $(wc -l <<<"$listed") -eq $configured ]] ||
    fail "--list reported $(wc -l <<<"$listed") configs but $configured exist"
grep -Fq 'packages/git/onlyoffice-git/.nvchecker.toml' <<<"$listed" ||
    fail "--list does not include the onlyoffice-git config"

# The merge must preserve the original bytes exactly. bash is the hard case: it
# has three sections, one of them quoted, and a combiner referencing the others.
multi="$root/packages/stable/bash/.nvchecker.toml"
if [[ -f $multi ]]; then
    merged=$("$tool" --print-config "$multi")
    head -n1 <<<"$merged" | grep -Fxq '[__config__]' ||
        fail "--print-config does not start with a [__config__] table"
    grep -Fq 'oldver = "' <<<"$merged" || fail "the merged config has no oldver"
    grep -Fq 'newver = "' <<<"$merged" || fail "the merged config has no newver"
    if ! diff -q <(tail -n +5 <<<"$merged") "$multi" >/dev/null; then
        fail "--print-config altered the recipe's config instead of copying it verbatim"
    fi
fi

# nvchecker persists nothing unless both files are named, and the paths must be
# absolute: a relative oldver/newver is resolved against the *config file's*
# directory, which for these recipes is inside the repository.
oldver=$("$tool" --print-config "$multi" | sed -n 's/^oldver = "\(.*\)"$/\1/p')
newver=$("$tool" --print-config "$multi" | sed -n 's/^newver = "\(.*\)"$/\1/p')
[[ $oldver == /* ]] || fail "oldver is not absolute: $oldver"
[[ $newver == /* ]] || fail "newver is not absolute: $newver"
[[ $oldver != "$root"/* ]] || fail "state would be written inside the repository: $oldver"
[[ $oldver == */old_ver.json && $newver == */new_ver.json ]] ||
    fail "the state files are not named old_ver.json/new_ver.json"

# Printing a config must not create state, here or anywhere. Asserted against a
# redirected state directory rather than by mtime, so a concurrent build writing
# into packages/ cannot make this flaky.
tmpstate=$(mktemp -d)
NVCHECK_STATE_DIR=$tmpstate "$tool" --print-config "$multi" >/dev/null
[[ -z $(ls -A "$tmpstate") ]] || fail "--print-config created state in its state dir"
rm -rf "$tmpstate"
strays=$(find "$root/packages" \( -name old_ver.json -o -name new_ver.json \) | wc -l)
[[ $strays -eq 0 ]] || fail "version state leaked into the repository"

# A config that already defines the table must be refused rather than silently
# producing a duplicate [__config__] that nvchecker would reject.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '[__config__]\noldver = "x"\nnewver = "y"\n\n[foo]\nsource = "git"\n' >"$tmp/already.toml"
if "$tool" --print-config "$tmp/already.toml" >/dev/null 2>&1; then
    fail "a config that already defines [__config__] was accepted"
fi

# Unknown arguments must fail rather than fall through to a full network run.
if "$tool" --not-a-flag >/dev/null 2>&1; then
    fail "an unknown argument was accepted"
fi

# The tool is host-side and must stay out of the fixture battery's discovery,
# which scans tests/ only.
if grep -rqF 'tools/nvcheck.sh' "$root/tests/run-all.sh"; then
    fail "run-all.sh references the tool; it must stay undiscovered"
fi

printf 'nvcheck aggregator fixture: PASS\n'
