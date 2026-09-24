#!/usr/bin/env bash
set -uo pipefail

# Local pacman database integrity probe — the 2026-09-24 vscodium-insiders
# incident: a window-close TERM killed `pacman -U` three seconds into its
# commit, leaving /var/lib/pacman/local/<pkg>/ containing only `mtree`.
# From then on every transaction failed pacman's MISLEADING
# `invalid or corrupted package` (blaming the innocent archive) and
# makepkg's .BUILDINFO query printed the raw `desc` open error during the
# package() phase. The entry was unusable in every direction (-U, -R, -Ql),
# so the builder now probes for desc/files-less entries and removes them
# ONLY when provably idle, mirroring the db.lck policy (2026-09-23).
#
# Sub-tests (all against fixture directories — the host's real
# /var/lib/pacman/local is never read or written):
#   1. idle broken entry (mtree only) → removed + loud warning naming the
#      entry and the reinstall step; rc 0.
#   2. same broken entry + live holder → kept, holder pid/cmd reported,
#      recovery text; rc 1 (a live transaction may be mid-commit).
#   3. healthy entry (desc+files) → never touched, no warning; rc 0.
#   4. desc present, files missing → also broken (both members are universal
#      on a healthy box: measured 1754/1754), removed when idle; rc 0.
#   5. empty/absent dir → rc 0, no output noise about removals.
#   6. static: the --local-db-check seam exists and check_pacman_db_health is
#      wired at all four sites (preflight, install_all, interrupt teardown,
#      run_pacman_locked failure path).
#
# Lock isolation: the stub `pgrep` is a fixture-side oracle (GSA_FAKE_PGREP_
# HOLDER), so a real pacman elsewhere on the host cannot make this fixture
# flap. The builder gains NO GSA_* test knob — it honours exactly the seven
# variables --help lists; GSA_FAKE_* names are consumed by the stubs only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-localdb-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

mkdir -p "$fixture/config/groups" "$fixture/packages/p1" "$fixture/bin"
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
for group in git stable core misc third-party app; do
    : >"$fixture/config/groups/$group.list"
done
printf 'pkgname=p1\n' >"$fixture/packages/p1/PKGBUILD"
printf 'p1|packages/p1\n' >"$fixture/config/packages.map"
printf 'p1\n' >"$fixture/config/groups/git.list"

cat >"$fixture/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
# Holder oracle: a non-empty GSA_FAKE_PGREP_HOLDER is THE pid "holding" the
# database (for -x pacman); unset = provably idle.
if [[ ${1:-} == -x ]]; then
    if [[ -n ${GSA_FAKE_PGREP_HOLDER:-} && ${2:-} == pacman ]]; then
        printf '%s\n' "$GSA_FAKE_PGREP_HOLDER"
        exit 0
    fi
    exit 1
fi
exit 1
EOF
chmod +x "$fixture/bin/pgrep"

run_check() { # $1 = local-dir, $2 = output-file, rest = extra env assignments
    local dir=$1 out=$2
    shift 2
    env PATH="$fixture/bin:$PATH" "$@" \
        fish "$fixture/build-all.fish" --local-db-check "$dir" >"$out" 2>&1
}

# ── 1. idle broken entry → removed + loud warning ───────────────────────────
echo "phase 1: idle broken entry (mtree only) is removed with a warning"
local_db="$fixture/var/pacman/local"
mkdir -p "$local_db/insiders-1.0-1"
: >"$local_db/insiders-1.0-1/mtree"
out1="$fixture/phase1.out"
run_check "$local_db" "$out1" ; rc=$?
[[ $rc -eq 0 ]] || fail "idle broken check rc=$rc, want 0" "$(cat "$out1")"
[[ ! -e $local_db/insiders-1.0-1 ]] ||
    fail "idle broken entry was NOT removed"
grep -q 'BROKEN local package database entries removed' "$out1" ||
    fail "no loud BROKEN warning for the removed entry:" "$(cat "$out1")"
grep -qF 'insiders-1.0-1' "$out1" ||
    fail "warning does not name the removed entry" "$(cat "$out1")"
grep -qE -- '-s -i|.-ia' "$out1" ||
    fail "warning does not name the reinstall step (-s -i / -ia)" "$(cat "$out1")"
grep -q 'interrupted pacman -U commit' "$out1" ||
    fail "warning does not explain the interrupted-commit cause" "$(cat "$out1")"

# ── 2. live holder → kept, reported, rc 1 ───────────────────────────────────
echo "phase 2: broken entry with a live transaction holder is left untouched"
mkdir -p "$local_db/held-1.0-1"
: >"$local_db/held-1.0-1/mtree"
sleep 60 &
holder=$!
out2="$fixture/phase2.out"
run_check "$local_db" "$out2" "GSA_FAKE_PGREP_HOLDER=$holder" ; rc=$?
[[ $rc -eq 1 ]] || fail "busy broken check rc=$rc, want 1" "$(cat "$out2")"
[[ -e $local_db/held-1.0-1 ]] ||
    fail "broken entry was REMOVED while a holder was alive"
grep -q "holder pid=$holder" "$out2" ||
    fail "holder pid not reported:" "$(cat "$out2")"
grep -q 'cmd=.*sleep' "$out2" ||
    fail "holder cmdline not reported:" "$(cat "$out2")"
grep -q 'interrupted pacman -U commit' "$out2" ||
    fail "report does not identify the broken entries:" "$(cat "$out2")"
grep -q 'sudo rm -rf' "$out2" ||
    fail "no manual recovery instructions for a held database" "$(cat "$out2")"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ── 3. healthy entry is never touched ───────────────────────────────────────
echo "phase 3: healthy entry (desc+files) survives an idle probe untouched"
mkdir -p "$local_db/healthy-1.0-1"
: >"$local_db/healthy-1.0-1/desc"
: >"$local_db/healthy-1.0-1/files"
: >"$local_db/held-1.0-1/mtree"   # keep a broken one around from phase 2
out3="$fixture/phase3.out"
run_check "$local_db" "$out3" ; rc=$?
# held-1.0-1 is still broken and now idle → it IS removed (rc 0), but the
# healthy entry must survive that same pass.
[[ $rc -eq 0 ]] || fail "idle probe after holder gone rc=$rc, want 0" "$(cat "$out3")"
[[ -d $local_db/healthy-1.0-1 ]] ||
    fail "HEALTHY entry was touched/removed by the probe"
[[ ! -e $local_db/held-1.0-1 ]] ||
    fail "broken entry survived once the holder left (idle removal broken)"

# ── 4. desc present, files missing → broken too ─────────────────────────────
echo "phase 4: desc-without-files entry is removed when idle"
mkdir -p "$local_db/nofiles-1.0-1"
: >"$local_db/nofiles-1.0-1/desc"
out4="$fixture/phase4.out"
run_check "$local_db" "$out4" ; rc=$?
[[ $rc -eq 0 ]] || fail "files-missing check rc=$rc, want 0" "$(cat "$out4")"
[[ ! -e $local_db/nofiles-1.0-1 ]] ||
    fail "desc-present/files-missing entry was NOT removed"

# ── 5. empty local dir → clean rc 0 ─────────────────────────────────────────
echo "phase 5: empty local dir is a clean no-op"
empty_db="$fixture/var/pacman/empty-local"
mkdir -p "$empty_db"
out5="$fixture/phase5.out"
run_check "$empty_db" "$out5" ; rc=$?
[[ $rc -eq 0 ]] || fail "empty local dir rc=$rc, want 0" "$(cat "$out5")"
grep -q 'BROKEN' "$out5" &&
    fail "empty local dir produced a BROKEN warning" "$(cat "$out5")"
run_check "$fixture/var/pacman/absent-local" "$out5" ; rc=$?
[[ $rc -eq 0 ]] || fail "absent local dir rc=$rc, want 0"

# ── 6. static wiring pins ───────────────────────────────────────────────────
echo "phase 6: seam + four call sites present"
grep -q -- '--local-db-check' "$fixture/build-all.fish" ||
    fail "--local-db-check seam missing from build-all.fish"
grep -q 'function check_pacman_db_health' "$fixture/build-all.fish" ||
    fail "check_pacman_db_health function missing"
wires=$(grep -c 'check_pacman_db_health (pacman_db_local_path)' \
    "$fixture/build-all.fish")
[[ "$wires" -ge 4 ]] ||
    fail "check_pacman_db_health wired at $wires site(s), want >=4" \
        "(preflight, install_all, interrupt teardown, run_pacman_locked)"
grep -q 'function pacman_db_local_path' "$fixture/build-all.fish" ||
    fail "pacman_db_local_path helper missing (DBPath seam)"

echo "local-db repair fixture: PASS"
