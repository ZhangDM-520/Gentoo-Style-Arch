#!/usr/bin/env bash
set -euo pipefail

# `-ccc`/`--nuclear` deletes the downloads makepkg leaves in a recipe directory,
# and the root .gitignore denies the same set. When the two drifted, a commit
# sweep picked up 36 MB of upstream archives (2026-09-20: ten files under
# `libreoffice-fresh`) because the cleanup matched only `*.tar.*` and `*.whl`.
# This fixture pins the pairing from the builder side: every archive type the
# ignore file denies is deleted, and nothing else is.
#
# It also pins the two properties that make a broad list safe:
#   * only URL-backed entries are targets — a local patch, keyring or hook in the
#     recipe directory is somebody's committed asset, and `tests/recipe-sources.sh`
#     would fail if it went missing;
#   * a symlinked source is deliberate sharing, so -ccc keeps it and reports it.
#
# The report itself is part of the contract for the same reason: a pipe is the
# documented way to read this builder (the dashboard is only for a terminal), and
# a maintenance sweep has to be able to see *what* -ccc is about to delete before
# it agrees. Assertions 3 and 5 pin that, which is also what caught the
# `echo (set_color …)"text"` form going blank off a terminal.
#
# Nothing here touches the real repository: the workspace is synthetic, under
# $TMPDIR, and `sudo` is a stub that runs the command it is handed.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-cleanup-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'cleanup-extensions fixture: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$fixture/config/groups" "$fixture/packages/demo" "$fixture/bin"
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
printf 'demo|packages/demo\n' >"$fixture/config/packages.map"
printf 'demo\n' >"$fixture/config/groups/git.list"

cat >"$fixture/packages/demo/PKGBUILD" <<'EOF'
pkgname=demo
pkgver=1.0
source=('https://example.invalid/thing-1.0.tar.xz'
        'https://example.invalid/bundle-2.0.tgz'
        'https://example.invalid/art-3.0.zip'
        'https://example.invalid/tool-4.0.jar'
        'https://example.invalid/font-5.0.ttf'
        'https://example.invalid/wheel-6.0-py3-none-any.whl'
        'https://example.invalid/plain-7.0.tar'
        'git+https://example.invalid/shared.git'
        'local.patch'
        'local.patch.sig')
EOF

# A stub that behaves like a passwordless `sudo`: run what it was given.
cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -n ]]; then
    shift
fi
exec "$@"
EOF
chmod +x "$fixture/bin/sudo"

pkgdir="$fixture/packages/demo"

# The downloads, named exactly as makepkg's SRCDEST would leave them, plus the
# companion files that travel with an archive.
for f in thing-1.0.tar.xz bundle-2.0.tgz art-3.0.zip tool-4.0.jar \
         font-5.0.ttf wheel-6.0-py3-none-any.whl plain-7.0.tar \
         thing-1.0.tar.xz.sig thing-1.0.tar.xz.asc thing-1.0.tar.xz.part; do
    printf 'download\n' >"$pkgdir/$f"
done
# A local asset and its signature: never a target, because neither is a URL.
for f in local.patch local.patch.sig; do
    printf 'asset\n' >"$pkgdir/$f"
done

# A VCS source that is shared by symlink, and a symlinked staging dir: both are
# deliberate and both must survive.
mkdir -p "$fixture/shared/shared" "$fixture/shared/src-target"
ln -s "$fixture/shared/shared" "$pkgdir/shared"
ln -s "$fixture/shared/src-target" "$pkgdir/src"

rc=0
printf 'y\n' | PATH="$fixture/bin:$PATH" GSA_STATE_DIR="$fixture/state" \
    fish "$fixture/build-all.fish" -ccc >"$fixture/out" 2>"$fixture/err" || rc=$?

(( rc == 0 )) || fail "nuclear cleanup exited $rc: $(tail -3 "$fixture/err")"

# ─── 1. Every extension the ignore file denies is now a cleanup target ──────
for f in thing-1.0.tar.xz bundle-2.0.tgz art-3.0.zip tool-4.0.jar \
         font-5.0.ttf wheel-6.0-py3-none-any.whl plain-7.0.tar \
         thing-1.0.tar.xz.sig thing-1.0.tar.xz.asc thing-1.0.tar.xz.part; do
    [[ ! -e "$pkgdir/$f" ]] || fail "a downloaded archive survived -ccc: $f"
done

# ─── 2. A local asset is not a download and must survive ───────────────────
for f in local.patch local.patch.sig; do
    [[ -e "$pkgdir/$f" ]] || fail "a local, non-URL source was deleted: $f"
done

# ─── 3. Symlinks are preserved and reported, not deleted ───────────────────
[[ -L "$pkgdir/src" ]] || fail "the symlinked staging dir was deleted"
[[ -e "$pkgdir/src" ]] || fail "the symlinked staging dir lost its target"
[[ -L "$pkgdir/shared" ]] || fail "the symlinked VCS source was deleted"
grep -q 'preserved' "$fixture/out" ||
    fail "symlinks were kept silently — the report does not say so: $(tail -5 "$fixture/out")"

# ─── 4. The report names what it deleted, so a maintainer can audit it ─────
grep -q 'art-3.0.zip' "$fixture/out" ||
    fail "-ccc did not report the .zip it deleted: $(tail -8 "$fixture/out")"

# ─── 5. …and it survives a pipe, which is the interface scripts read ───────
grep -q 'NUCLEAR' "$fixture/out" ||
    fail "the deletion banner is invisible in piped output"
grep -q 'symlink(s) preserved' "$fixture/out" ||
    fail "the symlink summary is invisible in piped output"

# ─── 6. The cleanup list and the ignore list are one list ──────────────────
# The invariant stated in build-all.fish: `-ccc` deletes exactly the archive
# types the root .gitignore denies. Drift one way and a sweep commits a
# download; drift the other and -ccc leaves it on disk for someone to commit.
# Static, because it is a property of the two files rather than a run: every
# member of the list must have a rule, and every archive rule must be a member.
# `.part`/`.sig`/`.asc`/`.log` are companions that follow a matched archive, and
# `*.pkg.tar.*`/`*.src.tar.*` are makepkg output rather than downloads, so those
# rules are legitimately absent from the list.
builder_list=$(sed -n 's/^set -g _DOWNLOAD_ARCHIVE_EXTS //p' "$root/build-all.fish" | tr -d "'")
[[ -n $builder_list ]] || fail "build-all.fish no longer defines _DOWNLOAD_ARCHIVE_EXTS"
for ext in $builder_list; do
    grep -qxF "*.$ext" "$root/.gitignore" ||
        fail "the cleanup list deletes '*.$ext' but .gitignore does not deny it"
done
while IFS= read -r rule; do
    ext=${rule#\*.}
    case $ext in
        # Companions that follow a matched archive, makepkg's own output, and
        # the generated-artifact / credential / scratch families further down
        # the file: none of these is a download, so none belongs in the list.
        pkg.tar.* | src.tar.* | part | sig | asc | log | log.*) continue ;;
        profraw | gcda | gcno | enc | tmp.*) continue ;;
    esac
    [[ " $builder_list " == *" $ext "* ]] ||
        fail ".gitignore denies '*.$ext' but -ccc would leave it on disk"
done < <(grep -E '^\*\.' "$root/.gitignore")

printf 'cleanup-extensions fixture: PASS\n'
