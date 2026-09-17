#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec bash "$root/tests/pgo-transition.sh" \
    glib2-git glib packages/core/glib2-git
