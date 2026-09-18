#!/usr/bin/env bash
set -euo pipefail

# tools/texlive-split-probe.sh is what stands between a reproduction attempt and
# a hard reset: it samples the machine 1 Hz and kills the run when a threshold
# trips. A safety net that silently does not fire is worse than none, so this
# fixture drives the abort paths deterministically — with a bare `sleep` and
# impossible thresholds, so nothing on the machine is actually stressed.
#
# It pins: the watchdog aborts and says which threshold tripped, the wrapped
# command is killed (not orphaned), and the sample log survives with the columns
# the analysis reads.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
probe="$root/tools/texlive-split-probe.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-probe-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'probe watchdog fixture: %s\n' "$1" >&2
    exit 1
}

run_probe() { # run_probe <tag> <probe args...>
    local tag=$1
    shift
    rc=0
    "$probe" --cwd "$tmp" --scratch "$tmp" --sample-hz 1 --keep "$@" \
        >"$tmp/out-$tag" 2>"$tmp/err-$tag" || rc=$?
}

# ─── 1. Wall-clock cap ─────────────────────────────────────────────────────
run_probe timeout --watch-cmd 'sleep 300' --timeout 3
(( rc != 0 )) || fail "the probe reported success after its wall-clock cap (rc=0)"
grep -q 'wall-clock cap' "$tmp/out-timeout" ||
    fail "the wall-clock abort did not name itself: $(tail -3 "$tmp/err-timeout")"

sleepers=$(pgrep -f 'sleep 300' | wc -l || true)
(( sleepers == 0 )) || fail "the wrapped command outlived the watchdog ($sleepers left)"

# ─── 2. A resource threshold, via an impossible minimum ────────────────────
# MemAvailable can never reach 999 GiB, so this trips on the first sample
# without any load being applied.
run_probe mem --watch-cmd 'sleep 300' --timeout 60 --min-mem 999
(( rc != 0 )) || fail "the probe ignored its memory threshold (rc=0)"
grep -q 'MemAvailable' "$tmp/out-mem" ||
    fail "the memory abort did not name itself: $(tail -3 "$tmp/err-mem")"
sleepers=$(pgrep -f 'sleep 300' | wc -l || true)
(( sleepers == 0 )) || fail "the wrapped command outlived the memory abort ($sleepers left)"

# ─── 3. The evidence file survives ─────────────────────────────────────────
run=$(cat "$tmp/out-mem" | sed -n 's/^probe: kept //p' | head -1)
[[ -n $run && -d $run ]] || fail "the probe did not keep its scratch dir for inspection"
samples="$run/samples.tsv"
[[ -s $samples ]] || fail "no samples were recorded"
head -1 "$samples" | grep -qE '^elapsed	dstate	psi_cpu	psi_io	psi_io_full	psi_mem	psi_mem_full	iops	mbps	util	await	inflight	mem_gib	zram_gib	dirty_mib	wb_mib	progress$' ||
    fail "sample header changed: $(head -1 "$samples")"
rows=$(($(wc -l <"$samples") - 1))
(( rows >= 1 )) || fail "the sample log has no rows"
awk -F'\t' -v rows="$rows" 'NF != 17 { bad++ } END { exit !(bad == 0) }' "$samples" ||
    fail "a sample row does not have 17 columns"
grep -q '^probe: peak D-state=' "$tmp/out-mem" || fail "no summary was printed"

printf 'probe watchdog fixture: PASS (2 abort paths, %s sample row(s), command killed)\n' "$rows"
