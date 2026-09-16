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

printf 'project configuration fixture: PASS\n'
