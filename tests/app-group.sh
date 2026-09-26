#!/usr/bin/env bash
set -euo pipefail

# app group + TTY multi-select prompt fixture.
#
# Pins (decisions recorded in docs/NOTE.md 2026-09-23):
#   1. loader demands config/topology.conf (a missing file = error; group
#      membership rides in each record's groups field, and the roster is the
#      builder's six names — git, stable, core, misc, third-party, app)
#   2. an app group with NO member refuses with a targeted hint (no phantom member)
#   3. non-TTY -n -g app builds the whole group and says the prompt was
#      skipped; the group is a LEAF selection — a local dependency edge to a
#      non-app workspace package must NOT pull that package into the run
#   4. -l never prompts (a prompt on a PTY with no input would abort/hang,
#      so exit 0 with the whole group proves silence)
#   5. on a PTY: Enter = whole group, numbers = only the checked subset,
#      q = non-zero abort
#   6. -g app combined with -g git: the filter touches only the app portion
#   7. a REAL build prompts too and builds only the checked subset

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-app-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ── Synthetic workspace: five fake packages, one topology record each ───────
make_workspace "$fixture" auto auto xhigh

# pkgver=1 (not the helper's $gsa_meta_any default) keeps these PKGBUILDs
# byte-identical to the hand-written skeleton this replaced.
for pair in "git:gitp1" "misc:extdep" "app:app1 app2 app3"; do
    grp=${pair%%:*}
    members=${pair#*:}
    for id in $members; do
        add_package "$fixture" "$id" $'pkgver=1\npkgrel=1\narch=(any)' "$grp"
    done
done

# app2 depends on extdep (a NON-app workspace package: must never be pulled
# in) and app3 depends on app2 (in-group edge: fixes dependency order).
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
printf 'fake makepkg %s\n' "$PWD"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
EOF
chmod +x "$fixture/bin/makepkg"

# Read-only helpers. Each captures combined output into $out/$err files and
# returns the builder's status (caller asserts with ||-style checks under -e).
run_quiet() { # <outfile> [args...] — stdin /dev/null (never a TTY)
    local out="$1"
    shift
    fish "$fixture/build-all.fish" "$@" </dev/null >"$out" 2>&1
}

run_pty() { # <input printf fmt> <outfile> <state-dir> [args...] — PTY stdin
    local input="$1" out="$2" state="$3"
    shift 3
    set +e
    # TERM=dumb on purpose: fish's terminal capability queries (DA1) have no
    # responder under script(1)'s PTY, and fish then consumes the piped toggle
    # input as bogus query replies (observed: "2" swallowed mid-exchange, the
    # next read hanging until the timeout). A dumb terminal skips the queries
    # entirely — the FD-level `test -t 0` the seam keys on stays true, and
    # nothing in this fixture asserts colours or the dashboard.
    printf '%b' "$input" | \
        timeout 60 env TERM=dumb \
            script -qec "PATH=\"$fixture/bin:\$PATH\" GSA_STATE_DIR='$state' \
                fish '$fixture/build-all.fish' $*" /dev/null >"$out" 2>&1
    RC=$?
    set -e
    return "$RC"
}

# Extract just the numbered package sequence from a dry-run preview.
# PTY runs carry \r (the slave's ONLCR maps every \n) — strip it, or each
# field compares as "app1\r" against the expected literal.
order_seq() {
    sed -n '/Build order (dry run):/,/^Total:/p' "$1" \
        | grep -E '^ +[0-9]+\. ' | awk '{print $2}' | tr -d '\r'
}

# Same numbered rows as a `-l` listing prints (the listing has no run record:
# listing/dry-run runs never start a build, so the rows ARE the data channel).
listed_seq() {
    sed -n '/Selected packages in dependency order/,$p' "$1" \
        | grep -E '^ +[0-9]+\. ' | awk '{print $2}' | tr -d '\r'
}

# ── 1. Loader: a missing topology file is an error ──────────────────────────
mv "$fixture/config/topology.conf" "$fixture/topology.conf.bak"
if run_quiet "$fixture/o1" --list; then
    fail "loader accepted a workspace without config/topology.conf" "$fixture/o1"
fi
grep -q 'topology not found:' "$fixture/o1" \
    || fail "loader error does not name the missing config/topology.conf" "$fixture/o1"
mv "$fixture/topology.conf.bak" "$fixture/config/topology.conf"

# ── 2. Empty app membership: refuse with a hint, never a phantom member ─────
# App members keep their category-group membership in the real tree, so mirror
# that here: app1..app3 records move to the git group while no record carries
# app in its groups field.
set_topology_record "$fixture" app1 git ''
set_topology_record "$fixture" app2 git 'extdep'
set_topology_record "$fixture" app3 git 'app2'
if run_quiet "$fixture/o2" -n -g app; then
    fail "-n -g app succeeded with no app-group member" "$fixture/o2"
fi
grep -q 'the app list is empty' "$fixture/o2" \
    || fail "empty app membership lacks the populate hint" "$fixture/o2"
grep -q 'selection resolved to no packages' "$fixture/o2" \
    || fail "empty app membership lacks the no-selection error" "$fixture/o2"
set_topology_record "$fixture" app1 app ''
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

# ── 3. Non-TTY: whole group, prompt skipped, NO dependency expansion ────────
run_quiet "$fixture/o3" -n -g app \
    || fail "non-TTY -n -g app failed" "$fixture/o3"
grep -q 'prompt skipped' "$fixture/o3" \
    || fail "non-TTY -g app did not report the skipped prompt" "$fixture/o3"
grep -q 'choose what to build' "$fixture/o3" \
    && fail "prompt rendered without a TTY" "$fixture/o3"
seq3=$(order_seq "$fixture/o3")
expected3=$(printf 'app1\napp2\napp3')
[ "$seq3" = "$expected3" ] \
    || fail "non-TTY order wrong: got [$(echo "$seq3" | tr '\n' ' ')], want [app1 app2 app3]" "$fixture/o3"
grep -q 'extdep' <(order_seq "$fixture/o3") \
    && fail "app group pulled its non-app dependency extdep into the run" "$fixture/o3"
# The count is DATA (the listed rows); the "Total: N packages" sentence is
# rendering, pinned once in tests/dashboard.sh's prose section.
[ "$(order_seq "$fixture/o3" | grep -c .)" = 3 ] \
    || fail "non-TTY -n -g app did not preview exactly 3 packages" "$fixture/o3"

# ── 4. -l: whole group, no prompt (non-TTY and on a PTY) ────────────────────
run_quiet "$fixture/o4" -l -g app \
    || fail "-l -g app failed" "$fixture/o4"
# The listed rows carry the membership (the header count is rendering).
[ "$(listed_seq "$fixture/o4")" = "$expected3" ] \
    || fail "-l -g app did not list all three members: got [$(listed_seq "$fixture/o4" | tr '\n' ' ')]" "$fixture/o4"
grep -q 'choose what to build' "$fixture/o4" \
    && fail "-l prompted on a pipe" "$fixture/o4"
# On a PTY with no input available: a prompting -l would block (timeout) or
# abort on EOF — exit 0 with the full list proves it never reads.
if ! run_pty '' "$fixture/o4p" "$fixture/state-l" -l -g app; then
    fail "-l -g app on a PTY exited non-zero (it must never prompt)" "$fixture/o4p"
fi
[ "$(listed_seq "$fixture/o4p")" = "$expected3" ] \
    || fail "-l -g app on a PTY did not list all three members: got [$(listed_seq "$fixture/o4p" | tr '\n' ' ')]" "$fixture/o4p"

# ── 5. PTY + Enter: menu renders, whole group builds ────────────────────────
run_pty '\n' "$fixture/o5" "$fixture/state-5" -n -g app \
    || fail "PTY -n -g app with plain Enter failed" "$fixture/o5"
grep -q 'choose what to build' "$fixture/o5" \
    || fail "prompt menu did not render on a PTY" "$fixture/o5"
grep -qF '[ ]' "$fixture/o5" \
    || fail "prompt menu rendered without unchecked entries" "$fixture/o5"
seq5=$(order_seq "$fixture/o5")
[ "$seq5" = "$expected3" ] \
    || fail "Enter should build the whole group, got [$(echo "$seq5" | tr '\n' ' ')]" "$fixture/o5"

# ── 6. PTY + toggle: only the checked subset ────────────────────────────────
run_pty '2\n\n' "$fixture/o6" "$fixture/state-6" -n -g app \
    || fail "PTY -n -g app with toggle input failed" "$fixture/o6"
grep -qF '[x]' "$fixture/o6" \
    || fail "toggled menu entry did not render as checked" "$fixture/o6"
seq6=$(order_seq "$fixture/o6")
[ "$seq6" = "app2" ] \
    || fail "checked-only preview wrong: got [$(echo "$seq6" | tr '\n' ' ')], want [app2]" "$fixture/o6"

# ── 7. PTY + q: abort with non-zero ─────────────────────────────────────────
if run_pty 'q\n' "$fixture/o7" "$fixture/state-7" -n -g app; then
    fail "-n -g app accepted 'q' (abort must exit non-zero)" "$fixture/o7"
fi
grep -q 'app selection aborted' "$fixture/o7" \
    || fail "abort path did not report the abort" "$fixture/o7"

# ── 8. Combined -g app -g git: only the app portion is filtered ─────────────
run_pty '1\n\n' "$fixture/o8" "$fixture/state-8" -n -g app -g git \
    || fail "PTY -n -g app -g git failed" "$fixture/o8"
seq8=$(order_seq "$fixture/o8")
expected8=$(printf 'app1\ngitp1')
[ "$seq8" = "$expected8" ] \
    || fail "combined selection wrong: got [$(echo "$seq8" | tr '\n' ' ')], want [app1 gitp1]" "$fixture/o8"

# ── 9. Real build prompts too, and builds only the checked subset ───────────
run_pty '2\n\n' "$fixture/o9" "$fixture/state-9" \
    -g app --allow-broken-rustc --no-sync \
    || fail "PTY build -g app with toggle input failed" "$fixture/o9"
grep -q 'choose what to build' "$fixture/o9" \
    || fail "real build did not prompt" "$fixture/o9"
# The real build emits a run record (PTY capture — the parsers strip the
# slave's \r): the prompt's answer decided the SELECTION, and the record says
# what that selection was and what happened to it.
[ "$(rr_scalar order <"$fixture/o9")" = "app2" ] \
    || fail "recorded selection is not exactly app2: $(rr_scalar order <"$fixture/o9")" "$fixture/o9"
[ "$(rr_scalar outcome <"$fixture/o9")" = "success" ] \
    || fail "recorded outcome is not success: $(rr_scalar outcome <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app2 status <"$fixture/o9")" = "succeeded" ] \
    || fail "app2 row is not succeeded: $(rr_row app2 <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app2 rc <"$fixture/o9")" = "0" ] \
    || fail "app2 row rc is not 0: $(rr_row app2 <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app2 reason <"$fixture/o9")" = "ok" ] \
    || fail "app2 row reason is not ok: $(rr_row app2 <"$fixture/o9")" "$fixture/o9"
[ -f "$fixture/state-9/logs/app2.log" ] \
    || fail "checked package app2 was not built" "$fixture/o9"
for unbuilt in app1 app3 extdep gitp1; do
    [ -f "$fixture/state-9/logs/$unbuilt.log" ] \
        && fail "unchecked package $unbuilt was built" "$fixture/o9"
done

printf 'app group fixture: PASS\n'
