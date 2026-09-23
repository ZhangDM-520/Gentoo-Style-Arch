#!/usr/bin/env bash
set -euo pipefail

# Root-mode half of the 2026-09-23 log-ownership contract (the unprivileged
# quarantine half is pinned by tests/log-ownership.sh).
#
# In root mode the supervisor's shell opens every log, so before the fix the
# per-package log was created root-owned at lane spawn and only repaired at
# package exit (chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR") — an
# interrupted run left the in-flight logs poisoned for the next unprivileged
# run. The contract this fixture pins:
#   * ownership is decided at WRITE time: an unopenable log is repaired in
#     place (chown + owner-writable) BEFORE any redirect opens it, loudly;
#   * root mode repairs in place and NEVER quarantines — .stale.* renames are
#     the unprivileged recovery path only;
#   * nothing root-owned survives: the run completes rc=0 with the build
#     running as the invoking user.
#
# Portability: a fixture cannot create genuinely root-owned files without
# sudo, so the poison combines the real shape (0644) with a `stat` stub that
# reports owner "root" for exactly that path — the builder's root-mode
# predicate is `stat -c %U`, so it sees precisely what it would see on the
# real incident, while the file stays writable so the repaired run can
# actually write. The `id` stub makes the builder believe it runs under sudo
# (SUDO_USER set); the `chown` stub records every invocation (a real chown to
# the current owner would be a no-op anyway). Assertions key on a PER-FILE,
# non-`-R` chown naming the poisoned log plus the announced repair — the
# pre-write-time repair — which the startup/exit `chown -R` sweeps can never
# produce (they name directories, never the log file).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-log-ownership-root.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'log-ownership-root: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '%s\n' "$2" >&2
    exit 1
}

dir="$fixture/rootmode"
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
for group in git stable core misc third-party app; do
    : >"$dir/config/groups/$group.list"
done
: >"$dir/config/packages.map"
for id in p1 p2; do
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
mkdir -p "$GSA_FAKE_MARKER_DIR"
touch "$GSA_FAKE_MARKER_DIR/$id"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF

# Pretend-root identity: `id -un` answers "root" only when the fixture asks
# for root mode; everything else falls through to the real id.
cat >"$dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -un && ${GSA_FAKE_ROOT_MODE:-0} == 1 ]]; then
    echo root
    exit 0
fi
exec /usr/bin/id "$@"
EOF

# Record every sudo invocation; `sudo -u <user> cmd…` drops the impersonation
# pair (the fixture really runs as the build user) and execs the rest.
cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?fixture forgot GSA_FAKE_SUDO_LOG}"
if [[ ${1:-} == -u && $# -ge 2 ]]; then
    shift 2
fi
((${#@})) || exit 0
exec "$@"
EOF

# Record every chown invocation and succeed. The helper's follow-up chmod
# (real, unstubbed) is what makes the poisoned file writable again; owner is
# already correct in the fixture, so a no-op chown + real chmod + stat
# verify is exactly the repair sequence asserted below.
cat >"$dir/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GSA_FAKE_CHOWN_LOG:?fixture forgot GSA_FAKE_CHOWN_LOG}"
exit 0
EOF

# Lie about ownership of exactly one path: fixtures cannot chown to root, but
# the root-mode repair branch keys on `stat -c %U`. Every other stat (mtime
# skip-checks, %A/%a modes) falls through to the real binary.
cat >"$dir/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${GSA_FAKE_ROOT_FILE:-} && ${1:-} == -c && ${2:-} == %U &&
    ${*: -1} == "$GSA_FAKE_ROOT_FILE" ]]; then
    echo root
    exit 0
fi
exec /usr/bin/stat "$@"
EOF

chmod +x "$dir/bin/makepkg" "$dir/bin/id" "$dir/bin/sudo" "$dir/bin/chown" \
    "$dir/bin/stat"

# Poison p1's log: run-A content, mode exactly like a real root-owned 0644
# log, owner reported as "root" by the stat stub (GSA_FAKE_ROOT_FILE).
mkdir -p "$dir/state/logs"
printf 'SENTINEL run-A crash evidence\n' >"$dir/state/logs/p1.log"

# Resolve the real user BEFORE the PATH prefix exists: bash expands prefixed
# assignments sequentially, so `id -un` inside the prefix would hit the stub
# (GSA_FAKE_ROOT_MODE is already set by then) and answer "root".
fixture_user=$(id -un)

set +e
output=$(
    PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_ROOT_MODE=1 \
        SUDO_USER="$fixture_user" \
        GSA_FAKE_SUDO_LOG="$dir/state/sudo.log" \
        GSA_FAKE_CHOWN_LOG="$dir/state/chown.log" \
        GSA_FAKE_ROOT_FILE="$dir/state/logs/p1.log" \
        GSA_FAKE_MARKER_DIR="$dir/state/built" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" --no-deps --allow-broken-rustc --no-sync p1 p2 \
        2>&1
)
rc=$?
set -e

if ((rc != 0)); then
    fail "root-mode run over a poisoned log must succeed via write-time repair, rc=$rc" "$output"
fi
if grep -q 'rc=125' <<<"$output"; then
    fail "misleading rc=125 lane row reappeared (log open failed before the build)" "$output"
fi
if grep -q 'An error occurred while redirecting file' <<<"$output"; then
    fail "fish redirect error escaped (the poisoned log was not repaired in time)" "$output"
fi
if ! grep -q 'repaired root-owned runtime file' <<<"$output"; then
    fail "write-time repair was not announced (must be loud, not silent)" "$output"
fi
if ! grep 'repaired root-owned runtime file' <<<"$output" |
    grep -F -- 'logs/p1.log' >/dev/null; then
    fail "repair announcement does not name the poisoned log" "$output"
fi

chownlog="$dir/state/chown.log"
[[ -f $chownlog ]] || fail "chown stub never invoked — no ownership repair ran" "$output"
# The pre-write-time repair: names the poisoned FILE, without -R (the exit
# chown -R names only directories and can never satisfy this).
if ! grep -v -- '-R' "$chownlog" | grep -F -- "logs/p1.log" >/dev/null; then
    fail "no per-file chown naming the poisoned log before it was opened:" \
        "$(cat "$chownlog")"
fi

# Root mode repairs IN PLACE — quarantine (.stale.*) is unprivileged-only.
shopt -s nullglob
stale=("$dir"/state/logs/*.stale.*)
shopt -u nullglob
if ((${#stale[@]} != 0)); then
    fail "root mode quarantined instead of repairing in place:" "$(ls -la "$dir/state/logs")"
fi

log="$dir/state/logs/p1.log"
[[ -w $log ]] || fail "log still not writable after repair: $log"
if ! grep -q 'fake makepkg' "$log"; then
    fail "build log missing stub makepkg output — the build never ran" \
        "$(cat "$log" 2>/dev/null)"
fi
for id in p1 p2; do
    [[ -f $dir/state/built/$id ]] ||
        fail "package $id never built — repair must not abort the run" "$output"
done

printf 'log-ownership-root fixture: PASS\n'
