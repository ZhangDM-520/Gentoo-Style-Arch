#!/usr/bin/env bash
set -euo pipefail

# The dashboard is 200 lines of terminal control that the rest of the battery
# never executes: _OUTPUT_INTERACTIVE is gated on `test -t 1`, and every other
# fixture pipes the builder's output. This fixture drives the real thing under
# a pty (script(1)) with a controlled width, so these invariants are tested
# rather than assumed:
#
#   1. the interactive path actually renders (render_dashboard runs at all);
#   2. no rendered row exceeds width-1 VISIBLE columns — the contract
#      fit_dashboard_line exists for, measured with the same
#      `string length --visible` production uses, so ANSI escapes and
#      multibyte icons are counted the way the builder counts them;
#   3. the width comes from the terminal, not the 80-column fallback;
#   4. hide-cursor and show-cursor are balanced, so a run never leaves the
#      user's terminal without a cursor;
#   5. an interrupt aborts the dashboard, restores the cursor, returns 130
#      *promptly*, and leaves no lane child behind — tested with a lane child
#      that ignores TERM, so the SIGKILL escalation is exercised rather than
#      the polite TERM.
#
# Case C is the only timing-sensitive assertion in the battery: it fails if the
# builder does not return within ~6s of the interrupt. That is deliberate — a
# builder that waits for its lanes instead of killing them is the defect.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dashboard.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

command -v script >/dev/null || {
    printf 'script(1) is required to drive a pty\n' >&2
    exit 1
}

# A long tail line, so a wide terminal has something to truncate: at 100
# columns the row must still fit 99, which is what distinguishes a real width
# from the 80-column fallback.
make_workspace() { # $1 = dir, $2 = columns
    local dir=$1 cols=$2
    mkdir -p "$dir/config/groups" "$dir/bin"
    cp "$root/build-all.fish" "$dir/build-all.fish"

    cat >"$dir/config/build-defaults.conf" <<'EOF'
lanes=2
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
    : >"$dir/config/packages.map"
    for id in p1 p2 p3; do
        mkdir -p "$dir/packages/$id"
        printf 'pkgname=%s\npkgver=1.0.0\npkgrel=1\narch=(any)\n' "$id" \
            >"$dir/packages/$id/PKGBUILD"
        printf '%s|packages/%s\n' "$id" "$id" >>"$dir/config/packages.map"
        printf '%s\n' "$id" >>"$dir/config/groups/git.list"
    done

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Case C records every lane child so its survival can be decided by PID
# rather than by matching `ps` argv — the builder execs makepkg by its bare
# name, so a path grep only ever matches the grep itself.
if test -n "${GSA_LANE_MARKER:-}"; then
    printf 'START %s\n' "$$" >>"$GSA_LANE_MARKER"
fi
# A lane supervisor is fish and dies on TERM; this child does not, which is
# the case stop_lane_process' SIGKILL escalation exists for.
trap '' TERM
trap 'exit 130' INT
for i in $(seq 1 "${GSA_FAKE_TICKS:-8}"); do
    printf 'compiling %s line %s of a deliberately overlong tail line that must be truncated to the terminal width\n' "$id" "$i"
    sleep 0.05
done
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    # script(1) runs -c through the user's login shell, which is fish here and
    # rejects `VAR=value cmd`, so the command goes through a wrapper script.
    cat >"$dir/run.sh" <<EOF
#!/usr/bin/env bash
stty cols $cols rows 24
export PATH="$dir/bin:\$PATH"
export GSA_STATE_DIR="$dir/state"
export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
export GSA_FAKE_TICKS=8
exec fish "$dir/build-all.fish" --allow-broken-rustc --no-deps --no-sync --lanes 2 p1 p2 p3
EOF
    chmod +x "$dir/run.sh"
}

# Runs the builder in a pty; captures the raw stream to $dir/out.raw and its
# exit status in RAW_RC.
run_pty() { # $1 = dir
    local dir=$1
    set +e
    TERM=xterm script -qec "$dir/run.sh" /dev/null >"$dir/out.raw" 2>&1
    RAW_RC=$?
    set -e
}

# Rows rendered through the dashboard are exactly those the builder prefixes
# with CR ESC[2K (render_dashboard emits that per row), so marking the prefix
# isolates dashboard output from ordinary banner lines that have no width
# contract.
extract_rows() { # $1 = raw file, $2 = output rows file
    local esc=$'\033'
    sed -e "s/\r${esc}\[2K/\n@@DASH@@/g" "$1" | sed -n 's/^@@DASH@@//p' >"$2"
}

# Longest VISIBLE row width, measured the way the builder measures it.
max_visible_width() { # $1 = rows file
    fish -c '
        set -l worst 0
        while read -l line
            set -l n (string length --visible -- "$line")
            if test "$n" -gt "$worst"
                set worst $n
            end
        end <"$argv[1]"
        echo $worst
    ' "$1"
}

# ─── Case A: a narrow terminal truncates every row to width-1 ───────────────
dir="$fixture/cols40"
make_workspace "$dir" 40
run_pty "$dir"

if ((RAW_RC != 0)); then
    printf 'cols=40: builder failed (rc=%s):\n' "$RAW_RC" >&2
    sed -n '1,40p' "$dir/out.raw" >&2
    exit 1
fi
if ! grep -q 'Progress:' "$dir/out.raw"; then
    printf 'cols=40: the dashboard never rendered:\n' >&2
    sed -n '1,40p' "$dir/out.raw" >&2
    exit 1
fi

extract_rows "$dir/out.raw" "$dir/rows.txt"
if [[ ! -s "$dir/rows.txt" ]]; then
    printf 'cols=40: no dashboard rows carried the CR ESC[2K prefix\n' >&2
    exit 1
fi
width40=$(max_visible_width "$dir/rows.txt")
if ((width40 > 39)); then
    printf 'cols=40: a rendered row is %s visible columns (limit 39):\n' "$width40" >&2
    awk 'length($0) > 39' "$dir/rows.txt" | head -5 >&2
    exit 1
fi

# ─── Case B: a wide terminal is used, not the 80-column fallback ────────────
dir="$fixture/cols100"
make_workspace "$dir" 100
run_pty "$dir"
if ((RAW_RC != 0)); then
    printf 'cols=100: builder failed (rc=%s)\n' "$RAW_RC" >&2
    exit 1
fi
extract_rows "$dir/out.raw" "$dir/rows.txt"
width100=$(max_visible_width "$dir/rows.txt")
if ((width100 > 99)); then
    printf 'cols=100: a rendered row is %s visible columns (limit 99)\n' "$width100" >&2
    exit 1
fi
# The 80-column fallback would cap rows at 79; the fake tail line is far longer
# than that, so anything above 79 proves the terminal width was read.
if ((width100 <= 79)); then
    printf 'cols=100: widest row is only %s columns — the dashboard used the\n' "$width100" >&2
    printf '80-column fallback instead of the terminal width\n' >&2
    exit 1
fi

# ─── Cursor balance: a run must never leave the terminal cursor hidden ──────
for label in cols40 cols100; do
    raw="$fixture/$label/out.raw"
    esc=$'\033'
    hidden=$(grep -o "${esc}\[?25l" "$raw" | wc -l)
    shown=$(grep -o "${esc}\[?25h" "$raw" | wc -l)
    if ((hidden != shown)); then
        printf '%s: cursor left in an inconsistent state (hide=%s show=%s)\n' \
            "$label" "$hidden" "$shown" >&2
        exit 1
    fi
    if ((hidden == 0)); then
        printf '%s: the dashboard never hid the cursor, so it never ran\n' "$label" >&2
        exit 1
    fi
done

# ─── Case C: an interrupt aborts the dashboard and reaps the lane children ──
#
# The property under test is promptness, not merely "nothing survived". A
# lane outliving the interrupt would keep compiling for hours on a machine the
# user believes is idle, so the run must return within seconds — and it must
# return 130 even when a lane child ignores TERM, because stop_lane_process
# escalates to SIGKILL. Both halves are load-bearing and both were falsified
# before this assertion was trusted:
#   - making lane_processes match nothing (so no lane pid is ever signalled)
#     leaves the builder blocked in stop_lane_process' `wait` until the lanes
#     finish on their own: the run then overruns the deadline below;
#   - removing the SIGKILL escalation leaves the TERM-ignoring children alive
#     and the survivor check below fails.
# A bare "no lane survived" check passes under both injections, because the
# trailing `wait $lane_pid` reaps the lane whenever the killer does nothing.
dir="$fixture/interrupt"
make_workspace "$dir" 40
cat >"$dir/run.sh" <<EOF
#!/usr/bin/env bash
stty cols 40 rows 24
export PATH="$dir/bin:\$PATH"
export GSA_STATE_DIR="$dir/state"
export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
export GSA_FAKE_TICKS=300
export GSA_LANE_MARKER="$dir/pids"
fish "$dir/build-all.fish" --allow-broken-rustc --no-deps --no-sync --lanes 2 p1 p2 p3 &
builder=\$!
sleep 1.4
kill -INT "\$builder" 2>/dev/null
# A zombie still answers kill -0, so "exited" is decided the way the builder
# decides it: no such pid, or a Z state.
attempts=0
while :; do
    state=\$(ps -o stat= -p "\$builder" 2>/dev/null | tr -d ' ')
    if test -z "\$state" || test "\${state#*Z}" != "\$state"; then break; fi
    attempts=\$((attempts + 1))
    if test "\$attempts" -ge 60; then
        printf 'interrupt: the builder was still running 6s after SIGINT —\\n' >&2
        printf 'the lanes were not signalled, so it waited for them\\n' >&2
        kill -KILL "\$builder" 2>/dev/null
        break
    fi
    sleep 0.1
done
wait "\$builder" 2>/dev/null
exit \$?
EOF
chmod +x "$dir/run.sh"
run_pty "$dir"

if ((RAW_RC != 130)); then
    printf 'interrupt: expected exit 130, got %s\n' "$RAW_RC" >&2
    tail -20 "$dir/out.raw" >&2
    exit 1
fi
esc=$'\033'
if ! grep -q "${esc}\[?25h" "$dir/out.raw"; then
    printf 'interrupt: the cursor was never restored (abort_dashboard did not run)\n' >&2
    exit 1
fi
if ! grep -q 'interrupted' "$dir/out.raw"; then
    printf 'interrupt: no interruption notice was printed\n' >&2
    tail -20 "$dir/out.raw" >&2
    exit 1
fi
# Baseline first: if no lane child ever ran, "none survived" would be vacuous.
if [[ ! -s "$dir/pids" ]]; then
    printf 'interrupt: no lane child recorded itself, so nothing was proven\n' >&2
    tail -20 "$dir/out.raw" >&2
    exit 1
fi
recorded=$(wc -l <"$dir/pids")
survivors=()
while read -r tag pid; do
    [[ $tag == START ]] || continue
    # `ps` exits 1 for a pid that is already gone — the outcome this case
    # wants — so the failure is absorbed rather than aborting on pipefail.
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || state=
    if [[ -n $state && ${state#*Z} == "$state" ]]; then
        survivors+=("$pid")
    fi
done <"$dir/pids"
if ((${#survivors[@]} > 0)); then
    printf 'interrupt: %s of %s lane children survived the interrupt: %s\n' \
        "${#survivors[@]}" "$recorded" "${survivors[*]}" >&2
    ps -o pid=,ppid=,pgid=,args= -p "${survivors[@]}" >&2 2>&1 || true
    exit 1
fi

rm -f "$dir/rows.txt"
printf 'dashboard fixture: PASS\n'
