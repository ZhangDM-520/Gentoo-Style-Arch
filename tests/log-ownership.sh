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

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-log-ownership.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'log-ownership: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '%s\n' "$2" >&2
    exit 1
}

make_case_workspace() { # $1 = sandbox dir
    local dir=$1
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 "$gsa_meta_any"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Scenario knob (fixture-defined, like GSA_FAKE_FAIL_PACKAGE): hold the lane open
# so a signal can land mid-run while the dispatcher is alive.
sleep "${GSA_FAKE_BUILD_SLEEP:-0}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    stub_sudo "$dir"
}

# ─── Run B meets run A's poisoned log ────────────────────────────────────────
dir="$fixture/poisoned"
make_case_workspace "$dir"
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
make_case_workspace "$dir"
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
        GSA_FAKE_BUILD_SLEEP=30 \
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

# ==== log-ownership-root.sh ====
(

# Root-mode half of the 2026-09-23 log-ownership contract (the unprivileged
# quarantine half is pinned by tests/log-ownership.sh).
#
# In root mode the supervisor's shell opens every log, so before the fix the
# per-package log was created root-owned at lane spawn and only repaired at
# package exit (chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR") — an
# interrupted run left the in-flight logs poisoned for the next unprivileged
# run. The contract this fixture pins:
#   * ownership is decided at WRITE time: an unopenable log is repaired in
#     place (chown + owner-writable) BEFORE any redirect opens it, loudly;
#   * root mode repairs in place and NEVER quarantines — .stale.* renames are
#     the unprivileged recovery path only;
#   * nothing root-owned survives: the run completes rc=0 with the build
#     running as the invoking user.
#
# Portability: a fixture cannot create genuinely root-owned files without
# sudo, so the poison combines the real shape (0644) with a `stat` stub that
# reports owner "root" for exactly that path — the builder's root-mode
# predicate is `stat -c %U`, so it sees precisely what it would see on the
# real incident, while the file stays writable so the repaired run can
# actually write. The `id` stub makes the builder believe it runs under sudo
# (SUDO_USER set); the `chown` stub records every invocation (a real chown to
# the current owner would be a no-op anyway). Assertions key on a PER-FILE,
# non-`-R` chown naming the poisoned log plus the announced repair — the
# pre-write-time repair — which the startup/exit `chown -R` sweeps can never
# produce (they name directories, never the log file).

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-log-ownership-root.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'log-ownership-root: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '%s\n' "$2" >&2
    exit 1
}

dir="$fixture/rootmode"
make_workspace "$dir" 2 2 low
for id in p1 p2; do
    add_package "$dir" "$id" "$gsa_meta_any"
done

cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
mkdir -p "$GSA_FAKE_MARKER_DIR"
touch "$GSA_FAKE_MARKER_DIR/$id"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF

# Pretend-root identity: `id -un` answers "root" only when the fixture asks
# for root mode; everything else falls through to the real id.
cat >"$dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -un && ${GSA_FAKE_ROOT_MODE:-0} == 1 ]]; then
    echo root
    exit 0
fi
exec /usr/bin/id "$@"
EOF

# Record every sudo invocation; `sudo -u <user> cmd…` drops the impersonation
# pair (the fixture really runs as the build user) and execs the rest. Leading
# sudo flags are dropped first (including --preserve-env, which host fish `sudo`
# wrapper functions inject).
cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?fixture forgot GSA_FAKE_SUDO_LOG}"
while [[ ${1:-} == -* ]]; do
    [[ ${1:-} == -u ]] && break
    shift
done
if [[ ${1:-} == -u && $# -ge 2 ]]; then
    shift 2
fi
((${#@})) || exit 0
exec "$@"
EOF

# Record every chown invocation and succeed. The helper's follow-up chmod
# (real, unstubbed) is what makes the poisoned file writable again; owner is
# already correct in the fixture, so a no-op chown + real chmod + stat
# verify is exactly the repair sequence asserted below.
cat >"$dir/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GSA_FAKE_CHOWN_LOG:?fixture forgot GSA_FAKE_CHOWN_LOG}"
exit 0
EOF

# Lie about ownership of exactly one path: fixtures cannot chown to root, but
# the root-mode repair branch keys on `stat -c %U`. Every other stat (mtime
# skip-checks, %A/%a modes) falls through to the real binary.
cat >"$dir/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${GSA_FAKE_ROOT_FILE:-} && ${1:-} == -c && ${2:-} == %U &&
    ${*: -1} == "$GSA_FAKE_ROOT_FILE" ]]; then
    echo root
    exit 0
fi
exec /usr/bin/stat "$@"
EOF

chmod +x "$dir/bin/makepkg" "$dir/bin/id" "$dir/bin/sudo" "$dir/bin/chown" \
    "$dir/bin/stat"

# Poison p1's log: run-A content, mode exactly like a real root-owned 0644
# log, owner reported as "root" by the stat stub (GSA_FAKE_ROOT_FILE).
mkdir -p "$dir/state/logs"
printf 'SENTINEL run-A crash evidence\n' >"$dir/state/logs/p1.log"

# Resolve the real user BEFORE the PATH prefix exists: bash expands prefixed
# assignments sequentially, so `id -un` inside the prefix would hit the stub
# (GSA_FAKE_ROOT_MODE is already set by then) and answer "root".
fixture_user=$(id -un)

set +e
output=$(
    PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_ROOT_MODE=1 \
        SUDO_USER="$fixture_user" \
        GSA_FAKE_SUDO_LOG="$dir/state/sudo.log" \
        GSA_FAKE_CHOWN_LOG="$dir/state/chown.log" \
        GSA_FAKE_ROOT_FILE="$dir/state/logs/p1.log" \
        GSA_FAKE_MARKER_DIR="$dir/state/built" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" --no-deps --allow-broken-rustc --no-sync p1 p2 \
        2>&1
)
rc=$?
set -e

if ((rc != 0)); then
    fail "root-mode run over a poisoned log must succeed via write-time repair, rc=$rc" "$output"
fi
if grep -q 'rc=125' <<<"$output"; then
    fail "misleading rc=125 lane row reappeared (log open failed before the build)" "$output"
fi
if grep -q 'An error occurred while redirecting file' <<<"$output"; then
    fail "fish redirect error escaped (the poisoned log was not repaired in time)" "$output"
fi
if ! grep -q 'repaired root-owned runtime file' <<<"$output"; then
    fail "write-time repair was not announced (must be loud, not silent)" "$output"
fi
if ! grep 'repaired root-owned runtime file' <<<"$output" |
    grep -F -- 'logs/p1.log' >/dev/null; then
    fail "repair announcement does not name the poisoned log" "$output"
fi

chownlog="$dir/state/chown.log"
[[ -f $chownlog ]] || fail "chown stub never invoked — no ownership repair ran" "$output"
# The pre-write-time repair: names the poisoned FILE, without -R (the exit
# chown -R names only directories and can never satisfy this).
if ! grep -v -- '-R' "$chownlog" | grep -F -- "logs/p1.log" >/dev/null; then
    fail "no per-file chown naming the poisoned log before it was opened:" \
        "$(cat "$chownlog")"
fi

# Root mode repairs IN PLACE — quarantine (.stale.*) is unprivileged-only.
shopt -s nullglob
stale=("$dir"/state/logs/*.stale.*)
shopt -u nullglob
if ((${#stale[@]} != 0)); then
    fail "root mode quarantined instead of repairing in place:" "$(ls -la "$dir/state/logs")"
fi

log="$dir/state/logs/p1.log"
[[ -w $log ]] || fail "log still not writable after repair: $log"
if ! grep -q 'fake makepkg' "$log"; then
    fail "build log missing stub makepkg output — the build never ran" \
        "$(cat "$log" 2>/dev/null)"
fi
for id in p1 p2; do
    [[ -f $dir/state/built/$id ]] ||
        fail "package $id never built — repair must not abort the run" "$output"
done

printf 'log-ownership-root fixture: PASS\n'
)
