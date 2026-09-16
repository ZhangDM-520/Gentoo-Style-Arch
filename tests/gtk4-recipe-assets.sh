#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/core/gtk4-git"
assets=(
    gtk-update-icon-cache.hook
    gtk-update-icon-cache.script
    gtk4-querymodules.hook
    gtk4-querymodules.script
)

for asset in "${assets[@]}"; do
    path="$recipe/$asset"
    if ! test -f "$root/$path"; then
        printf 'missing GTK4 recipe asset: %s\n' "$path" >&2
        exit 1
    fi
    if ! git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        printf 'untracked GTK4 recipe asset: %s\n' "$path" >&2
        exit 1
    fi
done

if test -f "$root/$recipe/.gitignore" &&
    grep -Fx '*' "$root/$recipe/.gitignore" >/dev/null; then
    printf 'GTK4 recipe has a wildcard ignore that can hide local assets\n' >&2
    exit 1
fi

printf 'GTK4 recipe assets fixture: PASS\n'
