# NOTE — Gentoo_Style_Arch maintainer incident journal

Historical journal for the self-built `-git` Arch package set. The current
project stores one clean recipe per package and keeps runtime `src/`, `pkg/`,
logs, caches, and source mirrors outside the publishable interface.
Chronological incident log below (symptom -> root cause -> fix -> rule);
current consolidated state lives in `MEMORY.md`.

Older entries retain historical directory names where they explain an
incident. They are not active configuration. Do not add private paths,
credentials, downloaded sources, or generated build output to this journal.

### Naming history (read this before interpreting old entries)

The workspace was reorganized twice; entries keep whatever names were true when
they were written. Current names are `packages/<category>/<package-id>/` with
categories `git`, `stable`, `core`, `misc`, `third-party`, and logical groups
of the same five names (`config/groups/*.list`).

| In older entries | Was | Now |
| --- | --- | --- |
| `.Heavy/`, `.Heavyweight/` | the heavyweight build area | `packages/core/` (or `packages/git/` for rolling recipes) |
| `.Static/`, `.Stable/` | stock-name packages whose versions track the repos | `packages/stable/` (or `packages/git/`) |
| `.Core/` | `.Heavyweight/` renamed 2026-09-15 | `packages/core/` |
| `.3rdP/` | third-party application recipes | `packages/third-party/` |
| `.Misc/` | auxiliary recipes | `packages/misc/` |
| `-g static`, `-g heavy`, `-g critical`, `-g rocm` | four separate groups | `-g stable` and `-g core` (2026-09-15); `core` auto-enables `-i` |
| `-si`, `--sepinstall` | the separated-install flag | removed 2026-09-17 — `-i`/`--install` is the only spelling |
| `--installall` at end of run | the old collective install | `-ia` remains as a one-transaction escape hatch; a normal run installs per package with `-i` |

So `.Static/qt6-base` and `packages/stable/qt6-base` are the same recipe family,
and `.Heavy/llvm-git` is today's `packages/core/llvm-git`. Package IDs,
dependency edges, and incident root causes are unaffected by the renames.

## 2026-09-24 (texlive prepare) — a config-only SVN husk in SRCDEST sailed past makepkg's warning and killed prepare() at the awk step

- **Symptom**: `build-all.fish` dispatched `texlive-texmf` (rc=1, 23m20s in
  `.state/logs/texlive-texmf.log`): the 6 minted overlay patches and
  `texmf.cnf.patch` applied cleanly (all 7 `patching file …` lines), then
  `awk: fatal: cannot open file 'tlpkg/texlive.tlpdb' for reading: No such
  file or directory` → `==> ERROR: A failure occurred in prepare().` The awk
  is prepare()'s last phase — the per-collection split that reads the tlpdb
  for membership, runfiles, formats, maps, hyphen rules and bin-script links
  (and whose output `texlive-basic` also *packages* into
  `/usr/share/tlpkg`).
- **Measurement** (plan gate, before any edit): upstream HAS the file at the
  pinned revision — `svn info -r 78408
  svn://tug.org/texlive/tags/texlive-2026.1/Master/tlpkg/texlive.tlpdb` →
  `Node Kind: file`, `Revision: 78408`, and `svn ls …/Master/tlpkg/` lists
  `texlive.tlpdb`. Locally `find` found no tlpdb anywhere in the recipe, and
  `svn info <recipe>/tlpkg` → `E155007: … is not a working copy`: the SRCDEST
  `tlpkg/` contained ONLY `.makepkg/` (svn's config dir — `auth`, `config`,
  `servers`, `README.txt`), no `.svn`, no content. The log shows why makepkg
  let it through: `-> Updating tlpkg svn repo...` / `Skipped '.'` /
  `svn: E155007: None of the targets are working copies` /
  `==> WARNING: Failure while updating tlpkg svn repo` — an *update* failure
  on an existing directory is non-fatal — and the extract step then copied
  the husk into `$srcdir/tlpkg` (identical 03:31 mtimes on both sides). The
  sibling sources show the healthy path: `x86_64-linux/` was absent at run
  start, so makepkg *cloned* it and it works. So: **absent locally, not moved
  upstream** — an interrupted/failed initial checkout (dir created 03:31,
  inside the run window whose TERM lands at 03:34:47 in dispatcher.log; the
  old run's log was overwritten, so interrupt-vs-network for that first
  failure is UNPROVEN) left a husk that every later run "updates" without
  ever fetching.
- **Patch-series question answered**: neither patch touches `tlpkg/`
  (`grep -c tlpkg` → 0 in both; targets are `texmf-dist/minted/*` and
  `./texmf.cnf` copied from `texmf-dist/web2c`), all 7 applied in the failing
  run, and `_rev=78408`/`pkgver=2026.1` are unchanged since the recipe's
  first commit — there was **no version bump**; nothing in prepare() besides
  the missing input changed.
- **Contract chosen**: the awk step stays byte-for-byte — the tlpdb
  legitimately ships at the pinned revision and is itself a packaged output,
  so skip/rewrite would gut the split. The fetch is repaired instead: the
  husk was moved to `/tmp/gsa-tlpkg-husk-backup` (evidence) and removed so
  makepkg performs a fresh pinned `svn checkout`, plus a preflight at the
  top of `prepare()` fails in seconds with the exact repair
  (`rm -rf tlpkg src/tlpkg && makepkg -f`) instead of 23 minutes in at a
  bare awk fatal. Sums (`SKIP` for the three VCS entries), sources and
  `.SRCINFO` are untouched (`makepkg --printsrcinfo` diff empty).
- **Validation**: `fish -n`, `bash -n`, `--audit`, `--list`, dry-runs
  git/core/stable, full battery **44/44**; the repaired checkout then took
  `build-all.fish --no-deps texlive-texmf` through prepare() into packaging
  (see validation note below).
- **Durable rules**: a non-working-copy directory in SRCDEST is a landmine —
  makepkg only WARNs on the update and builds from whatever garbage is
  there; never "just re-run" a tlpdb-class failure without checking
  `svn info <source-dir>` first. `svn ls`/`svn info` against the pinned
  revision is the measurement for "the source disappeared"; the build log's
  text alone is not.

## 2026-09-24 (lane reap race) — `signal-abort-lock.sh`'s rc=125 flake: the dispatcher read the result, then checked the child, and the child died in between

- **Symptom**: `tests/signal-abort-lock.sh` failed intermittently (one
  44-fixture battery 43/44, green on rerun; also seen 1-in-8 and, when pinned
  by a strictly SERIAL loop, at iter 20/30) with
  `phase 3 … dispatcher did not report the honest 143` and the run summary
  `✗ lane supervisor produced no valid result (pid=3542191, state=(gone))` /
  `result file bytes: (no bytes)` — while the package log *simultaneously*
  carried `lane child received TERM (rc=143, pid=3542191) — honest signal
  result recorded`, i.e. the child did everything the 2026-09-23 fix
  promised, with the SAME pid the supervisor named.
- **Root cause** (ordering proof, no guesswork): the dispatcher's reap reads
  the result ONCE (`cat "$rf"`) and only afterwards asks
  `lane_pid_alive`. `write_lane_result` publishes atomically with `mv`,
  and the child's sequence is `mv → honest log line → re-raise → death`.
  `(no bytes)` therefore means the `cat` happened **before** the `mv`;
  `state=(gone)` plus the honest line (which precedes the forensics block in
  `p1.log`) means the `ps` happened **after** the death — the whole
  publish-and-die fell into the gap between the read and the check. The
  result was on disk; the dispatcher had already decided it saw nothing and
  reaped rc=125. Window is milliseconds, hence ~1-in-20 serially. (Two
  other reds seen while reproducing — "run … reported success" — were
  self-inflicted: two overlapping loop instances, whose global
  `find_lane_pid` greps crossed; that hazard is already named in the
  2026-09-24 harness entry and is NOT this defect.)
- **Fix** (one hunk in `build-all.fish`'s reap): after the liveness check
  reports the child dead with no valid result, re-read the file ONCE.
  Publication happens-before death, so if the child wrote, the result exists
  at that moment; a genuinely missing write stays empty and keeps today's
  forensics/`stop_lane_process` behaviour unchanged. No new GSA_* knob, no
  fixture reshuffle, no restyling.
- **Validation**: red-first — the unmodified fixture's phase-3 failure was
  captured serially with full output before the edit; after the edit the
  same fixture ran **50/50 green serially** and the full battery **44/44**;
  `fish -n` clean. A deterministic red harness is impossible without a
  builder test knob (the window is dispatcher-internal), so the pin is the
  captured red plus the 50-run green tail, not a new fixture.
- **Durable rules**: result-file reads and liveness checks are NOT one
  atomic observation — any future code that branches on "empty result" must
  re-read after observing death; `rc=125 with '(no bytes)' forensics` can
  still be this lost race, not only a dead-before-write child; and the
  serial-reproduction rule stands (two overlapping batteries produce
  unrelated reds that look like new defects).

## 2026-09-24 (sync anchoring) — one missing published checksum refused the recipe, and the refusal strangled the dispatch; sync now runs updpkgsums, and an unanchorable recipe defers

- **Symptom**: `build-all.fish -g stable,core,git,third-party -s -i`
  (unprivileged and root alike), `linux-tools` committed at 7.2.5 while the
  repos served 7.2.7: `✗ linux-tools: BUILD FAILED (rc=1, 0m01s)` —
  `refusing to build — the official packaging repo carries linux-tools 7.2.7
  but publishes no checksum for: linux-7.2.7.tar.sign` plus the manual
  `updpkgsums` line — makepkg never started — and the first lane failure
  stopped everything: `✗ Build failed — stopped dispatching, drained
  in-flight lanes.`, ~120 packages never dispatched, two consecutive runs.
  (Both rows were measured by the plan; the mechanism is line-traced below
  and both behaviours are reproduced at fixture scale. The full-scale run was
  NOT re-executed — the tree already carries the 7.2.7 sums.)
- **Root cause**, two defects plus one stance gap:
  1. `source_filename`'s detached-signature suffix list was
     `.sig|.asc|.signature` — missing `.sign`, the kernel.org spelling. So
     the signature entered `anchor_names`, `srcinfo_sum_map` drops the
     official SKIP value, and the grade step classified it "unanchored" and
     refused *before* updpkgsums ever ran. Measured with `makepkg
     --verifysource`: intact `.sign` → `linux-7.2.7.tar ... Passed`;
     corrupted → `SIGNATURE NOT FOUND`, rc=1 — its integrity is
     cryptographic (PGP against `validpgpkeys`, over a payload whose sha256
     IS published: `4ac34c…` matched the on-disk tarball), not a hash of the
     signature. Real `updpkgsums` preserves `SKIP` too (measured on a copy:
     sums stayed `4ac34c/SKIP/2e187`).
  2. The dispatcher treated ANY lane rc≠0 as a failed build →
     `stop_starting` → drain. Anchoring-impossible (no official document,
     refresh failure) is not a build failure.
  3. Stance: the refusal's own remedy told the maintainer to run
     `updpkgsums` by hand — the guard declined to automate exactly what it
     prescribed, and one such entry parked a 126-package run.
- **Fix** (the trust model, stated): entries the official `.SRCINFO`
  publishes a value for are unchanged — anchored, verified against Arch after
  the `updpkgsums` write; a disagreement still refuses and restores, and now
  *stops* the dispatch (integrity signal, like a failed build). Entries it
  publishes NO checksum for (SKIP or absent) are refreshed at sync-fire by
  the same `updpkgsums` run and recorded LOUDLY as fetch-only: per entry in
  the package log (`publishes no checksum for (refreshed from the fetch, NOT
  anchored)` + the attestation line — PGP for a signature, #tag/#commit for a
  VCS, TLS for a plain download) and in a new run-level
  `Synced with the repo this run …` summary (`synced.list`, cleared per run)
  carrying the review/commit instruction. Signature files are excluded from
  checksum anchoring altogether (`.sign` added to `source_filename`). No
  official document at our version still refuses and restores — nothing can
  be classified without the document — but is DEFERRED:
  `_ANCHOR_DEFER_RC` (99) rides the ordinary lane-rc field (the `pkgdir rc
  seconds` protocol is untouched), the reap parks it (not `failed`, no
  `stop_starting`), dependents are held back by `pick_next_ready` and
  labelled `waits on a deferred package` (not "cycle"), the summary tails
  the parked log (named error + manual recovery + `--no-sync`), and the run
  exits non-zero with the parked packages in the resume command. Install
  failures and makepkg failures still stop the run; root-mode ownership
  semantics were not touched (concurrent log-ownership work left intact).
- **Validation**: red-first — flipped case 5, new case 5b, and
  `tests/anchor-defer.sh` were all red on the old code (the defer fixture's
  RED output reproduced the measured stop-dispatch signature at scale-1:
  `c-plain` never dispatched), green after; full battery **44/44**;
  `fish -n`, `--audit`, `--list`, dry-runs git/core/stable all green. Also
  regenerated the five stale `-git` `.SRCINFO`s (pre-existing battery red
  from uncommitted version bumps) and `linux-firmware`'s (bumped externally
  mid-session).
- **Durable rules**: never fetch-alone for an entry Arch publishes — that
  half of the guard is exactly as it was; refresh-only entries must always be
  named (log + run summary), never silent; a checksum disagreement with Arch
  stops the run; an anchoring that is merely *impossible* defers, never
  aborts, and its dependents never build; the run-level sync summary is the
  commit witness — a run never commits.

## 2026-09-24 (harness) — sudo-keepalive's fake clock raced itself; never run two batteries at once

- **Symptom**: `tests/sudo-keepalive.sh` failed ~2 runs in 3 — on the
  pre-change baseline *and* on the log-ownership tree alike (proven by
  stashing `build-all.fish` and re-running): `✗ p3/p4: BUILD FAILED (rc=125,
  -60m00s)` with `result file bytes: 'p3 0 -5400'`.
- **Root cause**: the fake `date` stub bumped a shared tick counter with an
  unguarded read-truncate-write. Dispatcher and lane children call it
  concurrently; a reader that opens the file between truncate and write gets
  an empty read, resets the counter to 1, and the lane's duration
  (`end - start`) turns negative — `lane_result_valid` rejects non-`[0-9]`
  durations, so a *successful* build is reaped as malformed rc=125.
- **Fix**: serialize the read-modify-write under `flock -x` on the counter
  (tests/sudo-keepalive.sh); the clock contract (+300 s per call) is
  unchanged.
- **Validation**: 3/3 green after the fix (2/3 red before, on both trees).
- **Durable rules**: fixture stub state shared across builder processes must
  be serialized (`flock`); and never run two fixture batteries at once —
  `signal-abort-lock.sh`'s survivor scan matches `--lane-job` processes
  GLOBALLY, so another session's lanes trip it (observed twice: one
  self-inflicted parallel run, one while a concurrent session ran its own
  battery). Both times the fixture was green when run alone.
- **Unproven row**: the first full battery showed `log-ownership-root.sh`
  failing with the pre-fix signature (rc=125, EACCES, no repair
  announcement) while every later run — battery-filtered and standalone —
  was green. Never reproduced; interference from the concurrent session
  during that battery is suspected. Named unproven, not fixed.

## 2026-09-23 (log ownership) — a root-mode crash poisoned the next run's logs; state ownership is now settled at write time

- **Symptom**: run A (`sudo fish build-all.fish …`, started 19:10) was killed
  mid-flight at 19:34. Run B — unprivileged `fish build-all.fish -g
  stable,core,git,third-party -s -i` at 22:33 — died in seconds:
  `✗ util-linux / dbus / libisl-git: BUILD FAILED (rc=125, 0m00s)`, each row
  preceded by fish's `warning: An error occurred while redirecting file
  '.state/logs/<pkg>.log' / open: Permission denied`. Exactly six logs were
  `root:root` (run A's in-flight set), `.state/` itself was root:root, and
  `linux-api-headers` — user-owned log — built fine.
- **Root cause**: every log open happens in the SUPERVISOR's shell, so root
  mode created files root-owned at birth: the lane-spawn
  `printf '' >"$child_log"` and `… >>"$child_log"` redirect,
  build_package's truncate, the makepkg append
  `sudo -u … makepkg >>"$log_file"` (fish opens the redirect before sudo
  drops privileges), and `tee -a` in `install_pkgs_now`. The only repair was
  `chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR"` at build_package EXIT —
  a crash window: a killed run leaves exactly its in-flight logs poisoned,
  and the next unprivileged run dies at the SAME redirect (rc=125) before
  build_package's `cannot write build log:` probe can print anything — hence
  every row claiming 0m00s. `$_STATE_DIR` appears in NO chown argument,
  which is the measured post-crash asymmetry: `.state` stayed root:root
  while `logs/` had already been repaired by an exit chown.
- **Fix — ownership is decided when a file is OPENED** (three helpers in
  `build-all.fish`):
  - `ensure_state_dirs` (startup, and at every former `mkdir -p "$LOG_DIR"`
    site): root mode sweeps `chown -R "$_BUILD_USER": "$_STATE_DIR"` —
    directories *and* files an earlier interrupted root run left behind;
    unprivileged mode refuses to run when `LOG_DIR` is not writable, naming
    the file/owner and the exact `sudo chown -R` remedy (`log_ownership_hint`).
  - `ensure_log_writable <file>` (before every state-file create, truncate or
    append): root mode repairs a wrong owner **in place**, loudly
    (`⚠ repaired root-owned runtime file:`), and creates missing files with
    `sudo -u "$_BUILD_USER" touch` — never as root, because root creation is
    precisely what poisons the next run (no fallback to root on failure).
    Unprivileged mode cannot chown, so an unopenable file is QUARANTINED to
    `<path>.stale.<epoch>.<pid>` — a rename needs only directory write — with
    a `⚠ preserved unopenable log:` announcement; the crashed run's forensics
    are moved aside, never truncated. Root mode deliberately checks OWNER
    only: real root can write a mode-0444 file, so mode is not the poison.
  - Sites wired: lane spawn (before any lane state exists; a preparation
    failure stops dispatch and is counted in `failed[]` so the run exits
    non-zero), build_package, the `install_pkgs_now` transcript (before
    pacman runs — rule-11 forensics must be recordable or the install is
    refused), `write_lane_result`'s tmp (chowned before the atomic publish —
    the `pkg rc seconds` protocol is untouched), the pacman-shim tmp, and
    `dispatcher.log`/reap/escalate/signal forensics as guarded best-effort
    (report, don't break, the run being recorded). The pacman mutex is the
    stated exception: never rename a possibly-held lock inode — root
    pre-creates it as the build user, unprivileged runs only verify readable
    (flock(1) opens read-only; measured: `flock -x` succeeds on a 0444 file).
  - `install-all.log` is a dead variable (`run_pacman_locked` never opens
    its `log_file` argument); documented at the site instead of invented.
- **Validation**: `tests/log-ownership.sh` (unprivileged quarantine contract:
  sentinel preserved under `.stale.*`, no rc=125, no redirect error, run
  green; red before the fix) and `tests/log-ownership-root.sh` (root-mode
  in-place repair: per-file non-`-R` chown naming the poisoned log, loud
  announcement, no quarantine, run green; red before the fix) — the fixture
  cannot chown to root, so the poison is a 0644 log whose owner a `stat`
  stub reports as root, which is exactly the predicate the builder tests.
  Full battery green: 43/43 fixtures on the final tree, both log-ownership
  halves included — `srcinfo-freshness` was closed by regenerating the two
  `.SRCINFO`s whose PKGBUILDs the run-B auto-sync bump had invalidated
  (`linux-firmware` 20260916, `linux-tools` 7.2.7: `makepkg --printsrcinfo`,
  the recipe-checklist follow-through); `--audit`, `--list` and three
  dry-runs (git/stable/core) green. See the 2026-09-24 harness entry for the
  `sudo-keepalive` fake-clock race and the battery-concurrency rule. Live on the real tree: `sudo chown root:` on
  `linux-api-headers.log`, then the unprivileged `-s` run quarantined it
  loudly and finished `All builds succeeded!` (rc=0, no rc=125); the documented
  `sudo chown -R zhangdm: .state` remedy then restored the whole state tree.
  Two run-A leftovers that broke `nvcheck-aggregator` were also repaired:
  `noctalia-git/pkg` and `vscodium-insiders-git/pkg` sat at mode 0111
  (owner without read → `find` EACCES).
- **Durable rule**: every `$LOG_DIR` open site must go through
  `ensure_log_writable` before the first redirect touches the file; state
  directories only through `ensure_state_dirs`; root never creates a state
  file directly; the mutex inode is never renamed. Forensics appends stay
  best-effort (guarded), everything else fails named.

## 2026-09-23 (night) — lanes died to an unnamed signal, the abort corrupted pacman, noctalia's training never ran, and zen trained on Speedometer 2.0

One report, three isolatable defects, fixed by three parallel agents.

### A. Builder: unexpected TERM, rc=125 "invalid outcome", and the lock storm they fed

- **Symptom**: a `sudo fish build-all.fish … 25..` run (started 19:33:53) had
  its dispatcher and all six lanes die **simultaneously at 19:34:01** —
  `dbus.log`, `util-linux.log`, `vencord-git.log`, `libisl-git.log`,
  `xcb-imdkit-git.log`, `texlive-texmf.log` all show `ERROR: TERM signal caught`
  mid-`git clone`/mid-`pacman -S`. The user account for exactly one interrupt
  all evening (a wrong `14..` range, ^C); for this event they did nothing.
  Follow-on: six logs of `waiting for builder pacman mutex → could not lock
  database: File exists` killed the next run in 5 s, and the recurring
  complaint was a lane raising `lane supervisor produced no valid result`
  (rc=125) *after pacman had installed successfully*.
- **Root cause chain, established from the journal, `sudo` session gantt, and
  fish history** (all runs sequential on pts/0 — no overlap):
  1. In code the dispatcher TERMs lanes only via `cleanup_active_lanes`,
     which runs **after the dispatcher itself receives INT/TERM** (the
     malformed-result branch's message appears in no log). So the dispatcher
     was signalled — by whom is **not provable post-hoc**: nothing in
     `build-all.fish`, no second run, no timer, no session teardown. One ^C
     is admitted; the 19:34:01 signal source remains unidentified, so the fix
     makes the *next* incident self-identifying instead of guessing.
  2. Lane children ran the dispatcher's `handle_interrupt` (INT+TERM bound to
     a bare flag-setter) and therefore **swallowed** signals, and a child
     killed before `write_lane_result` produced the rc=125 "invalid outcome"
     with no clue why.
  3. `stop_lane_process` TERMed every PID in the lane PGID **every 50 ms,
     SIGKILL at ~0.5 s**. A pacman caught in that blast was re-signalled
     while unlocking, so it never removed `/var/lib/pacman/db.lck` (dir mtime
     19:34; cleaned by hand via pkexec at 19:34:33) — the stale lock is what
     made every later install hard-fail. Independently, makepkg's own `-s`
     dependency installs run `pacman` **outside** the builder flock (six
     dep-pacmans raced the builder's `pacman -U` at 19:33:58; `util-linux.log`
     shows pacman politely waiting, the `-U` side failing).
- **Fix (`build-all.fish`)**:
  - Handlers split: `gsa_on_int/term/hup` → `gsa_handle_signal`. Dispatcher
    mode appends timestamped `[DEBUG-gsa-term] signal: … (pid, ancestry)` to
    the new **`$LOG_DIR/dispatcher.log`** then sets `_INTERRUPT_HANDLED` as
    before; **HUP is newly bound** (it used to orphan live lanes silently).
    Lane mode (marker set at `--lane-job` entry) writes an honest result
    (`129/130/143`) + `lane child received <SIG>` to the package log and
    re-raises — fish's `exit` inside a handler always yields rc 0, so the
    child erases its handler and re-raises; INT is the exception (fish exits
    0 even handler-less), which is why the result *file* carries the honest
    130: the dispatcher reads only that file.
  - `stop_lane_process`: **one** TERM sweep, deadline-based `_LANE_STOP_GRACE_S
    = 30` (0.1 s polls that `ps` cost cannot stretch), single SIGKILL of
    survivors afterwards, escalations logged to dispatcher.log *and* the
    package log; zombies excluded from `lane_processes`. The WHY-comment
    cites this incident: the old 50 ms blitz re-interrupted pacman's unlock.
  - Reap forensics: a missing/malformed result now records the lane pid's
    `ps` state plus the escaped raw result bytes (and an empty pid list no
    longer silently skips the statement — fish drops commands whose
    substitution failed).
  - `check_pacman_lock`: holder probe (PATH-stubbable `pgrep` on
    pacman/packagekitd/pamac) with recovery instructions, **never removes
    while a holder is alive**; removal only after two idle probes 1 s apart,
    loudly. Path from `pacman-conf DBPath` (fallback
    `/var/lib/pacman/db.lck`) so fixtures never touch host state; hidden
    `--stale-lock-check <path>` mode is the fixture seam (no new `GSA_*`
    knob — the builder still honours exactly seven). Wired into
    `check_runtime_prereqs` (refuse `-i`/`-ia` while busy, warn build-only),
    `install_all`, after `cleanup_active_lanes`, and `run_pacman_locked`'s
    failure path. *Reconciliation*: the older report-only todo said "NEVER
    remove"; the user's later explicit approval chose idle-removal — both are
    honored (report always, remove only when provably idle), recorded in the
    code comment.
  - `ensure_pacman_shim`: install runs generate `$LOG_DIR/.pacman-shim` (0755,
    baked absolute mutex, `flock -x -w 300 /usr/bin/pacman "$@"`) and
    `lane_job` exports `PACMAN=<shim>` (makepkg honours `PACMAN=${PACMAN:-pacman}`,
    verified at `/usr/bin/makepkg:1203`) — makepkg's dep installs now
    serialize on the builder mutex. Leaf/no-deadlock: `run_pacman_locked` is
    flock→pacman directly.
- **Validation**: `fish -n`, `--audit`, `--list`, dry-runs git/stable/core
  (58/29/41) all pass; new fixtures `tests/signal-abort-lock.sh` (stale/busy
  lock probe, honest `143` result instead of rc=125, INT/TERM/HUP → exit 130 +
  named signal in dispatcher.log + exactly-one-TERM + zero survivors,
  busy-preflight `-i` refusal, static 30 s/one-TERM/KILL-after-grace shape)
  and `tests/pacman-mutex-shim.sh` pass; manual PTY proofs: interrupt exits
  130 with SIGKILL at exactly +30 s. `tests/dashboard.sh` case C was rebased
  (6 s → 60 s deadline, stub ticks 300 → 900): the old bound encoded the very
  TERM-blast being removed — the stub lanes now run ~45 s so the post-grace
  KILL, not their own loop, is what ends them.
- **Durable rules**: a run's signal story must be readable after the fact —
  dispatcher.log names the signal, the result file names the lane's death;
  rc=125 without forensics is a bug. Never blast-TERM a process group that
  may hold a package database lock: one TERM, grace, then KILL. Every pacman
  invocation a lane can reach (yours *or* makepkg's) goes through the one
  flock.

### B. noctalia-git: the training sway died on `sun_path`, so PGO never trained

- **Symptom**: `==> WARNING: PGO profile incomplete (1 .gcda files)` then
  `ERROR: Value "none" … not one of the choices. Possible choices … "off",
  "generate", "use"` → `A failure occurred in build()`.
- **Root cause**: `_pgo_train` sandboxed `XDG_RUNTIME_DIR` under the deep
  `$srcdir/pgo-work`; sway's `sway-ipc.<pid>.<rand>.sock` then exceeded the
  **108-byte Unix `sun_path`** (`src/pgo-work/sway.log`: `Socket path won't
  fit into ipc_sockaddr->sun_path`; journal shows the training sway SEGVing at
  19:29:48 and 19:33:20 — the second was the user's manual `makepkg -si`).
  Dead sway → no GUI workload → 1 `.gcda` → the fallback's
  **`-Db_pgo=none`, a value meson does not have** (the enum is
  off/generate/use) hard-failed the build.
- **Fix**: fallback → `-Db_pgo=off`; `XDG_RUNTIME_DIR` now
  `mktemp -d /tmp/nct-pgo-rt.XXXXXX` (700, removed on exit — house precedent
  mold-git/easyeffects-git train under `/tmp`); the training tree launches
  under `setsid` and is torn down as a **group** (TERM → 5 s bounded grace →
  KILL) so no stray sway survives; CLI subcommands run `env -u WAYLAND_DISPLAY`
  so they always take the exit-through-main() path that flushes profiles.
  `pkgrel=2`, `.SRCINFO` regenerated.
- **Validation**: acceptance build `fish build-all.fish --no-deps noctalia-git`
  exit 0 (7m36s): **315 fresh `.gcda`** (baseline cleared first), log says
  `PGO profile collected (315 …)` + meson `b_pgo : use`, zero `sun_path`
  errors in the new sway.log, no journal SEGV, no strays, no `/tmp/nct-pgo-rt.*`
  leftovers. Fixtures `tests/noctalia-pgo.sh` + `tests/noctalia-pgo-train.sh`
  pass and were red-checked against the old PKGBUILD.
- **Pitfalls pinned**: sandbox paths have a **length budget** — anything a
  compositor/socket puts in `XDG_RUNTIME_DIR` must fit `sun_path`; and stock
  `update_pkgver()` rewrites the PKGBUILD and **resets `pkgrel=1`** whenever
  `pkgver()` moves — for `-git` recipes bump `pkgrel` after the first
  post-sync build (this build moved r5568→r5570 and undid the bump once).

### C. zen-browser: profile collection ran deprecated Speedometer 2.0

- **Symptom/decision**: the PGO profile phase's workload entry was the
  deprecated **Speedometer 2.0** with a single scenario; user decision
  *sp3-only* — replace it, keep everything else.
- **Audit (1.07 GB `zen.source.tar.zst`, 1.22.3b = FF156 base)**: the tree
  *already* carries a correct SP3 setup — `profileserver.py` starts
  `sp3_httpd` on port 8000 with docroot `third_party/webkit/PerformanceTests/Speedometer3`
  (a real 62 MB tree; `params.mjs` honours `startAutomatically`) plus the
  `http://localhost:8000/index.html?startAutomatically=true` entry with the
  120 s extended timeout. SP3 **requires a root path** ("will fail if it is
  not"), which is exactly why the second httpd exists — so the planned
  relative `webkit/…` entry would have been wrong. The fix is therefore a
  deletion: `0007-pgo-speedometer3.patch` removes only the SP2 entry (zero
  additions), applied in `prepare()` after 0004/0005; `pkgrel=2`.
- **Bonus finding**: `sha256sums[0]` was still the **1.22.1b** sum — commit
  `5f4078b` (update zen upstream track) bumped `pkgver` without re-pinning the
  tarball, so the recipe could not have fetched at all. Re-pinned to
  `5dafd8ae…`, verified against **GitHub's server-side asset digest** (exact
  hash + 1,068,387,924 size — anchored, not TOFU); `.SRCINFO` regenerated
  (was stale at 1.22.1b too). Root `.gitignore:21 *.tar.*` already covers the
  fetched tarball.
- **Validation**: `tests/zen-pgo-workload.sh` + `tests/zen-pgo-speedometer.sh`
  pass (red-checked on drift), real-tree `patch -Np1 --dry-run` rc=0,
  `bash -n` clean; the full three-pass build is deliberately left to the
  user's next big run (the fetched tarball is kept as its resume cache).
- **Durable rule**: an upstream-track bump that changes `pkgver` must re-pin
  every version-spelled sum in the same commit, and a benchmark swap must
  check *root-path* requirements before choosing a URL shape.

### D. Battery and cross-lane integration

Three agents worked disjoint file sets (`build-all.fish`+fixtures;
`packages/git/noctalia-git`; `packages/third-party/zen-browser-pgo`+fixtures),
each running only its filtered fixtures; the parent ran the **full battery
once: 41 fixtures** — 40 pass, `recipe-sources.sh` flags the new untracked
`0007-…patch` until it is committed (by design: sources must be committed).
The sweep also caught a **pre-existing** stale `.SRCINFO` on `gcc-snapshot`
(from `8dd4f46 update gcc upstream track`) — regenerated mechanically.

## 2026-09-23 — vencord-git initiates injection: wrapper + official-compatible shim, and the scriptlet phases have no fallback

- **Symptom**: phase 1 (`f5811c1`) shipped the payload only — the installed
  files were inert, exactly the "stale scripts" reported. Worse, the host had
  already been injected by the *official* installer (root-owned shim written
  10:58 requiring `~/.config/Vencord/dist/patcher.js`, its own downloaded
  copy), so nothing at all pointed Discord at the pacman-owned
  `/usr/lib/vencord`.
- **Root causes (three)**:
  1. the official installer cannot be repointed at a pacman payload — it
     downloads its own Vencord build into `~/.config/Vencord/dist` and would
     hit EACCES writing under `/usr/lib` as a user;
  2. this host's `discord` is the self-updating bootstrap — every self-update
     lands a pristine `app-*/resources` tree, so any one-shot patch dies on
     the next update;
  3. **pacman has no scriptlet-phase fallback**: an upgrade calls
     `pre_upgrade`/`post_upgrade`, never `pre_install`/`post_install`. Proven
     live — the pkgrel=2 upgrade executed nothing (no output, desktop
     unwrapped) even though `pacman -Qp` reported "Install Script: Yes"
     (pacman 7's `.PKGINFO` has no `install =` key at all; the `.INSTALL`
     archive member is the scriptlet, and PKGBUILD(5) names each phase).
- **Fix (`pkgrel=3`, all in `packages/git/vencord-git/`)** — the initiation
  contract:
  - `vencord-inject` (python, stdlib only): byte-equivalent port of the
    official `WriteAppAsar` — verified against the *live* official shim
    (identical framing `4I` header, identical JSON shape, round-trip parse).
    `inject` renames `app.asar`→`_app.asar` on a pristine tree and always
    rewrites the shim to `require("/usr/lib/vencord/patcher.js")`, so it is
    idempotent **and** adopts an official-installer patch in place;
    `uninject` restores the original bytes; `status` exits 0 only when the
    newest `app-*` of every `discord*` channel under `$XDG_CONFIG_HOME` is
    injected against the payload. Root policy mirrors upstream: never bare
    root, `SUDO_USER`/`DOAS_USER` HOME adopted, root-written files chowned
    back (verified: env survives pacman's scriptlet sandbox).
  - `discord-vencord` wrapper: re-asserts injection on **every launch** —
    this is what survives Discord self-updates — then `exec`s the stock
    launcher with args intact; injection failure is non-fatal.
  - stock `discord.desktop` `Exec=` redirect **without shipping that path**
    (a shipped file would file-conflict with the `discord` package):
    `post_install`/`post_upgrade` wrap it, a Path-trigger libalpm hook
    re-wraps after every discord install/upgrade (house gtk4/glib2 pattern,
    format compared), and `pre_remove` — the house cleanup phase (7
    `pre_remove` vs 2 `post_remove` in this repo; `post_remove` runs after
    the package's own files are already deleted) — unwraps **and** unpatches
    so a removal never leaves a shim requiring a missing `patcher.js`.
  - `depends=('python')`, four local sources sha256-pinned, `.install` and
    hook committed as recipe assets.
- **Validation**: `tests/vencord-recipe.sh` now pins the initiation assets,
  the `python` depend, the no-client-hard-depends rule, `pre_remove` cleanup
  and **the `post_upgrade` presence** (the no-fallback lesson); the new
  `tests/vencord-inject.sh` proves inject/status/adoption/idempotence
  (sha-stable)/interrupted-state repair/byte-exact uninject/fresh-bootstrap
  no-op/desktop wrap+restore idempotence/absent-file no-op/wrapper
  arg+exec-through on scratch `$XDG_CONFIG_HOME` trees; full battery
  **PASS 34 → 35**; then the **full live lifecycle on this host**:
  `pacman -R` → `pre_remove` restored the pristine `app.asar` and the stock
  `Exec=`, fresh `-U` → `post_install` message + wrapped `Exec=` + live shim
  repointed to `/usr/lib/vencord/patcher.js` (`status` rc 0), same-version
  `-U` → `post_upgrade` re-ran the same body with sha-identical results;
  `pacman -Dk` clean. Two measurement traps while testing: a `pacman -R`
  without `--noconfirm` aborts silently at the prompt (read the state, not
  the pipe's exit code), and a log filter keyed on the word `upgrading`
  misses pacman's actual `reinstalling` line.
- **Rules**: (1) the payload is inert until injected — initiation is part of
  this package's job, not the user's; (2) any `.install` action that must
  happen on upgrades needs the upgrade-phase function names; (3) scriptlets
  must be exercised through real transactions — install **and** upgrade
  **and** remove, because each phase is a separate entry point; (4) never
  ship a file at another package's path — redirect through a Path-triggered
  hook that edits content in place.

## 2026-09-23 — new `app` group: a TTY multi-select prompt as a layer in front of the normal selection pipeline

- **Decision (user-confirmed)**: isolate a sixth logical group `app` for
  optional applications drawn from the git/third-party/stable categories —
  mechanism only, membership wired separately. Four confirmed behaviors:
  (1) app packages are **leaf builds, never `expand_deps`** — they are ABI
  *consumers*, so installed dependencies are assumed current and a local
  dependency edge must not drag a costly chain into the run; (2) non-TTY stdin
  skips the prompt and builds the whole group; (3) the prompt is a
  fish-native numbered toggle loop (no fzf/gum dependency); (4) it triggers on
  real builds and `-n` only — `-l` lists the whole group, unprompted.
- **Design**: `prompt_app_selection` prints the menu on **stderr** (stdout is
  the data channel the seam captures) and returns checked-only, or the whole
  group when everything is unchecked (all-unchecked = build all; `q` aborts
  non-zero). The seam sits immediately after `resolve_group` in the `-g` loop:
  whatever comes back becomes that group's contribution to `build_list`, and
  topo sort, ranges, lanes, install are the unchanged existing pipeline.
  Group selections were *already* leaf selections — `expand_deps` only runs
  for positional names — so requirement (1) needed pinning, not new blocking
  logic.
- **Bug found while testing (empty-group phantom)**: fish `printf` with **no
  arguments still runs the format once**, so an empty `app.list` produced a
  phantom `""` member: `resolve_group` emitted one newline, `topo_sort` read
  `""` as a package and reported `blocked: (empty)`, and the final
  `printf '%s\n' $sorted` re-injected it at the output seam ("Total: 1
  packages" with an empty entry). Fixed in all three places: the `app` case
  prints only when non-empty, `topo_sort` drops empty input tokens, and its
  output is guarded. An empty `app.list` now warns (`populate
  config/groups/app.list`) and exits non-zero with the standard no-selection
  error.
- **Fixture learnings (`tests/app-group.sh`, PTY via `script -qec`)**:
  (a) emptying `app.list` with single-membership members trips the loader's
  "listed in no group" rule *before* the seam — mirror reality (members keep
  their category group) by moving them aside for that scenario; (b) fish's DA
  terminal query has no responder under `script`'s PTY and **consumes the
  piped toggle input as bogus query replies** (the `2` vanished mid-exchange,
  the next read hung until timeout) — run the PTY scenarios with `TERM=dumb`,
  which skips the queries while the FD-level `test -t 0` the seam keys on
  stays true; (c) the PTY slave maps `\n`→`\r\n` (ONLCR), so extracted fields
  compare as `app1\r` — strip CR before string comparisons. Also: an inverted
  `[ ! -f ] && fail` assertion "passed" whenever the file was correctly
  absent — assertions of absence need the positive form.
- **Wiring**: six group files exactly (`app.list` starts comments-only);
  `project-config.sh` now pins six, the ten synthetic-workspace fixtures loop
  six names, and the loader/resolve/help/audit/bare-list enumerations all
  gained `app`. No auto `-i` for app (unlike core — consumers, not ABI
  providers).
- **Validation**: `fish -n`; `--audit`, `--list`, `-n -g git|stable|core`
  green; empty `-n -g app` refuses with the hint; `bash tests/run-all.sh`
  (full battery, incl. the new fixture — loader strictness, empty-list
  refusal, non-TTY whole-group + no-expansion pin, `-l` silence on a PTY,
  Enter/toggle/`q` on a PTY, combined `-g app -g git`, real-build subset).
- **Durable rules**: `config/groups/` holds exactly six files; `-g app` is a
  leaf selection whose prompt is a front-layer filter (never re-plumb the
  pipeline for it); the prompt reads stdin only after `test -t 0`, so pipes
  can never hang.

## 2026-09-23 — added `vencord-git`: desktop standalone Discord client mod in the git group

- **Scope decisions (user-confirmed)**: package https://github.com/Vendicated/Vencord
  as `packages/git/vencord-git` with the **desktop standalone artifacts only**
  (`pnpm buildStandalone` → the six bundles → `/usr/lib/vencord`); no web build
  and no browser-extension outputs. `check()` runs `pnpm testTsc` (type-check
  only — upstream's full `pnpm test` also re-runs eslint, stylelint and the
  plugin-manifest generator on every git bump). Fixture, host IgnorePkg entry
  and docs shipped in the same change.
- **Recipe**: root `pnpm install --frozen-lockfile` — Vencord's root
  `pnpm-workspace.yaml` declares `packages/*`, so a *subdirectory* install
  would need the workspace-isolating flag (the 2026-09-18 logseq incident);
  there is no subdirectory install here, and `tests/vencord-recipe.sh` pins
  that guard's absence. `arch=(any)`, `provides`/`conflicts` = `vencord`, and
  **no hard depends**: `discord`/`vesktop` are optdepends because the loader is
  a host choice — a deliberate divergence from the AUR recipe, which
  hard-depends on `vesktop` (not installed here). `package()` writes the
  `package.json` shim beside the payloads (loader contract, AUR parity).
- **Optimization (MEMORY §4 Electron/JavaScript bullet)**: `options=('!strip'
  '!debug' '!lto')` — nothing ships compiled except esbuild's prebuilt helper —
  plus the house ccache + mold probe for any incidental native addon, and no
  hard-coded ISA/optimisation flags of its own. Upstream honours
  `SOURCE_DATE_EPOCH` (`BUILD_TIMESTAMP`), so makepkg's stamp is baked in.
- **Wiring**: one `packages.map` record, one `git.list` member, one lone
  `dependencies.conf` record (no workspace edges — git/nodejs/pnpm come from
  the host repos). `build-all.fish` needed **no code change**: the loader
  revalidates the whole map/graph/sort on every invocation, and `--audit`,
  `--list` and the three group dry-runs went green with the record in place.
- **Host**: `/etc/pacman.conf` backed up to
  `/etc/pacman.conf.20260923-vencord.bak` first, then `IgnorePkg =
  vencord-git` inserted **inside `[options]`** (after the last IgnorePkg
  line; a line in a repo section is silently dropped). Closure check per the
  2026-09-19 audit — `comm -23` of the `.SRCINFO` **pkgname set** vs
  `pacman-conf IgnorePkg` — is empty again. Note the pkgbase-only names
  `fcitx5-qt-git` and `texlive-texmf` are *not* gaps: they are non-installable
  split bases whose outputs (`fcitx5-qt5/6-git`, 24 `texlive-*` splits) are
  covered.
- **Counts were already stale before this change**: the README claimed
  126 recipes / 129 memberships / git 56, but measuring (find PKGBUILD,
  group-line sums) showed 127 / 130 / 57 pre-change — an earlier addition
  never updated them. Corrected to the measured post-change truth:
  **128 recipe directories, 131 group memberships, git 58** (stable 29,
  core 41, misc 1, third-party 2; `hip-runtime`/`hsa-rocr`/`openssl` are
  deliberately double-listed, so 131 sums to 128 distinct members).
- **Validation**: `bash -n`; `makepkg --printsrcinfo`; `--audit`/`--list`/
  dry-runs for git, stable and core all rc=0; full fixture battery **PASS
  (33 fixtures**, 32 → 33 with `tests/vencord-recipe.sh` pinning assets,
  source, stage order, the optimisation standard, topology membership,
  gitignore visibility and `.SRCINFO` freshness); a **real build**
  (`--no-deps --no-sync vencord-git`) finished green in 1m54s — makepkg
  wrote `pkgver=1.15.6.r4.g59a542865` back into the PKGBUILD, and the
  archive `vencord-git-1.15.6.r4.g59a542865-1-any` (1.6 MB) was inspected:
  all six bundles + css/maps/`.LEGAL.txt`, the shim, LICENSE and README are
  present, and `.PKGINFO` carries `conflict = vencord`, the optdepends and
  the makedepends. **No install was performed.**
- **Rules**: (1) `~/.makepkg.conf` sets `BUILDENV=(… !check …)`, so makepkg
  skips **every** recipe's `check()` on this host — the stage was validated
  by running `pnpm testTsc` manually against the built tree (rc=0, 13.5 s);
  do not read a missing `Starting check()...` line as a recipe defect.
  (2) Never edit the README/MEMORY counts from memory — measure first; the
  baseline was already off by one. (3) pnpm's `configured to use 11.9.0 …
  your current pnpm is v11.26.0` warning is cosmetic (install, type-check
  and build all proceeded).

## 2026-09-20 — `build-all.fish` audit: the harness was misreporting its own success

- **Scope**: a full static read of `build-all.fish` (3561 lines, 73 functions)
  against the documentation that describes it, plus the fixtures that were
  supposed to pin it. Baseline `75bd2f6`. Fixture count 26 → 32. Repairs only:
  no behaviour was redesigned, and no real build was run, so **every finding
  here is proven by static reading or by a fixture, never by a completed
  build**.
- **Root cause, one family**: almost every defect was the builder making a
  **claim about its own work that was not true**. Not a crash and not a wrong
  build — a false report of success, of verification, or of coverage. That
  shape is why they survived: a check that cannot fail its caller reports
  success whether or not the thing it checks happened, and nothing downstream
  contradicts it.

Findings, in the order they were fixed:

1. **`-i` reported success while pacman never ran** (`8a7a672`).
   `list_split_pkgs` read `pkgver=` with `grep | cut | string trim -c "'"`,
   which keeps a trailing PKGBUILD comment, so the split-archive pattern
   matched nothing; `install_pkgs_now` then treated *no arguments* as success.
   Reproduced end-to-end before touching anything: the run printed "All builds
   succeeded!" and `pacman.log` stayed empty. Two defects hiding each other —
   neither is visible alone. Fixed with `pkgbuild_var()`, which parses a *value*
   rather than text (strips an unquoted trailing comment — `x=1#2` is one word
   in bash, so the strip requires leading whitespace — and either quote style,
   and whose every stage is fed by the pipeline above it so no stage can fall
   back to reading stdin, which interactively is the terminal). Used for
   pkgver/pkgrel/pkgbase in `list_split_pkgs` and `sync_stable_version`, where
   the same defect bit from the other side: a trailing comment made an
   already-current stable recipe differ from the repo version on **every** run,
   so it was rewritten each time and a garbage operand reached `vercmp`, the
   comparison the never-downgrade guard rests on. `install_pkgs_now` now fails
   loudly on an empty list.
2. **Invalid project config named nothing** (`ed2d444`). `load_project_config`
   returned 1 silently from six places, and the caller can only say "project
   configuration is invalid under <dir>" — so a malformed record, an unknown
   package or dependency, an ungrouped package, or a missing file all left the
   user bisecting their own config by hand. Each path now names the offender.
   The numeric/parallelism defaults also named the internal variable
   (`_MEMORY_PER_JOB_GIB`) instead of the key the user actually wrote
   (`memory_per_job_gib`).
3. **The resume command did not resume what was run** (`434940e`). The failure
   summary's resume line carried only `--lanes/--jobs/--intensity`, so resuming
   a run made with `-i` rebuilt the remaining packages **without installing
   them** — the rule-11 ABI hazard `-i` exists to prevent — while the tip
   printed directly beneath it said "add -s so already-built pkgs are skipped".
   It now mirrors `--install`, `--no-deps`, `--no-sync` and
   `--allow-broken-rustc`, and invents nothing that was not passed.
   `read_group_config` rejected a bad entry with a bare `return 1`, so the only
   message was "invalid package group: git" beside a 56-line list — and a
   *missing* file was reported as *invalid*. It now names file and line (bad
   character, unknown package, duplicate), and says "missing" when that is what
   happened.
4. **The interactive dashboard had no coverage at all** (`4c818ab`). ~200 lines
   of terminal control; `_OUTPUT_INTERACTIVE` is gated on `test -t 1` and every
   other fixture pipes the builder, so nothing had ever executed it.
   `tests/dashboard.sh` drives the real thing under a pty (`script -qec` with a
   controlled `stty cols`), and measures rendered rows with the same
   `string length --visible` production uses, so escapes and multibyte icons
   count the way the builder counts them. Also de-duplicated the log path
   (finding 8 below).
5. **An invariant three documents state had no fixture** (`e64a3ff`). "Core
   runs solo" is asserted in README, docs/architecture.md and MEMORY.md;
   `tests/scheduler-intensity.sh` pinned only the printed plan numbers, so
   `GSA_CPU_THREADS`/`GSA_MEMORY_GIB` covered the formula, not the behaviour.
   New `tests/scheduler-core-solo.sh` measures observed concurrency from the
   stub's own timestamps.
6. **The checksum verification the stable sync disables was invisible**
   (`e417a7e`). `sync_stable_version` rewrites a stable recipe's pkgver/pkgrel
   in place and deliberately leaves the committed sums describing the previous
   version, so `build_package` adds `--skipchecksums` for that build — and
   those sources are built, and with `-i` installed, without a committed sum.
   `--skipchecksums` appeared **exactly once in the whole repository**, on the
   line that adds it: not in `--help`, not in `build-guide.md`, not in
   MEMORY.md. In the shipped flow it was not merely undocumented but
   *unreachable*: `build_package` has one call site (`lane_job`, always
   `quiet_flag=1`), every lane redirects its stdout/stderr into the per-package
   log, and the single echo naming the argv is gated on the non-quiet flag that
   nothing passes — so the flag reached neither the terminal nor any log. The
   trade is deliberate (skipping the check is what makes a synced build
   possible), so the fix is **disclosure, not a behaviour change**: the package
   log states it unconditionally and ungated, because a multi-lane run's log is
   the only record it leaves; `--help` explains it under `--no-sync`;
   `build-guide.md` gains a section covering the rewrite, the skipped checks,
   the fact that signature checks are **unaffected** (`--skipchecksums` is not
   `--skippgpcheck`), and how to restore verification.
7. **Coverage added that was not a defect**: `sync_stable_version` had never
   been exercised by any fixture. `tests/stable-sync-checksums.sh` pins the
   rewrite itself (so the rest cannot pass vacuously), the flag reaching
   makepkg's argv, the disclosure in the log, and — in a second run — that
   `--no-sync` disables all three, so the message cannot rot into unconditional
   noise.
8. Duplicate report, not a defect: the BUILD FAILED / "Last lines" / `-i` hint
   block appears twice, but the two paths are mutually exclusive by
   `_OUTPUT_INTERACTIVE`. Left alone.

- **Method, and the part worth keeping**: every fixture was **falsified before
  it was trusted**. `git stash push -- build-all.fish`, run, `git stash pop`;
  the fixture must fail on the pre-fix builder. Two of them were wrong first
  and the failure is the instructive part:
  - `tests/dashboard.sh`'s interrupt case originally asserted "no lane child
    survived" by grepping `ps` argv for the sandbox makepkg path. Replacing
    `lane_processes` with something that cannot signal anything left it
    **passing** — so it measured nothing. Cause: the builder execs makepkg by
    **bare name** (`bash <dir>/bin/makepkg`), so the grep matched the fixture's
    own command line. Lanes are now identified by recorded PID (`kill -0` plus
    a `Z`-state check, the way `lane_pid_alive` decides it). Second cause, more
    important: "nothing survived" is not a property of `stop_lane_process` at
    all — the function ends in `wait $lane_pid`, so even a builder that signals
    nothing returns only once its lanes finished by themselves. The property
    that matters is **promptness**; the stub now runs 15 s and ignores TERM, so
    a builder that waits instead of killing overruns a 6 s deadline, and the
    SIGKILL escalation in `stop_lane_process` is genuinely exercised.
  - The core-solo invariant needed **two scenarios**, because each direction
    passes while the other's guard is removed. Uniform stub durations were
    tried first and were wrong: every lane frees in the same poll, core is
    dispatched into an already-idle pool and the guard is never reached. Phase
    A needs staggered durations **and** an asserted precondition that core was
    actually held back, plus a baseline that two normal packages overlapped, so
    "core never overlapped" cannot be true for the wrong reason. Phase B places
    core first and requires the other lane to stay idle with work ready.
- **Rules recorded** (MEMORY.md §1.18 and §6): a *lowered guard must be
  announced where the record is*; and the audit method — **grep a
  security-relevant flag for its documentation, in both directions**.
- **Validated**: `fish -n`; `--audit`; `--list`; dry-runs for git/stable/core;
  `bash tests/run-all.sh` 32/32 PASS.
- **Left open, deliberately**:
  - the `--skipchecksums` **policy** question — should a synced stable build
    refresh the sums (`updpkgsums`) instead of skipping verification? That is
    the owner's decision, not the auditor's, and it is the one remaining hole
    under finding 6.
  - an unreproduced `tests/sudo-keepalive.sh` flake: it failed once inside a
    battery and then passed 5/5 isolated, 3/3 under load and 32/32 twice. Its
    failure text was lost to `tail` (the runner prints a failing fixture's
    output *before* the summary, so piped output discards the only evidence).
    The hypothesis — the fixture installs a stub `date` advancing 300 s per
    call, so assertions counting dispatcher polls are load-sensitive by
    construction — is recorded, not fixed.
  - `install_all`'s `install-all.log` is dead: `run_pacman_locked` ignores its
    `-a log_file`, and all four call sites redirect at the call site. Writing
    it would either hide pacman output or add a `tee`; left alone.
  - `assign_group` has no `case '*'`; unreachable today, recorded as latent.

## 2026-09-20 — cmake-git's PGO phase 2 never ran: the configure cache, not the rebuild, holds the flags

- **Symptom**: the queued rebuild of `cmake-git` — the fix for the five
  instrumented installed files — **failed 100 % of the time**, aborting inside
  its own `package()` guard with "final package still contains profile
  instrumentation" for `cmake`, `ccmake`, `cpack` and `ctest`, while the
  installed instrumented build (4.4.3.936, built 2026-09-07) stayed in place.
  Read as a machine-load or environment problem it made no sense: the run had
  the whole host.
- **Root cause**: `build()` ran PGO as two phases, and phase 2 could not work.
  Phase 1 exports `-fprofile-generate` and runs `./bootstrap`; phase 2 only
  swaps the flags in the exported variables
  (`${CFLAGS/-fprofile-generate/-fprofile-use}`) and runs `make clean; make`.
  But **CMake reads `CFLAGS`/`CXXFLAGS`/`LDFLAGS` once, while it initialises the
  cache**, and phase 1's `./bootstrap` wrote `CMakeCache.txt` with the phase-1
  flags. `make clean` does not remove that cache, so the final link line still
  read `-fprofile-generate` and the payload stayed a phase-1 build. Phase 1 did
  its job — the log records `Profile data generated: 755 .gcda files`.
- **Proven, not inferred**: `CMakeCache.txt` still read
  `CMAKE_CXX_FLAGS:STRING=… -fprofile-generate` after the "phase-2" rebuild, and
  the final executable link line in the build log still carried
  `-fprofile-generate`. Reproduced in ~10 s on a scratch CMake project: with the
  cache present, changing the environment changes nothing; **even re-running the
  configure step with the cache in place still ignores the environment**; only
  dropping `CMakeCache.txt` (or passing `-DCMAKE_C_FLAGS=` explicitly) makes the
  new flags take effect.
- **Fix, first form (refused by the build — kept here because the reason is the
  useful part)**: factor the bootstrap invocation into a `bootstrap_cmake()`
  helper and make phase 2 `make clean` → `rm -f CMakeCache.txt` →
  `bootstrap_cmake` → `make`. The re-bootstrap was wrong: `./bootstrap` compiles
  the bootstrap CMake out of the same sources, so running it a second time under
  `-fprofile-use` recompiles those objects against the profiles phase 1 produced
  *for a generate-mode build* and dies on
  `-Werror=coverage-mismatch` ("source locations … have changed, the profile
  data may be out of date") in `Bootstrap.cmk/Makefile`. The build log shows
  phase 1 fine (`Profile data generated: 755 .gcda files`) and the failure
  immediately after, in `bootstrapping CMake`.
- **Fix, second form (also refused — the warning trap)**: phase 2 becomes
  `make clean` → `rm -f CMakeCache.txt` → `make`, deleting the cache so the
  generated `Makefile` reconfigures by itself on the next invocation, reading the
  phase-2 environment. Measured on a scratch project rather than assumed:
  `-DFOO=1` at configure, then `rm CMakeCache.txt` and `make` with `-DFOO=2` →
  `flags.make` contains `-DFOO=2` and the build succeeds. **It failed anyway**,
  one step further on: `make_unique`/`unique_ptr`/`filesystem` all answered
  "no" during the reconfigure, so configure aborted with "The C++ compiler does
  not support C++11 (e.g. std::unique_ptr)". `Source/Checks/cm_cxx_features.cmake`
  decides a feature is missing when the probe output matches
  `"(^|[ :])[Ww][Aa][Rr][Nn][Ii][Nn][Gg]"` — **any** warning counts as
  unsupported — and the probes are compiled fresh, so `-fprofile-use` warns
  `-Wmissing-profile` ("profile count data file not found", the paths are new)
  on every one of them. The check log shows the probes *building and linking
  cleanly*; only the warning made CMake answer "no".
- **Fix, third form (also refused — the profile mismatch)**: phase 2 keeps the
  cache purge **and** appends `-Wno-missing-profile`. That is the one warning the
  probes legitimately produce, and suppressing it let the reconfigure reach a yes
  — but the build then died at 5 % on
  `Source/kwsys/ProcessUNIX.c.o`, in *both* the C and the C++ target:
  "number of counters in profile data for function `cmsysProcess_AddCommand`
  does not match its profile data (counter `arcs`, expected 15 and have 16)
  [-Werror=coverage-mismatch]". GCC treats a mismatched profile as an error by
  default, and the mismatch is intrinsic to the two-phase scheme rather than
  something in this tree: `-fprofile-use` enables passes the `-fprofile-generate`
  phase did not run, so a handful of functions come back with a different arc
  count.
- **Fix, fourth form (the purge itself was wrong — measured, then replaced)**:
  keeping the purge and adding both flags produced a payload that *built* clean
  (0 baked paths in all four binaries) and then failed `package()` on an
  unrelated symptom: the phase-2 configure had printed `-- Using bundled: CURL
  EXPAT …` where phase 1 printed `-- Using system-installed: …`, and the tree
  landed under `pkg/usr/local/…`. Root cause: `CMakeCache.txt` is not "the
  flags" — it is every decision `./bootstrap` made, so `--prefix=/usr`,
  `--mandir`/`--docdir`/`--datadir`, thirteen `CMAKE_USE_SYSTEM_*` entries and
  `-fuse-ld=mold` all reverted the moment it was deleted. The exported
  `CFLAGS`/`CXXFLAGS`/`LDFLAGS` in this form were dead code for the same reason
  the original code was: with a cache present, CMake ignores the environment.
- **Fix, final**: rewrite the flag strings *inside* the cache and force a
  regeneration — `sed -i 's/-fprofile-generate/-fprofile-use
  -Wno-missing-profile -Wno-error=coverage-mismatch/g' CMakeCache.txt`, fail the
  build if any `-fprofile-generate` survives, `touch CMakeLists.txt`, then
  `make clean` → `make`. Pre-flight on the real tree: the reconfigure took
  **3.1 s** (the cached feature answers mean no probe re-runs at all, which also
  demotes `-Wno-missing-profile` from required to backstop), and it regenerated
  **65/65** `flags.make` and **44/44** `link.txt` to the use-flags with **0**
  left at generate, kept `CMAKE_INSTALL_PREFIX:PATH=/usr` in both the cache and
  `cmake_install.cmake`, kept mold on the link line and all thirteen
  `CMAKE_USE_SYSTEM_*` entries. `-Wno-error=coverage-mismatch` is what lets the
  build finish, at the cost of compiling the mismatching functions (kwsys
  process handling) without profile data — every other function keeps the real
  profile, and the payload is uninstrumented either way, which is the point of
  the phase. `make clean` stays, for a second reason: regenerated rules do not
  invalidate phase-1 objects, so without it `make` would relink the instrumented
  ones against fresh sources.
- **Validation**: `bash -n` on the recipe; `.SRCINFO` freshness fixture green.
  The real build is the remaining proof and is deliberately **not** run as a
  syntax check — `strings -a /usr/bin/cmake | grep -c '\.gcda'` must reach 0 for
  `cmake`/`ccmake`/`cpack`/`ctest`.
- **Rule**: this is the **CMake twin of the Meson staleness rule** — a
  configure-time argument cache survives a rebuild, and `make clean` is not a
  reconfigure. Replace the cached values and make the build system regenerate;
  do **not** delete the cache, which carries the install prefix, the install
  directories and the dependency selection as well as the flags, and losing them
  is invisible until the payload is inspected. Do **not** re-run the bootstrap
  either: it is a *build of a compiler* and inherits whatever profile data the
  previous phase left lying in its own object directory.
  Then watch what the reconfigure has to say: `-fprofile-use` adds
  `-Wmissing-profile` to every fresh probe, and a project whose feature checks
  treat a warning as a negative answer will read an untrained profile as a
  missing compiler feature. A PGO phase 2 needs its build system's *own* probe
  policy checked, not just its cache.
- **`-fprofile-generate` and `-fprofile-use` do not describe the same build.**
  `-fprofile-use` enables optimization passes the generate phase never ran
  (`-funroll-loops`, `-fpeel-loops`, `-ftracer`, …), so some functions come back
  with a different arc count and GCC refuses their profile — as an *error*, by
  default. A phase 2 that cannot regenerate its inputs needs
  `-Wno-error=coverage-mismatch` (which compiles those functions unprofiled)
  alongside `-Wno-missing-profile`.
  The distinction is worth keeping: `xorg-xwayland-git` gets it right with
  `meson setup --reconfigure`, and its rebuild is simply waiting its turn.

## 2026-09-20 — the downloaded-archive rule lived in two places, and they had already drifted twice

- **Symptom**: 36 MB of upstream release archives (nine archives plus a font,
  ten files) were tracked and pushed in `packages/stable/libreoffice-fresh/`,
  and had been public since the 2026-09-16 release sweep. The ignore half was
  fixed on the spot (`213424a`: `git rm --cached` plus `*.tgz`/`*.zip`/`*.jar`/
  `*.ttf` in the root `.gitignore`), but its **other half was still broken**:
  `nuclear_cleanup()` matched downloads with a hand-written test,
  `string match -q '*.tar.*' -- "$fname"; or string match -q '*.whl'`, so
  `-ccc` deleted this recipe's eighteen `.tar.*` downloads and left the ten
  behind for a sweep to commit.
- **Root cause**: the same list was written twice — once as the ignore rules,
  once as the cleanup match — with no link between them. They had in fact
  **already drifted once** (see the 2026-09-14 entry: `texlive-texmf`'s `svn://`
  checkouts and its `latexminted` wheel survived `--nuclear` forever), and each
  drift was repaired by appending one more pattern to one of the two lists.
- **Fix**: one list, in `build-all.fish`, as `_DOWNLOAD_ARCHIVE_EXTS`, used by
  `nuclear_cleanup()`; `.gitignore` carries the same set and names the shared
  invariant in a comment. `*.whl` joined the ignore rules so the two sets are
  literally equal, and `_DOWNLOAD_ARCHIVE_EXTS`'s wildcard entry is **quoted** —
  fish glob-expands an unquoted `tar.*` and silently drops it when nothing
  matches, which would have shrunk the list back to the old behaviour without
  any error.
- **Second defect, found by the new fixture**: the report of what `-ccc` keeps is
  the maintainer's only chance to see it before agreeing, and in a pipe it
  printed a blank line. The builder shadows `set_color` with a wrapper that is
  empty off a terminal, and fish drops a whole word like
  `(set_color cyan)"text"(set_color normal)` when the substitution yields
  nothing — so `echo` lost the text entirely. Eighteen call sites (this function's
  banner, the symlink summary, and the `--link-sources`/dedup reports) were
  rewritten as `printf '%s%s%s\n' (set_color cyan) "text" (set_color normal)`,
  where the text is its own argument and survives either way. A pipe is the
  documented interface to parse, so a report that only exists on a terminal is
  not a report.
- **Validation**: new `tests/cleanup-extensions.sh` drives a synthetic workspace
  under `$TMPDIR` and asserts that every archive type the ignore file denies is
  deleted by `-ccc`, that a local (non-URL) asset and its signature survive, that
  a symlinked source is kept and reported, that the deletion is named in the
  report, and that the report survives a pipe. It also **cross-checks the two
  lists statically in both drift directions**, and was proven to fail in each
  (shrinking the builder list; deleting a rule; adding `*.7z`). Battery
  24 → **25 fixtures, all green**. `tests/texlive-recipe.sh` asserted the old
  literal `'*.whl'` match; it now asserts membership of the shared list, pointing
  at the general fixture.
- **Rule**: a deny-list and a delete-list are the same list, so keep one
  definition and test the equality — an interval where only one of them is right
  is invisible in the diff and shows up months later as committed upstream
  archives. Corollary, from the same fixture: anything a scripted consumer is
  expected to read must be checked **through a pipe**, because the colour
  wrapper that makes a terminal pleasant is what silently deletes the text.

## 2026-09-20 — the PGO payload check was a per-recipe convention, so it kept being missed

- **Symptom**: the 2026-09-16 PGO leak recurred on `cmake-git` and
  `xorg-xwayland-git` — five installed files (`cmake`, `ccmake`, `cpack`,
  `ctest`, `Xwayland`) re-creating hundreds of `.gcda` files on every run —
  even though a fix for exactly this defect had already landed, and two
  recipes carried a verification function for it.
- **Root cause**: verification was a per-recipe convention, not an invariant.
  21 recipes instrument with `-fprofile-generate`; only 5 checked their own
  output. Two earlier commits each fixed the subset they were looking at
  (`f613685`, `4db32c5`), so the 22nd recipe was guaranteed to miss it. Worse,
  **four of those five checks could not fail a build at all**: they were called
  mid-`package()` without `|| return 1`, and bash returns the status of the
  *last* command, so the check printed its ERROR, exited 0, and makepkg
  packaged the instrumented payload anyway. Only `cairo-git` had the call as
  the final command, which is the one position where the status propagates by
  accident. The 2026-09-16 entry had also documented *two* checks —
  `readelf -sW` for symbols **and** `strings` for baked `.gcda` paths — while
  the digest line and the recipe function implemented only the first, which is
  a false negative on anything makepkg has stripped (`readelf` → 0 matches on
  `/usr/bin/Xwayland`, `strings -a` → 348).
- **Fix**: moved the invariant into the builder. `verify_pgo_payload()` in
  `build-all.fish` runs at both install seams (`install_pkgs_now()` and
  `install_all()`), gated on the sibling `PKGBUILD` containing
  `-fprofile-generate`, extracts the **whole** archive, requires a standalone
  `/<path>.gcda` string, and fails closed when `tar` yields nothing.
  `audit_workspace()` gained an "Installed PGO payloads" section, because a
  gate cannot retroactively fix a stale install — that is what hid this defect
  for six weeks. The five existing recipe guards were upgraded to the dual
  predicate, which also fixed a latent bug where `return 1` on the first hit
  skipped the remaining files, and `cmake-git` gained the guard it never had.
- **Validation**: `tests/pgo-payload-guard.sh` pins the gate end-to-end in a
  synthetic workspace (four payloads, stub `pacman`/`sudo`); red tests prove
  the gate, the archive scope and the strict predicate are each load-bearing.
  `tests/pgo-transition.sh` now exercises both detectors at the recipe seam,
  asserts repo-wide that no call site discards the check result, and uses leak
  paths that avoid `.Heavyweight`, which `--audit` correctly reported as
  legacy-layout drift.
- **Measurements that changed the design** (each replaced a written
  assumption): `.BUILDINFO` contains no `.gcda` — it records
  `-fprofile-generate` in `buildenv`, which a path predicate ignores — so the
  "whole-archive scanning trips over metadata" rationale was simply wrong, and
  whole-archive scanning turned out to be the more complete choice. Scanning
  every file owned by every PGO recipe costs ~13 s for 14 559 files, which
  `--audit` can afford. `ctest` carries **482** baked paths, not 481, because
  the first sweep had been restricted to `/usr/bin`, `/usr/lib` and
  `/usr/lib32` while the recipe path is `packages/git/xorg-xwayland-git`.
- **Rule**: a whole-set invariant belongs in the builder, not in a per-recipe
  convention — if two commits can each fix "part of it", the next recipe will
  miss it. A check that cannot fail its caller is worse than no check, because
  it reports success: a `verify_*` call inside `package()` needs `|| return 1`
  (or must be the function's last command), since bash discards the status of
  every earlier command. Verify PGO payloads with `strings`; add `readelf` only
  where the files are still unstripped. And a check that guards a write into
  `/usr` must never report clean because it in fact scanned nothing.

## 2026-09-19 — two orphan trees under `~/Projects` were instrumented binaries, and the IgnorePkg closure had drifted

- **Symptom**: `~/Projects/.Heavyweight/cmake-git/src/cmake/` and
  `~/Projects/xorg-xwayland-git/src/build/` kept reappearing — 779 files, every
  one a `.gcda`, with no `PKGBUILD`, no `.SRCINFO` and no `.git` anywhere inside.
  They were first read as debris from an old `makepkg` run under the pre-2026-09-15
  layout. They are not.
- **Root cause**: a recurrence of the 2026-09-16 defect, on the two packages that
  fix did not cover. The **installed** `/usr/bin/cmake` (cmake-git 4.4.3.936,
  built 2026-09-07) and `/usr/bin/Xwayland` (built 2026-09-16) are PGO phase-1
  builds that were packaged, so each carries hundreds of *absolute* `.gcda`
  destinations baked into the executable — 431 in `cmake`, plus 432/438/481 in
  `ccmake`/`cpack`/`ctest`, and 348 in `Xwayland`. libgcov `mkdir -p`s those
  paths at process exit, which is why deleting the trees achieved nothing.
- **How it was proven, not inferred**: the trees were deleted twice, and one
  `cmake --version` plus one `Xwayland` call re-created **all 779 files**. The
  mechanism was then isolated by running `cmake --version` alone and watching the
  mtime of a single `.gcda` advance from `00:13:02` to `00:19:05`, and by
  `strings -a /usr/bin/cmake | grep -c 'Heavyweight.*\.gcda'` → 431.
- **The verification in this journal was half-implemented**: the 2026-09-16 entry
  prescribes both `readelf -sW` (no `__gcov_`/`__llvm_profile` symbols) **and**
  `strings` (no legacy `.gcda` destinations), but the digest line and
  `verify_no_profile_instrumentation()` in the `xorg-xwayland-git` recipe implement
  only the first. On a stripped binary that half-check is a false negative:
  `readelf -sW /usr/bin/Xwayland` reports clean while `strings -a` finds all 348
  paths. The recipe is incomplete rather than wrong — inside `package()` the
  binaries are not yet stripped, so the check does work there.
- **Sweep**: every installed file under `/usr/bin`, `/usr/lib` and `/usr/lib32`
  was tested for an absolute `.gcda` destination. Exactly five files in two
  packages match. `glib2-git` and `cairo-git` return 0, so the 2026-09-16 fix held
  for the packages it touched.
- **Fix**: queued, not applied — a rebuild of `cmake-git` and `xorg-xwayland-git`
  via `--no-deps --install`. Neither name can be fixed by `-Syu`, because both are
  `IgnorePkg`-locked, which is the protection working as intended.
- **Second finding, same session**: the `IgnorePkg` closure golden rule was **32
  names short**. `comm -23` of the committed `.SRCINFO` pkgname set (218) against
  `pacman-conf IgnorePkg` (221, no globs) left the three
  `linux-cachyos-rt-bore-lto*` outputs, all 30 `texlive-*` splits, `autofdo-git`,
  `bpftune-git`, `logseq-desktop-git`, `mkinitcpio`, `openshadinglanguage` and
  `vscodium-insiders-git` unprotected. The audit must read `.SRCINFO`: the kernel's
  `pkgbase="linux-$_pkgsuffix"` makes a `PKGBUILD` grep report a literal `linux-`.
- **Fix applied**: the 32 names were appended as three new one-line `IgnorePkg =`
  entries inside `[options]`, after backing `/etc/pacman.conf` up to
  `/etc/pacman.conf.bak-20260919`. The existing 221 entries were not regenerated.
- **Verification**: `comm -23` is empty; `pacman-conf IgnorePkg` parses and reports
  253 entries, all lines still inside `[options]`; no duplicate names introduced.
  `pacman -Sy` was **not** usable as a check while a build held the database lock —
  `pacman-conf` reads the file directly and needs no lock.
- **Rule**: an installed binary that writes `.gcda` is not "debris in a stale
  directory", it is a packaging failure with a self-healing symptom. Delete the
  tree only after the package is rebuilt, and verify the rebuild with `strings`,
  never with `readelf` alone.

## 2026-09-19 — a mistyped package name said nothing useful, and `-g gti` said nothing at all

- **Symptom**: `fish build-all.fish mesa-gti` printed

  ```
  ✗ package recipe not found for ID 'mesa-gti'
  ```

  and stopped. No suggestion, no pointer to the listing, and no way to tell a
  typo from a package that does not exist. `fish build-all.fish -g gti` was
  worse: it exited 1 having printed **nothing**, so the only clue was the exit
  status. A name that *is* installed on the host — `zen-browser` — was refused
  outright, because resolution knew only recipe IDs and recipe paths.
- **Root cause (two, and only the second is the interesting one)**:
  1. `canonicalize_pkg_ref` had exactly two lookup tables (the ID list and the
     map's recipe-path column) and neither is the name a user has in hand. The
     pacman `pkgname` was simply not a lookup key, even though every recipe
     commits a `.SRCINFO` that names it.
  2. `resolve_group`'s diagnostic went to **stdout**, which is a *data* channel:
     `main` reads the group with `set -l gl (resolve_group $g)`, so the message
     was captured into `$gl` and thrown away. The function's own return status
     was the only surviving signal, and the caller's `ui_error` path was never
     reached because the caller only returns when `resolve_group` fails — which
     it does, silently.
- **Fix — the name index**: `_pkgname_index` reads `name|id` pairs from every
  recipe's committed `.SRCINFO` (218 distinct names across 126 recipes; measured
  zero unexpanded `${…}`, because `makepkg --printsrcinfo` already expanded
  them, and *no name shared by two recipes*, so a lookup cannot pick the wrong
  recipe). `canonicalize_pkg_ref` gained two exact tiers — case-variant ID and
  pacman `pkgname` — and `_ref_form_note` announces each substitution, so a
  reference never silently means something else. A typo is deliberately **not**
  auto-corrected: a wrong guess would build a whole dependency chain, and
  `libstdc++-snapshot` → `gcc-snapshot` is a 17-package split recipe. Typos are
  reported by `_report_unknown_ref` with up to three ranked candidates
  (exact name, case variant, substring, Levenshtein ≤ 2). The distance sweep
  runs in **awk**, one process for all 126 candidates: the same sweep in fish
  costs ~0.4 s, and `awk` was also the correct tool because a token containing
  glob characters (`libstdc++-snapshot`) cannot become a pattern there.
  `resolve_group` now writes its diagnostic to stderr.
- **Fix — the listings, which is where the same defect class showed up again**:
  a range indexes the **selection** in dependency order, but `--list` printed
  the whole-set order and `-l` returned at parse time, discarding `-g`. So
  `-l` index 22 was `vscodium-insiders-git` while `-g git 22..24` built
  `ninja-git, mesa-git, niri-spicy-git` — two different answers with nothing
  saying which one a range meant. `-l` now runs *after* the selection pipeline
  (so `-l -g git` prints the 56 packages a range addresses, and says so), `-n`
  with no selection covers the whole set — which is what `--help` had claimed
  for it all along while the run errored — and ranges name their mistakes:
  out-of-bounds reports the selection size and the valid window, a clamped bound
  warns, `..` and `N..M` with a start past the end are refused instead of
  silently selecting everything or nothing. `-g core`'s auto-install warning is
  suppressed for `-l` only: a listing installs nothing.
  A bare name that expands into its dependency chain now says how much of the
  selection it added (`niri-spicy-git` → "added 2 of the 3").
- **Validation**: `tests/project-cli-hints.sh` (new, 23rd fixture) asserts every
  message above — including that the group diagnostic is on **stderr** and not
  on stdout — and was mutation-tested red on five mutations: hints removed,
  `-l`'s parse-time return restored, the out-of-bounds guard dropped, the
  pkgname tier dropped, and `resolve_group`'s `>&2` removed. The last one
  initially stayed **green**, because the swallowed text leaked back into the
  output through another path (the captured string became a "package" and was
  echoed by the topology error) — which is exactly why the assertion was
  rewritten to check the channel, not the merged text. Full battery 23/23;
  `--list` with no selection is byte-identical to before (diffed against the
  previous revision), so `tests/project-config.sh` and every documented
  invocation are unaffected.
- **Durable rule**: a diagnostic written to a function's stdout is *data* when a
  caller captures it — put it on stderr, or it will be silently swallowed and
  the exit status will be the only evidence. And an index that a user has to
  know by heart (which of 126 IDs is the one) should be discoverable from the
  metadata the repo already commits: `.SRCINFO` is authoritative, needs no
  PKGBUILD evaluation, and `tests/srcinfo-freshness.sh` already keeps it honest.

## 2026-09-19 — the knob switch died in makepkg's integrity check

- **Symptom**: a build of the recipe with `_cpusched=cachyos` — every other knob
  at its default — aborted before `prepare()`:

  ```
  ==> ERROR: Integrity checks (b2) differ in size from the source array.
  ```

  Nothing in the recipe mentioned sums, and the failure arrived after
  "Retrieving sources", so it looked like a corrupt download or a tampered
  source rather than a bookkeeping mismatch.
- **Root cause**: `source[]` is assembled from four knobs, `b2sums` is a single
  flat literal, and makepkg requires exactly one integrity entry per source.
  Measured by sourcing the PKGBUILD per knob set: `_cpusched=cachyos|eevdf|rt`
  drops the one scheduler patch (4 sources), `_build_zfs=yes` adds one,
  `_build_r8125=yes` adds one, `_build_nvidia_open=yes` adds four — and
  `_use_llvm_lto`, `_build_debug`, `_autofdo`, `_propeller`, `_capture_chain`,
  `_hardened` and `_host_tune` change nothing. The committed literal is sized
  for the defaults (5), so it is correct for exactly one combination out of the
  reachable ones. The recipe's own NOTE said to run `updpkgsums` after a
  `_cpusched` switch, but nothing enforced it and makepkg's message names
  neither the knob nor the remedy.
- **Why the obvious fix is wrong**: per-knob sums (`b2sums+=('…')` next to each
  `source+=`) make every combination build, but `updpkgsums` rewrites the whole
  `b2sums=(…)` assignment as a literal on every version bump, so the appends
  would double-count at the first bump — a silent break in the tool the version
  bump depends on. Upstream avoids the problem by shipping one PKGBUILD per
  scheduler (`linux-cachyos`, `-bmq`, `-eevdf`, `-rt-bore`, `-hardened`, `-lts`,
  `-rc`), each with sums sized for its own default; a merged recipe cannot.
- **Fix**: the PKGBUILD now checks the pair itself, at parse time, before
  anything is fetched or written:
  ```sh
  if [ "${GENINTEG:-0}" -eq 0 ] && [ "${#b2sums[@]}" -ne "${#source[@]}" ]; then
      _die "b2sums has N entries but source[] has M for this knob set. … Run 'updpkgsums' in ${startdir} …"
  fi
  ```
  The `GENINTEG` exemption is the load-bearing part: `updpkgsums` runs
  `makepkg -g`, which has to source the PKGBUILD to do its job, and the whole
  point of running it is that the sums do not match yet — an unguarded abort
  would make the remedy impossible to run. makepkg sets `GENINTEG=1` during
  option parsing and sources the PKGBUILD into its own shell, so the mode is
  visible to it (measured on pacman 7.x; no `/proc` poking needed).
- **Validation**: the guard refuses `_cpusched=cachyos` and
  `_build_nvidia_open=yes` by name; accepts the default set and the six knobs
  measured to be source-neutral; `makepkg --printsrcinfo` on the pristine recipe
  is byte-identical to the committed `.SRCINFO`; and the remedy was run
  end-to-end in a scratch copy — `_cpusched=cachyos updpkgsums` regenerated
  `b2sums` to 4 entries, after which the `cachyos` set parsed clean and
  `rt-bore` was the set that got refused. `tests/kernel-recipe-sums.sh` pins all
  of it and is red on four mutations: guard removed, guard unconditional,
  `GENINTEG` exemption removed, and a default set edited away from the shipped
  sums (the drift case the 7.3 move hit when `misc/0001-rt-i915.patch` was
  dropped).
- **Durable rule**: a `b2sums` literal is sized for one knob combination. Either
  keep the source set knob-independent, or make the recipe refuse the
  combination it cannot serve *and* keep the sum-generation path runnable.

## 2026-09-19 — the recipes were reporting on my laptop

- **Symptom**: `CONTRIBUTING.md` scopes a contribution to "a clean Arch
  checkout" and excludes "host-specific logs and profiles", but two commits of
  mine (`56e6c76`, `3ecf456`) had put the opposite into tracked files. The
  `linux-cachyos` PKGBUILD documented the running kernel version
  (`7.2.5-1-cachyos-rt-bore-lto`), the CPU thread count, an inventory of the
  Limine command line and its sysctl drop-in, the `mitigations=off` and
  `zswap.enabled=0` boot decisions, and a narrative of a hard freeze. A tracked
  working document under `stable/systemd/` carried the exact CPU model in its
  first "verified facts" list. A `third-party` recipe ID claimed `znver5` while
  the recipe set no ISA at all.
- **Root cause**: the journal rule — host incidents go in `NOTE.md`, the
  operational contract goes in `MEMORY.md` — was never stated as a rule for
  *recipes*, so every fact learned while debugging leaked into the file being
  edited. Nothing stated who the set is *for* either, so a machine-specific
  trim read as an accident rather than as the target.
- **The audit's own correction**: the ISA half of the complaint did not hold.
  No recipe hard-codes this machine's ISA — every native-flag injection is
  conditional and says so (`niri-spicy-git`, `rust-bindgen-git`,
  `xwayland-satellite-git`), no recipe narrows `arch` below `x86_64`,
  `rust-git` parameterises through `GSA_TARGET_CPU`, and the kernel's
  `_processor_opt` is a documented knob with `zen4`/`generic` alternatives.
  What *is* machine-specific is the **artifact**, because `makepkg.conf`
  supplies `-march=native`. That distinction is now written down rather than
  assumed.
- **Fix**:
  - 16 comment sites — 15 in `packages/misc/linux-cachyos/PKGBUILD`, one in
    `verify-config.sh` — rewritten to explain the option or the trim instead of
    the machine. Three needed the *claim* to move, not the wording: the AutoFDO
    drift note is now self-contained (the committed `config` carries no
    `AUTOFDO_CLANG`/`PROPELLER_CLANG` line, so the old text rested on host
    state); `_host_tune` is grounded in the committed `config` (`MAXSMP=y`,
    `NR_CPUS=8192`, `CPUMASK_OFFSTACK=y`, `ZSWAP=y`) rather than a thread
    count; the capture-chain note keeps the contradiction it documents and
    drops the incident.
  - `_capture_chain` default flipped to `no`, with the off branch given the same
    verified treatment so the flip has a tested opposite. The default run stays
    **84 expectations**: the 8 capture assertions swap to their off-state
    counterparts, read out of the committed `config` and confirmed at the seam.
  - `README.md` now states the target (**AMD laptops** — AMD CPUs with
    amdgpu/radeon graphics) and that trimming has been exercised on one model;
    `docs/portability.md` splits the portable recipe from the non-portable
    artifact; `CONTRIBUTING.md` measures a contribution against the target and
    states the comment rule.
  - `linux-firmware`, `libdrm-git` and `hip-runtime` now say the AMD target
    instead of "this machine" where the trim follows from the target. The five
    remaining "this machine" sites (`dbus`, `udisks2`, `wireplumber`,
    `rocm-llvm`) are capability absences, not specs, and stay.
  - `stable/systemd/Workspace_information&TODO.md` deleted — a completed
    planning document with the CPU model in it, and not an artifact
    `docs/package-policy.md` permits. Its durable findings moved into the
    recipe: the PGO branch is now marked as never having completed (the
    experimental GCC 17 snapshot segfaults in `IPA pass: profile`), and
    `check()` names the pre-existing openssl/tpm2-tss failures and `--nocheck`.
  - `Zen-Browser-Arch-znver5-optimized` renamed to `zen-browser-pgo`; the
    README now says what the recipe does (3-tier PGO, `-O3`, thin+cross LTO via
    mozconfig, ISA inherited from the host).
  - Two further sites the plan's inventory missed and the repo-wide sweep
    caught: `bpftune-git`'s hook rationale carried a coredump count and two
    timestamps (`2026-09-16 07:38:35, 18:57:50`) plus `/var/log/pacman.log` as
    evidence — the mechanism (dlopen + stale pointers → `strstr()` SIGSEGV)
    stays, the evidence goes; and `pyside6-git`'s maintainer line carried
    `~/Projects`. Both date from `b02cefd` ("Prepare Gentoo_Style_Arch for
    public release"), so the release pass missed them. `libdrm-git`'s trim now
    says the AMD target rather than naming an SoC it does not actually select
    on (the meson flags are AMD-wide, not SoC-specific).
- **Validation**: `bash -n` on every edited recipe; `makepkg --printsrcinfo`
  unchanged; real seam (`makepkg --nobuild`, real 7.3-rc3 tree) — default 84
  with the off-state set, `_capture_chain=yes` 84 with the on-set,
  `_hugepage=always` aborting by name; the `_capture_chain=yes` environment
  override proven to reach the lane child (the spawn is `setsid --wait fish
  build-all.fish --lane-job`, which inherits the environment, and the seam
  proves `makepkg` passes it into `prepare()`); 21/21 fixtures;
  `--audit`/`--list`/`--dry-run --group third-party` clean after the rename.
- **Durable rules**:
  - **A comment explains the code, the kernel option, or the trim decision; it
    does not inventory the machine it was written on.** Kernel versions,
    installed package versions, CPU thread counts, bootloader command lines and
    incident narratives belong in this journal.
  - **Declare the target.** A trim that follows from the maintained hardware is
    a scope statement and should name the platform; a trim that follows from one
    author's environment is a capability absence and should say so. Neither is a
    licence plate for the running machine.
  - **A recipe is portable; the artifact is not.** Recipes derive ISA settings
    from the environment and so build on any x86_64 host; `makepkg.conf`
    supplies `-march=native`, so the packages are tuned to the builder and are
    not redistributable.
  - `_capture_chain` is opt-in. `WQ_WATCHDOG` and `PSTORE_CONSOLE` are
    config-only — no command line can set them — so a kernel built with the
    default off keeps whatever panic path the command line provides but loses
    the workqueue-hang detector. Set `_capture_chain=yes` in the environment
    when that detector is the point.

## 2026-09-19 — `linux-cachyos`: the config toggles were a wish list, not a contract

- **Symptom**: three of the recipe's knobs did nothing, and nothing anywhere said
  so. The installed 7.2.5 kernel and the freshly resolved 7.3-rc3 `.config` both
  carry **no `TRANSPARENT_HUGEPAGE` at all** — not `=n`, *absent* — although the
  shipped `config` file asks for `madvise` and the recipe's `_hugepage` default
  is `madvise`. THP has never been enabled on this host.
- **Root cause — three independent ones, all silent:**
  1. **`_hugepage` is dead code.** `mm/Kconfig:844` gates the whole
     `menuconfig TRANSPARENT_HUGEPAGE` on `!PREEMPT_RT`, and `_cpusched=rt-bore`
     writes `PREEMPT_RT=y`. `scripts/config` sets the symbol without consulting
     Kconfig, the next `olddefconfig` deletes it, and the log prints neither.
     The same gate removes `NUMA_BALANCING` and `QUEUED_RWLOCKS` from the
     shipped config (15 symbols in total are `!PREEMPT_RT`-gated).
  2. **`_use_kcfi` is dead code.** 7.3's user-selectable symbol is `CONFIG_CFI`
     (`arch/Kconfig:954`); `ARCH_SUPPORTS_CFI_CLANG` no longer exists and
     `CFI_CLANG` is a promptless `transitional` symbol kept only to migrate an
     old `.config`. Measured: the recipe's three-name write leaves `CONFIG_CFI`
     **unset**, while `-e CFI` selects it.
  3. **`cachyos`/`eevdf` wrote a symbol that cannot exist.** `SCHED_BORE` is
     *added* to `init/Kconfig` by `sched/0001-bore-cachy.patch`, and the source
     case only fetched that patch for `bore|hardened|rt-bore`. Verified: upstream
     `linux-cachyos` and `linux-cachyos-rc` have the identical gap, so this is
     **not** a local divergence — the fix records the fact (`!SCHED_BORE`)
     instead of pretending to fix it.
  Plus two ordering faults: `_use_current` (`zcat /proc/config.gz > .config`) and
  `_localmodcfg` (`make localmodconfig`) ran *after* the entire toggle block and
  discarded it, and `_preempt` under `rt*` was skipped without a word.
- **Fix**: the knobs become a *resolved, verified* contract — every expectation
  either holds in the final `.config` or `prepare()` aborts in seconds with a
  named reason.
  - New `verify-config.sh` (recipe-local; bash + coreutils only) takes
    `<config-file> <expectation>...` in five forms — `SYM=v`, `SYM`, `!SYM`,
    `SYM!=v`, `SYM>=N` — prints **every** failure as `SYMBOL: expected X, got Y`,
    and exits 1 on any unmet expectation (2 on misuse). It reports `absent`
    separately from `n` on purpose: `n` means "fix the dependency", `absent`
    means "the symbol was renamed or removed, fix the name".
  - `prepare()` builds `_config_wants` beside each write and runs the check right
    after `make prepare` / `make config`; failure is a named `_die`. The default
    run asserts **84** expectations.
  - Base-config selection moved **ahead** of every toggle, so the explicit knobs
    always win whatever base was chosen.
  - Parse-time gates (a `_die` before any write, so they cost seconds, not a
    patch run): `bmq` and `hardened` (the 7.3 patch set ships neither), `muqss`
    (the local patch still targets 7.2), `_hugepage` or `_preempt` explicitly set
    under `rt*`, `_build_zfs=yes` under `rt*`.
  - New knobs: `_capture_chain` (yes — the config now argues *for* the crash
    chain that was assembled entirely outside the recipe), `_host_tune` (yes,
    `_nr_cpus=64`), `_hardened` (no), `_rt_feature_drops` (`abort|accept`).
    `_tcp_bbr3` renamed to `_tcp_bbr` with a warned legacy alias: it enables plain
    BBR + FQ, and `CONFIG_TCP_CONG_BBR3` no longer exists in 7.3 at all.
  - Deleted the dead `_sums_sched` array (nothing consumed it, and its
    `rt|rt-bore` entry still pointed at the removed `misc/0001-rt-i915.patch`).
- **Validation**: new `tests/kernel-config-verify.sh` covers every engine form,
  the absent-vs-`n` distinction, multi-failure counting, misuse exit 2, and
  structural assertions on the PKGBUILD (base-config selection precedes the first
  `scripts/config`; every documented `_cpusched` value is handled by all three
  `case` blocks; no unconditional `!SYM` in the invariants array contradicts a
  toggle's `-e SYM`). Real seam, `makepkg --nobuild` against the real 7.3-rc3
  tree: default 84, `_hardened=yes` 85, `_hugepage=always
  _rt_feature_drops=accept` 84 (warns), `_autofdo=yes` 84, `_use_llvm_lto=none`
  83, `_host_tune=no` 80 — all rc=0; and all seven contradiction cases abort with
  their named reason. Full fixture battery 21/21.
- **Durable rules**:
  - **A `scripts/config` write is not evidence.** An unknown symbol is a no-op
    and a gated symbol is written and then deleted. Only the resolved `.config`
    *after* `make prepare` is evidence, which is why the check reads the file
    instead of trusting the write.
  - **`!SYM` and `SYM=n` are different claims.** A `choice` member whose prompt
    is hidden — `bool "Cubic" if TCP_CONG_CUBIC=y` in `net/ipv4/Kconfig`, with
    `TCP_CONG_CUBIC=m` here — **disappears from `.config` entirely** (absent),
    while a merely unselected member is emitted `# CONFIG_X is not set` (`n`);
    `DEFAULT_RENO` in the same choice is `n` while `DEFAULT_CUBIC` is absent.
    Assert `!SYM` for such members. This cost one wrong table entry, caught only
    by the real-seam run. (The `IOMMU_DEFAULT_*` choice members do emit `n`, so
    it is per-symbol — measure, do not generalise.)
  - **An invariant must not contradict its own toggle.** `!AUTOFDO_CLANG` sat in
    the unconditional invariants array while `_autofdo=yes` wrote
    `-e AUTOFDO_CLANG`, which made the AutoFDO path unbuildable; the same shape
    was waiting on the `_hardened` trio. Guard such an assertion on the knob,
    outside the array. The fixture now enforces this class directly.
  - **Validate the copy you edited, on a clean `src/`.** The seam scratch tree
    holds a *copy* of the recipe, and two validation rounds silently tested the
    stale copy and reported a contradiction that had already been fixed. And
    makepkg re-applies patches to an existing `src/`, so every case that reaches
    `prepare()` needs a clean `src/` or it fails on an already-patched tree — a
    harness fault that looks exactly like a recipe fault.
  - **AutoFDO/Propeller drift is a decision, not a default.** The installed
    7.2.5 kernel was built with `AUTOFDO_CLANG=y` and `PROPELLER_CLANG=y`; the
    recipe defaults both to `no`, so the first default rebuild replaces an
    optimised kernel with a plain one and warns nowhere. The header records it
    and `prepare()` asserts the off state, so the swap is at least visible.
  - **A verification failure is fatal on purpose.** Shipping a kernel whose
    options silently differ from the recipe's own declaration is worse than not
    shipping one — the whole point of the exercise is that the recipe cannot
    lie about itself.

## 2026-09-19 — kernel: the build freezes were CVE-2026-90432; recipe moved to the CachyOS RC channel

- **Symptom**: any build could hard-freeze the machine — last frame stuck, no
  keyboard or mouse, hard power-off the only recovery — and it was independent
  of build weight. Nothing was ever recorded: no panic, oops, MCE, RCU stall,
  hung-task report or OOM in any retained journal.
- **Root cause**: `CVE-2026-90432`, "sched_ext: Abort directly from the
  hardlockup handler" (Tejun Heo, 2026-07-27; `Fixes: bd2d76455b65 "sched_ext:
  Defer scx_hardlockup() out of NMI"`). `scx_hardlockup()` deferred the abort to
  an `irq_work`, and *"the perf watchdog fires on the hard-locked CPU itself,
  where a queued irq_work never runs with IRQs off"* — so a stalled sched_ext
  scheduler left that CPU hard-locked for good. The same commit notes the
  handler *"used to return %true whenever sched_ext was loaded, suppressing the
  kernel's hardlockup report even when the abort was refused"*, which is why
  every journal was blank. Affected `7.1 <= v < 7.2.6`; fixed in 7.2.6+ /
  7.3-rc1+. Stable backport `4d6270bbb…`, upstream `3c4b38064…`, file
  `kernel/sched/ext/ext.c`.
- **Why it was hard to see**: every crash kernel (7.2.2-1, 7.2.3-ck1-1,
  7.2.4-ck1-1, 7.2.4-1.1, 7.2.5-1) lies inside the affected range, so the earlier
  "six kernel packages crashed, therefore not a kernel regression" reading was
  wrong; the one kernel never booted during a crash (`linux-cachyos-lts` 6.18.52)
  is the one outside the range. The trigger is a fork/exec + I/O storm — i.e.
  any build — which is why build weight never mattered. Upstream's own analysis
  (`sched-ext/scx#3687`, closed 2026-08-18) describes the same framework-side
  fault affecting **all** sched_ext schedulers, with the same workload shape
  ("fork/exec-heavy I/O load", "concurrent fsync, `O_DIRECT` and fork-mode I/O"),
  and measured 1 unrecoverable freeze in 30 induced stall runs on a 12-CPU guest
  — this host has 24 threads. Field report `sched-ext/scx#3667` names
  `scx_pandemonium` directly. The 2026-09-18 texlive freezes are the same fault:
  that workload is the same fork/exec + I/O pattern, so the NVMe-ASPM /
  `ananicy-cpp` / zram leads are retired.
- **Why nothing was captured**: besides the CVE suppressing the report, the host
  had `nowatchdog` (so `nmi_watchdog=0`), `hardlockup_panic=0`,
  `panic=0`/`panic_on_oops=0`, `kernel.sysrq=16` (sync only) and a 5-minute
  journald `SyncIntervalSec`. It was configured to be undiagnosable. The chain is
  now armed — see `MEMORY.md` §5.
- **Fix**: `packages/misc/linux-cachyos` moved from the 7.2 stable channel to the
  CachyOS RC channel — `_major=7.3`, `_rcver=rc3`, `_tagrel=4`,
  `pkgver=${_major}.${_rcver}` = `7.3.rc3`, `_srctag=cachyos-7.3-rc3-4`.
- **Version-sensitive follow-on**: `_patchsource` is scoped by `_major`, so one
  bump invalidates every patch filename. The 7.3 set has no
  `misc/0001-rt-i915.patch` (CachyOS added it to 7.2 on 2026-06-29 and never
  carried it forward; it touches `drivers/gpu/drm/i915/` and `kernel/ksysfs.c`,
  so its absence affects Intel GPUs only), no `sched/0001-prjc-cachy.patch` and
  no `misc/0001-hardened.patch`, and the nvidia patches renumber
  (`0002`/`0003` → `0001`/`0002`, plus a new `0003-Pass-dmem_cgroup_init…`).
  CachyOS's own 7.3 RC PKGBUILD still names rt-i915, but only in a branch its
  default `_cpusched=cachyos` cannot reach — dead code there, a 404 here.
  `config` was replaced with `linux-cachyos-rc/config`: 185 lines differ from the
  7.2 rt-bore config, 12 of them tool versions and the rest symbol churn, while
  `PREEMPT`/`PREEMPT_DYNAMIC`/`HZ=300`/`NO_HZ_FULL`/`RCU_BOOST` are identical and
  the variant identity is applied by `scripts/config` anyway. `_nv_ver` also
  moved 610.57.04 → 615.71.09 to match upstream.
- **Trap worth remembering**: the recipe's startdir *is* `SRCDEST`, and the
  tracked patch files sitting there are what makepkg actually uses — so
  `updpkgsums` printed "Found <file>" and re-summed the stale 7.2
  `0001-bore-cachy.patch` (40,750 B) instead of fetching the 7.3 one (42,503 B).
  Green sums, wrong patch. Replaced by hand; `0001-rt-i915.patch` deleted as
  unreferenced.
- **Validation**: tarball signature `Good signature from "Peter Jung
  <admin@ptr1337.dev>"`, fingerprint
  `E8B9AA39F054E30E8290D492C3C4820857F654FE` — matching `validpgpkeys`, so no
  `--skippgpcheck`; both patches apply cleanly to the extracted
  `cachyos-7.3-rc3-4` tree (`patch -Np1 --dry-run`); `PREEMPT_RT`, `SCHED_BORE`
  and `CACHY` still exist in the new tree, so no silent variant loss;
  `bash tests/run-all.sh` PASS (20 fixtures), including the repo-wide
  `srcinfo-freshness` (126 recipes); `--audit`, `--list` and `--dry-run -g misc`
  clean. The earlier 6-minute `-c --no-deps bettbox` rebuild passed (Tctl 91 °C)
  but ran with sched_ext unloaded, so it is a smoke test, not a control.
  The hand-holding this bump needed is now pinned by
  `tests/kernel-recipe-version.sh`: the tarball URL must name `pkgver`, and every
  `_patchsource` URL must sit under the `pkgver`'s major. Verified red on both —
  a hardcoded `_srcname` and a patch set scoped to `master/7.2` each fail with a
  named reason, and both were reverted before the run.
- **Still open**: the 2026-09-01 cluster — four unclean shutdowns inside 27
  minutes, the first ten minutes after `ryzenadj` + `ryzen_smu-dkms-git` were
  installed and **before `scx-scheds-git` existed** — cannot be this CVE. See
  `MEMORY.md` §5.
- **Rule**: before blaming a workload for a hard freeze, check the build host's
  kernel against the sched_ext abort/lockup CVEs; and when a freeze leaves *no*
  trace at all, suspect a handler that suppresses the report rather than an
  absence of faults.

## 2026-09-19 — bettbox: a host freeze corrupted the Go module cache

- **Symptom**: `fish build-all.fish -g third-party` failed inside bettbox's
  `build()` — `run go mod tidy` →
  `verifying github.com/xyproto/randomstring@v1.0.5: zip: not a valid zip file` →
  `Unhandled exception: go mod tidy error` (`setup.dart:167`). The recipe was not
  at fault.
- **Root cause**: the host had hard-frozen and been powered back on at 12:28. XFS
  log recovery restored metadata without the data of the last seconds, so files
  existed with plausible sizes and mtimes and **zeroed content**. In `~/go`: 17
  module zips of size 0, 19 `.ziphash` files of the correct length but entirely
  NUL, 32 of 149 extracted trees holding zero-length files, 17 zero-length
  `~/.cache/go-build` entries. The all-NUL hashes are the dangerous half — Go
  caches "verified" there, so it never re-downloads the module and the failure
  surfaces later (`zip has been modified`) or not at all.
- **Not the recipe, not the network**: the tarball's sha256 matched the PKGBUILD
  (`7e6ed765…`), `proxy.golang.org` served the module, the vendored
  `core/Clash.Meta` tree was complete (1035 files, 7.4 MB), and the Flutter/pub
  caches were clean. `bettbox` is the repo's only Go recipe.
- **Red signal**: `cd .../Bettbox-1.19.2/core && go mod verify` — seconds,
  read-only, and it named every damaged module.
- **Fix**: `go clean -modcache && go clean -cache` — a deliberately blunt purge,
  because the damage class is "size preserved, content zeroed" and a surgical
  purge cannot see all of it. The rebuild then re-downloaded all 149 modules and
  completed: `✓ bettbox (5m56s)`, archive `bettbox-1.19.2-1-x86_64.pkg.tar.zst`
  (50 MB), and `go mod verify` → `all modules verified`.
- **A second, unrelated break found while fixing it**: the committed `.SRCINFO`
  was still at 1.19.1 with the *previous* tarball's sha256 while the PKGBUILD was
  1.19.2 — a version bump that never re-ran `--printsrcinfo`. Only three fixtures
  checked `.SRCINFO`, each its own recipe, so the other 123 were unchecked; a
  recipe consumed through `.SRCINFO` would have built the wrong sources against
  the wrong sums.
- **New tooling**: `tools/go-modcache-check.sh` — read-only detector for the four
  detectable damage classes (zero-length zip, all-NUL `.ziphash`, zero-length
  record, zero-length `.go` inside an extracted tree; `.lock` is legitimately
  empty and is skipped), with `--purge` to remove the affected module's record and
  tree. `tests/modcache-check.sh` drives it against a synthetic cache and keeps a
  damaged **decoy** cache it is never pointed at, which must survive untouched.
  `tests/srcinfo-freshness.sh` generalises the per-recipe `.SRCINFO` check across
  all 126 recipes from `config/packages.map` (~32 s at `-P 8`;
  `GSA_SRCINFO_JOBS` overrides the parallelism).
- **Validation**: `go mod verify` clean, `✓ bettbox (5m56s)` with the archive
  produced, `bash tests/run-all.sh` → **PASS (19 fixtures)**.
- **Rule**: after any unclean shutdown, treat freshly written files as suspect and
  verify the consumer before blaming the recipe — for Go, `go mod verify`, and
  `go clean -modcache` whenever a file could have kept its size. A version bump
  must regenerate `.SRCINFO` in the same commit, and a repo-wide fixture now
  enforces that.

## 2026-09-19 — hard freezes: the capture chain is armed, and the history is longer

- **Symptom (restated)**: a build kick-off freezes the whole machine — last frame
  stuck, no keyboard or mouse input, only a hard power-off recovers it. Two more
  this session (11:55:48→12:01:07, 12:28:03→12:43:03). It also zeroed the
  authoring session's own `plan.md`, the same write-loss that corrupted the Go
  cache above, and zeroed a restored copy of the bettbox plan.
- **New: the freeze is chronic, not a 2026-09-18 episode.** `last -x` over the
  whole wtmp (the machine was installed 2026-08-31 15:20) shows ~23 unclean
  shutdowns, and the *first* is **2026-09-01 00:37 — ten minutes after
  `ryzenadj` and `ryzen_smu-dkms-git` were installed at 00:33/00:36**, with four
  inside 27 minutes. They continue on 09-05, 07, 08, 09, 10 (six), 11, 14, 17, 18
  (three) and 19 (two), across **four** kernel packages (`7.2.2-1-cachyos`
  bore-lto, `7.2.3-ck1-1`, `7.2.4-ck1-1.1`, `7.2.5-1` rt-bore-lto) — so it is not
  a kernel-version regression. `scx-scheds-git` was not installed until 09-03
  17:52, so sched_ext cannot explain the first night.
- **Why every freeze was silent, and what changed.** The configuration forbade
  evidence: `nowatchdog` on the cmdline (`nmi_watchdog=0`, `watchdog=0`), every
  `*_panic` sysctl 0 including `panic`/`panic_on_oops`, `kernel.sysrq=16` (sync
  only — no recovery key worked), and journald's 5-minute default flush losing the
  final seconds every time. The 2026-09-18 entry left "make sysrq persistent and
  drop `nowatchdog`" outstanding; that is now done, plus:
  - `/etc/sysctl.d/99-diagnostic.conf` — `watchdog_thresh=30`, watchdog and both
    lockup detectors enabled, `softlockup_panic`/`hardlockup_panic`/
    `softlockup_all_cpu_backtrace`/`hung_task_panic`/`panic_on_oops`=1, `panic=10`,
    `sysrq=1`, re-applied every boot.
  - `/etc/default/limine` — `nowatchdog` removed and
    `hardlockup_panic=1 softlockup_panic=1 softlockup_all_cpu_backtrace=1
    hung_task_panic=1 hung_task_timeout_secs=120 panic_on_oops=1 panic=10
    efi_pstore.pstore_disable=N` added; `limine-update` regenerated all three boot
    entries.
  - `/etc/systemd/journald.conf.d/10-diagnostic.conf` — `SyncIntervalSec=1s` (was
    the 5-minute default) and `SystemMaxUse=1G`, overriding the vendor 50 MB cap.
  - `gsa-heartbeat.service` — a timestamp to `/var/log/heartbeat.log` and the
    journal every 5 s, which separates "the kernel died" from "the display died".
- **Closure (2026-09-20): the chain is gone, because it answered its question.**
  CVE-2026-90432 in the sched_ext fork/exec path was the cause (2026-09-19 entry
  above), the kernel moved past it, and a diagnostic left armed past its question
  is only unmeasured overhead — so the list above was dismantled:
  `/etc/sysctl.d/99-diagnostic.conf`, `gsa-heartbeat.service` with
  `/usr/local/bin/gsa-heartbeat.sh` and `/var/log/heartbeat.log`,
  `/etc/systemd/journald.conf.d/10-diagnostic.conf`, and the eight parameters
  added to `/etc/default/limine` were all removed; `limine-update` regenerated
  all four boot entries at 09:35 and the running boot keeps the old chain until
  the next reboot. `tools/texlive-split-probe.sh` and `tests/probe-watchdog.sh`
  went with them. Everything is backed up in
  `/root/freeze-diag-backup-20260920/`, and the pre-cleanup command line is at
  `/etc/default/limine.bak-20260920-pre-diag-cleanup`
  (`/etc/default/limine.bak-20260919-freeze-diag` is the earlier, pre-diagnosis
  one and still carries `nowatchdog`). The two lessons below are the durable
  half and are why re-arming is worth doing *first*, not after.
- **`efi_pstore` was disabled by default** (`pstore_disable=Y`), so
  `/sys/fs/pstore` had never been able to receive anything despite being mounted
  and empty since installation. Set to `N`, the chain was validated at 13:09 with
  a deliberate `Alt+SysRq+c`: `Kernel panic - not syncing: sysrq triggered crash`
  landed in pstore in 17 compressed records and the machine self-rebooted in 27 s
  on `panic=10`. **The panic never reached the journal** — pstore is the channel
  that survives, which is exactly why it had to be enabled first.
- **One full-length rebuild has since passed**: bettbox, 6 minutes, 149 modules
  re-downloaded, Tctl peaking at 91 °C against a 92 °C limit — no freeze. That run
  had the undervolt applied but `sched_ext` unloaded (`/etc/scx_loader.toml` was
  rewritten at 13:00:46 without `default_sched`; `dmesg` shows pandemonium
  unregistering at uptime 965 s), so it is an sched_ext-free data point, **not** a
  control.
- **Hypotheses, none confirmed**: (a) the `ryzenadj` undervolt applied at every
  login — present at *every* crash including the four that predate scx, though the
  maintainer's counter-evidence is that a −14 global offset survived single-core
  builds; the untested half is the per-core `--set-coper` path, whose
  `core<<20 | offset` packing is hand-rolled, whose CO value cannot be read back
  (`--dump-table` has no CO field), and whose `ryzenadj` exit status the script
  discards; (b) `scx_pandemonium` under a fork/exec storm; (c) the pre-existing
  NVMe ASPM/device lead. On (c): the link does run ASPM L1 + L1.2 (`LnkCtl: ASPM
  L1 Enabled`, `L1SubCtl1: PCI-PM_L1.2+ ASPM_L1.2+`) with the policy now
  `default`, but **all AER counters are zero** on both the device and its root
  port, the NVMe error log is empty and SMART reports 0 media errors — absence of
  evidence, not evidence.
- **Still queued at the time** (all superseded by the CVE finding): a real
  ASPM-off differential (removing `pcie_aspm=powersave` only moved the policy to
  `default`, which still enables L1 — it needs `pcie_aspm=off`), `ananicy-cpp`
  (still active), the zram resize
  (`zram-size = ram * 2.5` = 74.9 GB of RAM-backed swap on a 29 GiB machine, and
  with `zswap.enabled=0` it is the only swap), and a phase-free 20 GB write
  burst. The last one needed the probe, which no longer exists.
- **Rule**: arm the capture chain *before* investigating a hard freeze — lockup
  detectors with `*_panic=1` so a wedge panics and reboots leaving a trace,
  `kernel.sysrq=1` so `Alt+SysRq`+`l`/`w`/`b` can dump and sync, a 1 s journal
  flush, a heartbeat witness, and pstore (check `pstore_disable`; it defaults to
  `Y`). And count crashes from `last -x` over the whole wtmp rather than the
  retained journals — journald keeps about a day, which hides how long a problem
  has existed.

## 2026-09-18 — copilot-instructions told agents to commit, not to ask

- **Symptom**: the agent instruction file stated that the host's commit routine
  was inherited unchanged and that "a completed task ends in its own descriptive
  commit, pushed". The host file at `~/.copilot/copilot-instructions.md` says
  the opposite — always ask whether to commit, commit & push, or leave the tree
  alone — so an agent reading only the repository instructions would commit and
  push unprompted.
- **Root cause**: commit 18d1011 added the host-comparison section and folded
  the commit routine into the inherited-unchanged list while introducing it.
  Nothing else in the file addressed committing, so the mischaracterisation
  stood as the only statement on the subject.
- **Fix**: the relationship section now claims workspace isolation alone as
  inherited unchanged, and a new **Committing** convention under Conventions
  restates the host rule concretely — ask first and let only the answer decide,
  never treat a green fixture battery as consent, and carry the host's trailer
  verbatim on a body shaped like the rest of the log.
- **Validation**: the trailer string compares byte-for-byte identical to the
  host file; `bash tests/run-all.sh` passes (16 fixtures) and no fixture reads
  the instruction file, so the change is documentation-only; `docs/MEMORY.md`
  carries no competing commit rule.
- **Rule**: when this file classifies a host rule as inherited unchanged, read
  the host wording first. An ask-first rule cannot be restated as an automatic
  action, and a prompt is not a default.

## 2026-09-18 — logseq: pnpm installed the repo root instead of `static`

- **Symptom**: after the Java-virtual fix (below) the build ran every bundle
  stage successfully — webpack app build, `desktop:prepare-runtime-js` — and
  then aborted in the Electron packaging step:
  `ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL Command "electron-builder" not found`,
  followed by `==> ERROR: A failure occurred in build()`. Nothing in the log
  named the install that was supposed to provide that binary.
- **Root cause**: the upstream tree carries `pnpm-workspace.yaml` at **its**
  root — since pnpm 10 that file holds non-auth settings, and this tree's copy
  declares `shamefullyHoist` plus `allowBuilds` but **no `packages:` field** —
  so `static/` is not a workspace member. pnpm 10.33 therefore resolved a
  `pnpm install` run from inside `static/` to the **workspace root** (the repo
  root) as the project to install. The root tree was already satisfied, so the
  command installed nothing, printed `Done` and exited **0** in about half a
  second; `static/node_modules` was never created and `pnpm exec
  electron-builder` had no local `.bin` entry to run. `--frozen-lockfile` could
  not catch this: the install *succeeded*, it just installed the wrong project,
  and the missing `node_modules` is only discovered one step later by an
  unrelated command whose error names the binary rather than the cause. The
  recipe already carried the guard for its other subdirectory install —
  `pnpm --dir cli install --frozen-lockfile --ignore-workspace` — so the hazard
  was known and had simply not been applied to `static/`.
- **Verification loop**: the exact recipe command, run in the `static/`
  directory, reproduced the failure byte for byte — `rc=0`, no `static/node_modules`,
  and `Progress: resolved 1, reused 1, downloaded 0, added 1, done`. The
  decisive evidence is pnpm's reporter label `..`: the project path relative to
  the working directory, i.e. the parent directory, i.e. the repo root. After
  adding `--ignore-workspace` the same command installed the real tree in
  14.7 s (`electron-builder 26.8.2`, `electron 42.3.0`,
  `@zvec/bindings-linux-x64`) and `static/node_modules/.bin/electron-builder`
  existed; `pnpm exec electron-builder --config electron-builder.yml
  --publish never --dir -c.executableName=logseq` then exited 0 and produced
  `static/dist/linux-unpacked/logseq` (209 853 656 bytes) with `chrome-sandbox`,
  `resources/app.asar`, `resources/app.asar.unpacked/node_modules/{keytar,@zvec}`,
  `resources/sidecar` and `resources/.agents/skills/logseq-cli/SKILL.md` all in
  place.
- **Fix**: the static packaging install became
  `pnpm install --frozen-lockfile --ignore-workspace`, with a comment recording
  why the flag is load-bearing. No metadata, dependency, or scheduler change was
  needed — `makepkg --printsrcinfo` reproduces the committed `.SRCINFO`
  byte-identically.
- **Two side effects were checked rather than assumed**, because
  `--ignore-workspace` also detaches the install from the root `.npmrc` and
  `pnpm-workspace.yaml`: pnpm consequently ignores the `allowBuilds` /
  `onlyBuiltDependencies` allowlists and does not populate
  `node_modules/electron/dist`, and it drops `shamefully-hoist` for this tree.
  Both are harmless here — electron-builder downloads the Electron 42.3.0
  distribution itself (observed: 119 MB, 8.3 s) and the static package's own
  `postinstall` (`install-app-deps`) rebuilds `keytar` for Electron
  (`preparing`/`finished moduleName=keytar`), while the packer falls back to
  `using manual traversal of node_modules to build dependency tree` and produced
  the complete payload above.
- **Tests**: `tests/logseq-desktop-recipe.sh` now extracts the `( cd static … )`
  block and requires the install line to carry `--ignore-workspace`. The
  assertion was red-verified (fails with the flag removed, passes with it) and
  the full battery passes (15 fixtures).
- **Rule**: a `pnpm install` run inside a subdirectory of a tree whose root has
  a `pnpm-workspace.yaml` must pass `--ignore-workspace` unless that
  subdirectory is a declared workspace member — otherwise the install silently
  targets the root project and reports success. Treat a successful install that
  creates no `node_modules` as the symptom, not the error from the command that
  later fails to find a binary.

## 2026-09-18 — texlive prepare(): two hard freezes, and a split loop that lost 8 minutes

- **Symptom**: building `texlive-texmf` froze the whole machine twice — once
  during the source fetch (08:40:54), once 43 s into `prepare()`'s split loop
  (10:41:38). The screen stopped, no CPU load was visible, and only a hard power
  reset brought it back. There was no log: the run's own log lived in `.state/`,
  which no longer exists, and nothing was captured before the reset.
- **What the journal still had**: it is persistent, so the frozen boot survives.
  Boots `-2` and `-1` are the only two of the last fourteen that end without a
  shutdown message, and both end during the texlive build. Nothing else — no OOM
  kill, no `systemd-oomd` action, no hung-task warning, no XFS error, no NVMe
  error, no `Call Trace`. The journal simply stops mid-stream, which is what a
  wedged device or a dead kernel looks like from outside. In the last run the
  loop had moved basic/bibtexextra/binextra/context (9.3k files) and 4,521 files
  into `fontsextra` when it died — ~14k renames and ~330 spawns/s, far too
  little to kill a machine by saturation.
- **Three configuration choices made it undiagnosable and unrecoverable**:
  `/etc/default/limine` carries `nowatchdog` (no lockup detector, so a kernel
  hang leaves no trace) and `loglevel=3` (warnings off the console), and
  `kernel.sysrq=16` disables every SysRq recovery key — a hard reset was the only
  way out. The drive reports **63 unsafe shutdowns**.
- **What measurement ruled out** (a temporary host sampler, `texlive-split-probe.sh`,
  written for this investigation and [removed 2026-09-20](#2026-09-19--hard-freezes-the-capture-chain-is-armed-and-the-history-is-longer)
  once the cause was known): the split
  loop itself. The real loop, extracted from the PKGBUILD at run time, running on
  a hardlink farm at full `fontsextra` scale — 105,846 files moved in 264 s —
  produced **io PSI 0.00 throughout, at most 2 processes in D state, peak device
  utilisation 16 %, memory flat, zram untouched**. The loop's work does not
  saturate this machine; the trigger needed something that was present then (the
  19 GB source fetch, a concurrent lane, or an intermittent device fault) — and
  it turned out to be the kernel itself (CVE-2026-90432). The prime suspect
  recorded here, the NVMe link (ASPM L1 + L1.2 on a **WD SN560**, which this
  entry said the cmdline forced via `pcie_aspm=powersave`), **rests on a premise
  that was never true**: checked 2026-09-20, there is no `pcie_aspm=` token in
  `/proc/cmdline` or `/etc/default/limine` and the policy reads `default` — the
  L1 state is the firmware default. The queued differentials (ASPM off,
  `ananicy-cpp` stopped, zram off) are therefore moot rather than pending.
- **Fixed regardless — the loop was the recipe's hot path**: 4,115 full rescans
  of the 18.7 MB tlpdb plus one `mkdir -p` + one `mv` per file (301k process
  spawns). It now cuts the tlpdb into per-package sections in ONE awk pass,
  extracts runfiles/formats/maps/hyphens with shell builtins, and issues the
  renames per destination directory in batches. Fixture: **37 spawns vs 2,482**
  (67x fewer). Real data: **0.94 s vs 13.79 s** for `fontsrecommended` (5,299
  files, 14.7x). The whole split drops from ~8 minutes to well under a minute,
  which shrinks the window in which a stall can happen at all.
- **Also fixed — a silently broken package**: the loop MOVES files out of
  `texmf-dist`, so a build resumed over an already-split tree produced packages
  with files missing. In this checkout **13,870 of 150,746** planned runfiles were
  already gone. `prepare()` now counts the gaps and refuses, printing the count,
  the reason, up to five of the missing paths, and the remedy (`rm -rf src`).
- **Validation**: `tests/texlive-split.sh` runs the previous implementation
  (frozen as `tests/assets/texlive-split-legacy.sh`) and the live one over the
  same synthetic tree and requires identical type/mode/path/symlink listings,
  identical content hashes, identical `pkgdesc-*`/`depends-*`/`packages-*` and
  `.fmts`/`.maps`/`.dat*`, plus the spawn reduction and the depletion refusal. On
  real data both implementations produced 6,098 identical tree entries and 5,302
  identical file hashes. The fixture earned its keep during the rewrite: an
  accumulated `AddFormat` list that kept a trailing newline made the follow-up
  `read` loop iterate once more and the `grep` match a second time.
- **Outcome (same day, resolved as "not the recipe")**: the maintainer ran the
  frozen pre-rewrite loop at full `fontsextra` weight from a console with no
  compositor and it **completed**; then built the package for real with
  `makepkg -si` in the desktop session and it **built and installed** (23
  archives, `texlive-meta` 2026.1-1 at 13:10, ~4 min of split on a fresh 19 GB
  checkout). So two independent full-weight runs of the exact workload that was
  mid-flight both freezes have since finished. A workload that resolves the
  symptom does not reproduce it, which leaves an intermittent device or kernel
  fault as the remaining explanation, and the ASPM/zram/ananicy differentials in
  `MEMORY.md` §5 as the next step. Nothing was changed on the host to make the
  builds succeed.
- **The part worth keeping: the freezes were diagnosable only by luck.** The
  journal was persistent, so `journalctl -b -1` still held the dead boot's kernel
  log; the recipe's own log did not exist (`.state/` was gone), and no lockup
  detector was armed (`nowatchdog`), no recovery key worked (`kernel.sysrq=16`),
  and a wildcard `rm -rf /tmp/texlive-split-probe.*` deleted the samples of a run
  that was still in flight. The probe is gone now, but the habit it taught is
  not: a sampler that aborts without keeping its evidence has thrown away the
  experiment, and nobody should clean `/tmp` by glob while a measurement is
  running.
- **Rule**: a bulk `prepare()` that moves files must (a) refuse to run on
  incomplete inputs instead of shipping a quietly broken package, and (b) be
  batched — these loops cost process spawns, not bytes. And when a machine
  hard-freezes with "no CPU load": read `journalctl -b -1` first (the frozen
  boot's kernel log survives the reset), and switch `kernel.sysrq` back on before
  blaming the workload.

## 2026-09-18 — logseq: a resumed build aborted on `opam switch create`

- **Symptom**: found while validating the fix above. The first `makepkg` run in
  that clone completed the opam stage, so `$srcdir/opam-root/logseq-cli`
  existed; re-running the build — the normal action after any failure —
  aborted with `[ERROR] There already is an installed switch named logseq-cli`
  and `==> ERROR: A failure occurred in build()`, before a single bundle was
  rebuilt. Every retry failed the same way, so the recipe was effectively
  single-shot per clean source tree, and the fix above would never have
  produced a package on the state the checkout was actually in.
- **Root cause**: `build()` assumed a pristine `$srcdir`. `opam switch create`
  exits **2** when the switch is already installed (measured), and makepkg's
  `run_function_safe` enables `shopt -o -s errexit errtrace` (line 397 of
  `/usr/bin/makepkg`), so a non-zero mid-`build()` command aborts the whole
  run. The `opam init` on the preceding line is idempotent (rc=0 against an
  initialized root, measured), which is why only this call was a problem.
- **Fix**: create the switch only when it is absent —
  `if ! opam switch list --short 2>/dev/null | grep -Fxq "${OPAMSWITCH}";
  then opam switch create "${OPAMSWITCH}" ocaml-base-compiler.5.1.1 -y; fi`.
  First-run behaviour is identical, and a resumed run reuses the pinned
  OCaml 5.1.1 switch the interrupted run already installed instead of redoing
  the opam work.
- **Validation**: the guard was exercised both ways against the real opam root
  — `logseq-cli` reports "exists, skip create", a bogus name reports "would
  create". `tests/logseq-desktop-recipe.sh` asserts the guard is present and
  was red-verified with a syntax-preserving mutation (the assertion fails while
  `bash -n` still passes). The resumed full build completed with the switch
  already in place, which is the same path a maintainer retry takes.
- **Rule**: `build()` restarts from the top on every invocation while `$srcdir`
  persists, so every step must be idempotent — `opam switch create`, `mkdir`,
  `patch`, a bare `git clone`. errexit turns any of their non-zero exits into a
  hard abort, and the error names the guard-less command rather than the reason
  the tree is not pristine.

## 2026-09-18 — logseq: a concrete Java dependency demanded the removal of the JDK

- **Symptom**: `makepkg -si` in `logseq-desktop-git` aborted before fetching
  anything:
  `jre-openjdk-26.0.2.u10-2 and jdk-openjdk-26.0.2.u10-2 are in conflict. Remove
  jdk-openjdk? [y/N]` — then `failed to prepare transaction (conflicting
  dependencies)` and `Missing dependencies: clojure, jre-openjdk, ocaml, opam`.
- **Root cause**: the recipe's `makedepends` named the concrete package
  `jre-openjdk` to satisfy "shadow-cljs needs a JVM". Arch's OpenJDK packages
  are mutually exclusive — `jre-openjdk` conflicts with `jdk-openjdk` (and both
  conflict with `jre-openjdk-headless`) — while `clojure`, which the same
  `makedepends` requires, itself depends on `java-environment`, i.e. on a JDK.
  So the recipe asked for a package that cannot coexist with the package the
  recipe's own dependency graph installs, and pacman's only way to satisfy both
  was to remove the JDK. The JRE entry was redundant as well: nothing in the
  build compiles Java (shadow-cljs emits JavaScript).
- **Verification loop**: `pacman -T` over the recipe's `depends` + `makedepends`
  is precisely makepkg's own gate (`check_deps()` → `run_pacman -T`, and only
  the resulting *missing* list is installed). Before the fix it printed
  `clojure jre-openjdk ocaml opam`, matching the user's log byte for byte;
  after it prints `clojure ocaml opam`. `pacman -Sp clojure java-runtime ocaml
  opam` also resolves with no conflict prompt.
- **Fix**: `'jre-openjdk'` → `'java-runtime'`. Every JDK and every full JRE
  provides that virtual, so any installed Java satisfies it (`pacman -T
  java-runtime` → rc=0 on the host) and nothing extra is downloaded; a
  headless-only JRE would still be satisfied by the JDK that `clojure`
  requires anyway. Upstream is consistent with this: its release workflow uses
  `actions/setup-java` (a JDK), and nothing in the tree invokes `javac` or
  reads `JAVA_HOME`.
- **Tests**: `tests/logseq-desktop-recipe.sh` now requires `java-runtime` and
  fails on any `'(jre|jdk)…'` entry in the recipe (both branches red-verified),
  and `.SRCINFO` was regenerated — the fixture's parity check caught the stale
  file immediately.
- **Rule**: request a capability through its virtual, never through one
  concrete provider (golden rule 4). A concrete provider can be *mutually
  exclusive* with another package the same dependency graph needs, at which
  point the graph is unsatisfiable rather than merely narrow.

## 2026-09-17 — sudo keepalive stopped runs for nothing, then spammed

- **Symptom** (screenshot from a `-i` run): a three-line block — "sudo timestamp
  expired and cannot be refreshed non-interactively — stopping dispatch" —
  repeated every poll for as long as lanes kept building, while the dashboard
  sat on `▲ STOPPING`. Dispatch stopped; when the in-flight lanes happened to
  succeed, the run then printed **"All builds succeeded! Built: 0 packages"**.
- **Root cause 1 — the probe measured the wrong thing.** `sudo -n -v` was used
  as a proxy for "an install can run". On this host it is not:
  `/etc/sudoers` has `(ALL) ALL` *and* `(ALL : ALL) NOPASSWD: ALL`, so
  `sudo -n -v` fails forever (the password rule owns validation) while
  `sudo -n pacman -U …` succeeds every time — verified live:
  `sudo -n -v` → rc=1, `sudo -n pacman --version` → rc=0. The keepalive fired
  ~150 s in (the cached credential had aged past its timeout by then), declared
  the credential dead, and stopped a run whose installs were never at risk.
- **Root cause 2 — the failure path had no memory.** `last_sudo` was only
  updated on success, so once the probe failed the branch re-fired on every
  0.5 s poll and re-printed the whole message; nothing latched.
- **Root cause 3 — a stopped dispatch reported success.** `run_lanes` returned
  0 whenever no package had *failed*, so packages that were never dispatched
  disappeared into "All builds succeeded! Built: 0 packages".
- **Fix** (`build-all.fish`):
  - `sudo_probe` classifies `fresh` (`sudo -n -v` refreshed), `nopasswd`
    (`-v` refused but `sudo -n pacman` works → nothing to keep warm) or `cold`,
    and the last of those probes the mechanism the lanes themselves use, so its
    answer cannot be rosier than an install would be.
  - An `-i` preflight settles sudo *before* building: it refreshes, or
    self-elevates, or refuses to start. Building for an hour to discover that
    the installs cannot happen was the old behaviour.
  - `sudo_elevate_interactively` lets the dispatcher ask for the password
    itself (it owns the terminal; lane children never do), gated on stdin
    being a terminal and bounded by `timeout` so an unattended run cannot hang.
  - The cold path latches (`sudo_state = down`): one message, one stop, no
    repeats — and if packages were left unstarted the run exits non-zero with
    `_RL_SUDO_NOTE` replacing the misleading "Build failed" heading.
- **Fixing that exposed a second, older bug** (same subsystem, found because the
  new fixture tails lane stderr): `set -gx MAKEFLAGS (string join ' ' $make_flags)`
  always failed — fish hands every argument after the first to `string`'s own
  option parser, so `-j4` produced `string join: -j4: unknown option`, the
  substitution aborted, and **MAKEFLAGS was never exported to a lane**. The
  per-lane job budget therefore never reached upstream Makefiles (only
  `GSA_BUILD_JOBS`, which the workspace's own PKGBUILDs read, did). Fixed with
  a quoted list expansion (`set -gx MAKEFLAGS "$make_flags"`), which joins with
  spaces and cannot be parsed as an option.
- **Tests**: new `tests/sudo-keepalive.sh` drives four real sudoers shapes
  (`nopasswd`, `cold`, `expires` mid-run, `promptable`) through the actual
  dispatcher with a fake `sudo`/`pacman` and a virtual clock (the 150 s
  interval elapses inside a 10 s fixture), including a pty sub-case via
  `script` that proves the dispatcher prompts exactly once and carries on. It is
  red on the previous script ("nopasswd run stopped dispatch although installs
  need no password"). `tests/scheduler-intensity.sh` now asserts each lane's
  exported `-j` budget in `MAKEFLAGS`/`NINJAFLAGS`/`GSA_BUILD_JOBS`, which is
  red on the old `string join` form.
- **Rule**: probe a capability with the mechanism the code will actually use,
  never with a neighbouring command that merely looks equivalent; and a run
  that stops before dispatching everything is a failure, not a success.

## 2026-09-17 — structure audit, phase C: documentation truth pass

- **Symptom**: the docs described a stack that had moved on. Every claim below
  was checked against the live host or the checked-in code, and each stale one
  was rewritten rather than softened.
- **`MEMORY.md` §5 "Pending tasks" was mostly already done** — verified with
  pacman, not assumed: `hyperv`, `intel-speed-select`, `x86_energy_perf_policy`
  and `llvm-ocaml-git` are gone, so that whole `-Rns` item is obsolete;
  `seatd-git` is installed *and* its `.PKGINFO` already carries
  `libseat.so=1-64`; the stale `gcc-*-snapshot` language splits are gone (only
  fortran, libs and `lib*-snapshot` remain); mesa-git's zero-gcda abort is
  implemented; llvm-git's `X86;AMDGPU;BPF` rebuild landed (`llvm-config
  --targets-built` reports all three) and scx-scheds-git was rebuilt after it.
  The ROCm row was **wrong in the opposite direction**: hsa-rocr, rocm-llvm and
  comgr were reinstalled, so only `hip-runtime` is missing. Still open and kept:
  the dbus-broker recipe redundancy, the gtk4-demos split, libadwaita-git's
  `check()`+`checkdepends=(weston)` (which the earlier check missed by looking
  in the wrong category), the doxygen-git purge, and one linux-firmware item
  whose subject was never recorded — now flagged for re-specification because
  upstream has no `legacy/` tree and the current trim already covers it.
- **`MEMORY.md` §3 was a dated snapshot with rotten versions** (it claimed
  `LLVM_TARGETS_TO_BUILD="X86;AMDGPU"` and qt6-base-git 6.13.0-dev while the
  installed stack was newer and different). Rewritten as durable stack facts
  with no version numbers — `pacman -Q` is authoritative — and the one-off
  install history was dropped (NOTE.md has it).
- **Golden rule 1 blamed the wrong thing**: it said the system `ls` is
  "NON-GNU". GNU coreutils 9.11 *is* installed; the flag hazard comes from
  CachyOS's fish aliases (`ls` → `eza -al`, `grep` → `--color=auto`, plus
  `la/ll/lt/l.`, `update`, `big`, `rip`). The rule now separates the real
  boundary — tool-call shells are bash, the login shell is fish — from the
  alias trap, and lists the aliases.
- **`MEMORY.md` §2** claimed `.state/` holds "logs, locks, lane results, and
  builder caches"; `LOG_DIR` is the only path derived from `_STATE_DIR`, and
  makepkg sources/archives land beside each recipe (`SRCDEST`/`PKGDEST` =
  `$startdir`).
- **`architecture.md` had the same runtime-state error** — it listed source
  mirrors and package outputs under `.state/`, contradicting `build-guide.md`
  and `README.md`. It also described a recipe as "a PKGBUILD, its .SRCINFO, and
  only the local files needed by makepkg", omitting the license material and
  maintenance metadata the tree actually carries (106 `LICENSE`/`LICENSES`,
  50 `.nvchecker.toml`, 3 `BUILDING`).
- **`portability.md` published one host's numbers** ("24-thread/21-GiB host …
  `2 lanes × -j3`") in a document whose point is that no host's shape is baked
  in. Replaced with the actual formulas from `run_lanes` — and verified by
  recomputing all five profiles for the fixture's pinned 24-thread/21-GiB
  inputs, which reproduce the fixture's expectations exactly (`low` 1/-j3/-j3,
  `medium` 2/-j3/-j4, `high` 3/-j3/-j6, `xhigh` 4/-j3/-j7, `max` 6/-j3/-j9).
- **Prerequisite lists were short**: `build-guide.md` and `README.md` sent
  readers to `--audit` without listing `ripgrep`, and omitted `ps`/`tail`.
  Corrected to match `check_runtime_prereqs` exactly, with `rg`/`git` called
  out as mode-specific.
- **`README.md`'s group table** invited a wrong sum: "126 recipes" over group
  counts adding to 129. It now states both numbers and names the five `core`
  members that live outside `packages/core/` (autofdo-git, libclc-git from
  `git`; hip-runtime, hsa-rocr, openssl from `stable`).
- **Triplicated PGO text collapsed**: the operational procedure stays in
  `build-guide.md` (now stating the five libraries are verified clean — checked
  live: `readelf` reports zero instrumentation symbols), the rule in
  `CONTRIBUTING.md` is one line pointing there, and the failure mechanisms stay
  in `MEMORY.md` §6.
- **`NOTE.md` naming-history preamble added**: a table mapping `.Heavy/
  .Heavyweight/.Static/.Stable/.Core/.3rdP/.Misc` onto today's
  `packages/<category>/`, and `static/heavy/critical/rocm` (plus `-si`) onto
  today's groups and flags, so the ~50 lines of pre-2026-09-15 entries are
  readable without archaeology. `MEMORY.md` links to it from its header.
- **Validation**: `tests/run-all.sh` → 13 fixtures pass (docs-only phase, so no
  script behaviour changed and nothing needed re-baselining); every internal
  `docs/*.md` reference resolves; the documented `.SRCINFO` command reproduces
  the committed file byte-for-byte.
- **Rule**: docs that state current state rot silently — state *how to check*
  (a command, a formula, a pointer) instead of copying the answer; keep dated
  snapshots in the journal, and re-verify a pending-task list against the host
  before trusting any item on it.

## 2026-09-17 — structure audit, phase B: control data, ignore rules, fixtures

- **Symptom**: the map, the ignore rules, and the fixture set all still
  described a tree that no longer existed, and nothing checked the invariants
  they encoded.
- **Dead control column removed**: `config/packages.map` carried a third field
  (`original-path`, e.g. `.Stable/dbus-broker`). `load_project_config` stores
  only `"$id|$relative_path"`, so the column was parsed and thrown away — its
  only consumer was the loader's own `count $fields -ne 3` guard. It was also
  internally inconsistent: 66 of 126 rows held a real pre-Git path while the
  rest held the bare package name as filler, since the restructure added the
  field to satisfy validation rather than to record anything. The map is now
  `package-id|recipe-path` and the loader requires exactly two fields; a
  three-field record is red-verified to fail with `invalid package map record`.
  Nothing is lost — the same old paths survive in this journal.
- **Integration caught by the new runner**: two recipe fixtures asserted the
  old `id|path|id` shape and failed the moment the map changed. They now assert
  `id|path`. This is the argument for running the whole battery rather than the
  fixture that matches the recipe being edited.
- **Dead ignore rule removed**: `.gitignore` excluded `Project-structure.txt`,
  a file that exists nowhere in the tree — a rule left over from the pre-Git
  workspace.
- **Self-hiding ignore removed**: `packages/git/xorg-xwayland-git/.gitignore`
  was a bare `*` with no negations, which also hid the file from itself — so it
  could never be committed, and a clean checkout had no ignore rule at all. The
  root rule `packages/*/*/*/` already covers the `xserver/` clone makepkg
  fetches there; verified by recreating the directory and confirming
  `git check-ignore -v` still matches it from the root rule while `git status`
  stays clean.
- **New fixture `tests/recipe-sources.sh`** (repo-wide, was only ever checked
  per-recipe): for all 126 recipes it sources each `PKGBUILD` in a subshell —
  the way the builder itself resolves sources — and asserts that every non-URL
  `source=()` entry exists **and** is committed, that every `install=` script
  exists and is committed (11 recipes; `${pkgbase}` is resolved), that no recipe
  `.gitignore` hides itself, and that no ignore rule matches an already-tracked
  file (`git ls-files -i -c --exclude-standard`). Baseline: 118 local sources,
  11 install scripts, all tracked.
  Red-verified one case at a time — nonexistent source, source present but
  ignored, source present but untracked, nonexistent install script, untracked
  install script, self-hiding ignore — each failing with its own message before
  being restored. `DOWNLOADED` GNU patch files under `packages/stable/bash/` are
  the single deliberate exemption.
- **New runner `tests/run-all.sh`**: discovers every fixture (a new one needs no
  edit here), runs them all, prints per-fixture results with the failing output
  indented, and exits non-zero on any failure. Accepts a substring filter
  (`tests/run-all.sh recipe`). Fixture permissions normalised to 755, and
  `CONTRIBUTING.md`'s validation section now points at the runner instead of a
  hand-maintained list that had already drifted.
- **CONTRIBUTING hardened**: a new local asset must negate its recipe's
  default-deny `*` rule in the same change (`git check-ignore -v <asset>` must
  print nothing), an ignore file must never match itself, and the map's
  two-field format is stated where maintainers add recipes.
- **Validation**: `fish -n`; `--list`, `--audit` and all five `--dry-run` outputs
  byte-identical to the pre-change baseline; `tests/run-all.sh` → 13 fixtures
  pass; each new assertion red-verified then restored.
- **Rule**: dead control data is worse than a missing feature — it looks like
  authority. When a column, rule, or script has no reader, delete it in the same
  change that retires the layout it describes; and never trust a per-recipe
  guard to cover a repo-wide invariant.

## 2026-09-17 — structure audit, phase A: dead CLI surface and the legacy audit

- **Symptom**: the builder carried an option nothing had needed since
  2026-09-07, a function nothing called, and an audit that ran the same scan
  three ways — two of them unable to ever fire again.
- **Dead function**: `find_audit_pkg_dirs` was a one-line wrapper around
  `find_pkg_dirs` with no call sites. Function-by-function call counting over
  all 55 definitions now shows every remaining function has a real invocation
  (`handle_interrupt` is registered through `--on-signal`), so none is dead.
- **Dead option**: `-si/--sepinstall` had been reduced to a warning plus the
  same `set install_flag 1` as `-i`. `-i` *is* the separated install, so the
  alias added a second spelling of one behaviour; removed from the parser and
  from `usage()`, and `-si` now reports `unknown option` like any other stale
  flag. The usage text for `-i` records where the alias went.
- **Audit collapsed**: the three legacy scans (`rg -n` "control-file
  references", a byte-identical `rg -l` pass mislabelled "generated-artifact
  references", and a `find -type l` symlink sweep) became one `rg` pass. The
  directory-existence and symlink arms were dropped: they resolved against
  top-level `.Stable/.Heavy/.Static` trees that no longer exist, so all three
  could only ever print `none`.
- **Audit widened while narrowing**: the single surviving scan matches
  `(^|[^[:alnum:]_])\.(Stable|Static|Heavy|Heavyweight|Core|Misc|3rdP)/`, i.e.
  every pre-Git layout name, not just the three the old pattern knew. The old
  pattern also required the name at line start or after `/`, so prose mentions
  such as "cp .Heavy/foo ." were invisible; verified against a scratch file that
  the new pattern catches both ` .Heavy/` and `/.Static/` while ignoring
  `x.Core/`. `config/` stays excluded — it is validated structurally at load
  time — and `docs/` stays excluded because this journal is *expected* to name
  the old layout.
- **`-ia/--installall` kept, documented**: it is the deliberate one-transaction
  escape hatch and it structurally cannot satisfy rule 11
  (install-before-dependents-compile). Its `usage()` entry now says so where the
  model choice is visible, instead of leaving the contradiction implicit.
- **Duplication removed**: `--lanes` and `--jobs` had byte-identical ~15-line
  validation blocks; both now call `parallelism_is_valid <flag> <value>`, with
  the caller's flag name interpolated so the two error strings are unchanged.
- **Stale comment**: the lane-design block called core packages "Heavy-group
  packages", a group name retired in the 2026-09-15 merge.
- **Validation**: `fish -n`; `--list`, `--audit` and `--dry-run` for all five
  groups byte-identical to the pre-change baseline except the audit's new
  section; `-si` now rejected; `--lanes`/`--jobs` error strings verified
  unchanged for missing, zero, and non-numeric values; the full fixture battery
  (11 fixtures) passes.
- **Rule**: an option, function, or audit arm that cannot change any outcome is
  not free — it is a stale claim about how the project works. When a layout or
  behaviour is retired, delete its CLI surface in the same pass; when an audit
  section can only print `none`, either widen what it looks for or remove it.
- **Note**: this is phase A of a three-part audit; layout (`config/`) and docs
  (`MEMORY.md`/`NOTE.md`) phases follow and are logged separately.

## 2026-09-17 — stray `config/groups` inventory removed

- **Symptom**: `config/groups/physical-groups.list` sat in the directory the
  builder loads group definitions from and looked authoritative, but nothing in
  the tree referenced it.
- **Character in the build script**: it was never read. `read_group_config` is
  called for exactly the five declared names
  (`for group_name in git stable core misc third-party`), and `resolve_group`
  switches on those same five, so `--group physical-groups` is rejected (rc=1)
  without any file being opened. Even if it were read, its tab-separated
  `category<TAB>package-id` lines fail the loader's `^[A-Za-z0-9._+-]+$` check
  and it would report `invalid package group`.
- **Staleness**: it was a publication-time snapshot that was already wrong when
  created — its 123 entries missed `core cmake-git` and `stable mkinitcpio`, and
  by now also missed `git logseq-desktop-git` and `git texlive-texmf`.
- **Redundancy**: its whole content is derivable from `config/packages.map`
  (`awk -F'|' 'NF>=2 && $0 !~ /^#/ {n=split($2,a,"/"); print a[2]"\t"$1}'
  config/packages.map | sort`), so nothing is lost by deleting it.
- **Fix**: deleted the file. Nothing else changed — the loader never opened it,
  `--group physical-groups` behaves identically before and after (rejected,
  rc=1, no output), and every group command still validates the five real files
  through `load_project_config`.
- **Guard**: `tests/project-config.sh` now asserts that `config/groups/`
  contains exactly the five declared groups, so a stray file there (an
  inventory, a `.bak`, a hand-made list) fails the fixture instead of drifting
  silently.
- **Validation**: `tests/project-config.sh` plus the whole fixture battery,
  `--list`, `--audit` and `--dry-run` for the five groups all pass after the
  removal.
- **Rule**: a file living in a directory the builder reads, but unreachable
  through that directory's loader, is a trap — either wire it up or delete it;
  never keep a stale duplicate of another control file.

## 2026-09-17 — texlive-texmf recipe (TeX Live collections, meta closure)

- **Task**: be able to build the 19 `texlive-*` packages that
  `paru -S texlive-meta` would install, tracking upstream, in the `git` group.
- **Finding**: those 19 packages are exactly `texlive-meta` plus its depends
  closure, and the dependencies come from a single pkgbase. Arch builds the
  whole collection set from `texlive-texmf`, whose three pinned SVN sources
  (`Master/{texmf-dist,tlpkg,bin/x86_64-linux}`, `#revision=78408`) are split
  per collection by `prepare()` from `tlpkg/texlive.tlpdb`. The per-collection
  repositories visible in Arch's GitLab (`texlive-fontsextra`, ...) are stale
  leftovers: the shipped `extra/texlive-*` packages come out of
  `texlive-texmf`, and `texlive-doc`/`texlive-meta` are splits of it too.
- **Decision**: keep the recipe trimmed to the maintained target —
  `texlive-meta` plus the 22 non-lang collections. The 17 `lang*` collections
  and `texlive-doc` are dropped together with their `texlive-langextra`
  provides/replaces and the `groups=('texlive-lang')` branch. Only whole splits
  are removed, so `pkgrel` stays 1 and every retained package remains
  content-identical to the repository package at `2026.1-1`.
- **Finding (SVN sources)**: `makepkg` accepts a plain `svn://…#revision=N`
  source (no `svn+` prefix needed), caches the checkout in
  `$SRCDEST/<basename>` and refreshes it with `svn update -r`. The builder's
  `nuclear_cleanup` only understood `git+` VCS sources and `*.tar.*` downloads,
  so the recipe's `texmf-dist`/`tlpkg`/`x86_64-linux` checkouts (~3.5 GB) and
  the new `latexminted` wheel would have survived `--nuclear` forever. Fixed:
  `svn://`/`svn+` sources are now resolved like `git+` ones (name derivation
  matches makepkg's `get_filename`, verified against all three URLs) and
  `*.whl` is cleaned with the other downloads.
- **Finding (optimisation)**: `arch=(any)` means there is no compiler phase, so
  the ISA/LTO/PGO playbook cannot apply. Debug packages are produced by the
  strip tidy rule, so upstream's `options=(!strip)` also disables the debug
  split, and the host `makepkg.conf` already sets `!debug`. The applicable
  optimisation is scope, so the tlpdb splitting loop and the
  `texmf-dist/doc/*` skip were left verbatim (changing them would alter package
  contents) and `makedepends` stay at `subversion` only.
- **Validation**: `bash -n`, `makepkg --printsrcinfo` parity, `fish -n`,
  `--list`, `--audit` (no membership drift; dependency graph resolves) and
  `--dry-run --group git` pass, and the new `tests/texlive-recipe.sh` fixture
  is red-verified for a removed collection, a pkgver bump, a `_rev` bump, a
  restored `texlive-doc` split, a dropped `!strip`, an added `build()` phase,
  a removed SVN cleanup branch, and a missing support file.
- **Live upstream check**: `2026.1` is the newest tag, and the pinned revision
  resolves (`svn info -r 78408` succeeds for both
  `tags/texlive-2026.1/Master/tlpkg` and `.../texmf-dist`). Two traps found
  while checking, both now documented in `BUILDING`: `Revision:` from
  `svn info` is the *repository* revision (80294 at check time) while
  `Last Changed Rev` is only that directory's own last change (78234) — TeX
  Live keeps patching a tag after it is cut (r78237 and r78408 touched files
  under `tlpkg`), so the higher pin is deliberate; and an https fallback does
  not exist (`https://svn.tug.org/texlive/` and `http://tug.org/svn/texlive/`
  answer HTTP 406, so only `svn://` on port 3690 works). An earlier draft of
  `BUILDING` claimed an https alternative and was corrected.
- **Not run**: the full build (multi-GB checkout plus 23 splits), by request.
- **Rule**: when a distribution builds many split packages from one pkgbase,
  mirror that pkgbase rather than inventing per-split recipes; trim by deleting
  whole splits together with their depends/provides/paths, and state explicitly
  when a package has no compiler phase to optimise.
- **Flagged, then fixed in a follow-up commit**: `config/groups/physical-groups.list`
  was unreachable, stale control state. Removed; the reason is recorded in the
  entry above this one.

## 2026-09-17 — logseq-desktop-git recipe (desktop, upstream HEAD)

- **Task**: add a self-tracking Logseq desktop recipe to the `git` group that
  follows the house optimization standard.
- **Decision**: track upstream `master` (the 2.x database line;
  `src/main/frontend/version.cljs` carries `2.0.1`) rather than the 0.10.x
  maintenance line, because group recipes follow upstream HEAD. `pkgver()`
  reads the version the tree carries and appends the revision count and short
  hash, matching the noctalia-git idiom.
- **Finding**: upstream removed the ClojureScript CLI. The desktop app embeds
  a CLI runtime that is built by OCaml + Melange (`cli/dune`) and bundled by
  Vite, and `scripts/prepare-desktop-runtime-js.mjs` hard-requires
  `static/js/logseq-cli.js`. `ocaml` and `opam` are therefore real
  makedepends, not optional extras. The recipe creates a private switch under
  `$srcdir/opam-root` (never the builder's `~/.opam`) and pins OCaml 5.1.1 to
  match the upstream release workflow.
- **Finding**: the only valid build sequence is the one in
  `.github/workflows/build-desktop-release.yml`: `pnpm install`, `gulp build`,
  `cljs:release-electron`, `db-worker-node:bundle`, `opam exec -- pnpm
  cli:release`, `webpack-app-build`, `desktop:prepare-runtime-js`, then
  electron-builder inside `static/`. The published AUR `logseq-desktop-git`
  PKGBUILD is stale (yarn, electron-forge, 0.9.10) and is kept only as
  attribution.
- **Optimization standard**: the only compiled code is the two native Node
  addons (`@zvec/zvec`, `keytar`), so the recipe declares
  `options=(!strip !debug !lto)` and applies ccache plus the mold probe to
  those addons only. No ISA or optimization flags are hard-coded.
- **Packaging**: electron-builder runs with `--dir` (unsigned unpacked tree)
  instead of the upstream AppImage; the tree is installed under
  `/opt/logseq-desktop-git`, `chrome-sandbox` is installed setuid root, and
  `/usr/bin/logseq` reads extra flags from
  `${XDG_CONFIG_HOME:-$HOME/.config}/logseq-flags.conf`. Electron is bundled
  from the version pinned in `resources/package.json` rather than taken from
  the repositories.
- **Validation**: `bash -n PKGBUILD`, `makepkg --printsrcinfo` parity,
  `fish build-all.fish --list`, `--dry-run --group git` (55 packages) and
  `--audit` (no membership drift, graph resolves) pass, together with
  `tests/project-config.sh` and the new `tests/logseq-desktop-recipe.sh`
  fixture (red-verified against removed mold probe, `!lto`, `ocaml`
  makedepend, setuid bit, and branch). The full build was not executed here:
  it needs several GB of npm, Clojure, opam and Electron downloads, and a full
  rebuild is explicitly not a syntax check for this project.
- **Rule**: for a from-source Electron package, mirror the upstream release
  workflow literally, treat heavyweight toolchains (opam/OCaml) as real
  makedepends, and keep their state inside `$srcdir`.

## 2026-09-17 — mkinitcpio optional NvPCR glob failure

- **Symptom**: `mkinitcpio -P` failed for every kernel with
  `file not found: '/usr/lib/nvpcr/*.nvpcr'`; the generated image was
  reported as potentially incomplete.
- **Cause**: the Projects systemd recipe intentionally sets
  `-Dbootloader=disabled` for Limine, so it does not install systemd's
  optional NvPCR definition files. Stock `mkinitcpio 42-1` added an
  unguarded glob to its systemd and `sd-encrypt` install hooks.
- **Fix**: added a `mkinitcpio` stable recipe at `pkgrel=2` with a minimal
  patch that skips absent optional `.nvpcr` files, plus a regression fixture.
  The systemd bootloader choice remains unchanged.
- **Second failure (source verification)**: the first rebuild of the new
  recipe aborted with `unknown public key 6B5387E670A955AD`. The upstream
  `validpgpkeys` array lists only nl6720's primary key; the `v42` tag is
  signed by the newer NIST P-384 signing subkey
  `73B3CABFC4BF3F207641BD4B6B5387E670A955AD`.
- **Fix for the second failure**: verified the subkey fingerprint against the
  maintainer's published key (GitHub `nl6720.gpg`, GitLab Arch, keys.openpgp.org),
  added it to `validpgpkeys` next to the primary key, imported the verified key,
  and re-ran the build. No verification was skipped.
- **Validation**: the hook fixture passes with no `/usr/lib/nvpcr` directory;
  `git verify-tag v42` reports `Good signature`; the package builds, and the
  installed `mkinitcpio 42-2` ships hooks with the guard at
  `/usr/lib/initcpio/install/{sd-encrypt,systemd}`. `sudo mkinitcpio -P`
  regenerated every preset (Limine) successfully, including
  `linux-cachyos-rt-bore-lto` and stock `linux`.
- **Rule**: optional initramfs payloads must be guarded at the hook boundary;
  do not make an unrelated bootloader feature mandatory to satisfy an
  optional glob.
- **Re-verify** without touching the installed package by pointing the hook
  search path at a directory of copied hooks (`-D` replaces, not extends, the
  search path, so pass the parent containing `hooks/`, `install/`, and
  `post/`):

  ```sh
  sudo mkinitcpio -D /tmp/hookroot -g /tmp/red.img -k /boot/vmlinuz-linux
  sudo mkinitcpio -D /usr/lib/initcpio -g /tmp/green.img -k /boot/vmlinuz-linux
  ```

  Stock hooks report `file not found: '/usr/lib/nvpcr/*.nvpcr'`; the patched
  hooks finish with `Initcpio image generation successful`.
- **Rule**: when a signed tag fails verification, resolve the signer against
  the maintainer's published key and add the signing subkey fingerprint to
  `validpgpkeys`; never bypass the check.

## 2026-09-16 — Published recipe omitted by local ignore rule

- **Symptom**: a fresh checkout rejected `xorg-xwayland-git` during
  `build-all.fish --list` with `invalid package map path`, even though the
  package was listed in `config/packages.map` and `config/groups/git.list`.
- **Cause**: the source workspace's package-local `.gitignore` contained `*`.
  The migration copied the map entry but a normal `git add` skipped the
  recipe directory, leaving a mapped package with no published `PKGBUILD`.
- **Fix**: restored the recipe and `.SRCINFO` to the public tree without the
  wildcard ignore file, and added `tests/project-config.sh` to exercise the
  real listing path.
- **Rule**: after a package migration, run `build-all.fish --audit` and
  `build-all.fish --list`; every map entry must have a tracked `PKGBUILD`.
  Do not publish package-local wildcard ignore files that can hide recipe
  changes.

## 2026-09-17 — GTK4 local packaging assets omitted

- **Symptom**: a clean checkout failed before building GTK4 because
  `gtk-update-icon-cache.hook` was declared in `source=()` but was not found
  in the recipe directory.
- **Cause**: the four GTK4 hooks/scripts existed only as ignored working-tree
  files; the package-local wildcard `.gitignore` hid them from the public
  repository.
- **Fix**: publish all four local assets, remove the GTK4 wildcard ignore, and
  add `tests/gtk4-recipe-assets.sh` to require every asset to be present and
  tracked.
- **Rule**: every non-URL `source=()` asset is essential recipe input and must
  be tracked; package-local wildcard ignore files are not an acceptable way to
  hide generated build state.

## 2026-09-16 — GLib and Cairo PGO reconfigure probe failure

- **Symptom**: after GLib or Cairo's PGO training pass, the final Meson
  reconfigure failed in compiler feature probes.
- **Cause**: Meson retained phase-1 `-fprofile-generate` in cached linker
  arguments while the recipe added `-fprofile-use` to compiler arguments.
  Meson's temporary `-Werror` probes then emitted `-Wmissing-profile` for
  untrained probe files and were reported as failed type-detection checks.
- **Fix**: both recipes now replace compiler and linker argument caches
  together and add `-Wno-error=missing-profile` only to the profile-use
  transition.
- **Validation**: shared fake-Meson fixtures reproduce the stale-cache
  failure for both recipes and pass after the fix; a real temporary Meson
  project confirms the four option sets are replaced and compiles successfully.
- **Rule**: treat Meson PGO transitions as a cache migration, not an
  environment-variable update; clear both compile/link instrumentation and
  tolerate missing profiles in configure probes.

## 2026-09-16 — GLib/Cairo PGO verifier false positive

- **Symptom**: the final GLib or Cairo build was rejected because
  `build/meson-private/sanity_check_for_c.exe` still exported profile
  instrumentation.
- **Cause**: the verifier scanned every executable in the Meson build tree,
  including temporary configure helpers left from the training phase. That
  helper is not installed into either GLib package.
- **Fix**: moved instrumentation verification to each staged package payload
  after `meson install`, while retaining rejection of instrumented shared
  libraries and executables that would ship.
- **Validation**: shared GLib/Cairo fixtures create the exact
  `meson-private` helper, confirm it is ignored, and confirm an instrumented
  staged library still fails validation.
- **Rule**: validate properties at the package boundary; do not reject
  temporary build helpers that cannot reach the installed artifact.

## 2026-09-16 — GTK PGO coverage symbols leaked into installed libraries

- **Symptom**: after a full group build, `nautilus` and Electron failed at
  load time with undefined `__gcov_indirect_call` from `libgtk-4.so.1` and
  `libgdk-3.so.0`. Replacing the custom GTK and libadwaita packages with
  repository builds restored linkage.
- **Cause**: `gtk3-git` and `gtk4-git` changed shell `CFLAGS`/`CXXFLAGS`
  after the initial Meson setup but did not replace Meson's cached linker
  arguments. They also had no package-boundary check, so coverage-instrumented
  GTK libraries could be installed.
- **Fix**: GTK3, GTK4, and the same-pattern `xorg-xwayland-git` recipe now
  replace all four Meson compiler/linker argument caches, exempt only
  missing-profile configure probes, and reject instrumentation in the staged
  payload. GTK3/GTK4 releases were bumped to `pkgrel=2`; Xwayland to `pkgrel=2`.
- **Validation**: shared fake-Meson fixtures cover GLib, Cairo, GTK3, GTK4,
  and Xwayland transitions, temporary Meson helpers, and contaminated staged
  libraries. All pass after the fix.
- **Rule**: never install a manual Meson PGO result until the final staged
  package is checked for `__gcov_*` and `__llvm_profile`; rebuild all
  consumers after replacing an instrumented GUI stack.

## 2026-09-16 — Full PKGBUILD optimization audit

- **Scope**: all 122 tracked `PKGBUILD` recipes in the public Projects
  checkout; every recipe passed `bash -n` and `.SRCINFO` generation.
- **Findings**: WirePlumber appended unconditional `-march=native -O3` flags
  and installed dead NEWS/README documentation. GTK4 demos and libadwaita's
  optional `weston`/check path remain documented cleanup candidates, not
  automatic removals.
- **Fix**: removed WirePlumber's host-specific flag override and dead
  documentation install, then added the optimization and trimming contract to
  `CONTRIBUTING.md`.
- **Rule**: use host `makepkg.conf` defaults, trim dead packaging inputs only
  with their dependent paths, and preserve PGO workloads and maintained
  features explicitly called out by `MEMORY.md`.

## 2026-09-04 — PKGBUILD trim audit (full workspace)

Standard: trim docs/man/examples/tests/dead splits/dead makedeps; keep
PGO-relevant test suites, all kmod compressors, gtk4 Vulkan renderer, rust
`profiler=true`, clang-opencl-headers split, cups (printing).

Applied (all `bash -n` + `makepkg --printsrcinfo` validated):

- **hip-runtime**: nvidia split + cuda makedep + HIPNV_DIR removed (AMD-only).
  cuda 13.3.1 & gcc15 now orphans — `pacman -Rns cuda gcc15` when convenient.
- **rocm-llvm**: projects `clang;lld` only (mlir/flang/flang-rt dropped — was
  ~30–40% of build time; clang-tools-extra dropped), targets `AMDGPU;Native`
  (NVPTX dropped), `CLANG_ENABLE_AMDCLANG=OFF` (no amdflang), FFLAGS sed block,
  HLFIRDialect workaround and clang-tidy build removed.
- **llvm-git**: targets `X86;AMDGPU`, no lldb/polly/ocaml split/docs/check().
- **gcc-snapshot** (IS system gcc): languages c,c++,fortran,lto (fortran kept —
  hdf5/scipy); no GPU offload/vtv/doxygen docs/16 dead lib splits; multilib and
  libgccjit KEPT (lib32-gcc-libs-snapshot installed / emacs).
- **rust-git**: sanitizers=false, debuginfo=1, dead checkdepends dropped.
- **mesa-git**: directx-headers/cbindgen/python-packaging makedeps, NVK crate
  block, venus-protocol source, bogus opencl-driver provide removed.
- **libclc-git**: amdgcn-only target; polly/spirv-llvm-translator makedeps gone
  (no OpenCL consumers anywhere — delete candidate if ever confirmed dead).
- **libdrm-git**: 8 driver libs disabled, install-test-programs=false.
- **polkit-git**: examples/docs/man/tests off.
- **gtk3-git/gtk4-git**: broadway/cloudproviders/man/docs off (+_pick fixes).
- **cmake-git**: no qt-gui/sphinx-html/emacs. **doxygen-git**: no wizard/search
  (drops qt6-base+xapian runtime deps!). **mold-git**: check() removed.
- **kmod/jemalloc/xz/libunwind/meson-git/libinput**: dead doc/test deps dropped
  (libinput keeps tests — PGO trains via meson test).
- **systemd**: install-tests=false (+tests split gone), homed=false,
  bootloader=false, intltool/kexec-tools dropped.
- **dbus-broker (both copies)**: docs=false, console-users line dropped.
  REDUNDANCY: top-level dbus-broker-git vs .Static/dbus-broker both build the
  same pkgs — resolve which one stays.
- **seatd-git**: server=disabled (seatd daemon not enabled; logind backend).
- **ccache/vulkan-icd-loader/libva/libdex**: docs/GIR/intel-optdepends trims.
- **util-linux**: python bindings + write/mesg off. **udisks2**: lvm2 split off.
- **pipewire**: ffado/onnx/roc/gst-plugin/zeroconf/v4l2/x11-bell splits removed
  - matching meson features disabled (names verified vs upstream 1.6.8).
- **wireplumber**: introspection=disabled. **scx-scheds**: layered/rustland/
  rusty/flatcg/chaos excluded.
- **qt6-base-git/qt5-base-git**: SQL drivers → sqlite-only, gtk3 makedep dropped
  (heavy rebuild — batch with next qtbase bump).
- **linux-tools**: hyperv/intel-speed-select/x86_energy_perf_policy splits off
  (usbip kept — explicitly installed).
- **dbus-c++ deleted** from workspace + uninstalled (only fed libffado →
  pipewire-ffado, both gone). Also uninstalled: pipewire-{onnx,roc,zeroconf,
  v4l2,x11-bell}, gst-plugin-pipewire, udisks2-lvm2.
- build-all.fish: new `-ccc/--nuclear` option — finds all pulled source
  clones/tarballs across the workspace and offers deletion (dry-run prints
  sizes, prompts before rm).

Clean/no-action: rocm-core, hsa-rocr, vulkan-headers, glib2/pango/cairo/pixman,
wayland, niri-spicy, noctalia, fish, zram-generator, pyside6, qt6ct/qt5ct,
xdg-desktop-portal-{gtk,gnome}, xorg-xwayland, xwayland-satellite,
easyeffects, scx-tools, liburing, lz4, mimalloc, zstd, zlib-ng*, ninja,
meson-git, libadwaita (check()+weston optional), linux-firmware (extra legacy
rm line deferred to next refresh).

- Qt verdicts after consumer check: qt6-webchannel/positioning/serialport KEEP
  (stock qt6-webengine ← fcitx5-chinese-addons), qt6-speech/multimedia KEEP
  (bibletime), whole Qt5 stack KEEP (kvantum/pyqt5/qt5-wayland).

## 2026-09-02 — Qt private-API skew (root incident)

`qt6-base-git` is Qt 6.13.0-dev internally and exports private symbols tagged
`QtPrivate_6_13_0`; stock 6.11.2 modules reference `QtPrivate_6_11_2` which no
longer exists → dlopen failure. Qt private API is version-locked per minor
release.

- Diagnose: `nm -D --undefined-only <lib> | grep QtPrivate_6_`. Acceptance test
  after every Qt rebuild: every installed qt6 lib must tag == qt6-base-git.
- Decision: maintain the full dev stack — all needed qt6 modules as -git
  builds with the SAME stock package names. Only `qt6-translations` (data),
  `qt6ct`/`qt5ct` (public API) may stay stock; qt6-webengine never attempted.
- pyside6-git: source `code.qt.io/pyside/pyside-setup` branch `dev`; single
  package provides/conflicts/replaces `pyside6` + `shiboken6` (+ provides
  `qt6-python-bindings` for blender/usd). Scope via `-DMODULES=...`
  (official override in `sources/pyside6/cmake/PySideSetup.cmake`); expand the
  list ONLY as matching module -git builds land. Its pkgver reads
  `sources/shiboken6/.cmake.conf` — git describe on dev resolves to an ancient
  tag (5.11.2) and must NOT be used.
- **Rebuild trigger: ANY qt6-base-git update ⇒ rebuild EVERY `.Heavyweight/qt6-*` in
  the same pass.** Never run `pacman -Syu` with a fresh qt6-base-git installed
  while stock modules are still 6.11.x.

## 2026-09-03 — batch expansion + pacman episode

- Wired 14+ packages (scx pair, fish, zram-generator, dbus/dbus-c++, pipewire,
  wireplumber, udisks2, linux-api-headers, linux-tools, linux-firmware,
  fcitx5). All built and installed. linux-firmware = trimmed Strix Halo set;
  **cirrus split re-added** (CS35L41 smart-amp + cs42l43 codec — this laptop),
  `other` picks it plus `cs42l43*`. **pipewire-jack split DROPPED** (conflicts
  jack/jack2 AND jack-client — a collective `pacman -U` of all splits would
  fail); `pipewire-jack-client` kept. GOTCHA: cleanup glob `pipewire-jack-*`
  also matched `-client` — re-run `makepkg -Rf` after glob-based cleanup.
- rust-git + mold-git live in `.Heavy/` (heavy = gtk4, libadwaita,
  gcc-snapshot, llvm-git, spirv-llvm-translator-git, mold, rust = 7).
- Docs/demos trimmed per package with ALL dependent `_pick` lines removed —
  audit `_pick` targets against disabled features (makepkg `set -e` aborts
  packaging on a `_pick` of a file that was never built).
- PGO with LTO-only fallback where yield was poor: pacman (sandboxed
  `-Q/-T/-Sp` training), dbus (`meson test`), pipewire (headless daemon +
  pw-cat sine + pw-cli, sandboxed XDG_RUNTIME_DIR), fish (mixed C+Rust:
  0 gcda / 9 profraw → Rust PGO ok, C fell back to LTO-only — accepted, Rust
  is fish 4.x bulk).
- **pacman permanently removed from the workspace**: self-built pacman
  corrupted the local db; user reverted to CachyOS pacman (verified clean),
  `.Static/pacman` deleted, un-ignored in pacman.conf. The
  `Architecture = auto x86_64_v3 x86_64_v4` line stays — harmless.
- Root-owned gcda: instrumented daemons installed mid-iteration wrote
  root-owned gcda into PGO dirs → needed `sudo rm -rf src`. Avoid installing
  mid-iteration.
- build-all.fish resilience: sync_static_version has epoch split
  (`epoch=`) + vercmp never-downgrade guard; **after ANY revert/desync,
  dry-run all groups (`-n -g git|static|heavy`) before building** — stale
  dirs in a group listing break the whole group. Fish: an UNMATCHED glob is a
  fatal runtime error `2>/dev/null` does NOT suppress — use `find -name`.

### 2026-09-04 — Qt dev-stack rebuild (20 modules), stale-meson purge, easyeffects

- All 20 `.Static/qt*` built and installed (qt6: shadertools/languageserver/
  svg/serialport/declarative/quick3d/tools/webchannel/positioning/speech/
  qt6ct/graphs/multimedia; qt5: declarative/multimedia/tools/speech/svg/
  webchannel/x11extras). qt6-graphs added for easyeffects (stock 6.11.2 =
  `QtPrivate_6_11_2` skew vs our 6.13-dev stack → QML UI abort).
- **pkgver() MUST grep `QT_REPO_MODULE_VERSION` from `.cmake.conf`** — git
  describe is unusable on Qt dev branches (release tags live on `release`
  branches, not dev ancestry; describe returned 6.7.0 for shadertools).
  pacman 7 makepkg also requires a non-empty static `pkgver=` placeholder.
- qtlanguageserver pin: mirror dev @ d845a85 (LSP 3.17 types) because
  qtdeclarative still uses 3.17 names — see
  `.Static/qt6-languageserver/PINNED-README.md`; unpin per TODO above.
- qt6-tools: `llvm22.patch` DROPPED — dev qttools tracks new clang natively
  (built clean against llvm-git 24).
- qt6-speech hollow-guard: built without Multimedia it packages EMPTY —
  always rebuild speech AFTER multimedia.
- gtk3-git replaces stock gtk3: `provides=`/`conflicts=` must go in the
  **package()-scoped arrays** (they OVERRIDE globals in split-style
  PKGBUILDs — a global-only edit silently does nothing).
- qt5ct deferred (see TODO); qt5 tags verified consistent
  (`Qt_5_PRIVATE_API`, 5.15.19 both sides).
- Mirror strategy (worked well): bare mirrors seeded at pkg dir root with
  retry + GitHub fallback (code.qt.io TLS flakes), then repo-local
  `url.<mirror>.insteadOf <upstream>` so makepkg fetches LOCALLY (silent
  self-fetch → update mirrors manually:
  `git fetch https://github.com/qt/<repo>.git dev:dev`).
- PGO trainers (Qt apps/modules): run against BUILD-TREE libs via
  LD_LIBRARY_PATH + QT_PLUGIN_PATH + `QT_QPA_PLATFORM=offscreen`; Arch ships
  NO Qt6 .pc files → pkg-config returns nothing, pass explicit `-I/-l`;
  trainer MUST self-quit (`QTimer::singleShot(8000, quit)`) — SIGINT/SIGTERM
  kills skip the atexit gcda flush → 0 profile files. `-Wmissing-profile`
  spam in phase 2 is normal (cold TUs). declarative 259 gcda, multimedia 170.
- **Stale-meson purge** (meson-git 1.12.0→1.12.99): 26 workspace build dirs
  configured by 1.12.0 fail on rebuild. Build dirs live at arbitrary
  depths/names (`xserver/build`, `pixman/_build`, `build-release`) — a
  maxdepth sweep MISSES them. Working audit: `find . -name meson-info.json`
  - check version ≠ installed meson-git; purge (`rm -rf <builddir>`), then
  rebuild a canary. Re-run this audit after EVERY meson-git upgrade.
- build-all.fish: `sync_static_version` skips pkgver()-driven PKGBUILDs; all
  pacman installs use `--ask 4` (conflict-replace: `-U --noconfirm` answers
  N to the removal prompt); sepinstall needs `-f` kept or makepkg skips
  build() when archives exist.

## 2026-09-04 — doxygen-git: upstream missing `<fstream>` include

- **Upstream regression**: `src/util.h` declares `openOutputFile(...,
  std::ofstream &)` but includes only `<cctype>/<functional>/<variant>` —
  relied on a transitive libstdc++ include that GCC 17 no longer provides
  (GCC even prints the fix as a `+#include <fstream>` diff note). No upstream
  fix yet.
- **Fix**: guarded `sed` in `prepare()` — idempotent, self-noops once upstream
  adds the include. Verified: 1.19.0.r99, PGO 167 gcda.
- build-all.fish takes only its own single-letter flags (`-si`, `-s`, ...);
  makepkg args like `-sif` must NOT be passed to build-all.fish itself.

## 2026-09-04 — jamesdsp-git → easyeffects-git

- jamesdsp-git removed (dir + package + script refs); easyeffects-git added
  (dep edge + git group). PGO: 224 gcda via a trainer that spawns private
  `pipewire` + `wireplumber` inside `dbus-run-session` with sandboxed XDG
  dirs — **easyeffects ABORTS at startup without a live PipeWire**; clean
  self-quit via `easyeffects --quit` (secondary → primary's QLocalServer →
  QApplication::quit() → gcda flush). NEVER pkill daemon names (user session!)
  — PID-scoped cleanup only.
- **GCC 17.0.0 experimental lto1 ICE** (`IPA pass: cp`, `-fprofile-use`,
  final link) — TRANSIENT here (retry succeeded once the box was no longer
  OOM-stressed; the systemd ICE was deterministic). Retry once before
  dropping PGO.
- OOM event ~10:45: closure build + an unrelated compile together OOMed the
  box (IDE included). Never run two heavy builds concurrently; sccache makes
  the replay cheap.
- Verified: QML UI loads headless (offscreen, private pipewire, 15 s run —
  only benign missing-lsp-plugins warnings); `nm`: easyeffects itself uses
  public Qt API only; qt6-graphs refs `QtPrivate_6_13` == base.

## 2026-09-04 — shared-source symlinks (-ccc preservatives + source dedup)

- **Root cause of "symlink feature not working"**: there never was symlink
  sharing — llvm-git mirror had `url.<libclc-path>.insteadOf=<github-url>` in
  its LOCAL config (origin LOOKED like GitHub so makepkg URL check passed,
  but fetches went to libclc clone) AND its `remote.origin.fetch` refspec was
  MISSING (fetch --all only got HEAD → llvm mirror stale at 1380 refs).
- **New layout** (canonical .Heavy clone + symlinks; makepkg SRCDEST mirrors
  are bare + full-ref, working copies in src/ use `git clone -s` alternates
  through the symlink — verified end-to-end with `makepkg -o`):
  - `.Heavy/llvm-git/llvm-project` ← `libclc-git/llvm-project-git` (canonical
    fixed: insteadOf removed, refspec +refs/*:refs/* restored, full 132k-ref
    fetch from real GitHub)
  - `.Heavy/rocm-llvm/rocm-llvm` ← `.Static/hip-runtime/hip-runtime-hipcc`
    (both pinned #tag=rocm-7.2.4)
  - `zlib-ng-git/zlib-ng` ← `zlib-ng-compat-git/zlib-ng`
  - `.Heavy/gtk4-git/gtk` ← `gtk3-git/gtk` (mirror holds gtk-3-24 branch;
    gtk3 checks out origin/gtk-3-24, gtk4 main — one mirror serves both)
  - Deleted with the clones: each twin src/ (its alternates pointed at the
    deleted clone → would dangle). ~14.5 G freed.
- Rules: canonical origin URL must equal the PKGBUILD source URL (minus .git)
  — makepkg aborts "is not a clone of" otherwise. When a mirror moves tag/URL,
  BOTH PKGBUILDs of a pair must change together (rocm 7.2.x). build-all.fish
  -ccc never touches symlinks (validated); nuclear of the CANONICAL dir
  deletes the real clone — twins dangle until the canonical rebuilds.
- build-all.fish `-ln / --link-sources` (2026-09-04): automates the above —
  groups all PKGBUILD git+ sources by effective URL (fragments stripped, so
  #tag/#branch variants share one mirror), picks canonical (real clone first,
  then .Heavy/), symlinks twins (incl. dangling links to not-yet-cloned
  canonicals — makepkg clones THROUGH the symlink into the canonical on first
  build), repairs canonical origin-URL mismatch + missing fetch refspec,
  warns on non-mirror refspecs/insteadOf redirects, deletes duplicate clones
  - their src/ (alternates!) after one y/N prompt. Fake-scenario tested
  (origin fix / refspec / destructive dedup / relink); real run: 4 groups,
  4 links verified, 0 changes.

## 2026-09-04 — .Static self-sync bug (hip-runtime replaced by stock after -Syu)

- **Root cause**: `sync_static_version` queried ONLY `pacman -Si $pkgbase`;
  hip-runtime builds `pkgname=(hip-runtime-amd)` (nvidia split dropped
  2026-09-04), repo only knows `hip-runtime-amd` (cachyos-extra-znver4) →
  silent early-return → custom 7.2.4-1 stayed < stock 7.2.4-1.1 → -Syu
  legitimately replaced the custom build (package now ships as -amd only).
- **Fix**: candidate list = pkgbase + every sourced pkgname; first repo hit
  wins. Validated: hip-runtime PKGBUILD auto-bumped 7.2.4-1 → 7.2.4-1.1,
  SRCINFO OK. Equal-version custom beats stock on next -Syu (no replacement).
- Group-wide read-only audit (pkgname-fallback sim): 5 more pending syncs
  found (ccache -1→-1.1, dbus-broker 37-3→37-3.1, linux-tools 7.2.2→7.2.3,
  qt5-webchannel 18→19, util-linux 2.42.2→2.42.3) — they resolve via pkgbase
  fine, will sync on next -s build. Guards verified: never-downgrade holds
  (linux-api-headers 7.2-1 > repo 1:7.1-1; qt6 dev builds > repo 6.11.2).
- Known gap: `libisl-git` never syncs — repo package is `libisl` (no -git
  stripping, intentionally). Manual pkgver bumps there.
- (2026-09-06 evening: obsolete — the ROCm runtime stack is no longer
  installed system-wide, only stock rocm-core 7.2.4-1.1 remains. The
  .Static/hip-runtime rebuild below is workspace-only now.)

## 2026-09-05 — meson/meson-git conflict: unversioned provides trap

- Symptom: dbus-broker-git build failed at "Installing missing dependencies" — pacman wanted repo `meson` (satisfying `meson>=0.60.0`), conflicting with installed `meson-git`.
- Root cause: `meson-git` (and ninja-git/cmake-git/doxygen-git) used UNVERSIONED `provides=(meson)`. An unversioned provide can NOT satisfy a versioned dep (`meson>=0.60.0`) — pacman ignores the provider and reaches for the repo package.
- Fix: versioned provides everywhere: `provides=("meson=${pkgver}")` (mold-git already did this correctly). Rebuilt+installed meson-git 1.12.0.r175 (Provides: meson=1.12.0.r175…), then dbus-broker-git built + both splits installed cleanly.
- Rule: every toolchain -git pkg that other PKGBUILDs makedepend on with `>=N` must carry a versioned provide; a provides-only fix needs a real rebuild (provides live in .PKGINFO).

## 2026-09-05 — xz-git: po4a trim vs autogen.sh hard-fail

- Symptom: prepare() aborted — xz upstream autogen.sh unconditionally runs `po4a/update-po`, which exits non-zero when po4a is missing (we dropped po4a makedep 2026-09-04 as docs-only).
- Fix: `./autogen.sh --no-po4a` (upstream-provided skip flag). Built 5.8.3.r85, installed; provides liblzma.so=5-64 intact. Side effect: translated man pages no longer generated (-1.4 MiB).
- Bonus hazard found in audit: .Static/util-linux still had po4a makedep → next build would silently REINSTALL the purged po4a (+ perl module deps). Dropped it (meson build treats po4a as optional, no _pick touches translated man dirs).
- Rule: when dropping a docs-only makedep, grep the package for it in prepare()/autogen paths — autogen.sh tools often need an explicit skip flag; and check remaining makedeps for tools that were purged system-wide (makepkg will reinstall them).

## 2026-09-05 — libunwind-git: two stacked failures (src pollution + missing soname provides)

- Failure 1: pkgver() → `.r0.ge76caf7` and `autoreconf: configure.ac required`. Cause: stale non-git `src/libunwind` (leftover build dirs) made makepkg skip cloning; git commands resolved UPWARD into the AUR-mirror `.git` now at `libunwind-git/` — pkgver read that repo (no tags), build ran in the wrong tree. makepkg even created a stray `makepkg` branch in the parent repo (deleted). Fix: `rm -rf src pkg`, rebuild. Rule: before rebuilding after repo restructuring, wipe `src/`; beware a parent `.git` swallowing git calls in `$srcdir`.
- Failure 2: install failed — `breaks dependency 'libunwind.so=8-64' required by gimp`. Cause: pacman 7.1 does NOT derive soname provides from package files at `-U` time; they must be in `.PKGINFO`. makepkg 7 `autodeps` would auto-add them but is disabled in makepkg.conf (`!autodeps`) and PKGBUILD lint rejects `options=(autodeps)` ("unknown option" — config-only, like `!check`). xz-git only worked because it declares `liblzma.so=5-64` explicitly. Fix: explicit provides array mirroring repo libunwind (5 sonames), pkgrel 2, installed OK, gimp happy.
- Debug path: `tar -xOf pkg.tar.zst .PKGINFO | grep provides` (PKGINFO uses singular lowercase `provides`/`conflict` — case-sensitive greps on `-Qi` style names will miss them); `pacman -U --debug` shows whether soname derivation happens (it does not).
- Rule: every self-built -git package shipping shared libs must declare versioned soname provides explicitly. Audit candidates: any workspace package whose repo counterpart has `.so=N-64` in Provides.

## 2026-09-05 — util-linux 2.42.3: three packaging traps after the trim pass

- Trap 1: `-Dpython=disabled` is WRONG — util-linux's `python` meson option is a STRING (interpreter name), so meson ran `find_installation('disabled')` → "Program disabled not found". The feature gate is `-Dbuild-python=disabled`. Rule: check option TYPES in meson_options.txt (`feature` vs `string`) before disabling; `feature` options take enabled/disabled/auto, `string` options take values.
- Trap 2: with `--auto-features enabled` (arch-meson), an auto-ENABLED feature whose tool is missing HARD-FAILS configure via `.require(tool.found())` — po-man/meson.build: "Feature translate-docs cannot be disabled" (po4a purged yesterday). Fix: `-Dtranslate-docs=disabled`. Rule: when purging a build tool (po4a), grep upstream meson for `.require(<tool>.found())` chains and explicitly disable the dependent feature — auto-enabled + missing tool = fatal, not skip.
- Trap 3: packaging mv failures — split-package STAGING dirs are created under $srcdir (makepkg runs package functions with cwd=$srcdir): stale `src/util-linux-libs/` from failed -Rf runs made `mv ... pkgconfig` nest (`pkgconfig/pkgconfig`) on repeat runs. Cleaning the PKGBUILD-root copy did nothing. Also: removing the `_python_stdlib` install -d accidentally removed the only creator of `pkgdir/usr/lib` → mv target missing. Fixes: clean `src/<pkgbase>-libs`, create `usr/lib` explicitly. Rule: staging lives in $srcdir — clean `src/<staging-name>`, never the PKGBUILD root; audit install -d lines that only "happen" to create parent dirs needed by later mv.
- Result: util-linux + util-linux-libs 2.42.3-1 built & installed; python bindings + translated man pages dropped; English man1/3/5/8 intact; pacman -Qkk clean.

## 2026-09-06 — xdg-desktop-portal: upstream meson option rename (docs → documentation)

- Symptom: build() aborted at meson setup — `xdg-desktop-portal/meson.build:4:0: ERROR: Unknown option: "docs"` (PKGBUILD passed `-D docs=disabled -D man=disabled`).
- Root cause: upstream renamed options in `meson_options.txt` → `meson.options`: `docs` → **`documentation`**, `man` → **`man-pages`**. Note upstream also switched to the new `meson.options` filename. `documentation` requires sphinx (purged) — `disabled` remains correct; man-pages likewise.
- Fix: PKGBUILD flags updated to `-D documentation=disabled -D man-pages=disabled`; wiped stale `src/build` from the failed run; rebuilt 1.22.0.r181.g86bd3e26-1 + installed clean.
- Workspace scan: every other PKGBUILD using legacy-looking flag names (`-D docs=false` dbus-broker×2/libdex, `-D man=false` polkit/gtk3, `-D docs/man=disabled` pipewire, `-Dman=enabled` systemd, wayland `-Ddocumentation=false`) built successfully on its latest run — rename is isolated to xdg-desktop-portal.
- Rule: meson option names are upstream API — a "Unknown option" error at setup means the project renamed/removed an option (check `<src>/meson.options` or `meson_options.txt`, not just git log). Add the new-name grep to the trim-audit checklist when refreshing a package after upstream moves.

## 2026-09-06 — wireplumber: trim-leftover _pick of never-built girepository dir

- Symptom: rebuild pass (first wireplumber build since the 2026-09-04 trim) failed in
  package_wireplumber(): `mv: cannot stat 'usr/lib/girepository-1.0'` right after meson
  install finished. Build + PGO itself was fine — packaging only.
- Root cause: `-D introspection=disabled` (line 48) means meson never installs
  `usr/lib/girepository-1.0`, but the trim removed only the GIR *content* picks and left
  the dir pick `_pick libw usr/lib/girepository-1.0` → `_pick`'s mv aborts under errexit.
  The Sep-4 installed package predates the trim, so the dead line survived until this
  first post-trim build.
- Fix: removed the stale pick (comment left in place: "do not re-add"); wiped stale
  `src/libw` staging + `pkg/` (split staging lives under $srcdir — util-linux trap);
  `makepkg -Rf` repackaged without rebuilding; installed both splits; wireplumber.service
  active; no `Wp` typelib left on disk (audit: no GIR consumers).
- RULE: when disabling a meson feature, grep the WHOLE package() + _pick list for every
  path that feature installs (dirs AND file globs) — content picks without dir picks is
  not a safe pattern; both must go.
- Bonus (source-verified, refines golden rule 3): makepkg `find_libprovides`
  (/usr/bin/makepkg) auto-VERSIONS any `provides=` entry ending in `.so` by readelf-ing
  the packaged lib's soname (`libwireplumber-0.5.so` → `libwireplumber-0.5.so=0-64`;
  confirmed in the fresh .PKGINFO). What it does NOT do is synthesize soname provides for
  libs that were never declared — THAT is the real libunwind-git mechanism (its provides
  array had no `*.so` entry). So: declaring a bare `libfoo.so` provide is sufficient for
  versioning; declaring nothing is fatal. `!autodeps` is irrelevant to this path. Keep
  the `tar -xOf pkg.tar.zst .PKGINFO | grep provides` check as the artifact-level audit.

## 2026-09-06 — qt5-base-git: makepkg LTO-strip hook hollows every packaged static archive (qt5ct link failure)

- Symptom: qt5ct 1.9 failed at the link of libqt5ct.so — undefined `QDBusMenuBar::*` /
  `QDBusPlatformMenu*` refs. Initial red herring: no `libQt5DBusSupport.a` exists in qtbase
  5.15; qdbusmenubar/dbusmenu/dbustray compile into `libQt5ThemeSupport.a`
  (src/platformsupport/themes/genericunix) which qt5ct links statically.
- Root cause: pacman 7.1 makepkg tidy hook `safe_strip_lto` (/usr/share/makepkg/tidy/50-strip.sh)
  runs `strip -R .gnu.lto_* -N __gnu_lto_v1` on EVERY packaged static archive. qtbase `-ltcg`
  compiles slim-LTO objects (pure IR; GCC ≥12 defaults slim even without -fno-fat-lto-objects)
  → the strip erases the entire member payload, leaving only `__gnu_lto_slim` stubs → every
  shipped `libQt5*.a` is unconditionally unlinkable for static consumers. The deterministic
  hollow md5 (ThemeSupport c661bb56 across every build) is the IR-strip of ANY slim archive
  collapsing to identical stub content.
- Verification loop: `ar p <archive> <member> > /tmp/x.o && gcc-nm /tmp/x.o | grep -v gnu_lto | wc -l`
  (0 = hollow). Traps learned: gcc-nm needs a REAL FILE — a stdin pipe silently returns nothing;
  `grep -c` exits 1 on zero, so an `|| fallback` turns a hollow result into a misleading -1.
- Wrong fix #1: deleting `-fno-fat-lto-objects` from QMAKE_CFLAGS_LTCG — GCC 17 defaults to
  slim, so the rebuilt archive stayed slim (3431430 bytes ≈ old 3431854) and packaged hollow
  again.
- Fix: prepare() sed replaces `-fno-fat-lto-objects` → `-ffat-lto-objects` in
  mkspecs/common/gcc-base.conf. Fat objects carry real machine code + IR, so the hook strips
  only the IR: qdbusmenubar.o keeps 18 defined QDBusMenuBar symbols in the packaged archive
  (new md5 f002bb99). Flag/mkspec change → full clean rebuild per golden rule 5:
  `git -C src/qtbase reset --hard && git -C src/qtbase clean -fdx` (keeps the .git clone — no
  re-clone), `rm -rf pkg`, `makepkg -f` (~13 min). Installed qt5-base-git
  5.15.2+kde_r45808.gfbed962c319-1 + qt5-xcb-private-headers-git; qt5ct 1.9-2.1 rebuilt clean
  (0 undefined refs) and installed.
- Diagnostic dead end worth remembering: `makepkg -Rf` DOES wipe pkgdir and re-run package() —
  but a repackage can never fix content mutated by tidy hooks; the hollowing happened in tidy
  (after install) every single time, so `-Rf` reproduced it byte-for-byte.
- Follow-up: qt6-base-git ships the same class of archives (libQt6BundledEmbree.a verifies
  hollow) — harmless today (bundled 3rd-party consumed only inside qt6's own .so builds). If a
  static consumer ever appears, apply the same -ffat-lto-objects treatment.

## 2026-09-06 — pacman.conf: IgnorePkg audit — 62 self-maintained names were unprotected

- User ask: make sure every self-maintained package is excluded from repo upgrades.
- Method: sourced all 94 workspace PKGBUILDs (root + .Heavy + .Static + .3rdP), unioned
  pkgbase + every pkgname token (159 names), diffed against `pacman-conf IgnorePkg | sort -u`.
- Finding: 62 names missing, 54 of them INSTALLED — .Static qt5-*/qt6-* module stack
  (qt5ct 1.9-2.1, qt6ct, all qt5-declarative…qt6-webchannel), every gcc-snapshot split
  (*-snapshot incl. lib32-gcc-libs-snapshot), pyside6-git, ccache, dbus-broker/-units +
  dbus-units (renamed split of .Static/dbus), linux-cachyos-muqss-lto{,-dbg,-headers},
  scx-scheds-git/scx-tools-git, easyeffects-git, libisl-git, spirv-llvm-translator-git,
  clang-opencl-headers-git, pipewire-libcamera, linux-firmware-cirrus, bettbox (.3rdP),
  plus not-yet-installed rocm-llvm splits (rocm-llvm, hsa-rocr, hip-runtime[-amd],
  rocm-device-libs). Single biggest latent footgun found this week: one `pacman -Syu`
  would have downgraded/clobbered the whole Qt module stack (and more).
- Fix: appended a second cumulative `IgnorePkg =` line after the existing one (pacman
  accumulates repeated IgnorePkg directives; verified by `pacman-conf IgnorePkg` count
  127→189). Backup: /etc/pacman.conf.bak-20260906. Closure re-diff now empty; stale
  entries (purged systemd-tests, udisks2-lvm2, dbus-daemon-units, disabled pipewire
  split names, …) intentionally left — IgnorePkg only affects installable/installed
  names, so they are inert.
- Traps hit during the edit: `sed "27r file"` appended the raw names WITHOUT the
  `IgnorePkg =` prefix (had to `28s/^/IgnorePkg = /` after) — always re-read the
  inserted line before trusting it. And an edit-tool slip briefly deleted the LTO-strip
  bullet's header in MEMORY.md §6 (restored) — verify file diffs after batch edits.

## 2026-09-06 — 19-package integration: gimp chain scaffolded + base-system stock rebuilds

- User added 6 root `-git` dirs (rust-bindgen-git, flatpak-git, git-git, gimp-git,
  blender-git, krita-git) + 11 `.Static/` stock rebuilds (gc, imagemagick, openssl,
  openssh, openvpn, networkmanager, networkmanager-openvpn, upower, zsh, bash,
  libreoffice-fresh) and asked for the optimization playbook + build script updates.
- **Missing prerequisite chain**: gimp-git hard-depends on `babl-git>=0.1.118` /
  `gegl-git>=0.4.66` — neither installed nor in the workspace. Scaffolded both from
  AUR (git clone) and converted to house style (arch-meson + guarded mold + meson
  compile/install). babl keeps the `ENABLE_DOC=0` env toggle; gegl keeps
  `-Dworkshop=true` + its gcc-snapshot `-Wno-error=implicit-function-declaration`.
- **`networkmanager-vpn-plugin-openvpn` mystery solved**: it is a split package of
  `networkmanager-openvpn` (meta-pkg pointing at the plugin). Split outputs also
  discovered: libnm, networkmanager-docs, nm-cloud-setup (NM); zsh-doc (zsh);
  libreoffice-fresh-sdk (LO). All 25 names → IgnorePkg.
- **Optimizations applied** (all validated `bash -n` + `makepkg --printsrcinfo`):
  - mold (guarded `command -v mold` check, house idiom): gc, imagemagick, openssh,
    openvpn, networkmanager-openvpn, openssl (its Configure consumes env LDFLAGS),
    openssh/openvpn before ./configure; networkmanager + upower before arch-meson;
    flatpak-git/gimp-git before meson; git-git via LDFLAGS export (consumed by
    `_make_options`); krita-git via the CMake 3-var linker-flags pattern;
    babl-git/gegl-git via LDFLAGS before arch-meson.
  - PGO 2-phase (house safety pattern: save orig flags, atomic profile update,
    gcda-verify before profile-use, non-PGO fallback, clean rebuild, profile wipe):
    **bash** + **zsh**, training = their `make check` suites (timeout 900, `|| true`),
    binary smoke-tested before packaging. KEY autotools detail: CFLAGS are baked in
    at ./configure time, so each phase must re-run ./configure — `make clean` alone
    is not enough (this is why meson needed the build-dir wipe in dbus).
  - rust-bindgen-git: `-C target-cpu=native` appended only if RUSTFLAGS lacks it.
  - **Deliberate no-ops**: blender-git (already `options=(!lto)` +
    `-DWITH_LINKER_MOLD=ON` + ccache), libreoffice-fresh (already `!lto` +
    `--enable-lto` + fortify 3→2 + `-g1` — gbuild linker injection skipped as
    high-risk/low-reward). No PGO for openssl/openssh/openvpn/NM (crypto-critical
    or no meaningful training workload; playbook lists nothing for them).
- **build-all.fish**: +14 `_DEPS` edges (openssl→openssh/openvpn/git-git/LO;
  babl→gegl→gimp; glib2/polkit→flatpak/NM/upower; NM→NM-openvpn;
  qt6-base+qt6-svg+qt6-tools→krita; rust-git→rust-bindgen). `_GROUP_git` 41→49,
  `_GROUP_static` 35→46. topo_sort verified: all 19 new pkgs sort with correct
  ancestry, no cycles (`-l` dry run).
- **IgnorePkg third cumulative line** (189→214): new line inserted at line 28 in
  [options]. NEW TRAP: `tee -a` put it at EOF — inside the `[extra]` repo section,
  where pacman-conf rejects the directive with a warning ("in section 'extra' not
  recognized") and silently drops it (closure check caught it). Fixed: delete the
  EOF line, `sed "27r /tmp/ignorepkg-line.txt"` with the `IgnorePkg =` prefix baked
  into the inserted file. Backup: /etc/pacman.conf.bak-20260906-newpkg.
- Update 2026-09-06 evening: the whole batch has since been BUILT + INSTALLED
  (incl. libreoffice-fresh after the util-linux verdef fix; rust-bindgen-git
  needed the rust-git rebuild first — see its own section).

## 2026-09-06 — rust-git vs minimal llvm-git: target-set skew bricks rustc

**Symptom**: `makepkg -si` in `rust-bindgen-git` died in prepare(): `rustc: symbol
lookup error: /usr/lib/librustc_driver-*.so: undefined symbol:
LLVMInitializeARMTargetInfo, version LLVM_24.0` → `error: target was empty`
(bindgen's `cargo fetch --target "$(rustc -vV ...)"` runs rustc, which is dead —
the fetch error is a downstream symptom, not the cause).

**Root cause**: rustc's driver links `LLVMInitialize*Target*` symbols for every
LLVM target present at BUILD time (`rustc_llvm` build.rs adapts via
`llvm-config --targets-built`). Rebuilding llvm-git with the deliberate minimal
target set (`-D LLVM_TARGETS_TO_BUILD="X86;AMDGPU"`) and installing it ABI-breaks
any rust-git built against a full-target llvm. Evidence: driver needs 337 LLVM
symbols; exactly 69 missing = target-init syms for the 14 removed targets
(AArch64, ARM, AVR, BPF, Hexagon, LoongArch, MSP430, Mips, NVPTX, PowerPC,
RISCV, Sparc, SystemZ, WebAssembly). pacman.log showed llvm r595038 → r595808
installed 4 s before the rust upgrade in the same batch — order was right, the
llvm *target set* changed, which no dep-edge tracks.

**Version-node red herring**: `libLLVM.so.24.0` has a single version node
(LLVM_24.0); ANY missing symbol reports "version LLVM_24.0". Use
`readelf -W --dyn-syms` diff + `llvm-config --targets-built` to identify the real
skew, not the version string.

**Fix**: rebuild rust-git against the minimal llvm (stage0 bootstrap is immune to
the broken system rustc — bootstrap.toml sed-deletes the `rustc`/`cargo` lines;
`rustfmt` line too, else the dead system rustfmt is picked up). PKGBUILD header
now carries a rebuild-order warning. Post-fix, `rustc --print target-list` still
lists all targets but codegen works only for X86/AMDGPU (fine on znver5).

**Rules**:

- rust-git must be rebuilt after EVERY llvm-git/llvm-libs-git reinstall — and
  conversely llvm-git target-set changes invalidate rust-git even when versions
  match. build-all.fish has the dep edge; manual rebuilds must follow it too.
- build-all.fish dep-chain rebuilds (`-si git-git`) may re-run already-installed
  deps (e.g. openssl) — that is normal and idempotent.
- Transient `curl 56 SSL_read unexpected eof` → `bad pack header` on the ~1.5 GB
  `src/llvm-project` submodule fetch: resume with
  `git -C src/rust submodule update src/llvm-project` (direct-fallback fetch of
  the pinned commit); src/ survives and makepkg skips completed submodules.
- zsh-doc packaging fix (same morning): trim audit removed TeX makedeps but
  package_zsh-doc() still hard-installed `Doc/zsh.pdf` → install failure. Dropped
  the PDF line (docs split now ships Info+HTML only); a hard `install` of an
  artifact nothing builds aborts the whole split build.

## 2026-09-06 (pm) — mold false-negatives meson has_link_argument → zero verdefs (libuuid/libblkid)

(Note: the meson-git r175 "regression" in the original heading was DISPROVEN —
mold was the real culprit all along; see the root cause below.)

**Symptom**: after the 09-05 20:01 util-linux 2.42.3-1 build, `/usr/lib/libuuid.so.1.3.0` and
`libblkid.so.1` carry ZERO `.gnu.version_d` verdefs, while `libmount.so.1` kept all 105 `MOUNT_*`
nodes. First victim: libreoffice-fresh configure — `-lSM` conftest link fails with
`undefined reference to uuid_unparse_lower@UUID_1.0` ("SM library not found"). Anything that
LINKS against stock libs referencing versioned uuid/blkid symbols breaks the same way (runtime
with unversioned refs is still fine — link-time is the hard failure).

**Root cause** (pinned 09-06 evening by conftest stderr + repro): util-linux wires its version
scripts two ways — libmount/libsmartcols pass `-Wl,--version-script=` **unconditionally**;
libuuid/libblkid gate it behind `cc.has_link_argument('-Wl,--version-script=…')`. Meson probes that
flag by linking a **trivial conftest** (no uuid_* symbols) with `-Wl,--fatal-warnings` + the sym
file. The house build() adds `-fuse-ld=mold` to LDFLAGS, and **mold hard-errors on version-script
entries whose symbols are absent from the link** ("cannot assign version `UUID_1.0` to symbol
`uuid_clear`: symbol not found") where GNU ld silently tolerates it → `--fatal-warnings` → check
returns NO → meson silently omits the link arg → libuuid/libblkid link WITHOUT the script → zero
verdefs. **NOT meson r175**: an earlier attribution to meson-git 1.12.0.r175 was coincidence — the
real build log still showed NO under r178, and clean-room probes passed because they lacked mold.
Repro (real sym + makepkg LDFLAGS + `-fuse-ld=mold`) fails identically. libmount/libsmartcols
escaped only because their wiring never consults the check.

**Fix**: PKGBUILD build() exports `LDFLAGS+=" -fuse-ld=mold -Wl,--undefined-version"`. mold's
`--undefined-version` restores the GNU-ld tolerance inside the probe (real library links are
unaffected — every symbol in the shipped sym files exists there). Rebuilt 2.42.3: 7 × UUID_1.0 +
43 × BLKID_ verdefs confirmed; installed 09-06 ~17:45. After any linker change (mold version bump,
mold→bfd flips), re-run: `readelf -V <lib> | grep -c VER_` for libuuid (UUID_1.0), libblkid
(BLKID_*), libmount (MOUNT_*). Meson `has_link_argument` checks that link trivial conftests are
**all suspect under mold** whenever the checked flag interacts with symbol presence.

**Collateral from the same pass, fixed 09-06 (pm)**:

- **git-git**: `make -C contrib/mw-to-git` aborted ("No such file or directory") — the MediaWiki
  contrib tooling was removed upstream (2025); excised the build()+package() lines. Rebuilt and
  installed 2.55.0.r787.g3cb9185f65-1 after rustc got fixed (libgit-rs needs a working rustc).
- **blender-git**: `Unknown download protocol: git-lfs` — the PKGBUILD correctly declares
  `makedepends+=('makepkg-git-lfs-proto')` (provides /usr/share/makepkg/source/git-lfs.sh), but the
  package itself was never installed (not in any repo). Built+installed makepkg-git-lfs-proto 3-1
  (pulls git-lfs 3.8.0). Cloning then hit repeated transient `curl 56 SSL_read unexpected eof` /
  TLS connect errors from projects.blender.org — retry loop with backoff eventually got the full
  ~2.5 GB LFS clone through (06 Sep evening). Next blocker: the house `blender-fix-oneapi-2026.patch`
  (removes `sycl::access::address_space::ext_intel_global_device_space` from Cycles atomic_ref)
  no longer applies — upstream now defines a version-gated `CYCLES_SYCL_GLOBAL_ADDRESS_SPACE`
  (libSYCL >= 9 → `global_space`, else the legacy ext_intel space), making the patch obsolete.
  Removed patch from source=()/sha256sums and deleted the file. Then the extract phase failed with
  6637 × `error transferring "<oid>": [0] remote missing object` — root cause: the agent-shell
  injected `safe.bareRepository=explicit` git config makes `git lfs install/fetch` inside the bare
  mirror exit 128 ("Not in a Git repository"), the git-lfs.sh download handler tolerates it, so the
  LFS store was never populated and the worktree `git lfs pull` (standalone file:// transfer) found
  nothing. Batch-API probe (422 "Object … is not 1 bytes", not 404) proved the objects exist
  server-side. Fix: `GIT_CONFIG_COUNT=0 makepkg` — the universal agent-shell makepkg workaround,
  now confirmed for tag verification AND git-lfs bare-repo fetches.
- **rust-bindgen-git** 0.73.1.r0.g66a1e2aa-1 built and installed once rustc worked (the `-si`
  auto-install hit the interactive pacman prompt — install manually with `pacman -U --noconfirm --ask 4`).

## 2026-09-06 (eve) — OSL vs llvm-git 24: version-node skew bricks oslc; house OSL 1.15.3.0-1.2

- Symptom: blender-git ninja failed instantly on every `.oso` shader target:
  `/usr/bin/oslc: /usr/lib/libLLVM.so.22.1: version 'LLVM_22.1' not found (required by
  /usr/lib/liboslcomp.so.1.15)`.
- Root cause: llvm-git 24.0.0 exports **only** the current version node (`LLVM_24.0`); the Sep-04
  SONAME shim `libLLVM.so.22.1 → libLLVM.so.24.0` satisfies linking but NOT versioned symbol
  lookups. Repo `openshadinglanguage 1.15.3.0-1.1` (CachyOS pkg, built vs LLVM 22.1) went dead on
  the llvm-git update. Scan for stale couplings:
  `for f in $(grep -l libLLVM.so /usr/lib/*.so.*); do readelf -V "$f" | grep -oE "LLVM_[0-9.]+"; done`
  (pattern must admit minor nodes like 22.1, not just X.0). Only the OSL libs were affected.
- Fix = house package `.Static/openshadinglanguage` 1.15.3.0-1.2. Keeping the 1.15.3.0 tarball means
  identical sonames/ABI → zero blender-side risk (OSL main wants OIIO ≥ 3.0 and carries 1.16-dev
  drift). `osl-llvm-compat.patch` = backport of upstream LLVM-23 support (commit `2e43fc367`)
  adapted to 1.15.3.0, gate bump `VERSION_MAX 22.9 → 24.9` (src/cmake/externalpackages.cmake),
  FindLLVM per-component clang libs skipped when `libclang-cpp` found, plus the LLVM-24 fallout
  found empirically on first build:
  - `llvm::PassInfoMixin` moved into `llvm::detail` in LLVM 24 → use
    `llvm::OptionalPassInfoMixin` (isRequired()==false, same as the old mixin default). Subtle
    part: OSL's `NewPreventBitMasksFromBeingLiveinsToBasicBlocks` relied on **ADL through the
    mixin base class** to resolve unqualified `createModuleToFunctionPassAdaptor(...)`; once the
    base changed namespace the call broke with "'createModuleToFunctionPassAdaptor' was not
    declared" pointing at the llvm:: one. Qualify with `llvm::` (upstream main already does).
  - `TargetOptions::{NoInfsFPMath,NoNaNsFPMath,NoSignedZerosFPMath}` removed in LLVM 23 →
    `#if OSL_LLVM_VERSION < 230` (1.15.3.0 already guards `UnsafeFPMath` the same way for 22).
  - `TargetOptions::FloatABIType` removed in LLVM 24 (float ABI now a module flag /
    triple-inferred; `FloatABI::Default` meant "infer" anyway) → `#if OSL_LLVM_VERSION < 240`.
- Verify after install: `oslc --help` runs; `readelf -V /usr/lib/liboslcomp.so.1.15 | grep -oE
  "LLVM_[0-9.]+"` → `LLVM_24.0`; `ldd /usr/bin/oslc` → `libLLVM.so.24.0`. Installed ~20:25.
- Patch authoring tip (non-git sources): extract the pristine tarball twice, edit one copy,
  `diff -ru orig patched` + sed the `a/`/`b/` path prefixes → context-exact patch, dry-run it with
  `patch -Np1 --dry-run` before wiring into source=/sha512sums.
- blender-git rebuilt cleanly through the whole oslc stage afterwards (0 shader failures).

## 2026-09-06 (eve) — blender-git 5.3: bundled extern/glog vs system libglog double-registration

- First-ever full blender run aborted instantly (exit 1, before any version output):
  `ERROR: flag 'logtostderr' was defined more than once (in files
  '/usr/src/debug/google-glog/.../flags.cc' and 'extern/glog/src/logging.cc')`.
- Anatomy: blender bundled extern/glog (compiled into the binary; its vendored CMake links SYSTEM
  libgflags → direct NEEDED libgflags.so.2.2) **and** the binary pulls system `libglog.so.2`
  transitively via `libceres.so.4`. Both register glog's flags at static-init/load → glog fatals
  on the duplicate. Never exercised before because every earlier blender build died earlier (LFS,
  oneapi patch, HIPRT, oslc).
- Fix in the blender-git PKGBUILD `_CMAKE_FLAGS`: `-DWITH_SYSTEM_GLOG=ON -DWITH_SYSTEM_GFLAGS=ON`
  (blender's own advanced options; FindGlog/FindGflags modules exist). Bundled extern/glog+gflags
  drop out; all glog/gflags registration goes through the one system libglog.so.2 → clean.
- Diagnostic path worth remembering: glog flag-duplicate errors name the two files — one under
  `/usr/src/debug/<system-pkg>` = a system lib's static init; one `extern/…` = vendored copy
  compiled in. Then `readelf -d <bin> | grep NEEDED` (direct deps) + ldd each dep lib to find who
  pulls the system copy (here: libceres).
- Verify: `blender --version` exits 0 (was exit 1); `blender -b --python-expr …` prints
  SMOKE-OK 5.3.0 Alpha. Installed 5.3.r164916.gf2261d10cdd5-1 (incremental rebuild was only 62
  ninja tasks — the glog flip doesn't touch most TUs).

## 2026-09-06 (eve II) — gegl-git mrg/maxflow auto-features + babl/gegl soname provides

**gegl-git configure hard-fail** (`mrg`, then `maxflow` not found): the arch-meson
`--auto-features enabled` pitfall again — gegl's meson_options.txt marks both `auto`, so
arch-meson turns "not found" into a fatal configure error (consumers would only be the
interactive `mrg-gegl` viewer + the matting-global op — neither ships in stock Arch gegl
0.4.70, so disabling is exact feature parity). Fix: `arch-meson … -Dmrg=disabled
-Dmaxflow=disabled`. Probe trick that found both in one pass: throwaway
`arch-meson <src> /tmp/probe` configure and read all `Dependency … not found` lines up front.

**Soname provides, the unversioned-soname variant** (broke the `gegl→gegl-git` swap: pacman
"removing gegl breaks dependency 'libgegl-npd-0.4.so=libgegl-npd-0.4.so-64' required by gimp"):

- The REQUIRED provide string for an unversioned soname is `libfoo.so=libfoo.so-64` —
  the version part is the soname itself + `-64` (pacman parseEVR: ver=`libfoo.so`,
  rel=`64`).
- That string CANNOT be written in provides= : `check_fullpkgver` lint splits at the last
  hyphen, then rejects any hyphen left in the ver part → "pkgver in provides is not
  allowed to contain … hyphens". A versioned provide like `libgegl-0.4.so=0-64` passes
  (ver=`0`, rel=`64`) — which is why libunwind-git's explicit declarations worked and this
  class looked lint-impossible.
- The clean mechanism was there all along: **declare the bare soname**
  (`provides+=('libgegl-0.4.so' 'libgegl-npd-0.4.so' 'libgegl-sc-0.4.so')`). makepkg's
  `find_libprovides` matches packaged files named `$p*`, reads the ELF soname, and
  emits `${p}=${soversion}-${soarch}` at packaging time — for a versioned soname
  (`libgegl-0.4.so.0`) that yields `0-64`; for an unversioned one the soname itself
  lands in the version slot, reproducing the repo string byte-for-byte. Lint never sees
  the derived entry. This is the standard Arch convention and survives every rebuild.
- Applied to **gegl-git** (all three sonames) and, when `pacman -Dk gimp` then flagged
  `missing 'libbabl-0.1.so=0-64'` from the earlier pass, **babl-git** (`libbabl-0.1.so`).
  Both `-Rf`-repackaged, installed; swap clean, `pacman -Dk gimp` free of gegl/babl
  errors, `ldd /usr/bin/gimp` resolves all three libs from the house packages.
- Audit habit for the rest of the gimp chain before/at gimp-git build: for each already-
  built house lib package, `tar -xOf <pkg>.pkg.tar.zst .PKGINFO | grep '^provides'` must
  show the soname lines repo consumers need.

**Bare (unversioned) name provides can't satisfy versioned depends** (2026-09-06, broke the
`gimp-git` build: makepkg tried to install repo `cairo>=1.14.0` → conflict with installed
cairo-git):

- The soname mechanism above auto-versions `*.so` entries, but plain name provides get NO
  version from anywhere. pacman/makepkg can't satisfy `dep>=X` from an unversioned provide,
  so makepkg pulls the repo package → conflict with the installed -git one.
- babl-git/gegl-git already used the correct house idiom; cairo-git and glib2-git had
  missed it. Fix (all three now): `provides+=("${pkgname%-git}=${pkgver%%.r*}")` — strip the
  `.rN.gsha` tail so the provide equals the upstream release version. glib2-git fixed in
  PKGBUILD only (PGO rebuild queued); cairo-git rebuilt + reinstalled same evening.
- Audit habit: after any new -git package, `pacman -Qi <pkg> | grep Provides` must show the
  versioned name provide if repo consumers could ever depend on `name>=X`.

**uic ≥ 6.13 rejects `class=" QWidget"` (leading space) — krita-git Assistants plugin** (2026-09-06):

- Symptom: krita-git build fails, `ui_AssistantsToolOptions.h: No such file or directory` —
  the header was never generated because uic itself failed: `Invalid class name: " QWidget"`,
  `File … AssistantsToolOptions.ui is not valid` (line `[1814/3730] Generating
  ui_AssistantsToolOptions.h` in the log; ninja moved on and the real error surfaced later
  at the dependent compile).
- Root cause: upstream krita commit `3e8c536cf3` ("Wrapped all docker tool option
  check-boxes…") shipped `<widget class=" QWidget" name="showDockerOptionsPanel">` with a
  leading space. Older uic tolerated it; the rewritten uic in qt6-base-git 6.13.0 validates
  every widget class name and rejects the entire file. Verified by direct `uic` repro +
  one-char fix repro (uic exits 0 after `class=" QWidget"` → `class="QWidget"`).
- Lesson: "smells upstream" compile errors in generated-file-includes (ui_*/moc_*) mean the
  *generator* failed earlier in the log — grep the log for the generate step before
  diagnosing the compile. Fix: `sed` in krita-git prepare() (drop when upstream fixes).

## 2026-09-07 — gimp/krita chain completed: cairo provide fix landed, gimp-git + krita-git installed

**Chain build pass (agent-executed):** cairo-git rebuilt (1.18.4.r141) with the versioned
`cairo=1.18.4` provide (fix from the eve-II section) → installed → gimp-git
(2:3.3.1.r1561, 4m52s with mold/24c) → krita-git (6.1.0.prealpha.r66655, uic sed in
prepare() worked first try). All verified: `pacman -Dk` free of gimp/babl/gegl/cairo/krita
errors, `ldd /usr/bin/gimp-3.3` resolves libgegl-0.4/libgegl-npd/libbabl-0.1 from the
house packages, `krita --version` → `6.1.0-prealpha (git d554c53)`.

**`pacman -U --noconfirm` does NOT auto-remove conflicting packages**: the
"…and X are in conflict. Remove X? [y/N]" prompt takes the DEFAULT (N) under --noconfirm
and the transaction dies with "unresolvable package conflicts". Passing `--ask 4`
(= ALPM_QUESTION_CONFLICT_PKG) auto-answers the removal. Non-interactive swaps of
stock→-git packages need `pacman -U --noconfirm --ask 4`.

**`tar -xOf` on package filenames containing an epoch colon** (`gimp-git-2:3.3.1-…`)
fails with "Cannot connect to gimp-git-2: resolve failed" — tar parses `host:file`
remote syntax. Prefix the filename with `./` (`tar -xOf ./"$P" .PKGINFO`).

**gimp-git installs `gimp-3.3`, not `gimp`**: GIMP's dev branch (odd minor) suffixes
binaries with the version (`gimp-3.3`, `gimp-console-3.3`, `gimptool-3.3`); there is no
`/usr/bin/gimp` symlink. Don't panic when `pacman -Ql | grep usr/bin/gimp$` is empty.
Provides are bare `gimp` (no version) — fine today (no versioned repo consumers), but
revisit if something ever depends on `gimp>=X`. krita-git, by contrast, declares the
versioned `krita=6.1.0.prealpha…` provide.

**Headless smoke tests of GUI apps from an agent shell**: `krita --version` initializes
the app and grabs the display — under xwayland it emits `BadWindow` noise; under
`QT_QPA_PLATFORM=offscreen` alone it still finds X. Clean form:
`env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 90 <app> --version`.

## 2026-09-07 — build-all.fish: end-install (`-i`) removed — it compiled mid-run packages against OLD installed deps

**Root cause of the 09-06 rust/llvm incident, restated** (`makepkg -si` bindgen failure,
see the rust-git section above): the user's full rebuild that day ran with the old
`-i/--install` = build-everything-then-install-collectively. `topo_sort` ordered
llvm-git before rust-git correctly, but llvm-git was only RECORDed in `_BUILT_PKGS`
— not installed. When rust-git compiled hours later, its `build.rs`/`llvm-config` saw
the OLD installed llvm-git (full target set), not the freshly built minimal one
sitting uninstalled in the workspace. The final batch transaction then swapped in the
minimal llvm under a rustc linked for full targets → bricked. **Correct build order
does not help if installation lags compilation**: ordering is only sound when every
package is INSTALLED before its dependents compile.

**Fix (2026-09-07, build-all.fish)**:

- `-i/--install` semantics changed to immediate per-package install in topo order:
  after each successful build, `install_pkgs_now` runs
  `sudo pacman -U --noconfirm --ask 4 <pkgs>` and CHECKS the rc — install failure
  returns 1 and aborts the run (a failed install means every later package would
  compile against the wrong system state). No more `makepkg -i` (it cannot forward
  `--ask 4` and its rc was previously discarded via `| tail -3`).
- `-si/--sepinstall` kept as a deprecated alias: prints a one-line warning, behaves
  identically to `-i`. `build_package` lost its sepinstall_flag parameter; the
  `-sif` makepkg special case is gone.
- All collective-install machinery deleted: `_BUILT_PKGS`, the end-of-run install
  block, the build-failure salvage block, and the signal-handler install. With
  immediate installs nothing is ever pending, so failure/interrupt leave the system
  in the best state the successful prefix allows; resume with `-s -i`.
- The `-s` skip path installs too (already-built packages still need topo-ordered
  installation) — same helper, same rc check.

**Rule**: never reintroduce build-then-install-collectively for ABI-coupled chains
(qt6-base→modules, llvm→rust/mesa, openssl→openssh, babl→gegl→gimp). A chain is only
correct if each package is installed before its dependents compile. `install_pkgs_now`
is the single install path — extend it, don't fork it.

## 2026-09-07 — build-all.fish: `-g critical` keystone group, `--no-deps`, mandatory selection

The `.Heavy/` split encoded "slow builds", but the operationally meaningful split is
"ABI-coupled keystones whose update must trigger a rebuild of everything downstream".
Three changes (same file, one pass):

1. **`-g critical`** — new `_GROUP_critical` = 6 keystone hubs (`.Heavy/llvm-git`,
   `.Heavy/rust-git`, `qt6-base-git`, `qt5-base-git`, `glib2-git`, `.Static/openssl`).
   New `expand_dependents` BFS-es the REVERSE `_DEPS` graph from the seeds and unions
   seeds + transitive dependents (61 pkgs as of 2026-09-07); topo_sort orders it
   (keystones first by construction). The run **auto-enables `-i`** with a notice —
   without immediate installs the chain rebuild is the rust/llvm bug again.
   gcc-snapshot deliberately excluded: no `_DEPS` edges, its "dependents" would be
   the whole workspace — manual rebuild only. `-g heavy` (12 slow builds) is unchanged.
2. **`--no-deps`** — explicit package args skip `expand_deps`: build exactly the named
   packages. Leaf rebuilds (niri without dragging llvm/rust/mesa). Default behavior
   WITHOUT the flag still expands the dep chain.
3. **No more default action** — bare `build-all.fish` (or a lone range) errors out:
   a selection (`-g` and/or package names) is mandatory. The interactive
   "Include heavy packages?" prompt and `--include-heavy` died with it. An unattended
   build-everything run is how the 09-06 break happened.

**Dep-edge audit (2026-09-07, verified against `pacman -Qi Depends`)** — added:
`polkit-git→glib2-git`, `.Static/wireplumber→glib2-git`, `.Static/udisks2→glib2-git`,
`.Static/openshadinglanguage→.Heavy/llvm-git,qt6-base-git` (OSL was missing from the
graph AND `_GROUP_static` entirely — yet it is the llvm-version-node-coupled package),
`blender-git→.Static/openshadinglanguage` (links libLLVM via OSL),
`mesa-git→.Heavy/llvm-git` (via the `aur-llvm-libs-git`/`llvm-libs` provider).
Rejected after verification: `noctalia-git→qt6-declarative` (no Qt in its depends —
it is not Qt-linked) and `networkmanager-openvpn→openssl` (reaches ssl only via
libnm). Rule: audit edges with pacman metadata, not assumptions; false edges cause
spurious rebuilds, missing edges cause ABI breaks.

**Ordering caveat**: closure-ordering edges (e.g. gimp→cairo) for NON-keystone
packages don't affect `-g critical` correctness (cairo isn't in the closure); add them
when/if those packages ever become keystones.

**`-g` multi-select** (same day): `-g` accepts several groups — repeat the flag
(`-g git -g heavy`) or comma-separate (`-g git,heavy`); groups may be combined with
positional packages. Resolution moved into `resolve_group`; the union is deduped
BEFORE topo_sort (rocm ⊂ static: `-g static,rocm` = 47, not 49 — a dupe would make
Kahn's queue process a package twice). Unknown group in any position errors out.

## 2026-09-07 — post-trim system audit: no missing libs (3 cleanups found)

Full-system verification that the 2026-09-04 PKGBUILD trim broke nothing:
`pacman -Dk` (dep graph), `pacman -Qkk` as root (file integrity), and a soname
audit (every ELF in /usr/{bin,sbin,lib,lib32,libexec}: DT_NEEDED vs ldconfig +
libdir listing → 60724 pairs, 1957 unique sonames, 55 unresolved → all classified
via `pacman -Qo`). Script pattern lives in the transcript; the awk one-liner that
builds the file→soname map from `readelf -d` (File: headers) is the reusable part.
**GOTCHA: never `xargs -P` parallel readelf into one pipe — outputs interleave
mid-line and corrupt the parse** (fake sonames like `libkrb5.`, `0x3e8`).

Verdict: **no required lib is missing; nothing the trim removed is needed**.

- `pacman -Qkk` hits all benign: cups runtime-rewritten configs, /boot perms
  hardening, nfs state files. (nfs-utils root-Qkk = 0 altered.)
- 48/55 unresolved sonames = optional feature libs never installed (espeak-ng,
  botan, openmpi, vtk, movit, rtaudio, sox-ng, openslide, hspell/nuspell/voikko,
  R, rrdtool, freetds, ffado, glade) consumed by dlopened plugins/bindings of
  stock packages (mlt, enchant/sonnet, opencv-viz, qca-qt6, boost-mpi,
  speech-dispatcher, vips, graphviz, sensord, arpd/apr-util, jack2-firewire,
  libhandy-glade). Pre-existing Arch optdepends behavior — leave.
- pyside6 soname skew: stock k*-bindings want `.6.11`, pyside6-git ships `.6.12`;
  PyQt5/PyQt6 binding modules for Qt libs not in our stack (qt5-serialport,
  qt5-xmlpatterns, qt6-connectivity/-remoteobjects/-sensors/-scxml/-websockets).
  Same acceptable family as the Qt private-API policy — import-time only.
- qt5-base-git still ships libqsqltds.so (needs absent freetds) — installed pkg
  predates the sqlite-only trim; resolves on the next batched qtbase rebuild.
- NM-openvpn legacy GTK3 editor needs absent libnma.so.0; the GTK4 editor plugin
  (libnma-gtk4) is installed and is the one actually used. Benign.

Three real findings (fixes):

1. **llvm-ocaml-git** stale pre-trim split pinning `llvm-git=24.0.0_r595038…`,
   Required By: None → `sudo pacman -Rns llvm-ocaml-git` (queued with the
   linux-tools splits removal).
2. **seatd-git** provided bare `seatd libseat` but no soname → wlroots0.20's
   `libseat.so=1-64` dep unsatisfied in pacman's graph (runtime was fine —
   /usr/lib/libseat.so.1 exists). PKGBUILD now declares `libseat.so` (bare
   entry → pacman 7.1 auto-derives the soname provide); rebuild pending.
3. **fastfetch** uninstalled while cachyos-fish-config depends on it — noise
   only (the fastfetch call in cachyos-config.fish is commented out). Either
   reinstall fastfetch or ignore.

- Soname-provide rule (reinforces the gimp/cairo one): a package shipping
  `lib*.so.N` that others declare as soname deps MUST list a bare `lib*.so`
  entry in provides.

## 2026-09-07 (pm) — heavy/critical group trim audit: keystones complete

Per-package verification that the trim didn't strip artifacts other packages
use (toolchain binaries, dlopened plugin sets, cmake/pkgconfig, Qt ABI tags):

- **ALL CLEAN except two decisions already pending**: llvm-git (llvm-config,
  FileCheck, ld.lld, libclang, clangd/clang-tidy via clang-tools-extra — all
  present), rust-git (rustc/cargo/clippy/std), gcc-snapshot (gfortran,
  libgccjit, multilib, gomp), qt6/qt5-base-git (moc/uic/rcc at
  `/usr/lib/qt6/{moc,uic,rcc}` and `/usr/bin/` respectively — qt5 uses flat
  /usr/bin, qt6 the libdir; sqlite-only sqldrivers already live in qt6, qt5
  still pre-trim), glib2-git, openssl, cmake/doxygen/meson/mold/spirv all
  present with consumers. Qt private-tag acceptance test: all 10 defining
  Qt6 libs tag `QtPrivate_6_13` == qt6-base-git. No ELF anywhere NEEDEDs a
  missing toolchain lib.
- **GTK4 print backends are NOT a loss**: upstream GTK4 builds them INTO
  libgtk (build log compiles into `gtk/libgtk.a.p/print_backends_*`; no
  `print-backends/*.so` exists to package — verify via `grep printbackendcups
  libgtk-4.so.1`). Don't "fix" a missing module dir for gtk4 like you would
  gtk3 (gtk3 still ships real `libprintbackend-cups.so`).
- **rocm-llvm + hsa-rocr + hip-runtime are UNINSTALLED** (pacman.log: one
  transaction 2026-09-06 10:11 removed rocm-llvm, comgr, rocm-device-libs,
  hsa-rocr, hip-runtime-amd, rocminfo, rocprofiler-register, hiprt,
  rocm-cmake). Nothing installed NEEDS any of their sonames (the libhiprtc
  grep hits are clang's compile-time HIP-driver strings, not runtime deps) —
  system is consistent, but HIP compute / Blender-HIP rendering is gone;
  `/opt/rocm/bin` holds only amd-smi + rdhc. Decision pending: rebuild via
  `-g rocm` or prune the 4 workspace dirs + group.
- **Stale pre-trim gcc-snapshot splits installed**: gcc-{ada,d,ga68,gcobol,
  go,m2,objc,rust}-snapshot still installed but the PKGBUILD now builds only
  c,c++,fortran,lto (+libgccjit-snapshot, lto-dump-snapshot splits). They
  still run (self-contained old builds) but are frozen. Remove with the
  queued `-Rns` batch or restore languages.
- rust-analyzer: not installed anywhere (no pacman pkg, no VS Code extension)
  — rust-git never shipped it; not a trim loss.
- stock qt6-webengine 6.11.2 (← fcitx5-chinese-addons) has no `QtPrivate_6_*`
  undefined refs in WebEngineCore but remains stock-on-dev — known-accepted
  per the 09-02 policy.
- libcloudproviders installed (← gtk3-git, nautilus) while gtk4-git has
  cloudproviders=disabled: only cosmetic (no cloud entries in GTK4 sidebars);
  nautilus links libcloudproviders directly.

## 2026-09-07 (pm II) — directory restructure: .Heavy → .Heavyweight, keystones moved

User directive: root dirs = git group; `.Heavy/` renamed to `.Heavyweight/`
(user confirmed spelling) holding heavy ∪ critical; `.Static/` unchanged.

- Moves: `.Heavy` → `.Heavyweight`; `qt6-base-git`, `qt5-base-git`,
  `glib2-git` moved from root into `.Heavyweight/` (critical ⊆ heavy ∪
  `.Static/openssl`). These are AUR-mirror git repos — `mv` preserves them.
- build-all.fish: every `.Heavy/` ref → `.Heavyweight/` (incl. the
  `string match -q '*/.Heavy/*'` canonical-clone ranker — a MISS here would
  silently demote heavy mirrors); keystone names prefixed `.Heavyweight/` in
  all _DEPS edges (keys AND colon-side refs — grep with a `(?<![/\w-])`
  lookbehind to catch bare refs, plain `.Heavy/` grep misses colon refs);
  `_GROUP_git` = 46 (−3), `_GROUP_heavy` = 15, `_GROUP_critical` = 6, closure
  still 61. Verified: `fish --no-execute` OK; dry-runs git 46 / static 47 /
  rocm 2 / heavy 15 / critical 61 / rocm+heavy 17 / static+rocm 47 (dedupe);
  critical topo order shows keystones first.
- **Auto version sync unaffected and proven**: `sync_static_version` gates on
  `*.Static/*` path match + static `^pkgver=` line. Sandbox-tested the
  extracted function on PKGBUILD COPIES: stale copy syncs (`↻ zsh: 5.8-1 →
  5.9.2-1.1`, epoch/pkgrel handling intact), current copy skips, libisl-git
  still never-syncs (repo pkg is `libisl`), and a `.Heavyweight/` path gates
  out — so the moved qt5/qt6-base + glib2 (pkgver()-driven -git builds) are
  correctly NOT repo-synced. All 50 .Static PKGBUILDs carry static `pkgver=`.
- Found during the move: root `cmake-git/` + `gtk4-git/` are src-only
  leftovers of the 2026-09-04 move (no PKGBUILD) — deletion candidates;
  stale `Project-structure.txt` (Sep 4) inside .Heavyweight vs the current
  root copy — artifact, ignore or delete.

## 2026-09-07 (pm III) — mold linker global + parallel build lanes

- **mold is now the system linker**: `-fuse-ld=mold` prepended to LDFLAGS in
  `/etc/makepkg.conf` (backup: `/etc/makepkg.conf.pre-mold-20260907`). Root
  cause of "link uses one core": bfd ld is single-threaded by design, and
  GCC `-flto=auto` gets no jobserver under ninja. Verified the driver passes
  `-fuse-ld=mold` through (`gcc -v` link test, binary runs).
- **build-all.fish: `--lanes N` parallel dispatcher** (default 1 = exact old
  sequential semantics). Ready-set scheduling on top of topo_sort:
  - lane refills as soon as a package's workspace deps are *installed*
    (never merely built — rule 11); lanes=1 dispatches in strict topo order
  - heavy-group packages run SOLO with full `-j$(nproc)` (LTO RAM guard);
    other lanes split `-j = max(4, nproc/N)`
  - pacman DB lock serializes concurrent `pacman -U`; dispatcher keeps the
    sudo timestamp warm (`sudo -v` every 4 min) — background lanes have no
    tty, so an expired timestamp would silently kill installs
  - failure: stop dispatching, DRAIN in-flight lanes, then summary + resume
    hint (remaining = never-started); cycle leftovers reported as "never
    became ready" instead of hanging the scheduler
  - output: makepkg fully redirected to per-pkg log (tee removed — terminal
    backpressure gone); dispatcher prints `▶/✔/✗ name (duration)` and tails
    failed logs; install output appended to the pkg log; `⏳` live status
    line every 10 s while 2+ lanes busy
- **Fish landmine**: command substitution splits on NEWLINES ONLY —
  `cat` of a one-line result file gives ONE list item; must `string split ' '`
  explicitly. Cost ~1 debug cycle in the lane reap loop.
- Validation: `fish --no-execute` OK; dry-run counts unchanged (git 46 /
  static 47 / rocm 2 / heavy 15 / critical 61 / rocm+heavy 17); 8/8 sandbox
  unit tests on pick_next_ready (ready-set, solo gate, empty-list edges);
  live 2-lane smoke (skip path) incl. stop-dispatch+drain failure drill in
  a /tmp mini-workspace. First real workload: pending llvm-git BPF rebuild.

## 2026-09-07 (pm IV) — fcitx5 chain: -git rebuild fixes Chinese IM addon skew

- **Root cause of broken Chinese addons** (user theory, inverted but right):
  `.Static/fcitx5` had built the installed core `fcitx5 5.1.21-1.1`, while
  fcitx5-chinese-addons/qt/gtk were STOCK repo builds compiled against the
  stock core ABI. Self-built -git core + stock addons = addon ABI skew.
- **Fix**: full -git chain now self-built & installed (all against the same
  fcitx5-git headers): xcb-imdkit-git, fcitx5-git (5.1.22.r0), fcitx5-lua-git,
  libime-git, fcitx5-qt-git (splits fcitx5-qt5-git + fcitx5-qt6-git),
  fcitx5-gtk-git, fcitx5-chinese-addons-git. Stock fcitx5* removed
  automatically via conflicts + `pacman -U --ask 4`. `.Static/fcitx5` dir
  deleted; git group 46→53, static 47→46.
- **Three hidden AUR deps**: the addon PKGBUILDs name `xcb-imdkit-git`,
  `libime-git`, `fcitx5-lua-git` BY PACKAGE NAME — stock xcb-imdkit/libime do
  not satisfy them. Cloned all three into root (tiny builds).
- **PKGBUILD trims/patches applied** (AUR originals were broken here):
  - fcitx5-qt-git: qt4 split removed (ENABLE_QT4=Off, no qt4 on system);
    `_mv_pkg` made tolerant of missing paths + dropped `usr/lib/fcitx5/qt5`
    (upstream no longer ships the qt5 quickphrase plugin — only qt6)
  - fcitx5-gtk-git: GTK2 module off (`-DENABLE_GTK2_IM_MODULE=OFF`, verified
    option name in fcitx5-gtk CMakeLists); make→ninja; prepare() sed inserts
    `#include <string>` into gtk{3,4}/utils.h — GCC 17 no longer provides
    <string> transitively via <memory>/<utility>
- Build ran through the new `--lanes 2` dispatcher end-to-end incl. a real
  stop-dispatch+drain failure cycle (first failure stopped dispatch, the
  in-flight package finished, tails printed, resume hint was correct).
- **Landmine (2nd occurrence)**: NEVER put a `#` comment after a `\` line
  continuation — in fish AND bash the comment swallows the rest of the logical
  command (broke _GROUP_static mid-list, parse error at the next line). Symptom:
  "Unknown command '<next-list-item>'". Comments go ABOVE the block.
- Not yet verified at runtime: restart fcitx5 and check Chinese IM in a real
  session (`fcitx5-remote`/addon list). qt6-wayland remains stock-missing —
  Qt6 apps on Wayland use the core's input-method-v2 path, im modules cover
  X11/Xwayland.

## 2026-09-07 (evening) — LLVM snapshot bump broke rustc (linux-tools build)

- **Symptom**: linux-tools build died; perf's Rust workload
  (`tests/workloads/code_with_type.rs`) → `rustc interrupted by SIGSEGV` in
  `compile_codegen_unit`, then `Error 139`. Bisect showed rustc crashes on
  EVERYTHING (hello world too) with heap corruption (`free(): invalid pointer`
  even in `env -i`). RUSTFLAGS (target-cpu=native / opt-level) NOT involved.
- **Root cause**: rust-git (built 09-06 16:16) vs llvm-libs-git rebuilt 09-07
  13:17 (the BPF build) + installed 15:48 — LLVM snapshots have NO stable C++
  ABI; rustc's driver links libLLVM directly. Victims (link libLLVM.so.24,
  built before today's snapshot): rust-git, mesa-git, spirv-llvm-translator-git,
  openshadinglanguage. linux-tools was just the first thing to compile Rust.
- **Why not just rebuild rust**: its bootstrap stage0 IS the broken rustc
  (chicken-and-egg); repo rust 1.98 links llvm-libs → also broken; stage0
  version checks would refuse stable-1.98 anyway.
- **Recovery — downgrade-rebuild llvm-libs to the rust-compatible snapshot**:
  1. Old snapshot recovered from /var/log/pacman.log: `r595808.29fda2c4ecca`
  2. PKGBUILD source pinned `#commit=<full hash>` (makepkg would otherwise
     pull origin/main back), rebuild + install as a DOWNGRADE — BPF target
     survives because it's build config, not the snapshot
  3. rustc works again; mesa/spirv/OSL consistent again (no rebuild needed);
     PKGBUILD UNPINNED with a same-pass rule comment
  4. Rebuilt+installed: linux-tools (perf 7.2.3-1, runs) + scx-scheds-git
     (1.1.3.r121, scx binaries present; clang --print-targets shows
     bpf/bpfeb/bpfel — the original scx blocker is CLOSED)
- **Lane dispatcher lesson (sudo)**: a 70-min build's background install can
  outlive the sudo timestamp; keepalive `sudo -v` in the dispatcher times out
  when nobody is at the tty. Build survives, install must be re-run manually
  (`sudo -n pacman -U ...`). Also fixed: non-heavy package could start
  alongside a running heavy solo build (RAM-guard defeat) — lanes now hold
  while a heavy is in flight.
- **Incident-response hardening (post-incident review)**: build-all.fish now
  handles this incident class end-to-end:
  - `check_rustc_sanity` preflight probe (trivial `fn main(){}` compile, ~2 s)
    aborts the run before it wastes an hour, with the recovery recipe inline;
    bypass `--allow-broken-rustc`. Sandbox-tested healthy + broken-stub paths.
  - keepalive: `sudo -n -v` (never hangs the dispatcher), 150 s interval —
    well inside the 5-min sudo timeout even under load
  - lane installs use `sudo -n` → fail fast instead of a 2-min doomed prompt
  - failure report distinguishes install-failure from build-failure (archive
    may exist → `-ia` or `-s -i` recover without rebuilding)
  - `-g critical` graph confirmed to include all incident victims (llvm →
    spirv/rust → mesa/OSL, 66-pkg closure, correct topo order)
- **Root-supervisor mode (2026-09-07 evening)**: `sudo fish build-all.fish …`
  now works cleanly — header shows `User: root (supervisor)`:
  - installs run DIRECTLY as root (sudo timestamp can no longer expire on
    multi-hour runs; keepalive/sudo -n only in unprivileged mode)
  - makepkg + ALL workspace artifacts run as the invoking user via
    `sudo -u $SUDO_USER env HOME=$HOME` — makepkg refuses root, and
    --asroot would scatter root-owned src/pkg into <project-root> plus caches
    (~/.ccache, ~/.cargo, ~/.cache/go-build) into /root
  - build_package restores user ownership (`chown -R`) after each package —
    root's clean/sync/PKGBUILD-edit touches never leave root-owned files
  - `-ln` refuses under sudo (git ops must be user-owned); `-cc`/`-ccc` rm
    only, safe either way
- **Rule-13 recurrence + rust-git self-rebuild capability (2026-09-08)**:
  llvm-libs moved twice on 09-07 (r595886 → r595945) while rust-git stayed at
  r339240 → rustc SIGSEGV on any input. Recovery: plain `makepkg` rebuild of
  rust-git — the PKGBUILD deletes `rustc = "/usr/bin/rustc"` from
  bootstrap.toml, so bootstrap uses the DOWNLOADED official stage0 (statically
  linked LLVM) and is immune to system libLLVM skew. This SUPERSEDES the
  earlier "rust-git cannot rebuild itself once broken" conclusion — that is
  no longer true with the current PKGBUILD. Rule 13 unchanged: after
  llvm-libs moves, rebuild rust-git + mesa-git + spirv-llvm-translator-git +
  openshadinglanguage in the same pass.
  - Hit during the rebuild: `*** stack smashing detected ***` in stage1 rustc
    inside libLLVM r595945 (`LLVMRustOptimize` → PassManager::run) while fat-
    LTOing rustc_driver. Nondeterministic (earlier pass over same inputs
    succeeded); cleared on retry. Diagnosis: `coredumpctl info <pid>` — the
    crashing frame named libLLVM.so + LLVMRustOptimize. If it ever becomes
    deterministic, suspect LLVM main drift (rust pins release/23.x, system
    llvm-git is 24-dev main) or a gcc17-built libLLVM miscompile.
  - ALSO found: the `<project-root>/.Heavy` → `.Heavyweight` rename had poisoned
    git internals — `src/rust/.git/objects/info/alternates` AND
    `src/rust/.git/config` remote origin still pointed at the old absolute
    path (symptom: "does not appear to be a git repository" during
    "Creating working copy"). Fixed with sed path rewrite; scanned all of
    .Heavyweight/.Static — no other affected package.
- **OLD-PATH AUDIT after .Heavy rename (2026-09-08)**: gtk3-git failed with
  `<project-root>/.Heavy/gtk4-git/gtk: Permission denied` during a
  FRESH `git clone --mirror` — the old path was referenced not by git
  internals this time but by a **share-the-mirror symlink**:
  `gtk3-git/gtk -> ../.Heavy/gtk4-git/gtk` (gtk3 and gtk4 PKGBUILDs use the
  same gitlab.gnome.org/GNOME/gtk.git URL, so the mirror was shared). The
  rename dangled it; a stray root-owned `.Heavy/gtk4-git` recreated on 09-07
  made it EACCES instead of ENOENT. Full audit (`find -type l` + target
  match, excluding src/pkg trees) found:
  - `libclc-git/llvm-project-git` → REPOINTED to ../.Heavyweight/llvm-git/
    llvm-project (target exists; still shares the giant llvm checkout)
  - `gtk3-git/gtk` → DELETED (makepkg recreates a local mirror; gtk4-git has
    no mirror yet, so repointing would dangle again)
  - `.Static/hip-runtime/hip-runtime-hipcc` → DELETED (rocm-llvm has no
    checkout in .Heavyweight yet; rocm stack still queued for restore-or-prune)
  - `.Heavyweight/rust-git/LICENSES/0BSD.txt -> <old-repository-path>` →
    upstream artifact, unused by PKGBUILD, deleted
  - stray root-owned `.Heavy/` (recreated 09-07 by builds that followed the
    dangling symlinks) → `sudo rm -rf`; nothing references it now
  - git-internals class (alternates + origin URL in src/rust/.git) was fixed
    earlier the same morning; string sweep of *.md/*.toml/*.json/*.kdl across
    Projects is clean (only stale CMakeConfigureLog.yaml in llvm-propeller/
    build — informational cache, harmless).
  LESSON: the rename damage came in THREE classes — git alternates, git
  origin URLs, and sharing symlinks; each surfaced at different times. Audit
  pattern: `find <project-root> -maxdepth 4 -type l` (+ `-xtype l` for dangles),
  grep alternates/config under .git dirs, then grep strings.
  RESOLVED same day: gtk3-git then failed in meson configure with
  "Unhandled python OSError" (no traceback) — forced with
  MESON_FORCE_BACKTRACE=1 → PermissionError EACCES on root-owned
  src/build leftovers. Root cause of the residue: build-all.fish's root-mode
  `chown -R` restore ran ONLY on the success path (`return 1` on build
  failure preceded it), so every failed root-mode run left root-owned files
  that poisoned retries (43 files found across gtk3-git, gtk4-git ×2,
  linux-cachyos). Fixed: chown now runs unconditionally (both paths);
  tree-wide `chown -R zhangdm:` applied. Diagnostic recipe for the masked
  OSError: it is always "an issue with your build environment" — force the
  traceback from INSIDE the failing context (env var via the PKGBUILD), not
  from an interactive shell, or the flakiness will look nondeterministic.
- **git-git: pod2man needed on PATH (2026-09-08)**: `all` target generates
  perl/build/man/man3/Git.3pm via pod2man → same Perl 5.42 core_perl
  relocation as openssl. Cannot trim docs like openssl (Git.3pm is part of
  the default build), so git's PKGBUILD now exports
  `PATH="/usr/bin/core_perl:$PATH"` in build().
- Fish landmines hit while implementing: `$pre cmd` with empty `$pre` =
  "expanded command was empty" (use if/else, no empty-prefix); root can't
  `>`-redirect over user-owned files in sticky /tmp (fs.protected_regular=2)
  → per-user temp names; rustc crate names come from output filenames →
  [A-Za-z0-9_] only, sanitize user suffixes.
- **`string join` + flag-leading argv (2026-09-07 evening)**: hint echo died
  with "string join: -g: unknown option" — argv elements starting with `-`
  are parsed as options; ALWAYS use `string join <delim> -- $argv`.
- **openssl 3.6.4: pod2man not found in package() (2026-09-07 evening)**:
  `install_man_docs` needs pod2man, which Perl 5.42 keeps at
  /usr/bin/core_perl — present in interactive PATH but missing inside the
  fakeroot/make context. Fixed with `no-docs` in Configure +
  `install_sw install_ssldirs` only (house style: docs trims; no pod2man
  dependency ever again). Rebuilt+installed; the fail-fast sudo path then
  worked as designed (build survived an expired timestamp, install re-run
  manually). Big 114-pkg run: resume with `-s -i --lanes 2` + remaining names.
- **bash PGO training run freeze: GNU timeout + interactive tests = SIGTTIN
  stop (2026-09-07 night)**: `timeout 900 make check` hung the bash build at
  0% CPU, ^C-immune. Cause: `timeout` runs the suite in a NEW background
  process group; the suite's interactive test (`tests/exec8.sub` runs
  `bash -i`) touches the controlling tty from a background group → kernel
  SIGTTIN → whole tree STOPped (`T` state). Stopped processes leave SIGINT
  pending, hence "won't respond to ^C"; only SIGKILL works. timeout would
  eventually SIGTERM them at 900s — a silent 15-min stall per attempt.
  Fix: `timeout --foreground 900 make check </dev/null >/dev/null 2>&1`
  (--foreground keeps the terminal's foreground pgroup; /dev/null stdin means
  interactive tests read EOF instead of the tty). Diagnosis pattern: `ps
  -eo pid,ppid,pgid,tpgid,stat,wchan` — STAT `T` + wchan `do_signal_stop` is
  the signature. Two orphan trees (lane + manual `makepkg -si`) were found
  racing on the same srcdir; killed both, partial profile (145 .gcda) let the
  phase-2 rebuild proceed normally.

## 2026-09-09 — vscodium-insiders-git optimization and scheduler wiring

- **Change**: added `ccache` and disabled package-level LTO for
  `vscodium-insiders-git`; its upstream build downloads a prebuilt Electron
  binary, so only native Node addons are locally compiled.
- **Optimization**: `build()` now uses the Arch ccache compiler wrappers and
  a persistent per-user cache, with mold selected through `LDFLAGS` when
  available. PGO was deliberately not added: VSCodium's build is primarily
  TypeScript/packaging work and has no meaningful local executable training
  phase.
- **Integration**: registered the package in `_DEPS` and `_GROUP_git` so
  dependency expansion, topological ordering, dry runs, and lane scheduling
  include it.
- **Rule**: optimize only the native compilation path; do not force LTO or
  invent a PGO phase for a prebuilt-Electron packaging workflow.
## 2026-09-15 — hsa-rocr build recovered from stale partial download

- **Symptom**: `makepkg -sif` repeatedly failed while retrieving
  `rocm-7.2.4.tar.gz`: curl attempted to resume at byte 831488, but the
  GitHub codeload endpoint rejected byte-range resume requests.
- **Root cause**: stale `rocm-7.2.4.tar.gz.part` remained after the previous
  interrupted download.
- **Fix**: removed only the resolved partial archive and reran
  `GIT_CONFIG_COUNT=0 makepkg -sif --noconfirm` under `.Static/hsa-rocr`.
  The fresh 41.3 MiB download, build, packaging, and pacman reinstall all
  completed successfully.
- **Verification**: installed `hsa-rocr 7.2.4-1.1`; `.PKGINFO` contains
  `provides = hsakmt-roct=7.2.4`. The existing `pkgrel=1.1` change was
  preserved.

## 2026-09-15 — imported PKGBUILD signing keys

- Extracted 46 unique active `validpgpkeys` fingerprints from all workspace
  `PKGBUILD` files, excluding commented-out examples.
- Imported the set in one `gpg --recv-keys` operation using
  `hkps://keyserver.ubuntu.com`; 43 fingerprints are now present in the user
  keyring.
- Three fingerprints were not retrievable from the public keyservers tried:
  `3D10AD045AB4AAFF8E8F36AF9B980AC2FB874FEB`,
  `ABAF11C65A2970B130ABE3C479BE3E4300411886`, and
  `C305FEBD4C4081119CB3C12CE640E67B2C7F96AA`.

## 2026-09-15 — linux-firmware VCN backport fixed for newer tag

- **Symptom**: `prepare()` failed at `git checkout 20260622 amdgpu/*vcn*`
  because the 20260910 source added `amdgpu/vcn_5_3_0.bin`, which does not
  exist in the 20260622 tag.
- **Root cause**: the old glob passed every current VCN path to checkout;
  Git rejects paths absent from the historical tree. Removing that firmware
  alone also left a stale `WHENCE` entry, causing `copy-firmware.sh` to fail.
- **Fix**: `prepare()` now enumerates current and historical VCN files,
  removes the current set, restores only files present in `20260622`, and
  removes manifest entries for VCN files absent from that tag.
- **Verification**: `makepkg -sif --noconfirm` completed; all seven split
  packages installed at `1:20260910-1`, initramfs regeneration succeeded,
  `makepkg --printsrcinfo` and `bash -n PKGBUILD` pass, and no packaged
  `vcn_5_3_0.bin` remains.

## 2026-09-15 — package-stack groups renamed and merged

- **Change**: renamed `.Static/` to `.Stable/` for packages whose versions
  synchronize with official repositories, and `.Heavyweight/` to `.Core/` for
  the heavyweight build area.
- **Groups**: replaced `static`, `heavy`, `critical`, and `rocm` with
  `stable` and `core`. `core` is the deduplicated union of the former
  heavyweight, ABI-critical, and ROCm memberships and automatically enables
  immediate per-package installation.
- **Script updates**: rewrote dependency paths, stable-version synchronization,
  scheduler solo-build checks, help text, group resolution, counts, and
  validation guidance in `build-all.fish`.
- **Documentation**: updated current-state descriptions in `MEMORY.md`;
  historical incident entries retain their original terminology.
- **Migration cleanup**: 5,320 preserved symlinks under the renamed trees
  referenced the old absolute or relative `.Heavyweight`/`.Static` paths;
  their targets were rewritten to `.Core`/`.Stable`. One unrelated broken
  staged dbus service symlink remains under `.Stable/dbus/pkg/` and was not
  changed.

## 2026-09-15 — legacy-leftover audit and builder audit mode

- **Change**: added `build-all.fish --audit`, a read-only report covering
  legacy directories, active control-file references, generated path
  references, package-group drift, dependency-path validity, and stale
  runtime/error artifacts.
- **Cleanup**: removed the stale `Project-structure.txt` snapshots, the
  abandoned `.build-logs/.lane1.result`, package-local `.srcinfo.err`
  remnants, and the unused `expand_dependents` helper. Historical migration
  references in this journal were retained.
- **Classification**: `.Stable/ccache`, `.Stable/dbus-broker`,
  `.Stable/systemd`, and the `.3rdP/` projects were classified as routine
  group candidates; `autofdo-git` and `bpftune-git` were added to `git`,
  while `ccache`, `dbus-broker`, and `systemd` were added to `stable`.
- **Auxiliary relocation**: moved `linux-cachyos` to `.Misc/`; `.Misc/`
  packages are excluded from audit membership and routine group discovery.
- **Outstanding**: `.Heavyweight/glib2-git/src/build` was recreated after
  the directory migration without a visible active builder. It was removed
  only after confirming no `makepkg`, `build-all.fish`, Meson, or Ninja
  process; if it reappears, trace the external creator before rebuilding.

## 2026-09-16 — OpenShadingLanguage LLVM 24 compatibility

- **Root cause**: LLVM 24 removed `TargetOptions::NoTrappingFPMath`,
  `FloatABIType`, and related legacy floating-point fields; OSL 1.15.3.0
  still referenced them, and its LLVM version ceiling rejected LLVM 24.
- **Fix**: repaired `osl-llvm-compat.patch` with valid LLVM version guards,
  removed the obsolete `UnifyFunctionExitNodes` include, updated the LLVM
  version ceiling to 24.9, and refreshed the patch checksum.
- **Validation**: the patch applies cleanly, the Ninja build completes, and
  `makepkg -sf --noconfirm` successfully creates the package.

## 2026-09-16 — legacy build-path guard

- **Cause**: old positional commands could still pass `.Heavyweight/...` or
  `.Static/...` directly to `build-all.fish`, so makepkg wrote into the
  pre-migration trees.
- **Fix**: positional paths now canonicalize to `.Core/...` or `.Stable/...`;
  `build_package` rejects any remaining legacy path. Removed the stale
  root-owned `.Heavyweight/{glib2-git,cmake-git,gtk4-git}` trees and added
  `.Heavyweight`/`.Heavy` → `.Core` plus `.Static` → `.Stable` compatibility
  aliases.
- **Validation**: legacy-path dry runs resolve to the migrated directories and
  `build-all.fish --audit` reports no legacy directory; the aliases resolve to
  the canonical trees.

## 2026-09-16 — multi-lane dispatcher made truly asynchronous

- **Symptom**: `--lanes 2` behaved like waves: the second lane started only
  after the first lane finished, and dependents waited for the whole wave
  instead of only their own dependencies.
- **Root cause**: Fish executes a backgrounded function call synchronously in
  this environment; `lane_job ... &` therefore blocked the dispatch loop.
- **Fix**: added a hidden `--lane-job` child mode and launch each lane through
  an external `fish` process. The parent now polls result files and refills an
  idle lane as soon as its dependencies finish (and install, when `-i` is set).
- **Validation**: mocked `cairo-git` (1s), `libdrm-git` (4s), and dependent
  `pango-git` (1s) ran with `--lanes 2`; `pango-git` started after `cairo-git`
  and before `libdrm-git` finished. Syntax, group dry runs, and `--audit` pass.

## 2026-09-16 — lane dashboard and process-output rendering

- **Symptom**: the interactive `--lanes 2` transcript could wrap lane events
  across terminal columns, interleave install/progress output with dispatcher
  lines, and print `Build interrupted` more than once after Ctrl-C. Piped
  output also contained ANSI color sequences.
- **Root cause**: the dispatcher emitted unbounded raw lines instead of owning
  a TTY-aware render surface; lane children inherited the parent's terminal
  and relied on inner build functions to stay quiet; and the signal handler
  was installed in the `--lane-job` children as well as the parent. Fish's
  `set_color` also emits ANSI when stdout is not a TTY.
- **Fix**: interactive runs now redraw a compact, width-capped dashboard;
  non-TTY and `TERM=dumb` runs use plain append-only output. Lane supervisors
  run under `setsid --wait` in isolated process groups, redirect their complete
  stdout/stderr stream to the package log, and are tracked for synchronous
  interruption cleanup. Child mode no longer installs the human-facing signal
  handler, and log tails strip carriage-return/escape controls before replay.
- **Validation**: a deterministic pseudo-TTY/pipe harness with long package
  names, child progress output, fake installs, a failing lane, and Ctrl-C
  passes the dashboard, no-ANSI, isolation, failure-drain, and exit-130 checks.
  `fish -n`, git/stable/core dry-run counts, legacy-path canonicalization, and
  `--audit` also pass.
- **Rule**: only the parent dispatcher may render live terminal state; all
  lane child output belongs in per-package logs, and every terminal update must
  be width-safe or use the plain non-TTY fallback.

## 2026-09-16 — LLVM source-heavy packages moved to core

- **Change**: moved `libclc-git` (the requested “linclc-git”) and
  `autofdo-git` from `git` to `core`; the routine counts are now 54 `git` and
  41 `core`. Both are serialized with other source-heavy/ABI-critical builds.
- **Source-sharing guard**: `-ln/--link-sources` now accepts only an actual Git
  mirror or working clone. It no longer mistakes an empty source directory
  inside a package repository for a valid mirror, and it can replace stale
  empty paths while preserving populated non-Git paths.
- **Current state**: the existing LLVM mirror path was empty; after confirming
  the live `-g git,stable` build did not touch these packages, the targeted
  fan-out was repaired. Both source-cache names now point at the missing
  `.Core/llvm-git/llvm-project` canonical path, which makepkg can populate on
  the first core LLVM build. Run the full unprivileged `build-all.fish -ln`
  after the active build finishes to recheck the other source groups.

## 2026-09-16 — lane dashboard log tails and activity hint

- **Symptom**: a long-running lane could appear healthy while blocked by a
  stale pacman database lock; the dashboard repeated its title and the event
  row did not visibly prove that the dispatcher was still polling.
- **Fix**: active lanes now show the last three sanitized lines from their
  per-package logs, refreshed on each 0.5-second dispatcher poll. The
  dashboard keeps only the one-time header, uses compact `✓`/`✗`/`⚠`/`·`
  markers, and prefixes the event row with a `-`/`\`/`|`/`/` spinner.
  Per-package logs are cleared at dispatch so preflight cannot expose a prior
  run's tail.
- **Boundary**: pipe and `TERM=dumb` output remains the existing plain
  append-only format; child build/install streams remain log-only.
- **Validation**: the temporary PTY/pipe fixture covers stale-lock visibility,
  exactly three tail rows, ANSI/control sanitization, title ownership,
  spinner cycling, narrow terminals, failure tails, and Ctrl-C exit 130.
  Fish syntax, group dry-runs, and workspace audit also pass.

## 2026-09-16 — builder frontend/backend hardening

- **Frontend review**: output paths had drifted between dashboard, sequential
  builds, installs, failures, maintenance commands, and argument errors
  (`✔`/`✓`, mixed headings, and duplicated ad-hoc color/icon formatting).
- **Backend review**: parallel installs could independently contend on
  pacman’s database lock; a lane supervisor that exited before writing a
  result could leave the dispatcher waiting forever; several filesystem,
  directory, ownership, dependency-expansion, and source-link failures were
  not surfaced explicitly.
- **Fix**: added shared UI helpers and status vocabulary, visible-cell
  dashboard truncation, atomic/validated lane results, supervisor liveness
  handling with fail-and-cleanup behavior, explicit blocked-selection failure,
  checked runtime/filesystem boundaries, and a builder-owned `flock` around
  pacman transactions. Stale `/var/lib/pacman/db.lck` files are never removed
  automatically.
- **Validation**: the temporary command matrix covers interactive/pipe output,
  narrow dashboards, fake pacman install serialization, dead and malformed
  lane results, failure reporting, source-link repair, Fish syntax, group
  dry-runs, and workspace audit. No live package build was used as a test.

## 2026-09-16 — root cause: PGO libraries recreated legacy paths

- **Evidence**: the installed `glib2-git` and `cairo-git` shared libraries
  exported `__gcov_*` symbols and contained absolute `.gcda` destinations
  under the old build trees. `gdbus --version` and `pango-view --help`
  refreshed those files, while `perf trace` captured `RDWR|CREAT` opens by
  the consumer process. This explains why the trees returned after deletion:
  an already-installed instrumented library writes its counters at process
  exit and recreates every missing parent directory.
- **Root cause**: the PGO recipes changed `CFLAGS`/`CXXFLAGS` before
  `meson setup --reconfigure`, but Meson retained the cached instrumented
  compiler options. The low-profile fallback also reconfigured without
  compiling the final non-instrumented build. Applications then loaded the
  instrumented libraries from `/usr/lib`.
- **Fix**: `glib2-git` and `cairo-git` now pass final flags explicitly through
  `-Dc_args`/`-Dcpp_args`, compile both PGO branches, reject final binaries
  containing coverage/profile symbols, and increment `pkgrel`. The public
  recipes must be rebuilt and installed before deleting the residual trees.
- **Verification**: after replacement, `readelf -sW` on the installed GLib and
  Cairo libraries must find no `__gcov_` or `__llvm_profile` symbols, and
  `strings` must contain no legacy `.gcda` destinations. The earlier
  `xdg-desktop-portal` `$HOME`/unknown-user warnings are a separate
  Flatpak/portal namespace issue, not the path creator.

## 2026-09-16 — selectable scheduler intensity profiles

- **Symptom**: automatic scheduling exposed only CPU/RAM-derived `lanes` and
  `jobs`, so users could not choose a documented effort level. The displayed
  `-j` value was per lane, making the old plan easy to misread as a global
  worker count.
- **Fix**: added `low`, `medium`, `high`, `xhigh`, and `max` profiles, with
  `xhigh` as the default. Automatic normal-lane memory is budgeted globally
  and divided across lanes; core packages retain a separate solo budget.
  `--intensity` and `GSA_INTENSITY` select the profile, while explicit
  `--lanes` and `--jobs` remain hard overrides.
- **Rule**: treat `max` as an intentional low-headroom mode. Keep the
  resolved intensity and plan in the startup output, and preserve both in
  failure resume commands.
- **Validation**: a temporary/future-maintainer fixture with fake `makepkg`
  runs all five profiles on a deterministic 24-thread/21-GiB host and checks
  the resolved lane/job plans without building a real package.

## 2026-09-20 — stable sync re-anchors its checksums to Arch

- **Symptom**: `sync_stable_version` rewrote `pkgver` from `pacman -Si` and the
  committed sums were deliberately left describing the previous version, so the
  builder passed `--skipchecksums`. The flag reached neither the terminal nor
  any log, because `build_package` is only ever called quiet and each lane logs
  its own stream.
- **Fix**: the builder now anchors the sums of every *moved* source to the value
  Arch published for the version it synced to, taken from the official packaging
  repo's `.SRCINFO`, writes them with `updpkgsums`, and verifies the fetched
  source against Arch's checksum. `--skipchecksums` is never passed. Anything
  it cannot anchor refuses the build and restores the recipe. `--help`,
  `docs/build-guide.md` and §1 rule 18 describe the behaviour instead of the
  now-removed flag.
- **Why the trigger is the source, not the version**: 26 of 28 `stable` recipes
  pin a literal version inside `source=()` URLs, so a `pkgver` bump usually
  leaves their sums valid — the rebuild difference is a *diff of the expanded
  `source=()` array*.
- **Rule**: a check that hashes what arrived agrees with a substituted tarball.
  Anchor to the authority the value came from, fail closed when it is
  unavailable, and never leave a lowered guard undisclosed.
- **Incidental finding**: sweeping every `stable` recipe against Arch found
  **four committed checksums that were simply wrong** — fish 4.9.3, upower
  1.91.4, ccache 4.14, systemd 261.3, all VCS `#tag=` sources at the same
  version as Arch. Each was confirmed from a fresh mirror with
  `makepkg --verifysource` before being rewritten, and each had been shipping a
  sum only a build with verification disabled could survive.
- **Validation**: `tests/stable-sync-checksums.sh` pins eleven scenarios, each
  falsified before being trusted; the full battery is 32/32. A partial clone
  (`--filter=blob:none`) proved unusable as a mirror — it renders an
  `export-subst` file differently and reports a false mismatch.

## 2026-09-22 — `noctalia-git` carries the upstream idle fix, so locking stops waking the display

- **Bug** (owner-reported, reproduced here): with `dim 50 s → screen off 70 s → lock 120 s`, the lock
  lit the panel back up and the whole chain replayed. Root cause is in Noctalia, not in the config:
  `IdleManager::setSessionLocked()` → `recreateBehaviorNotifications()` →
  `recreateBehaviorNotification()` ran `runResumeBehavior()` for every behaviour whose
  `phase == BehaviorPhase::Idled`, then destroyed and recreated the notification.
  `action = "screen_off"` hard-wires `resumeAction = ScreenOn`
  (`resolveIdleBehaviorActions()`), so a `screen_off` that had already blanked the display powered the
  monitors back **on** at the lock, `dim`'s `resume_command` restored the backlight, and every
  countdown restarted from the lock instant.
- **Evidence, not logs**: `/sys/class/drm/card1-eDP-1/dpms` (kernel DRM state) goes `Off` at the
  blanking stage and **back `On` 36 ms after** `[lockscreen] session is locked`, with
  `idle behavior notifications re-armed` following at `+0.31 s`. Chain shortened to 10/15/20 s so a
  cycle takes 20 s; reproduced twice on demand.
- **Upstream, not bespoke**: issue **noctalia-dev/noctalia#4190** (open, `niri`) and PR **#4002**
  (`mergeable`, "Closes #4190"). The PR was built and verified on niri from this host — panel stays
  `Off` across the lock, no replay, backlight still restored on real input — and a review plus an
  approving review were submitted upstream, together with the reproducer on #4190. **This recipe is a
  stopgap for one host until that PR merges.**
- **Change**: `prepare()` applies
  `0001-idle-lock-resume-and-inhibit-tracking.patch` with `git apply -3`, following the
  `xwayland-satellite-git` convention (`source=(... patch)`, `sha256sums` + verified hash). The patch
  is PR #4002's diff unchanged, applied against `main` at `e7acd06`; plain and 3-way application were
  both pre-flighted. `.SRCINFO` regenerated with `makepkg --printsrcinfo` — the patch appears as a
  source, as it does for the sibling package.
- **Why the host, not the recipe class**: `noctalia-git` is foreign and already in `IgnorePkg`, so a
  locally built package survives updates; a `stable` recipe here would have had to pin a moving VCS
  ref. Built with `./build-all.fish --no-deps -i noctalia-git` (9m08s), installed, shell restarted the
  niri way (`kill <pid>` + `niri msg action spawn -- noctalia`); the running binary reports
  `v5.1.0-70-ge7acd065406b-dirty`, where `-dirty` is the marker that the patch is in.
- **Removal**: delete the patch, the `source`/`sha256sums` entry and `prepare()`, and regenerate
  `.SRCINFO`, once #4002 lands. The `-dirty` suffix in the version string is the reminder.
