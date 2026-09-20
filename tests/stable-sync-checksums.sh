#!/usr/bin/env bash
set -euo pipefail

# A stable recipe is version-synced by rewriting pkgver/pkgrel in place from
# the Arch repos, and the committed sums are deliberately left describing the
# previous version. makepkg would reject the freshly downloaded tarball, so
# build_package adds --skipchecksums for that build.
#
# That is a real weakening — those sources are built and (with -i) installed
# without a committed sum — and it was completely silent: build_package is only
# ever called quiet, every lane redirects its stdout/stderr into the package
# log, and the one echo that names the argv is gated behind the non-quiet flag
# that nothing ever passes. So nothing in the terminal or in the log ever said
# it had happened. This fixture pins:
#
#   1. the sync really happens (pkgver rewritten) — otherwise the rest is
#      vacuous, which is the trap this fixture exists to avoid;
#   2. --skipchecksums really reaches makepkg's argv (the mechanism), and the
#      package log says so in words (the disclosure);
#   3. --no-sync disables all three: no rewrite, no flag, no disclosure — so
#      the disclosure cannot rot into unconditional noise.
#
# vercmp must be present for the sync to compare versions.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-stable-sync.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

command -v vercmp >/dev/null || {
    printf 'vercmp is required (it ships with pacman)\n' >&2
    exit 1
}
# The repo version the stub repo advertises, and the version the recipe pins.
repo_version=2.0.0
staged_version=1.0.0

make_workspace() { # $1 = dir
    local dir=$1
    mkdir -p "$dir/config/groups" "$dir/packages/stable/s1" "$dir/bin"
    cp "$root/build-all.fish" "$dir/build-all.fish"

    cat >"$dir/config/build-defaults.conf" <<'EOF'
lanes=1
jobs=2
intensity=low
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
    : >"$dir/config/dependencies.conf"
    for group in git stable core misc third-party; do
        : >"$dir/config/groups/$group.list"
    done
    printf 's1\n' >>"$dir/config/groups/stable.list"
    printf 's1|packages/stable/s1\n' >"$dir/config/packages.map"

    cat >"$dir/packages/stable/s1/PKGBUILD" <<EOF
pkgname=s1
pkgver=$staged_version
pkgrel=1
arch=(any)
source=("https://example.invalid/s1-\$pkgver.tar.gz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
EOF

    # The stub repository: sync_stable_version runs `pacman -Si <name>`.
    cat >"$dir/bin/pacman" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == -Si ]]; then
    printf 'Repository      : extra\nName            : s1\nVersion         : $repo_version-1\n'
    exit 0
fi
exit 0
EOF
    chmod +x "$dir/bin/pacman"

    # Records the argv it was invoked with, which is where the flag has to show.
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_MAKEPKG_ARGV"
printf 'fake makepkg: %s\n' "$*"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
}

run_build() { # $1 = dir, $2 = label, extra args...
    local dir=$1 label=$2
    shift 2
    set +e
    output=$(
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_CPU_THREADS=4 \
        GSA_MEMORY_GIB=8 \
        GSA_FAKE_MAKEPKG_ARGV="$dir/argv" \
        fish "$dir/build-all.fish" --allow-broken-rustc --no-deps \
            --intensity low s1 "$@" 2>&1
    )
    rc=$?
    set -e
    printf '%s' "$output" >"$dir/out.txt"
    if ((rc != 0)); then
        printf '%s: the builder exited %s:\n%s\n' "$label" "$rc" "$output" >&2
        exit 1
    fi
}

# ─── Case 1: the default sync path ──────────────────────────────────────────
sync_dir="$fixture/sync"
make_workspace "$sync_dir"
: >"$sync_dir/argv"
run_build "$sync_dir" 'sync'

# (1) The rewrite must have happened, or nothing below proves anything.
if ! grep -q "^pkgver=$repo_version$" "$sync_dir/packages/stable/s1/PKGBUILD"; then
    printf 'the recipe was not version-synced, so this run cannot exercise the\n' >&2
    printf 'checksum path it is meant to pin:\n' >&2
    cat "$sync_dir/packages/stable/s1/PKGBUILD" >&2
    exit 1
fi

# (2) The mechanism and its disclosure.
if ! grep -q -- '--skipchecksums' "$sync_dir/argv"; then
    printf 'a synced stable build did not pass --skipchecksums to makepkg:\n' >&2
    cat "$sync_dir/argv" >&2
    exit 1
fi
sync_log="$sync_dir/state/logs/s1.log"
if ! grep -q 'NOT checksum-verified' "$sync_log"; then
    printf 'the build disabled checksum verification without saying so in the\n' >&2
    printf 'package log, which is the only record a human can inspect:\n' >&2
    cat "$sync_log" >&2
    exit 1
fi
if ! grep -q -- '--skipchecksums' "$sync_log"; then
    printf 'the log mentions the weaker build but not the flag that causes it:\n' >&2
    cat "$sync_log" >&2
    exit 1
fi

# ─── Case 2: --no-sync must disable all three ───────────────────────────────
nosync_dir="$fixture/nosync"
make_workspace "$nosync_dir"
: >"$nosync_dir/argv"
run_build "$nosync_dir" 'no-sync' --no-sync

if ! grep -q "^pkgver=$staged_version$" "$nosync_dir/packages/stable/s1/PKGBUILD"; then
    printf '--no-sync rewrote the recipe version anyway:\n' >&2
    cat "$nosync_dir/packages/stable/s1/PKGBUILD" >&2
    exit 1
fi
if grep -q -- '--skipchecksums' "$nosync_dir/argv"; then
    printf '--no-sync still skipped checksum verification:\n' >&2
    cat "$nosync_dir/argv" >&2
    exit 1
fi
if grep -q 'NOT checksum-verified' "$nosync_dir/state/logs/s1.log"; then
    printf 'the disclosure is unconditional noise: it appeared without a sync\n' >&2
    exit 1
fi

printf 'stable-sync fixture: PASS\n'
