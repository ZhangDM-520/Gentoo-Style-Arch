#!/usr/bin/env bash
set -uo pipefail

# Run the whole fixture battery. Every fixture is self-contained and
# non-mutating: they build scratch trees under $TMPDIR, diff committed metadata,
# and assert on the builder's own output, so this is safe on a working checkout.
#
# Usage:
#   tests/run-all.sh            # every fixture
#   tests/run-all.sh recipe     # only fixtures whose name matches "recipe"
#
# Order is alphabetical (stable and maintenance-free); discovery means a new
# fixture needs no edit here.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

filter="${1:-}"
pass=0
failed=()

for fixture in $(cd "$root/tests" && find . -maxdepth 1 -name '*.sh' \
    ! -name 'run-all.sh' -printf '%f\n' | sort); do
    if [[ -n $filter && $fixture != *"$filter"* ]]; then
        continue
    fi
    if output=$(bash "$root/tests/$fixture" 2>&1); then
        pass=$((pass + 1))
        printf '  ✓ %s\n' "$fixture"
    else
        failed+=("$fixture")
        printf '  ✗ %s\n' "$fixture"
        printf '%s\n' "$output" | sed 's/^/      /'
    fi
done

echo ""
if ((${#failed[@]} == 0)); then
    printf 'fixture battery: PASS (%d fixture(s))\n' "$pass"
    exit 0
fi
printf 'fixture battery: FAIL (%d passed, %d failed: %s)\n' \
    "$pass" "${#failed[@]}" "${failed[*]}" >&2
exit 1
