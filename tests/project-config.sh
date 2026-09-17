#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

output=$(fish "$root/build-all.fish" --list 2>&1) || {
    printf '%s\n' "$output" >&2
    exit 1
}

if ! grep -F 'xorg-xwayland-git' <<<"$output" >/dev/null; then
    printf 'package listing omitted xorg-xwayland-git:\n%s\n' "$output" >&2
    exit 1
fi

# config/groups/ is reachable only through the five declared group names:
# read_group_config is called for exactly git/stable/core/misc/third-party and
# resolve_group rejects every other name, so any other file in that directory is
# unreachable control state that silently goes stale. A run of --list above
# already proved the five real files load, so only the directory's contents need
# checking here.
expected_files=(core.list git.list misc.list stable.list third-party.list)
mapfile -t group_files < <(
    find "$root/config/groups" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
)
if [[ "${group_files[*]}" != "${expected_files[*]}" ]]; then
    printf 'unexpected config/groups contents: %s (expected: %s)\n' \
        "${group_files[*]}" "${expected_files[*]}" >&2
    exit 1
fi

printf 'project configuration fixture: PASS\n'
