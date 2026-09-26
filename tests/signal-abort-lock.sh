#!/usr/bin/env bash
set -uo pipefail

# Signal honesty, transaction-safe lane abort, stale-lock probe, and the
# pacman-mutex shim — one synthetic workspace (2026-09-23 incident):
#   - dispatcher + all six lanes died at 19:34:01 with NO recorded signal;
#   - a signal-killed lane left no result at all → rc=125 "no valid result";
#   - stop_lane_process's 20x TERM + KILL-at-0.5 s blitz re-interrupted
#     pacman's db.lck unlock → stale lock → six installs hard-failed;
#   - makepkg's `-s` dep installs ran pacman outside the builder flock.
#
# Sub-tests:
#   1. --stale-lock-check: idle holder-less lock removed + STALE warning;
#      live holder kept + pid/cmd + recovery text.
#   2. direct --lane-job: SIGTERM the lane child → honest result line
#      "p1 143 N", process rc 143, "lane child received TERM" in the log.
#   3. full run: SIGTERM the live lane child → dispatcher reports
#      BUILD FAILED (rc=143), never "no valid result"; the run-start shim
#      exists (0755, flock/mutex/pacman/"$@") and the stub makepkg saw
#      PACMAN pointing at it.
#   4. SIGINT/SIGTERM/SIGHUP the dispatcher → dispatcher.log names the
#      signal, run exits 130 printing "Build interrupted", exactly ONE TERM
#      reaches the lane pgrp (the old blitz logged 20), no lane survives.
#   5. busy db.lck preflight: -i refused with holder + recovery, lock kept;
#      build-only run warns and builds anyway.
#   6. static: grace constant 30 s, one TERM, KILL strictly after the grace.
#   7. direct shim invocation: stub flock proves "$@" pass-through.
#
# Lock isolation: the PATH-stub `pacman-conf` answers DBPath with a fixture
# directory, so the host's real /var/lib/pacman/db.lck is never probed; the
# stub `pgrep` is a fixture-side oracle. The builder gains NO GSA_* test knob
# (it honours exactly the seven variables --help lists); GSA_FAKE_* names are
# consumed by the stubs only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-signal-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

make_workspace "$fixture" auto auto xhigh
add_package "$fixture" p1

# ── stubs (behaviour driven by GSA_FAKE_* variables the STUBS define) ───────
cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
name=$(basename "$PWD")
[[ -n ${GSA_FAKE_PACMAN_ENV_LOG:-} ]] &&
    printf '%s\n' "${PACMAN:-}" >>"$GSA_FAKE_PACMAN_ENV_LOG"
if [[ -n ${GSA_FAKE_MARKER_DIR:-} ]]; then
    mkdir -p "$GSA_FAKE_MARKER_DIR"
    touch "$GSA_FAKE_MARKER_DIR/$name"
fi
if [[ -n ${GSA_FAKE_BUILD_SECONDS:-} ]]; then
    # Record every signal receipt (the old 20x TERM blitz would show up as
    # repeated lines) and exit promptly on TERM so a well-behaved teardown
    # never has to reach SIGKILL-after-grace.
    trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "TERM\n" >>"$GSA_FAKE_SIGNAL_LOG"; exit 143' TERM
    trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "INT\n" >>"$GSA_FAKE_SIGNAL_LOG"' INT
    trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "HUP\n" >>"$GSA_FAKE_SIGNAL_LOG"' HUP
    sleep "${GSA_FAKE_BUILD_SECONDS}" &
    wait $!
fi
touch "$PWD/$name-1.0-1-x86_64.pkg.tar.zst"
exit 0
EOF

cat >"$fixture/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
# Lock-holder oracle: a non-empty GSA_FAKE_PGREP_HOLDER is THE pid "holding"
# db.lck (for -x pacman); unset = provably idle. Fully stub-controlled so a
# real pacman elsewhere on the host cannot make this fixture flap.
if [[ ${1:-} == -x ]]; then
    if [[ -n ${GSA_FAKE_PGREP_HOLDER:-} && ${2:-} == pacman ]]; then
        printf '%s\n' "$GSA_FAKE_PGREP_HOLDER"
        exit 0
    fi
    exit 1
fi
exit 1
EOF

cat >"$fixture/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
# DBPath oracle: fixtures must never probe the host's real
# /var/lib/pacman/db.lck — answer with a fixture directory instead.
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:-/nonexistent-gsa-db}"
    exit 0
fi
exit 1
EOF

cat >"$fixture/bin/flock" <<'EOF'
#!/usr/bin/env bash
# Shim invocation probe: keep REAL flock semantics, but redirect the baked
# /usr/bin/pacman to the recorder so no real database is ever touched.
args=("$@")
for i in "${!args[@]}"; do
    [[ ${args[i]} == /usr/bin/pacman ]] && args[i]=$GSA_FAKE_STUB_PACMAN
done
exec /usr/bin/flock "${args[@]}"
EOF

cat >"$fixture/bin/record-pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_STUB_PACMAN_LOG"
exit 0
EOF

chmod +x "$fixture/bin/"*

BARGS=(--allow-broken-rustc --no-deps --no-sync --lanes 1 --jobs 1 p1)
RUN_ENV=()
disp=""
wd=""

mk_env() { # state build_seconds [pgrep_holder]
    local state=$1 secs=$2 holder=${3:-}
    mkdir -p "$state"
    RUN_ENV=(
        "PATH=$fixture/bin:$PATH"
        "GSA_STATE_DIR=$state"
        "GSA_FAKE_DB_PATH=$state/var/pacman"
        "GSA_FAKE_MARKER_DIR=$state/built"
        "GSA_FAKE_PACMAN_ENV_LOG=$state/pacman-env.log"
        "GSA_FAKE_SIGNAL_LOG=$state/signals.log"
        "GSA_FAKE_BUILD_SECONDS=$secs"
    )
    [[ -n $holder ]] && RUN_ENV+=("GSA_FAKE_PGREP_HOLDER=$holder")
}

wait_for_file() { # path [timeout-s]
    local f=$1 t=${2:-10} i
    for ((i = 0; i < t * 10; i++)); do
        [[ -e $f ]] && return 0
        sleep 0.1
    done
    return 1
}

run_bg() { # out-file cmd...   → sets $disp/$wd
    local out=$1; shift
    env "${RUN_ENV[@]}" "$@" >"$out" 2>&1 &
    disp=$!
    ( for ((i = 0; i < 800; i++)); do
          command kill -0 "$disp" 2>/dev/null || exit 0
          sleep 0.1
      done
      command kill -KILL "$disp" 2>/dev/null ) &
    wd=$!
}

end_bg() { # wait for $disp → $rc; reap the watchdog
    wait "$disp" 2>/dev/null
    rc=$?
    command kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
}

find_lane_pid() {
    # Scoped to THIS fixture's synthetic workspace. The battery runs fixtures in
    # parallel, so a global `--lane-job` match would pick a sibling fixture's
    # lane (the 2026-09-24 "never run two batteries at once" hazard, which a
    # parallel runner would otherwise self-inflict on every run). Lane argv
    # always carries the builder's own path: `fish $SCRIPT_DIR/build-all.fish
    # --lane-job …`, and SCRIPT_DIR lives under $fixture here.
    ps -eo pid=,args= | awk -v f="$fixture" \
        '/build-all\.fish --lane-job/ && index($0, f) && !/awk/ {print $1; exit}'
}

# ── 6. static shape of stop_lane_process (do NOT wait out the real 30 s) ────
gf="$root/build-all.fish"
# The default must still be 30 — the value lives behind the env-override seam
# (tests/dashboard.sh shortens it to prove the KILL path fast), so pin both
# halves: the 30 fallback and the seam that may replace it.
grace=$(sed -n 's/^[[:space:]]*set -g _LANE_STOP_GRACE_S \([0-9][0-9]*\)$/\1/p' "$gf" |
    head -1)
[[ $grace == 30 ]] ||
    fail "grace default must be 30 s (got '$grace')"
grep -qF 'if not set -q _LANE_STOP_GRACE_S; or not string match -qr' "$gf" ||
    fail "_LANE_STOP_GRACE_S must stay an env-overridable internal seam"
stop_body=$(sed -n '/^function stop_lane_process/,/^function cleanup_active_lanes/p' "$gf")
[[ -n $stop_body ]] || fail "could not extract stop_lane_process from build-all.fish"
term_lines=$(grep -c 'kill -TERM' <<<"$stop_body")
[[ $term_lines -eq 1 ]] ||
    fail "stop_lane_process must issue exactly ONE TERM sweep (found $term_lines)"
grep -q 'sleep 0.1' <<<"$stop_body" ||
    fail "stop_lane_process must poll at 0.1 s granularity"
grep -q 'SIGKILL after grace' <<<"$stop_body" ||
    fail "escalation after grace must be logged as 'SIGKILL after grace'"
grep -q '\[DEBUG-gsa-term\]' "$gf" ||
    fail "missing [DEBUG-gsa-term] forensics tag"
term_line=$(grep -n 'kill -TERM' <<<"$stop_body" | head -1 | cut -d: -f1)
grace_line=$(grep -n 'grace_deadline' <<<"$stop_body" | head -1 | cut -d: -f1)
kill_line=$(grep -n 'kill -KILL' <<<"$stop_body" | head -1 | cut -d: -f1)
[[ -n $term_line && -n $grace_line && -n $kill_line ]] ||
    fail "could not locate TERM/grace/KILL lines in stop_lane_process"
(( term_line < grace_line && grace_line < kill_line )) ||
    fail "SIGKILL must come strictly after the grace window"

# ── 1. hidden --stale-lock-check against fixture lock paths ────────────────
echo "phase 1: stale-lock probe (idle → removed, holder → kept)"
idle_lock="$fixture/idle.lck"
: >"$idle_lock"
idle_out="$fixture/phase1-idle.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    fish "$fixture/build-all.fish" --stale-lock-check "$idle_lock" >"$idle_out" 2>&1
p1_rc=$?
[[ $p1_rc -eq 0 ]] ||
    fail "idle lock check rc=$p1_rc, want 0" "$(cat "$idle_out")"
[[ ! -e $idle_lock ]] ||
    fail "idle (holder-less) lock was NOT removed"
grep -q 'STALE pacman lock' "$idle_out" ||
    fail "no loud STALE warning for the removed lock:" "$(cat "$idle_out")"
grep -qF "$idle_lock" "$idle_out" ||
    fail "stale warning does not name the lock path"

sleep 60 &
holder=$!
busy_lock="$fixture/busy.lck"
: >"$busy_lock"
busy_out="$fixture/phase1-busy.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    GSA_FAKE_PGREP_HOLDER="$holder" \
    fish "$fixture/build-all.fish" --stale-lock-check "$busy_lock" >"$busy_out" 2>&1
p1b_rc=$?
[[ $p1b_rc -eq 1 ]] ||
    fail "busy lock check rc=$p1b_rc, want 1" "$(cat "$busy_out")"
[[ -e $busy_lock ]] ||
    fail "lock with a live holder was REMOVED"
grep -q "holder pid=$holder" "$busy_out" ||
    fail "holder pid not reported:" "$(cat "$busy_out")"
grep -q 'cmd=.*sleep' "$busy_out" ||
    fail "holder cmdline not reported:" "$(cat "$busy_out")"
grep -q 'Recovery:' "$busy_out" ||
    fail "no recovery instructions for a held lock"
grep -qF "$busy_lock" "$busy_out" ||
    fail "busy report does not name the lock path"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ── 2. direct --lane-job: honest result file + process rc on SIGTERM ───────
echo "phase 2: SIGTERM the lane child directly"
state="$fixture/state-lane"
mk_env "$state" 1.5
res="$state/logs/.lane-direct.result"
run_bg "$state/lane.out" fish "$fixture/build-all.fish" \
    --lane-job p1 "$res" 1 0 0 0 1 0
lane=$disp
wait_for_file "$state/built/p1" 10 ||
    fail "stub makepkg never started (lane did not reach the build)" \
        "$(cat "$state/lane.out")"
command kill -TERM "$lane"
end_bg
[[ $rc -eq 143 ]] ||
    fail "signal-exited lane child rc=$rc, want honest 143" "$(cat "$state/lane.out")"
[[ -s $res ]] ||
    fail "no result file after lane SIGTERM" "$(cat "$state/lane.out")"
grep -Eq '^p1 143 [0-9]+$' "$res" ||
    fail "result file not honest: '$(cat "$res")' (want 'p1 143 <secs>')"
grep -q 'lane child received TERM' "$state/logs/p1.log" ||
    fail "package log missing 'lane child received TERM'" "$(cat "$state/logs/p1.log" 2>/dev/null)"

# ── 3. full run: dispatcher sees an honest 143, never rc=125 ───────────────
echo "phase 3: SIGTERM the live lane child under a dispatcher"
state="$fixture/state-full"
mk_env "$state" 3
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
wait_for_file "$state/built/p1" 15 ||
    fail "lane never started in the full run" "$(cat "$state/run.out")"
lane=$(find_lane_pid)
[[ -n $lane ]] ||
    fail "no --lane-child process found for the SIGTERM"
command kill -TERM "$lane"
end_bg
[[ $rc -ne 0 ]] ||
    fail "run with a signal-killed lane reported success" "$(cat "$state/run.out")"
grep -q 'BUILD FAILED (rc=143' "$state/run.out" ||
    fail "dispatcher did not report the honest 143" "$(cat "$state/run.out")"
if grep -q 'no valid result' "$state/run.out"; then
    fail "dispatcher fell back to 'no valid result'" "$(cat "$state/run.out")"
fi
grep -q 'lane child received TERM' "$state/logs/p1.log" ||
    fail "package log missing 'lane child received TERM' after full run"

shim="$state/logs/.pacman-shim"
[[ -e $shim ]] ||
    fail "run start did not generate $shim"
[[ $(stat -c %a "$shim") == 755 ]] ||
    fail "shim mode is $(stat -c %a "$shim"), want 755"
grep -q 'flock -x -w 300' "$shim" ||
    fail "shim lacks 'flock -x -w 300': $(cat "$shim")"
grep -qF "$state/logs/.pacman-install.lock" "$shim" ||
    fail "shim lacks the absolute mutex path: $(cat "$shim")"
grep -q '/usr/bin/pacman' "$shim" ||
    fail "shim lacks /usr/bin/pacman: $(cat "$shim")"
grep -qF '"$@"' "$shim" ||
    fail "shim does not pass through \"\$@\": $(cat "$shim")"
[[ -f $state/pacman-env.log ]] ||
    fail "stub makepkg never observed its environment"
grep -qxF "$shim" "$state/pacman-env.log" ||
    fail "PACMAN did not point at the shim: $(cat "$state/pacman-env.log")"

# ── 4. dispatcher forensics for INT / TERM / HUP ───────────────────────────
for sig in INT TERM HUP; do
    echo "phase 4: SIG$sig the dispatcher"
    state="$fixture/state-dispatch-$sig"
    mk_env "$state" 4
    run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
    wait_for_file "$state/built/p1" 15 ||
        fail "$sig: lane never started" "$(cat "$state/run.out")"
    command kill -s "$sig" "$disp"
    end_bg
    [[ $rc -eq 130 ]] ||
        fail "$sig: dispatcher run exited rc=$rc, want 130" "$(cat "$state/run.out")"
    grep -q 'Build interrupted' "$state/run.out" ||
        fail "$sig: no 'Build interrupted' message" "$(cat "$state/run.out")"
    dlog="$state/logs/dispatcher.log"
    [[ -f $dlog ]] ||
        fail "$sig: dispatcher.log was never created"
    grep -q "signal: $sig received" "$dlog" ||
        fail "$sig: dispatcher.log does not name the signal:" "$(cat "$dlog")"
    grep -q '\[DEBUG-gsa-term\]' "$dlog" ||
        fail "$sig: dispatcher.log lines lack the [DEBUG-gsa-term] tag"
    grep -q 'Build interrupted' "$dlog" ||
        fail "$sig: permanent 'Build interrupted' event missing from dispatcher.log"
    grep -q 'cleanup begin' "$dlog" ||
        fail "$sig: cleanup_active_lanes left no forensics trail"
    # exactly ONE TERM per lane pgrp (the removed blitz sent 20 in 0.5 s),
    # and the lane exits on it fast — no SIGKILL escalation ever happens.
    [[ -f $state/signals.log ]] ||
        fail "$sig: the lane pgrp received no TERM during teardown"
    term_count=$(grep -c '^TERM$' "$state/signals.log")
    [[ $term_count -eq 1 ]] ||
        fail "$sig: lane pgrp received $term_count TERMs, want exactly 1" \
            "$(cat "$state/signals.log")"
    sleep 0.3
    # Scoped to $fixture for the same reason as find_lane_pid: a sibling
    # fixture's lane running concurrently must not be read as a survivor.
    if ps -eo args= | grep -F 'build-all.fish --lane-job' | grep -F "$fixture" |
        grep -v grep >/dev/null; then
        fail "$sig: a lane process survived the dispatcher:" \
            "$(ps -eo pid=,args= | grep -F 'build-all.fish --lane-job' |
            grep -F "$fixture" | grep -v grep)"
    fi
    if ps -eo args= | grep -F "$fixture/bin/makepkg" | grep -v grep >/dev/null; then
        fail "$sig: a stub makepkg survived the dispatcher"
    fi
done

# ── 5. preflight: busy lock refuses -i, warns but builds build-only ────────
echo "phase 5: busy db.lck preflight"
state="$fixture/state-preflight"
mkdir -p "$state/var/pacman"
lock="$state/var/pacman/db.lck"
: >"$lock"
sleep 60 &
holder=$!
mk_env "$state" 0.5 "$holder"
run_bg "$state/i.out" fish "$fixture/build-all.fish" \
    --allow-broken-rustc --no-deps --no-sync --lanes 1 --jobs 1 --install p1
end_bg
[[ $rc -ne 0 ]] ||
    fail "-i run over a busy lock was not refused" "$(cat "$state/i.out")"
grep -q 'refusing to start an -i run' "$state/i.out" ||
    fail "no refusal message for busy lock:" "$(cat "$state/i.out")"
grep -q "holder pid=$holder" "$state/i.out" ||
    fail "refusal does not report the holder:" "$(cat "$state/i.out")"
grep -q 'Recovery:' "$state/i.out" ||
    fail "refusal lacks recovery instructions:" "$(cat "$state/i.out")"
grep -qF "$lock" "$state/i.out" ||
    fail "refusal does not name the lock path:" "$(cat "$state/i.out")"
[[ -e $lock ]] ||
    fail "busy lock was removed by the refused -i run"
[[ ! -d $state/built ]] ||
    fail "lanes dispatched despite the refused -i run"

mk_env "$state" 0.5 "$holder"
run_bg "$state/build.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "build-only run over a busy lock failed" "$(cat "$state/build.out")"
grep -q 'building anyway' "$state/build.out" ||
    fail "build-only run did not warn about the busy lock" "$(cat "$state/build.out")"
grep -q "holder pid=$holder" "$state/build.out" ||
    fail "build-only warning does not report the holder" "$(cat "$state/build.out")"
[[ -e $lock ]] ||
    fail "build-only preflight removed a held lock"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ── 7. direct shim invocation: "$@" reaches pacman untouched ───────────────
echo "phase 7: invoke the shim directly"
stub_log="$fixture/stub-pacman.log"
: >"$stub_log"
env PATH="$fixture/bin:$PATH" \
    GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
    GSA_FAKE_STUB_PACMAN_LOG="$stub_log" \
    "$shim" --frobnicate 'arg with space' 'wild*card' ||
    fail "shim invocation failed"
[[ $(cat "$stub_log") == '--frobnicate arg with space wild*card' ]] ||
    fail "shim did not pass \$@ through verbatim: '$(cat "$stub_log")'"

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "a fixture process survived:" \
        "$(ps -eo args= | grep -F "$fixture" | grep -v grep)"
fi

printf 'signal-abort-lock fixture: PASS\n'
