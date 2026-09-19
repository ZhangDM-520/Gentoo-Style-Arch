#!/usr/bin/env bash
set -euo pipefail

# tools/go-modcache-check.sh detects the module-cache corruption an unclean
# shutdown leaves behind. On 2026-09-19 exactly this damage made bettbox's
# `go mod tidy` fail with "verifying github.com/xyproto/randomstring@v1.0.5:
# zip: not a valid zip file" while the recipe itself was correct — the freeze
# had cost the last seconds of unflushed writes, so files kept their size and
# mtime with zeroed content.
#
# The fixture drives the tool against a synthetic cache under $TMPDIR. The real
# `go env GOMODCACHE` is never read or written: a decoy cache is left in place,
# damaged and NOT pointed at, and must survive untouched — that is what pins
# "the tool acts only on the cache it is told to".

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/tools/go-modcache-check.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-modcache-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'go-modcache-check fixture: %s\n' "$1" >&2
    exit 1
}

# --- a healthy cache --------------------------------------------------------
cache=$tmp/cache
mkdir -p "$cache/cache/download/github.com/ok/fine/@v" "$cache/github.com/ok/fine@v3.0.0"
printf 'PK\x03\x04real\n' >"$cache/cache/download/github.com/ok/fine/@v/v3.0.0.zip"
printf 'h1:ok=\n' >"$cache/cache/download/github.com/ok/fine/@v/v3.0.0.ziphash"
printf 'package fine\n' >"$cache/github.com/ok/fine@v3.0.0/fine.go"

out=$(GOMODCACHE=$cache "$tool") || fail "a clean cache must exit 0 (got $?)"
grep -Fq "clean ($cache)" <<<"$out" ||
    fail "a clean cache must report the path it inspected, got: $out"

# --quiet is the contract the battery and scripts use: no output at all.
out=$(GOMODCACHE=$cache "$tool" --quiet) || fail "--quiet on a clean cache must exit 0"
[[ -z $out ]] || fail "--quiet on a clean cache must print nothing, got: $out"

# --- the decoy: damaged, and never pointed at -------------------------------
decoy=$tmp/decoy
mkdir -p "$decoy/cache/download/github.com/decoy/pkg/@v" "$decoy/github.com/decoy/pkg@v9.9.9"
: >"$decoy/cache/download/github.com/decoy/pkg/@v/v9.9.9.zip"
: >"$decoy/github.com/decoy/pkg@v9.9.9/gone.go"
find "$decoy" | sort >"$tmp/decoy.before"

# --- damage, one of each detectable class ----------------------------------
# 1. zero-length zip (the loud case)
mkdir -p "$cache/cache/download/github.com/foo/bar/@v" "$cache/github.com/foo/bar@v1.0.0/sub/deep"
: >"$cache/cache/download/github.com/foo/bar/@v/v1.0.0.zip"
printf 'h1:abc=\n' >"$cache/cache/download/github.com/foo/bar/@v/v1.0.0.ziphash"
# 2. all-NUL ziphash with an intact zip (the silent case: Go trusts it forever)
mkdir -p "$cache/cache/download/github.com/baz/qux/@v"
head -c 64 /dev/zero >"$cache/cache/download/github.com/baz/qux/@v/v2.0.0.ziphash"
printf 'PK\x03\x04x\n' >"$cache/cache/download/github.com/baz/qux/@v/v2.0.0.zip"
# 3. zero-length record, plus a legitimately empty .lock that must be ignored
: >"$cache/cache/download/github.com/baz/qux/@v/v2.0.0.mod"
: >"$cache/cache/download/github.com/baz/qux/@v/v2.0.0.lock"
# 4. zero-length source inside an extracted tree
: >"$cache/github.com/foo/bar@v1.0.0/sub/deep/empty.go"

set +e
out=$(GOMODCACHE=$cache "$tool" 2>&1)
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "damage must exit 1, got $rc"

grep -Fq 'zero-length zip: cache/download/github.com/foo/bar/@v/v1.0.0.zip' <<<"$out" ||
    fail "did not report the zero-length zip"
grep -Fq 'all-NUL ziphash' <<<"$out" || fail "did not report the all-NUL ziphash"
grep -Fq 'zero-length record: cache/download/github.com/baz/qux/@v/v2.0.0.mod' <<<"$out" ||
    fail "did not report the zero-length .mod"
grep -Fq 'github.com/foo/bar@v1.0.0/sub/deep/empty.go' <<<"$out" ||
    fail "did not report the zero-length source"

# False positives are as damaging as misses: the lock file and the healthy
# module must not be named.
grep -Fq 'v2.0.0.lock' <<<"$out" && fail "reported a legitimately empty .lock file"
grep -Fq 'ok/fine' <<<"$out" && fail "reported a healthy module"

# --- purge ------------------------------------------------------------------
set +e
out=$(GOMODCACHE=$cache "$tool" --purge 2>&1)
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "--purge must still exit non-zero while damage was found, got $rc"

[[ -e $cache/cache/download/github.com/foo/bar/@v ]] &&
    fail "purge left the damaged download record in place"
[[ -e $cache/github.com/foo/bar@v1.0.0 ]] &&
    fail "purge left the damaged extracted tree in place"
[[ -e $cache/cache/download/github.com/baz/qux/@v ]] &&
    fail "purge left the all-NUL module's record in place"

# The healthy module survives, or a purge is just `rm -rf`.
[[ -f $cache/github.com/ok/fine@v3.0.0/fine.go ]] || fail "purge removed a healthy extracted tree"
[[ -f $cache/cache/download/github.com/ok/fine/@v/v3.0.0.zip ]] ||
    fail "purge removed a healthy download record"

# The decoy must be byte-for-byte untouched.
find "$decoy" | sort >"$tmp/decoy.after"
diff -q "$tmp/decoy.before" "$tmp/decoy.after" >/dev/null ||
    fail "the tool modified a cache it was not pointed at"
grep -Fq 'decoy' <<<"$out" && fail "the tool named a cache it was not pointed at"

# --- and now it is clean ----------------------------------------------------
GOMODCACHE=$cache "$tool" --quiet ||
    fail "after --purge the cache must be clean"

printf 'go-modcache-check fixture: PASS\n'
