#!/usr/bin/env bash
set -uo pipefail

# go-modcache-check.sh — detect the Go module cache damage an unclean shutdown leaves.
#
# Why this exists
# ---------------
# On 2026-09-19 a hard freeze (frozen frame, only a power-off recovered it) was
# followed by `go mod tidy` failing in bettbox with
#
#   verifying github.com/xyproto/randomstring@v1.0.5: zip: not a valid zip file
#
# Nothing was wrong with the recipe. The freeze cost the last seconds of
# unflushed writes, and XFS log recovery restored metadata without the data, so
# files existed with plausible sizes and mtimes and zeroed content. The damage
# class is nasty for two reasons:
#
#   * a `*.zip` of size 0 fails loudly, which is the lucky case;
#   * a `*.ziphash` of the correct length whose bytes are all NUL makes Go
#     believe the module is already verified, so it never re-downloads it — the
#     build then fails later with `zip has been modified`, or, worse, succeeds
#     against a truncated tree;
#   * an extracted `<module>@<version>` directory can hold zero-length `.go`
#     files, which compile as empty sources instead of erroring.
#
# Read-only by default. `--purge` deletes the offending module's download record
# and its extracted tree so the next build re-fetches it.
#
# Caveat worth reading before trusting a purge: the checks below find what is
# *detectable*. A file whose size was preserved and whose content was zeroed
# inside an otherwise valid module tree is indistinguishable from a legitimately
# empty file, so `--purge` cannot clear that class. After a hard freeze on a
# machine that builds Go code, `go clean -modcache` is the only complete repair.
#
# Usage:
#   tools/go-modcache-check.sh [--purge] [--quiet]
#
#   GOMODCACHE   cache to inspect (default: `go env GOMODCACHE`)
#
# Exit status: 0 clean, 1 damage found (reported, and purged with --purge),
# 2 usage or environment error.
#
# This is a host-side diagnostic and deliberately outside tests/: it inspects a
# real cache the battery must never touch. tests/modcache-check.sh pins its
# behaviour against a synthetic cache under $TMPDIR.

usage() {
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

purge=0
quiet=0
while (($# > 0)); do
    case $1 in
        --purge) purge=1 ;;
        --quiet) quiet=1 ;;
        -h | --help) usage ;;
        *) printf 'go-modcache-check: unknown argument: %s\n' "$1" >&2; usage ;;
    esac
    shift
done

if [[ -n ${GOMODCACHE:-} ]]; then
    cache=$GOMODCACHE
else
    if ! command -v go >/dev/null 2>&1; then
        printf 'go-modcache-check: no go in PATH and GOMODCACHE is unset\n' >&2
        exit 2
    fi
    cache=$(go env GOMODCACHE)
fi
cache=${cache%/}

if [[ ! -d $cache ]]; then
    # Nothing cached means nothing to corrupt; that is a pass, not an error.
    ((quiet)) || printf 'go-modcache-check: no module cache at %s\n' "$cache"
    exit 0
fi

download=$cache/cache/download
found=0
declare -a damaged_modules=()

report() {
    printf 'go-modcache-check: %s\n' "$1"
}

# Record a damaged module and its two removable paths: the download record and
# the extracted tree. Paths are derived from the cache layout, which is
# `<cache>/<module-path>@<version>` for an extraction and
# `<cache>/cache/download/<module-path>/@v/<version>.<ext>` for a record.
note_module() { # <download-record-path> <version>
    local rel=${1#"$download"/}
    local moddir=${rel%%/@v/*}
    damaged_modules+=("$moddir@$2")
}

# --- 1. zero-length zips (the loud, lucky failure) --------------------------
while IFS= read -r -d '' f; do
    found=1
    report "zero-length zip: ${f#"$cache"/}"
    note_module "$f" "$(basename "$f" .zip)"
done < <(find "$download" -name '*.zip' -type f -size 0 -print0 2>/dev/null)

# --- 2. all-NUL hashes (Go trusts these, so it never re-downloads) ----------
while IFS= read -r -d '' f; do
    # A hash file is legitimately non-empty printable hex; all NUL means the
    # write was lost while the metadata (and so the length) survived.
    if [[ -z $(tr -d '\0' <"$f") ]]; then
        found=1
        report "all-NUL ziphash (module will never be re-downloaded): ${f#"$cache"/}"
        note_module "$f" "$(basename "$f" .ziphash)"
    fi
done < <(find "$download" -name '*.ziphash' -type f -size +0 -print0 2>/dev/null)

# --- 3. zero-length records ------------------------------------------------
# `.lock` files are legitimately empty and are excluded on purpose.
while IFS= read -r -d '' f; do
    found=1
    report "zero-length record: ${f#"$cache"/}"
    case $f in
        *.ziphash) note_module "$f" "$(basename "$f" .ziphash)" ;;
        *.mod | *.info) note_module "$f" "$(basename "${f%.*}")" ;;
    esac
done < <(find "$download" \( -name '*.ziphash' -o -name '*.mod' -o -name '*.info' \) \
    -type f -size 0 -print0 2>/dev/null)

# --- 4. zero-length .go files inside extracted trees ------------------------
while IFS= read -r -d '' f; do
    found=1
    report "zero-length source in an extracted module: ${f#"$cache"/}"
    # The extracted tree is the ancestor directory carrying the @version
    # marker; the module path itself contains slashes, so walk up rather than
    # splitting on the first one.
    d=$(dirname "$f")
    while [[ ${d##*/} != *@* && $d != "$cache" && $d != / ]]; do
        d=$(dirname "$d")
    done
    [[ ${d##*/} == *@* ]] && damaged_modules+=("${d#"$cache"/}")
done < <(find "$cache" -path "$download" -prune -o -name '*.go' -type f -size 0 -print0 2>/dev/null)

if ((found == 0)); then
    ((quiet)) || printf 'go-modcache-check: clean (%s)\n' "$cache"
    exit 0
fi

if ((purge == 0)); then
    printf 'go-modcache-check: %d damaged entr(y|ies) — re-run with --purge to remove them,\n' \
        "${#damaged_modules[@]}" >&2
    printf '                   or `go clean -modcache` for the complete repair.\n' >&2
    exit 1
fi

# --- purge ----------------------------------------------------------------
# De-duplicate: one module can show several symptoms.
declare -A seen=()
for entry in "${damaged_modules[@]}"; do
    [[ -n ${seen[$entry]:-} ]] && continue
    seen[$entry]=1
    # entry is "<module-path>@<version>"; the download record lives under @v/.
    moddir=${entry%@*}
    version=${entry##*@}
    if [[ -d $download/$moddir/@v ]]; then
        rm -rf -- "$download/$moddir/@v"
        printf 'go-modcache-check: purged record %s/@v\n' "$moddir"
    fi
    if [[ -d $cache/$moddir@$version ]]; then
        rm -rf -- "$cache/$moddir@$version"
        printf 'go-modcache-check: purged tree %s@%s\n' "$moddir" "$version"
    fi
done

printf 'go-modcache-check: purged %d module(s); the next build re-downloads them.\n' \
    "${#seen[@]}" >&2
printf 'go-modcache-check: NOTE — a zeroed file that kept its original size is not\n' >&2
printf '                   detectable. If the machine hard-froze, prefer\n' >&2
printf '                   `go clean -modcache` over a targeted purge.\n' >&2
exit 1
