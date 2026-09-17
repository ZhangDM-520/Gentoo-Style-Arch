#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec bash "$root/tests/pgo-transition.sh" \
    xorg-xwayland-git xserver packages/git/xorg-xwayland-git
