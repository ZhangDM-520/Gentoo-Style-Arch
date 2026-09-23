#!/usr/bin/env bash
set -euo pipefail

# Log-ownership crash window (2026-09-23 incident): a root-mode run that dies
# mid-flight leaves the in-flight per-package logs root-owned, because the
# supervisor's shell opens them (lane-spawn truncate/redirect), not the
# user-context build. The next UNPRIVILEGED run then dies at the same redirect
# with a misleading "BUILD FAILED (rc=125, 0m00s)" and fish's "An error
# occurred while redirecting file ... open: Permission denied" — before the
# build even starts, and the crashed run's log content is left unopenable.
#
# The builder must instead: recognize the log cannot be opened for write by the
# build user, QUARANTINE it under a .stale.* name (preserving the crash
# forensics — never a silent truncate), announce the preserved path, and build
# normally into a fresh log.
#
# Portability note: fixtures never use sudo, so a genuinely root-owned file
# cannot be produced here. A user-owned 0444 file is the same class — the
# predicate is test -w by the build user, and open-for-write fails with the
# same EACCES either way (root-owned 644 vs own 0444). The root-mode branch
# (chown repair) needs real root and is argued in docs/NOTE.md, not pinned here.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-log-ownership.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'log-ownership: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '%s\n' "$2" >&2
    exit 1
}

make_workspace() { # $1 = sandbox dir
    local dir=$1
    mkdir -p "$dir/config/groups" "$dir/bin"
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
    for group in git stable core misc third-party app; do
        : >"$dir/config/groups/$group.list"
    done
    : >"$dir/config/packages.map"
    mkdir -p "$dir/packages/p1"
    printf 'pkgname=p1\npkgver=1.0.0\npkgrel=1\narch=(any)\n' \
        >"$dir/packages/p1/PKGBUILD"
    printf '%s|packages/%s\n' p1 p1 >>"$dir/config/packages.map"
    printf '%s\n' p1 >>"$dir/config/groups/git.list"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Scenario knob (fixture-defined, like GSA_FAIL_PACKAGE): hold the lane open
# so a signal can land mid-run while the dispatcher is alive.
sleep "${GSA_FIXTURE_BUILD_SLEEP:-0}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
args=()
for a in "$@"; do
    case $a in
    -n | -v | --) ;;
    *) args+=("$a") ;;
    esac
done
((${#args[@]})) || exit 0
exec "${args[@]}"
EOF
    chmod +x "$dir/bin/sudo"
}

# ─── Run B meets run A's poisoned log ────────────────────────────────────────
dir="$fixture/poisoned"
make_workspace "$dir"
mkdir -p "$dir/state/logs"
sentinel='SENTINEL run-A crash evidence'
printf '%s\n' "$sentinel" >"$dir/state/logs/p1.log"
chmod 0444 "$dir/state/logs/p1.log" # stand-in for root-owned 644 (see header)

set +e
output=$(
    PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" --no-deps --allow-broken-rustc --no-sync p1 \
        2>&1
)
rc=$?
set -e

if ((rc != 0)); then
    fail "run over a poisoned log must succeed (quarantine + rebuild), rc=$rc" "$output"
fi
if grep -q 'rc=125' <<<"$output"; then
    fail "misleading rc=125 lane row reappeared (log open failed before the build)" "$output"
fi
if grep -q 'An error occurred while redirecting file' <<<"$output"; then
    fail "fish redirect error escaped (the poisoned log was not handled)" "$output"
fi

log="$dir/state/logs/p1.log"
if [[ ! -f $log ]]; then
    fail "fresh build log was not created: $log" "$output"
fi
if [[ ! -w $log ]]; then
    fail "build log still not writable by the build user: $log"
fi
if ! grep -q 'fake makepkg' "$log"; then
    fail "build log missing stub makepkg output — the build never ran" \
        "$(cat "$log" 2>/dev/null)"
fi

shopt -s nullglob
quarantined=("$dir"/state/logs/p1.log.stale.*)
shopt -u nullglob
if ((${#quarantined[@]} != 1)); then
    fail "expected exactly one quarantined log p1.log.stale.*, found ${#quarantined[@]}" \
        "$(ls -la "$dir/state/logs")"
fi
if ! grep -qF "$sentinel" "${quarantined[0]}"; then
    fail "quarantined log lost the crashed run's content (silent truncate?)" \
        "$(cat "${quarantined[0]}")"
fi
if ! grep -q 'preserved' <<<"$output"; then
    fail "run output does not name the preserved log path (quarantine must be loud)" \
        "$output"
fi

# ─── dispatcher.log poison: forensics appends must survive too ──────────────
# dispatcher_log swallows its own append errors (2>/dev/null), so a poisoned
# dispatcher.log used to lose signal forensics silently. Same contract: it must
# be reopened/quarantined, not dropped.
dir="$fixture/poisoned-dispatcher"
make_workspace "$dir"
mkdir -p "$dir/state/logs"
printf 'SENTINEL run-A dispatcher\n' >"$dir/state/logs/dispatcher.log"
chmod 0444 "$dir/state/logs/dispatcher.log"
# A successful run does not write dispatcher.log on its own (it records
# signals/reap anomalies only), so drive it through the SIGINT path instead:
# dispatcher.log must be reopened (quarantined + recreated) and the
# interrupted run's line recorded — the append used to vanish behind
# dispatcher_log's 2>/dev/null.
set +e
output=$(
    PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        GSA_FIXTURE_BUILD_SLEEP=30 \
        fish "$dir/build-all.fish" --no-deps --allow-broken-rustc --no-sync p1 \
        2>&1 &
    builder=$!
    # Interrupt only while the lane (and therefore the dispatcher) is
    # provably alive; the stub makepkg holds the lane open for 30 s.
    lane_seen=0
    for _ in $(seq 100); do
        if pgrep -f -- "$dir/build-all.fish --lane-job" >/dev/null; then
            lane_seen=1
            break
        fi
        sleep 0.1
    done
    kill -INT "$builder" 2>/dev/null
    wait "$builder"
    echo "lane-seen=$lane_seen interrupted-rc=$?"
)
set -e
grep -q 'lane-seen=1' <<<"$output" ||
    fail "lane child never spawned (cannot drive the signal scenario)" "$output"
dlog="$dir/state/logs/dispatcher.log"
if [[ ! -w $dlog ]]; then
    fail "dispatcher.log still not writable after a poisoned start" "$output"
fi
if ! grep -q '\[DEBUG-gsa-term\] signal: INT' "$dlog"; then
    fail "signal forensics never reached dispatcher.log" \
        "$(ls -la "$dir/state/logs"; cat "$dlog" 2>/dev/null)"
fi
if ! grep -q 'SENTINEL run-A dispatcher' "$dlog"; then
    # The quarantine must have moved the old content aside, not overwritten it.
    shopt -s nullglob
    dst=("$dir"/state/logs/dispatcher.log.stale.*)
    shopt -u nullglob
    if ((${#dst[@]} != 1)) || ! grep -q 'SENTINEL run-A dispatcher' "${dst[0]}"; then
        fail "dispatcher.log forensics were destroyed instead of quarantined" \
            "$(ls -la "$dir/state/logs"; cat "$dlog" 2>/dev/null)"
    fi
fi

printf 'log-ownership fixture: PASS\n'
