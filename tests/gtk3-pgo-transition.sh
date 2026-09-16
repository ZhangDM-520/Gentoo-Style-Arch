#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec bash "$root/tests/pgo-transition.sh" \
    gtk3-git gtk packages/git/gtk3-git
