#!/usr/bin/env bash
set -euo pipefail

# Sudo liveness for unprivileged -i runs. Lane installs run `sudo -n` (lane
# children have no tty), so the dispatcher must decide, without ever hanging:
# is sudo still usable, and what happens when it is not? This fixture pins
# that decision — each mode is a real sudoers shape:
#
#   1. nopasswd  — `sudo -v` can never refresh a credential this host does not
#                  use, yet every install is password-free (dual rule
#                  "(ALL) ALL" + "(ALL : ALL) NOPASSWD: ALL"). Stopping the
#                  run here is wrong.
#   2. cold      — nothing works without a password and no human is attached:
#                  refuse BEFORE building, not 150 s in.
#   3. expires   — the credential dies mid-run: say so ONCE (the per-poll
#                  re-print spammed the terminal), keep draining, and do not
#                  report success while packages are left unbuilt.
#   4. promptable— nothing works non-interactively, but the dispatcher owns a
#                  terminal, so it must re-elevate itself (pty sub-case).
#
# The builder's keepalive interval is 150 s of real time; the fake `date` in
# the fixture bin advances a virtual clock 300 s per call, so that interval
# elapses in a run that lasts seconds and no test knob is added to the builder.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-sudo-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/config/groups" "$fixture/packages" "$fixture/bin"
cp "$root/build-all.fish" "$fixture/build-all.fish"

cat >"$fixture/config/build-defaults.conf" <<'EOF'
lanes=auto
jobs=auto
intensity=xhigh
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
: >"$fixture/config/dependencies.conf"
for group in git stable core misc third-party; do
    : >"$fixture/config/groups/$group.list"
done

ids=(p1 p2 p3 p4)
for id in "${ids[@]}"; do
    mkdir -p "$fixture/packages/$id"
    printf 'pkgname=%s\n' "$id" >"$fixture/packages/$id/PKGBUILD"
    printf '%s|packages/%s\n' "$id" "$id" >>"$fixture/config/packages.map"
    printf '%s\n' "$id" >>"$fixture/config/groups/git.list"
done

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$PWD")
mkdir -p "$GSA_FAKE_MARKER_DIR"
touch "$GSA_FAKE_MARKER_DIR/$name"
touch "$PWD/$name-1.0-1-x86_64.pkg.tar.zst"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.1}"
EOF

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fixture/bin/date" <<'EOF'
#!/usr/bin/env bash
# Virtual clock: 300 s per call, so the builder's 150 s sudo keepalive
# interval elapses inside a fixture that runs for seconds.
set -uo pipefail
if [[ ${1:-} == '+%s' ]]; then
    : "${GSA_FAKE_DATE_COUNTER:?fixture forgot to set GSA_FAKE_DATE_COUNTER}"
    ticks=0
    [[ -s $GSA_FAKE_DATE_COUNTER ]] && read -r ticks <"$GSA_FAKE_DATE_COUNTER"
    ticks=$((ticks + 1))
    printf '%s\n' "$ticks" >"$GSA_FAKE_DATE_COUNTER"
    printf '%s\n' "$((1700000000 + ticks * 300))"
    exit 0
fi
exec /usr/bin/date "$@"
EOF

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_SUDO_LOG"
interactive=1
for arg in "$@"; do
    [[ $arg == -n ]] && interactive=0
done
case "$GSA_FAKE_SUDO_MODE" in
    nopasswd)
        [[ " $* " == *' pacman '* ]] && exit 0
        exit 1
        ;;
    expires)
        # The credential survives one refresh, then dies for good (the machine
        # was suspended, the timestamp timed out, ...).
        if [[ " $* " == *' -v '* ]]; then
            validations=0
            [[ -s $GSA_FAKE_SUDO_STATE/validations ]] &&
                read -r validations <"$GSA_FAKE_SUDO_STATE/validations"
            validations=$((validations + 1))
            printf '%s\n' "$validations" >"$GSA_FAKE_SUDO_STATE/validations"
            ((validations <= 2)) && exit 0
        fi
        exit 1
        ;;
    promptable)
        # Nothing works non-interactively until a human validates the
        # credential — after which `sudo -n` behaves like any warmed-up host.
        [[ -e $GSA_FAKE_SUDO_STATE/elevated ]] && exit 0
        if ((interactive)) && [[ " $* " == *' -v '* ]]; then
            touch "$GSA_FAKE_SUDO_STATE/elevated"
            exit 0
        fi
        exit 1
        ;;
    cold)
        exit 1
        ;;
esac
exit 1
EOF

chmod +x "$fixture/bin/makepkg" "$fixture/bin/pacman" "$fixture/bin/date" "$fixture/bin/sudo"

run_rc=0
run_output=""

run_builder() {
    local state=$1 mode=$2 build_s=${3:-1.2}
    mkdir -p "$fixture/state-$state"
    run_rc=0
    run_output=$(
        PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$fixture/state-$state" \
        GSA_FAKE_SUDO_MODE="$mode" \
        GSA_FAKE_SUDO_LOG="$fixture/state-$state/sudo.log" \
        GSA_FAKE_SUDO_STATE="$fixture/state-$state" \
        GSA_FAKE_DATE_COUNTER="$fixture/state-$state/clock" \
        GSA_FAKE_MARKER_DIR="$fixture/state-$state/built" \
        GSA_FAKE_BUILD_SECONDS="$build_s" \
        fish "$fixture/build-all.fish" \
            --allow-broken-rustc --no-deps --no-sync \
            --lanes 2 --jobs 2 --install "${ids[@]}" 2>&1
    ) || run_rc=$?
}

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

count_occurrences() {
    printf '%s\n' "$1" | grep -c -F -- "$2" || true
}

built_count() {
    find "$fixture/state-$1/built" -maxdepth 1 -type f 2>/dev/null | wc -l
}

STOPPED='cannot be refreshed'
REFUSED='cannot install non-interactively'

# 1. Password-free installs must not stop the run: `sudo -v` refuses, every
#    install works.
run_builder nopasswd nopasswd
if [[ $run_rc -ne 0 ]]; then
    fail "nopasswd run failed (rc=$run_rc) — password-free installs must not stop dispatch" \
        "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$STOPPED") -ne 0 ]]; then
    fail "nopasswd run stopped dispatch although installs need no password" "$run_output"
fi
if [[ $(built_count nopasswd) -ne 4 ]]; then
    fail "nopasswd run built $(built_count nopasswd)/4 packages" "$run_output"
fi
if grep -q -E -- '^-v$' "$fixture/state-nopasswd/sudo.log"; then
    fail "nopasswd run validated a credential it never uses: $(cat "$fixture/state-nopasswd/sudo.log")"
fi

# 2. No usable sudo and no terminal: refuse before spending build time.
run_builder cold cold
if [[ $run_rc -eq 0 ]]; then
    fail "cold run reported success without usable sudo" "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$REFUSED") -ne 1 ]]; then
    fail "cold run did not refuse exactly once:" "$run_output"
fi
if [[ $(built_count cold) -ne 0 ]]; then
    fail "cold run built $(built_count cold) package(s) before noticing sudo was unusable"
fi

# 3. Credential dies mid-run: one message, non-zero exit, packages reported
#    as remaining instead of a silent "All builds succeeded!".
# A long first wave keeps lanes busy while the dispatcher notices: the
# pre-per-poll re-print was only visible because package builds outlive it.
run_builder expires expires 3
if [[ $run_rc -eq 0 ]]; then
    fail "expired-credential run reported success with unbuilt packages" "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$STOPPED") -ne 1 ]]; then
    fail "expired-credential run printed the stop message $(count_occurrences "$run_output" "$STOPPED")x (want 1)" \
        "$run_output"
fi
if ! printf '%s\n' "$run_output" | grep -F -- 'Remaining:' >/dev/null; then
    fail "expired-credential run did not report remaining packages" "$run_output"
fi
if grep -q -E -- '^-v$' "$fixture/state-expires/sudo.log"; then
    fail "expired-credential run prompted a password with no terminal attached:" \
        "$(cat "$fixture/state-expires/sudo.log")"
fi
if find "$fixture/state-expires/logs" -maxdepth 1 -name '.lane*.result*' -print -quit | grep -q .; then
    fail "lane result artifact remained after the sudo stop"
fi

# 4. Same shape as 3, but attached to a terminal: the dispatcher must ask for
#    the password itself and carry on.
if command -v script >/dev/null 2>&1; then
    mkdir -p "$fixture/state-prompt"
    pty_rc=0
    pty_output=$(
        script -qec "PATH=\"$fixture/bin:\$PATH\" GSA_STATE_DIR='$fixture/state-prompt' \
GSA_FAKE_SUDO_MODE=promptable GSA_FAKE_SUDO_LOG='$fixture/state-prompt/sudo.log' \
GSA_FAKE_SUDO_STATE='$fixture/state-prompt' GSA_FAKE_DATE_COUNTER='$fixture/state-prompt/clock' \
GSA_FAKE_MARKER_DIR='$fixture/state-prompt/built' GSA_FAKE_BUILD_SECONDS=1.2 \
fish '$fixture/build-all.fish' --allow-broken-rustc --no-deps --no-sync \
--lanes 2 --jobs 2 --install ${ids[*]}" /dev/null 2>&1
    ) || pty_rc=$?
    if [[ $pty_rc -ne 0 ]]; then
        fail "interactive run failed (rc=$pty_rc) instead of re-elevating itself" "$pty_output"
    fi
    if [[ $(count_occurrences "$pty_output" "$STOPPED") -ne 0 ]]; then
        fail "interactive run stopped dispatch instead of asking for a password" "$pty_output"
    fi
    prompts=$(grep -c -E -- '^-v$' "$fixture/state-prompt/sudo.log" || true)
    if [[ $prompts -ne 1 ]]; then
        fail "interactive run prompted $prompts time(s) (want 1):" \
            "$(cat "$fixture/state-prompt/sudo.log")"
    fi
    if [[ $(built_count prompt) -ne 4 ]]; then
        fail "interactive run built $(built_count prompt)/4 packages" "$pty_output"
    fi
fi

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "lane child remained after the fixture runs"
fi

printf 'sudo keepalive fixture: PASS\n'
