#!/usr/bin/env bash
set -euo pipefail

# The failure summary prints a copy-pasteable resume command. It used to carry
# only --lanes/--jobs/--intensity, so a resume of a run made with -i rebuilt the
# remaining packages WITHOUT installing them — while the tip printed directly
# below it said "add -s so already-built pkgs are skipped", and the code's own
# comment says to resume with "-s -i". Later packages then compile against the
# old installed ABIs, which is the rule-11 hazard -i exists to prevent.
#
# This fixture fails a middle package so a remainder exists, and requires the
# resume command to preserve the flags that change what the resume means.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-resume-cmd.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

# Three independent packages: p2 fails, so p3 is never dispatched and the
# summary has something to resume. Stubs come from the helper: trivial makepkg
# (fail on GSA_FAKE_FAIL_PACKAGE + touch archive), sudo passthrough, pacman log.
make_case_workspace() { # $1 = sandbox dir
    local dir=$1 id
    make_workspace "$dir" 1 2 low
    for id in p1 p2 p3; do
        add_package "$dir" "$id" $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    done
    stub_makepkg "$dir"
    stub_sudo "$dir"
    stub_pacman "$dir"
}

# run_expecting_failure <dir> <label> [builder flags...] -> RESUME_OUTPUT
run_expecting_failure() {
    local dir=$1 label=$2
    shift 2
    set +e
    RESUME_OUTPUT=$(
        PATH="$dir/bin:$PATH" \
            GSA_STATE_DIR="$dir/state" \
            GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
            GSA_FAKE_FAIL_PACKAGE=p2 \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir/build-all.fish" "$@" p1 p2 p3 2>&1
    )
    local rc=$?
    set -e
    if ((rc == 0)); then
        printf '%s: the failing run unexpectedly succeeded:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if ! grep -q '^  build-all.fish ' <<<"$RESUME_OUTPUT"; then
        printf '%s: no resume command in the failure summary:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_CMD=$(grep '^  build-all.fish ' <<<"$RESUME_OUTPUT" | head -1)
}

# ─── A -i run must resume with --install, or it silently stops installing ────
dir="$fixture/with-install"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'with -i' --install --no-deps --allow-broken-rustc --no-sync
for flag in --install --no-deps --allow-broken-rustc --no-sync; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -i: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -i: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A -fi run must resume with --forceinstall, keeping the force semantics ──
# -fi implies -i, so the resume must carry --forceinstall INSTEAD of --install
# (one flag preserving both halves) plus every other semantics-changing flag.
dir="$fixture/with-forceinstall"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'with -fi' --forceinstall --no-deps --allow-broken-rustc --no-sync
for flag in --forceinstall --no-deps --allow-broken-rustc --no-sync; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -fi: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" == *"--install"* ]]; then
    printf 'with -fi: resume carries both --install and --forceinstall:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -fi: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A run without -i must NOT acquire --install on resume ──────────────────
dir="$fixture/without-install"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'without -i' --no-deps --allow-broken-rustc
if [[ "$RESUME_CMD" == *"--install"* ]]; then
    printf 'without -i: resume command invented --install:\n  %s\n' "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'without -i: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── The FAILED package itself must be in the resume set (2026-09-26 bug) ───
# The summary used to compute the resume set as selection minus
# succeeded+failed, which DROPPED the failed package: a user copying the
# suggested command rebuilt only the not-yet-attempted packages and silently
# left the failed one stale, so its dependents then built against the stale
# installed copy. Both the resume command and the "Remaining" count must
# include the failed package, with a note saying it has to rebuild first.
dir="$fixture/failed-included"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'failed included' --no-deps --allow-broken-rustc --no-sync
if ! grep -qw 'p2' <<<"$RESUME_CMD"; then
    printf 'failed included: resume command drops the FAILED package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if ! grep -qw 'p3' <<<"$RESUME_CMD"; then
    printf 'failed included: resume command drops the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
pre_p2=${RESUME_CMD%%p2*}
pre_p3=${RESUME_CMD%%p3*}
if ((${#pre_p2} > ${#pre_p3})); then
    printf 'failed included: resume command lists the failed package after the unbuilt one:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
remaining_line=$(printf '%s\n' "$RESUME_OUTPUT" | grep '^Remaining:' | tail -1)
remaining_count=$(printf '%s\n' "$remaining_line" | tr -dc '0-9')
if [[ "$remaining_count" != 2 ]]; then
    printf 'failed included: Remaining must count p2 (failed) + p3 (unbuilt) = 2, got: %s\n%s\n' \
        "${remaining_count:-<none>}" "$RESUME_OUTPUT" >&2
    exit 1
fi
if ! printf '%s\n' "$RESUME_OUTPUT" | grep -q 'failed package(s) included'; then
    printf 'failed included: no note saying the failed package must rebuild:\n%s\n' \
        "$RESUME_OUTPUT" >&2
    exit 1
fi

printf 'resume command fixture: PASS\n'
