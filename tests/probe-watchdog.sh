#!/usr/bin/env bash
set -euo pipefail

# tools/texlive-split-probe.sh is what stands between a reproduction attempt and
# a hard reset: it samples the machine and stops the run when a threshold trips.
# A safety net that silently does not fire is worse than none, so this fixture
# drives the abort paths with a bare marker loop and impossible thresholds — no
# load is applied to the machine.
#
# It pins the contract that matters in practice:
#   * an abort exits non-zero and names the threshold it tripped;
#   * a FARM run stops its own workload (it is ours to stop);
#   * a WATCH run leaves the command it measures alone (that command is somebody's
#     build — a probe that kills it on a timeout is worse than no probe);
#   * the sample log survives a failure, with the columns the analysis reads
#     (which is why every probe call here passes --scratch "$tmp": a kept
#     directory is the intended behaviour, and the fixture must not litter /tmp
#     with them).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe="$root/tools/texlive-split-probe.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-probe-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'probe watchdog fixture: %s\n' "$1" >&2
    exit 1
}

# A watched command that keeps ticking, so "still running" is observable without
# matching process names (the probe's own cmdline contains the watched command).
ticker="$tmp/ticks"
watched="while :; do date +%s%N >>$ticker; sleep 0.2; done"

run_probe() { # run_probe <tag> [probe args...]
    local tag=$1
    shift
    rc=0
    "$probe" --cwd "$tmp" --scratch "$tmp" --sample-hz 1 --keep "$@" \
        >"$tmp/out-$tag" 2>"$tmp/err-$tag" || rc=$?
}

# ─── 1. Wall-clock cap in a watch mode: sample, report, leave it alone ──────
: >"$ticker"
run_probe timeout --watch-cmd "$watched" --timeout 3
(( rc != 0 )) || fail "the probe reported success after its wall-clock cap (rc=0)"
grep -q 'wall-clock cap' "$tmp/out-timeout" ||
    fail "the wall-clock abort did not name itself: $(tail -3 "$tmp/err-timeout")"
grep -q 'left running' "$tmp/out-timeout" ||
    fail "the watch-mode abort did not say the command survived: $(tail -4 "$tmp/out-timeout")"
ticks_before=$(wc -l <"$ticker")
sleep 1
ticks_after=$(wc -l <"$ticker")
(( ticks_after > ticks_before )) ||
    fail "a watch mode killed the command it was measuring"
# Stop the marker loop: everything it leaves behind carries this fixture's path
# (the loop runs inside the workload script, so its cmdline is the script path).
for pid in $(pgrep -f "$tmp" 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
sleep 1

# ─── 2. A resource threshold, via an impossible minimum ────────────────────
# MemAvailable can never reach 999 GiB, so this trips on the first sample, and
# the watched command must survive it too.
: >"$ticker"
run_probe mem --watch-cmd "$watched" --timeout 60 --min-mem 999
(( rc != 0 )) || fail "the probe ignored its memory threshold (rc=0)"
grep -q 'MemAvailable' "$tmp/out-mem" ||
    fail "the memory abort did not name itself: $(tail -3 "$tmp/err-mem")"
ticks_before=$(wc -l <"$ticker")
sleep 1
(( $(wc -l <"$ticker") > ticks_before )) ||
    fail "the threshold abort killed the command it was measuring"
for pid in $(pgrep -f "$tmp" 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
sleep 1

# ─── 3. The evidence survives a failure, in the documented shape ───────────
run=$(sed -n 's/^probe: kept //p' "$tmp/out-mem" | head -1)
[[ -n $run && -d $run ]] || fail "a failed run did not keep its scratch dir"
samples="$run/samples.tsv"
[[ -s $samples ]] || fail "no samples were recorded"
head -1 "$samples" | grep -qE '^elapsed	dstate	psi_cpu	psi_io	psi_io_full	psi_mem	psi_mem_full	iops	mbps	util	await	inflight	mem_gib	zram_gib	dirty_mib	wb_mib	progress$' ||
    fail "sample header changed: $(head -1 "$samples")"
rows=$(($(wc -l <"$samples") - 1))
(( rows >= 1 )) || fail "the sample log has no rows"
awk -F'\t' 'NF != 17 { bad++ } END { exit !(bad == 0) }' "$samples" ||
    fail "a sample row does not have 17 columns"

# ─── 4. A farm run stops its own workload ──────────────────────────────────
# The smallest tree the real code path accepts, so this exercises plan + farm +
# workload generation rather than a stand-in.
tree="$tmp/tree"
mkdir -p "$tree/tlpkg" "$tree/texmf-dist/web2c" "$tree/texmf-dist/tex/generic/config" \
    "$tree/texmf-dist/tex/mini" "$tree/x86_64-linux"
printf 'minione body\n' >"$tree/texmf-dist/tex/mini/one.sty"
cat >"$tree/tlpkg/texlive.tlpdb" <<'EOF'
name collection-mini
category Collection
shortdesc Mini collection
depend minione

name minione
category Package
shortdesc Mini one
runfiles
 texmf-dist/tex/mini/one.sty
EOF
for f in fmtutil.cnf updmap.cfg texmf.cnf; do : >"$tree/texmf-dist/web2c/$f"; : >"$tree/$f"; done
for f in language.dat language.dat.lua language.def; do : >"$tree/texmf-dist/tex/generic/config/$f"; : >"$tree/$f"; done

rc=0
"$probe" --tree "$tree" --recipe "$root/packages/git/texlive-texmf" \
    --stage full --collections mini --sample-hz 1 --keep --scratch "$tmp" \
    --max-await -1 --timeout 60 >"$tmp/out-farm" 2>"$tmp/err-farm" || rc=$?
(( rc != 0 )) || fail "a farm run ignored an impossible await threshold (rc=0)"
grep -q 'await' "$tmp/out-farm" ||
    fail "the farm abort did not name the threshold: $(tail -4 "$tmp/err-farm")"
grep -q 'workload stopped' "$tmp/out-farm" ||
    fail "a farm abort did not stop its own workload: $(tail -4 "$tmp/out-farm")"
sleep 1
# pgrep exits 1 on no match, which pipefail+set -e would turn into a silent
# exit before the assertion can report anything.
left=$(pgrep -cf "$tmp" 2>/dev/null || true)
left=${left:-0}
(( left == 0 )) || fail "the farm workload outlived the abort ($left process(es) left)"

printf 'probe watchdog fixture: PASS (watch aborts leave the command, farm aborts kill it, %s sample row(s))\n' "$rows"
