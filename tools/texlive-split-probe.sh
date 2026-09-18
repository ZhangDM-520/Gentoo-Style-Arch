#!/usr/bin/env bash
set -uo pipefail

# texlive-split-probe.sh — guarded reproduction harness for the texlive-texmf
# prepare() split loop.
#
# Why this exists
# ---------------
# prepare() in packages/git/texlive-texmf moves ~150k files out of
# $srcdir/texmf-dist with one `mkdir -p` plus one `mv` per file, and re-parses
# the 18.7 MB tlpkg/texlive.tlpdb twice per package (about 6.3k full rescans,
# ~235 GB of scanning). On 2026-09-18 that workload coincided with two total
# system freezes: boots ended abruptly with no kernel message, no OOM kill, no
# device error — the journal simply stops 43 s into prepare(), ~14k renames in.
#
# This probe reproduces that loop under measurement so the trigger can be
# attributed, without endangering the machine:
#
#   * the loop body is EXTRACTED FROM THE PKGBUILD at run time (no copy that can
#     drift away from the recipe) and runs on a HARDLINK FARM, so the real tree
#     is never modified in place;
#   * the run is confined with cgroup limits (memory, swap, cpu, io weight);
#   * a 1 Hz sampler records PSI, D-state count, device utilisation/await, zram
#     usage and XFS metadata counters into a file fsynced every sample, and
#     prints the same line live — the last visible frame is evidence;
#   * a watchdog KILLS the run when a threshold trips, so the machine is never
#     pushed to the point of freezing.
#
# This is a host-side diagnostic, deliberately outside tests/ (heavy, mutating,
# needs a populated texlive tree and cgroup control); the fixture battery stays
# small and CI-safe.
#
# Staged workloads isolate the trigger:
#   parse  the loop with mkdir/mv/cp/ln neutralised — the sed/grep cost only
#   move   a precomputed rename plan replayed with the recipe's own command
#          shape — the I/O and process-churn cost only, no parsing
#   full   the real loop, unmodified
#
# Exit status: 0 clean, 1 aborted by the watchdog or a failure, 124 timeout.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
    awk 'NR>3 && /^#/ { sub(/^# ?/, ""); print } NR>3 && !/^#/ { exit }' "${BASH_SOURCE[0]}"
    cat <<'EOF'

Options:
  --tree DIR           populated texlive tree to borrow files from
                       (default: $GSA_TEXLIVE_TREE, else the recipe directory,
                       where makepkg's SRCDEST keeps it)
  --recipe DIR         recipe directory holding the PKGBUILD
                       (default: this repo's packages/git/texlive-texmf)
  --collections LIST   comma-separated collections to split
                       (default: fontsrecommended; fontsextra is the one that
                       froze the machine and is ~20x the work)
  --stage STAGE        parse | move | full   (default: full)
  --scratch DIR        parent for the farm (default: $XDG_CACHE_HOME or /tmp)
  --keep               keep the scratch dir and print its path
  --limit-mem GiB      cgroup MemoryMax                 (default: 4)
  --limit-cpu PERCENT  cgroup CPUQuota                  (default: 400%)
  --limit-io-weight N  cgroup IOWeight 1..10000         (default: 10)
  --limit-io MBps      hard read+write bandwidth cap on the root device, the
                       one control that actually bounds device pressure when
                       nothing else competes (default: 50)
  --timeout SEC        wall-clock cap                   (default: 300)
  --sample-hz SEC      sampler interval                 (default: 1)
  --max-d N            abort above this D-state count    (default: 25)
  --max-psi-io PCT     abort above io PSI full avg10     (default: 50)
  --min-mem GiB        abort below this MemAvailable     (default: 2)
  --max-await MS       abort above this device await     (default: 500)
  --unsafe             run WITHOUT cgroup limits (needs --yes-unsafe; prints
                       the SysRq runbook first — the only mode that can freeze
                       the machine). Use it for a faithful reproduction in a
                       farm, or for --watch-cmd on the real build.
  --yes-unsafe         acknowledge the above
  --watch-cmd CMD      instrument an EXISTING command instead of the farm
                       workload: run CMD under the same sampler and watchdog.
                       This is how the real build gets measured — e.g.
                       --watch-cmd 'makepkg -si' --cwd <recipe> --unsafe
  --cwd DIR            working directory for --watch-cmd (default: --recipe)
  --full-farm          hardlink the whole tree instead of only the files this
                       run will move (more faithful directories, slower start)
  --rebuild-farm       rebuild the golden farm even if it exists
  -h, --help           this help
EOF
}

die() { printf 'probe: %s\n' "$1" >&2; exit 1; }

recipe_dir=""
tree_dir=""
collections="fontsrecommended"
stage="full"
scratch_parent="${XDG_CACHE_HOME:-/tmp}"
keep=0
limit_mem_gib=4
limit_cpu="400%"
limit_io_weight=10
limit_io_mbps=50
timeout_s=300
sample_hz=1
max_d=25
max_psi_io=50
min_mem_gib=2
max_await=500
unsafe=0
yes_unsafe=0
full_farm=0
rebuild_farm=0
watch_cmd=""
cwd_dir=

while (($#)); do
    case "$1" in
        --tree) tree_dir=${2:?--tree needs a value}; shift 2 ;;
        --recipe) recipe_dir=${2:?--recipe needs a value}; shift 2 ;;
        --collections) collections=${2:?--collections needs a value}; shift 2 ;;
        --stage) stage=${2:?--stage needs a value}; shift 2 ;;
        --scratch) scratch_parent=${2:?--scratch needs a value}; shift 2 ;;
        --keep) keep=1; shift ;;
        --limit-mem) limit_mem_gib=${2:?}; shift 2 ;;
        --limit-cpu) limit_cpu=${2:?}; shift 2 ;;
        --limit-io-weight) limit_io_weight=${2:?}; shift 2 ;;
        --limit-io) limit_io_mbps=${2:?}; shift 2 ;;
        --timeout) timeout_s=${2:?}; shift 2 ;;
        --sample-hz) sample_hz=${2:?}; shift 2 ;;
        --max-d) max_d=${2:?}; shift 2 ;;
        --max-psi-io) max_psi_io=${2:?}; shift 2 ;;
        --min-mem) min_mem_gib=${2:?}; shift 2 ;;
        --max-await) max_await=${2:?}; shift 2 ;;
        --unsafe) unsafe=1; shift ;;
        --yes-unsafe) yes_unsafe=1; shift ;;
        --watch-cmd) watch_cmd=${2:?--watch-cmd needs a value}; shift 2 ;;
        --cwd) cwd_dir=${2:?--cwd needs a value}; shift 2 ;;
        --full-farm) full_farm=1; shift ;;
        --rebuild-farm) rebuild_farm=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

case "$stage" in parse|move|full) ;; *) die "--stage must be parse, move or full" ;; esac
[[ "$collections" =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]] || die "--collections must be a comma-separated list of collection names"

# ─── Resolve the recipe (holds the PKGBUILD we extract the loop from) ────────
if [[ -z $recipe_dir ]]; then
    for candidate in "$SCRIPT_DIR/packages/git/texlive-texmf"; do
        [[ -f $candidate/PKGBUILD ]] && recipe_dir=$candidate
    done
fi
[[ -n $recipe_dir && -f $recipe_dir/PKGBUILD ]] || die "no texlive PKGBUILD found; pass --recipe"
recipe_dir=$(cd "$recipe_dir" && pwd)
[[ -n $cwd_dir ]] || cwd_dir=$recipe_dir
[[ -d $cwd_dir ]] || die "--cwd $cwd_dir is not a directory"
cwd_dir=$(cd "$cwd_dir" && pwd)

# ─── Resolve the tree (borrowed read-only through hardlinks) ────────────────
# --watch-cmd measures somebody else's command and needs none of this, so the
# tree is only resolved for the farm workload.
if [[ -n $watch_cmd ]]; then
    tree_dir="(none)"
else
    if [[ -z $tree_dir ]]; then
        # A populated tree lives beside the recipe (makepkg's SRCDEST defaults to
        # $startdir), so the recipe directory is the generic answer;
        # GSA_TEXLIVE_TREE points at a checkout elsewhere — another clone, say.
        for candidate in "${GSA_TEXLIVE_TREE:-}" "$recipe_dir"; do
            [[ -n $candidate && -d $candidate/texmf-dist ]] && tree_dir=$candidate && break
        done
    fi
    [[ -n $tree_dir && -d $tree_dir/texmf-dist ]] || die "no populated texmf-dist found; pass --tree"
    tree_dir=$(cd "$tree_dir" && pwd)

    for needed in texmf-dist/web2c/fmtutil.cnf texmf-dist/web2c/updmap.cfg \
                  texmf-dist/web2c/texmf.cnf texmf-dist/tex/generic/config/language.dat \
                  texmf-dist/tex/generic/config/language.dat.lua \
                  texmf-dist/tex/generic/config/language.def; do
        [[ -f $tree_dir/$needed ]] || die "tree is missing $needed (wrong --tree?)"
    done
    tlpdb=""
    for candidate in "$tree_dir/tlpkg/texlive.tlpdb" "$tree_dir/src/tlpkg/texlive.tlpdb"; do
        [[ -f $candidate ]] && tlpdb=$candidate && break
    done
    [[ -n $tlpdb ]] || die "no tlpkg/texlive.tlpdb in $tree_dir"
fi

# ─── Extract the loop from the PKGBUILD (single source of truth) ────────────
# prepare() is taken from the recipe file itself, then trimmed to the split
# loop, so this probe can never test a stale copy of the logic.
if [[ -z $watch_cmd ]]; then
loop_body=$(awk '
    /^prepare\(\) *\{/ { inprep = 1; next }
    inprep && /^\}/ { exit }
    inprep { print }
' "$recipe_dir/PKGBUILD" | awk '
    /# Split files per package/ { keep = 1 }
    keep { print }
')
[[ -n $loop_body ]] || die "could not extract the split loop from $recipe_dir/PKGBUILD (did prepare() change shape?)"
grep -q '_collections' <<<"$loop_body" || die "extracted loop does not reference _collections"
fi   # end of the loop extraction (skipped for --watch-cmd)

run_id="texlive-split-probe.$$.$(date +%s)"
scratch="$scratch_parent/$run_id"
mkdir -p "$scratch" || die "cannot create $scratch"
golden="$scratch_parent/texlive-split-probe.golden"
run="$scratch/run"
mkdir -p "$run"

if [[ -n $watch_cmd ]]; then
    # --watch-cmd: instrument an existing command (the real build, a real svn
    # update, ...). No farm, no plan, no substituted workload — the point is to
    # sample the thing that actually froze the machine.
    plan="$run/plan.tsv"
    : >"$plan"
    plan_files=0
    collections_in_plan="(watch-cmd)"
    link_count=0
    tree="$run"
    mkdir -p "$tree"
    workload="$run/workload.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'cd %q || exit 1\n' "$cwd_dir"
        printf '%s\n' "$watch_cmd"
    } >"$workload"
    chmod +x "$workload"
else

# ─── The rename plan: one pass over tlpdb instead of ~12.6k sed scans ───────
# Mirrors the recipe exactly: iterate the selected collections in order, walk
# each collection's direct `depend` list in file order, skip collection-*
# entries, and emit the package's runfiles that live under texmf-dist (docs
# excluded, as the recipe does).
plan="$run/plan.tsv"
awk -v cols="$collections" '
    /^name /    { name = $2; next }
    /^depend /  { if (name ~ /^collection-/) deps[name] = deps[name] " " $2; next }
    /^runfiles/ { inrun = 1; next }
    /^[a-z]/    { inrun = 0 }
    {
        if (inrun && substr($0, 1, 1) == " ") {
            f = substr($0, 2)
            if (f ~ /^texmf-dist\// && f !~ /^texmf-dist\/doc\//) files[name] = files[name] "\n" f
        }
    }
    END {
        n = split(cols, C, ",")
        for (i = 1; i <= n; i++) {
            cn = "collection-" C[i]
            if (!(cn in deps)) { print "MISSING-COLLECTION\t" C[i] > "/dev/stderr"; continue }
            k = split(deps[cn], D, " ")
            for (j = 1; j <= k; j++) {
                p = D[j]
                if (p ~ /^collection-/) continue
                m = split(files[p], F, "\n")
                for (t = 1; t <= m; t++) if (F[t] != "") print C[i] "\t" F[t]
            }
        }
    }
' "$tlpdb" >"$plan" || die "plan generation failed"

plan_files=$(grep -c . "$plan" || true)
collections_in_plan=$(cut -f1 "$plan" | sort -u | paste -sd, -)
[[ $plan_files -gt 0 ]] || die "the plan is empty (collection names wrong? tlpdb truncated?)"

# ─── The hardlink farm ─────────────────────────────────────────────────────
# Only the files this run will actually move are linked (plus the read-only
# inputs), which keeps the start-up cost proportional to the run and leaves the
# real tree untouched: `mv` in the farm renames the link, never the data.
tree="$run/tree"
mkdir -p "$tree" || die "cannot create $tree"

link_one() { # link_one <relative path>
    local rel=$1 src="$tree_dir/$1" dst="$tree/$1"
    [[ -e $src || -L $src ]] || return 0
    mkdir -p "$(dirname "$dst")" || return 1
    ln "$src" "$dst" 2>/dev/null || cp -a "$src" "$dst" || return 1
    return 0
}

link_count=0
if ((full_farm)); then
    rsync -a --exclude=.svn --link-dest="$tree_dir/" "$tree_dir/" "$tree/" \
        || die "rsync farm build failed"
else
    while IFS=$'\t' read -r _coll rel; do
        link_one "$rel" || die "cannot link $rel"
        link_count=$((link_count + 1))
    done <"$plan"
fi

mkdir -p "$tree/tlpkg"
ln "$tlpdb" "$tree/tlpkg/texlive.tlpdb" 2>/dev/null || cp "$tlpdb" "$tree/tlpkg/texlive.tlpdb"
if [[ -d $tree_dir/x86_64-linux ]]; then
    rsync -a --exclude=.svn --link-dest="$tree_dir/" "$tree_dir/x86_64-linux/" "$tree/x86_64-linux/" \
        || die "x86_64-linux farm build failed"
fi
for f in web2c/fmtutil.cnf web2c/updmap.cfg web2c/texmf.cnf; do
    ln "$tree_dir/texmf-dist/$f" "$tree/$(basename "$f")" 2>/dev/null \
        || cp "$tree_dir/texmf-dist/$f" "$tree/$(basename "$f")"
done
for f in language.dat language.dat.lua language.def; do
    ln "$tree_dir/texmf-dist/tex/generic/config/$f" "$tree/$f" 2>/dev/null \
        || cp "$tree_dir/texmf-dist/tex/generic/config/$f" "$tree/$f"
done

# ─── Build the workload: real loop, or a faithful replay of its I/O ─────────
workload="$run/workload.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' 'cd "$(dirname "$0")/tree" || exit 1' \
        'srcdir=$PWD' 'export srcdir'
    printf '_collections=(%s)\n' "$(tr ',' ' ' <<<"$collections")"
    case "$stage" in
        parse)
            # Neutralise the filesystem work but keep every other call, so the
            # run measures the parsing/CPU side of the loop alone.
            printf '%s\n' \
                'mkdir() { return 0; }' \
                'mv() { return 0; }' \
                'cp() { return 0; }' \
                'ln() { return 0; }' \
                'xargs() { cat >/dev/null; return 0; }'
            printf '%s\n' "$loop_body"
            ;;
        move)
            # No parsing at all: replay the plan with the recipe's own command
            # shape (one mkdir -p and one mv per file).
            printf '%s\n' \
                'while IFS=$'"'"'\t'"'"' read -r _coll _rel; do' \
                '    [[ -n $_rel ]] || continue' \
                '    mkdir -p "texlive-$_coll/$(dirname "$_rel")"' \
                '    mv "$_rel" "texlive-$_coll/$(dirname "$_rel")"' \
                'done <"'"$plan"'"'
            ;;
        full)
            printf '%s\n' "$loop_body"
            ;;
    esac
} >"$workload"
chmod +x "$workload"

fi   # end of the farm/workload branch

# ─── Sampling, watchdog ────────────────────────────────────────────────────
samples="$run/samples.tsv"
loop_out="$run/loop.out"
abort_reason="$run/abort.reason"
: >"$samples"
: >"$loop_out"

root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
disk=$(basename "${root_src:-nvme0n1}")
if [[ -e /sys/block/$disk/stat ]]; then
    stat_file="/sys/block/$disk/stat"
else
    part=$(basename "${root_src:-}")
    parent=$(lsblk -no PKNAME "/dev/$part" 2>/dev/null | head -1)
    stat_file="/sys/block/${parent:-$part}/stat"
fi
zram_stat=/sys/block/zram0/mm_stat

hf() { # human GiB from bytes
    awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

sample_line() { # sample_line <elapsed> -> TSV row, sets sample_* globals
    local elapsed=$1
    local now_ns=$(date +%s%N)
    local dt_ms=$(( (now_ns - last_ns) / 1000000 ))
    ((dt_ms > 0)) || dt_ms=1
    last_ns=$now_ns

    read -r psi_cpu psi_io psi_io_full psi_mem psi_mem_full < <(awk '
        ($1 == "some" || $1 == "full") {
            split($2, a, "="); v = a[2]
            k = FILENAME; sub(/.*\//, "", k)
            if (k == "cpu"     && $1 == "some") c  = v
            else if (k == "io" && $1 == "some") i  = v
            else if (k == "io" && $1 == "full") if1 = v
            else if (k == "memory" && $1 == "some") m  = v
            else if (k == "memory" && $1 == "full") mf = v
        }
        END { printf "%s %s %s %s %s", c, i, if1, m, mf }' \
        /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory)

    set -- $(cat "$stat_file")
    local rio=$1 rsect=$3 wio=$5 wsect=$7 inflight=$9 ioticks=${10} qtime=${11}
    local dio=$(( (rio + wio) - (last_rio + last_wio) ))
    local dsect=$(( (rsect + wsect) - (last_rsect + last_wsect) ))
    local dtick=$(( ioticks - last_ioticks ))
    local dq=$(( qtime - last_qtime ))
    last_rio=$rio; last_rsect=$rsect; last_wio=$wio; last_wsect=$wsect
    last_ioticks=$ioticks; last_qtime=$qtime
    local iops=$(( dio * 1000 / dt_ms ))
    local mbps=$(awk -v s="$dsect" -v ms="$dt_ms" 'BEGIN { printf "%.1f", s*512/1000000/(ms/1000) }')
    local util=$(awk -v t="$dtick" -v ms="$dt_ms" 'BEGIN { u=100*t/ms; if(u>100)u=100; printf "%.0f", u }')
    local await=$(awk -v q="$dq" -v d="$dio" 'BEGIN { printf "%.1f", (d > 0 ? q/d : 0) }')

    local memavail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    local dcount=$(awk '{ i=index($0,")"); if (i>0 && substr($0,i+2,1)=="D") n++ } END { print n+0 }' /proc/[0-9]*/stat 2>/dev/null)
    local xfs_xlog=$(awk '/^xlog / { s=0; for (i=2;i<=NF;i++) s+=$i; print s }' /proc/fs/xfs/stat 2>/dev/null)
    local xfs_all=$(awk '{ for (i=2;i<=NF;i++) s+=$i } END { print s+0 }' /proc/fs/xfs/stat 2>/dev/null)
    local zram_mem=0
    [[ -r $zram_stat ]] && zram_mem=$(awk '{print $3}' "$zram_stat")
    local progress=$(tail -c 300 "$loop_out" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -1 | tr '\t' ' ' | cut -c1-60)

    sample_dcount=$dcount
    sample_psi_io_full=$psi_io_full
    sample_psi_mem_full=$psi_mem_full
    sample_mem_avail_kb=$memavail
    sample_zram_bytes=$zram_mem
    sample_await=$await
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$elapsed" "$dcount" "$psi_cpu" "$psi_io" "$psi_io_full" "$psi_mem" "$psi_mem_full" \
        "$iops" "$mbps" "$util" "$await" "$inflight" "$(hf "$((memavail * 1024))")" "$(hf "$zram_mem")" "$progress" \
        >>"$samples"
    printf '\r[%4ss] D=%-3s psi_io=%-5s full=%-5s psi_mem_full=%-5s iops=%-6s MB/s=%-7s util=%-4s%% await=%-7s mem=%-6sG zram=%-5sG | %-60s' \
        "$elapsed" "$dcount" "$psi_io" "$psi_io_full" "$psi_mem_full" "$iops" "$mbps" "$util" "$await" \
        "$(hf "$((memavail * 1024))")" "$(hf "$zram_mem")" "$progress" >&2
    sync "$samples" 2>/dev/null
}

# ─── Run it ────────────────────────────────────────────────────────────────
{
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        elapsed dstate psi_cpu psi_io psi_io_full psi_mem psi_mem_full iops mbps util await inflight mem_gib zram_gib progress
} >"$samples"

# Prime the delta counters so the first sample is meaningful.
last_ns=$(date +%s%N)
read -r last_rio last_rsect last_wio last_wsect _last_inflight last_ioticks last_qtime < <(
    awk '{ print $1, $3, $5, $7, $9, $10, $11 }' "$stat_file")
start_ts=$(date +%s)

if ((unsafe)); then
    if ((!yes_unsafe)); then
        cat >&2 <<'EOF'
probe: --unsafe runs the workload with NO cgroup limit. That is the mode that
       can freeze this machine (it has done so twice: 2026-09-18 08:40 and
       10:41, both times mid-prepare()).

       Before you continue, be at a physical keyboard and know these keys:
         Alt+SysRq+R  take the keyboard back from X/Wayland
         Alt+SysRq+E  SIGTERM every process      (then wait ~10 s)
         Alt+SysRq+I  SIGKILL every process
         Alt+SysRq+S  sync, Alt+SysRq+U  remount read-only
         Alt+SysRq+B  reboot now
       kernel.sysrq is set to 1 for this session, so those work.
       If the screen is dead but the box is alive, Ctrl+Alt+F3 lands on a VT and
       the sampler output above is the evidence we need.

       Re-run with --yes-unsafe to accept.
EOF
        exit 2
    fi
    printf 'probe: UNSAFE mode — no cgroup limits. Watchdog thresholds still armed.\n' >&2
    runner=(setsid bash "$workload")
else
    root_dev="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)"
    [[ -b $root_dev ]] || root_dev=$(findmnt -no SOURCE /)
    runner=(setsid systemd-run --user --scope --quiet \
        -p "MemoryMax=${limit_mem_gib}G" -p MemorySwapMax=0 \
        -p "CPUQuota=${limit_cpu}" -p "IOWeight=${limit_io_weight}" \
        -p "IOReadBandwidthMax=${root_dev} ${limit_io_mbps}M" \
        -p "IOWriteBandwidthMax=${root_dev} ${limit_io_mbps}M" \
        bash "$workload")
fi

"${runner[@]}" >"$loop_out" 2>&1 &
run_pid=$!

stop_run() {
    [[ -n ${run_pid:-} ]] || return 0
    kill -TERM -- "-$run_pid" 2>/dev/null
    for _ in $(seq 20); do
        kill -0 -- "-$run_pid" 2>/dev/null || return 0
        sleep 0.2
    done
    kill -KILL -- "-$run_pid" 2>/dev/null
    return 0
}

aborted=0
exit_reason="completed"
while kill -0 "$run_pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start_ts ))
    sample_line "$elapsed"
    reason=""
    (( sample_dcount > max_d )) && reason="D-state ${sample_dcount} > ${max_d}"
    [[ -z $reason ]] && awk -v v="$sample_psi_io_full" -v m="$max_psi_io" 'BEGIN { exit !(v > m) }' && reason="io PSI full ${sample_psi_io_full} > ${max_psi_io}"
    [[ -z $reason ]] && (( sample_mem_avail_kb / 1048576 < min_mem_gib )) && reason="MemAvailable $(hf "$((sample_mem_avail_kb * 1024))")G < ${min_mem_gib}G"
    [[ -z $reason ]] && awk -v v="$sample_await" -v m="$max_await" 'BEGIN { exit !(v > m) }' && reason="device await ${sample_await}ms > ${max_await}ms"
    [[ -z $reason ]] && awk -v v="$sample_psi_mem_full" -v m="$max_psi_io" 'BEGIN { exit !(v > m) }' && reason="memory PSI full ${sample_psi_mem_full} > ${max_psi_io}"
    if [[ -n $reason ]]; then
        printf '%s\n' "$reason" >"$abort_reason"
        stop_run
        aborted=1
        exit_reason="ABORTED: $reason"
        break
    fi
    if (( elapsed >= timeout_s )); then
        printf '%s\n' "wall-clock cap ${timeout_s}s" >"$abort_reason"
        stop_run
        aborted=1
        exit_reason="ABORTED: wall-clock cap ${timeout_s}s"
        break
    fi
    sleep "$sample_hz"
done

wait "$run_pid" 2>/dev/null
workload_rc=$?
wall=$(( $(date +%s) - start_ts ))
printf '\n' >&2

# ─── Result ────────────────────────────────────────────────────────────────
moved=0
for _d in "$tree"/texlive-*; do
    [[ -d $_d ]] && moved=$((moved + $(find "$_d" -type f 2>/dev/null | wc -l)))
done
split_dirs=$(find "$tree" -maxdepth 1 -name 'texlive-*' -type d 2>/dev/null | wc -l)

printf 'probe: stage=%s collections=%s tree=%s\n' "$stage" "$collections_in_plan" "$tree_dir"
if [[ -n $watch_cmd ]]; then
    printf 'probe: watched command (cwd=%s): %s\n' "$cwd_dir" "$watch_cmd"
else
    printf 'probe: plan=%s files to move, %s linked into the farm, %s split dir(s) produced, %s file(s) moved\n' \
        "$plan_files" "$link_count" "$split_dirs" "$moved"
fi
printf 'probe: wall=%ss exit=%s workload_rc=%s\n' "$wall" "$exit_reason" "$workload_rc"

awk -F'\t' '
    NR == 1 { next }
    {
        n++
        if ($2+0 > d) d = $2
        if ($4+0 > pio) pio = $4
        if ($5+0 > piof) piof = $5
        if ($7+0 > pmem) pmem = $7
        if ($8+0 > iops) iops = $8
        if ($9+0 > mbps) mbps = $9
        if ($10+0 > util) util = $10
        if ($11+0 > await) await = $11
        sum_pio += $4; sum_util += $10; sum_await += $11
        if (mem == "" || $13+0 < mem) mem = $13
        if ($14+0 > zram) zram = $14
    }
    END {
        if (n == 0) { print "probe: no samples recorded"; exit }
        printf "probe: peak D-state=%d  psi_io=%s (full=%s)  psi_mem_full=%s\n", d+0, pio+0, piof+0, pmem+0
        printf "probe: peak iops=%d  MB/s=%s  util=%d%%  await=%sms\n", iops+0, mbps+0, util+0, await+0
        printf "probe: mean psi_io=%.1f util=%.0f%% await=%.1fms  min mem=%sG  peak zram=%sG  samples=%d\n",
            sum_pio/n, sum_util/n, sum_await/n, (mem == "" ? "?" : mem), zram+0, n
    }
' "$samples"

if ((aborted)); then
    printf 'probe: threat found — %s\n' "$exit_reason"
    printf 'probe: last progress: %s\n' "$(tail -n 1 "$samples" | cut -f15)"
elif ((workload_rc != 0)); then
    printf 'probe: workload exited rc=%s (see %s)\n' "$workload_rc" "$loop_out"
    tail -3 "$loop_out" >&2
else
    printf 'probe: clean — no threshold tripped\n'
fi

if ((keep)); then
    printf 'probe: kept %s\n' "$run"
else
    rm -rf -- "$scratch"
fi

((aborted)) && exit 1
((workload_rc != 0)) && exit 1
exit 0
