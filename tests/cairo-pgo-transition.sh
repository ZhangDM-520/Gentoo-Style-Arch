#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec bash "$root/tests/pgo-transition.sh" \
    cairo-git cairo packages/git/cairo-git
