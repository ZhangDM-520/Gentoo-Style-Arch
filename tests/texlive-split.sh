#!/usr/bin/env bash
set -euo pipefail

# texlive-texmf split-loop equivalence fixture.
#
# prepare() in packages/git/texlive-texmf splits texmf-dist into one directory
# per TeX Live collection, by parsing tlpkg/texlive.tlpdb. That loop was
# rewritten on 2026-09-18 (one awk pass instead of ~4.1k full-file rescans,
# renames batched per destination instead of one mkdir+mv per file) because it
# is the hot path of a build that twice froze the machine. A rewrite of a split
# loop can silently change what the packages contain, so this fixture runs the
# PREVIOUS implementation — frozen in tests/assets/texlive-split-legacy.sh — and
# the live one over the same synthetic tree and requires identical results.
#
# It also pins the two properties the rewrite exists for: far fewer process
# spawns, and a refusal (instead of a silently incomplete package) when
# texmf-dist has already been split, because the loop MOVES files out of it.
#
# Everything happens in a scratch tree; the real tree is never touched.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/texlive-texmf"
legacy="$root/tests/assets/texlive-split-legacy.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-texlive-split.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'texlive split fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The synthetic srcdir, mirroring the real tree's shape ─────────────────
base="$tmp/base"
mkdir -p "$base/tlpkg" "$base/x86_64-linux"
mkdir -p "$base/texmf-dist/tex/alpha/sub" "$base/texmf-dist/tex/beta"
mkdir -p "$base/texmf-dist/fonts/alpha" "$base/texmf-dist/scripts/alphaone"
mkdir -p "$base/texmf-dist/doc/alpha" "$base/texmf-dist/doc/beta"

printf 'one.sty content\n' >"$base/texmf-dist/tex/alpha/one.sty"
printf 'two.tex content\n' >"$base/texmf-dist/tex/alpha/sub/two.tex"
printf 'beta one\n'        >"$base/texmf-dist/tex/beta/one.sty"
printf 'tfm\n'             >"$base/texmf-dist/fonts/alpha/two.tfm"
printf '#!/bin/sh\necho alphaone\n' >"$base/texmf-dist/scripts/alphaone/alphaone.pl"
printf 'alpha doc\n'       >"$base/texmf-dist/doc/alpha/one.pdf"
printf 'beta doc\n'        >"$base/texmf-dist/doc/beta/one.pdf"
ln -s ../../texmf-dist/scripts/alphaone/alphaone.pl "$base/x86_64-linux/alphaone"

cat >"$base/tlpkg/texlive.tlpdb" <<'EOF'
# synthetic texlive.tlpdb for tests/texlive-split.sh
name collection-alpha
category Collection
shortdesc Alpha collection
longdesc Alpha long description
depend alphaone
depend alphatwo
depend collection-beta
depend alphaone.ARCH

name alphaone
category Package
shortdesc Alpha one
depend alphaone.ARCH
runfiles
 texmf-dist/tex/alpha/one.sty
 texmf-dist/doc/alpha/one.pdf
 texmf-dist/scripts/alphaone/alphaone.pl

name alphaone.x86_64-linux
category TLCore
shortdesc x86_64-linux files of alphaone
binfiles arch=x86_64-linux size=1
 bin/x86_64-linux/alphaone

name alphatwo
category Package
shortdesc Alpha two
execute AddFormat name=alphafmt engine=pdftex options=alphafmt.ini
execute addMap alpha.map
execute AddHyphen name=alpha
runfiles
 texmf-dist/tex/alpha/sub/two.tex
 texmf-dist/fonts/alpha/two.tfm

name collection-beta
category Collection
shortdesc Beta collection
depend betaone

name betaone
category Package
shortdesc Beta one
execute addMixedMap beta.mixed.map
runfiles
 texmf-dist/tex/beta/one.sty
 texmf-dist/doc/beta/one.pdf

EOF

# A single directory holding many files is the case the rewrite exists for: the
# legacy loop issues one dirname + one mkdir + one mv per file, while the rewrite
# issues one mkdir and a couple of mv calls for the whole directory. gamma is the
# only collection whose size matters, so it is generated rather than written out.
gamma_dir="$base/texmf-dist/fonts/gamma"
mkdir -p "$gamma_dir"
{
    printf '\nname collection-gamma\ncategory Collection\nshortdesc Gamma collection\ndepend gammaone\n'
    printf '\nname gammaone\ncategory Package\nshortdesc Gamma one\nrunfiles\n'
    for i in $(seq 1 600); do
        printf ' texmf-dist/fonts/gamma/g%03d.tfm\n' "$i"
        printf 'g%s\n' "$i" >"$gamma_dir/g$(printf '%03d' "$i").tfm"
    done
} >>"$base/tlpkg/texlive.tlpdb"

# The files prepare() copies into $srcdir before splitting.
cat >"$base/fmtutil.cnf" <<'EOF'
# fmtutil.cnf
alphafmt pdftex  -alphafmt.ini
otherfmt luatex  -other.ini
EOF
cat >"$base/updmap.cfg" <<'EOF'
# updmap.cfg
Map alpha.map
MixedMap beta.mixed.map
KanjiMap other.map
EOF
cat >"$base/language.dat" <<'EOF'
% language.dat
from alphatwo: % alpha hyphenation
alpha hyph-alpha.tex
% end of data
EOF
cat >"$base/language.dat.lua" <<'EOF'
return {
from alphatwo: -- alpha hyphenation
  ["alpha"] = { "hyph-alpha.tex" },
}
EOF
cat >"$base/language.def" <<'EOF'
% language.def
from alphatwo: % alpha hyphenation
\addlanguage{alpha}{hyph-alpha.tex}{}{2}{2}
% end of data
EOF

# ─── Extract the live implementation from the recipe ───────────────────────
# Same contract as the frozen asset: cwd is the synthetic tree, `_collections`
# is set, and `${srcdir}` points at it.
live_section="$tmp/live-section.sh"
awk '
    /^prepare\(\) *\{/ { inprep = 1; next }
    inprep && /^\}/ { exit }
    inprep && /# Split files per package/ { keep = 1 }
    keep && inprep { print }
' "$recipe/PKGBUILD" >"$live_section"
grep -q '_collections' "$live_section" || fail "could not extract the split loop from the PKGBUILD"
grep -q '_tl_root' "$live_section" || fail "the extracted loop is not the batched implementation"

# ─── Run an implementation over a private copy of the tree ─────────────────
# A PATH shim records every external command the implementation runs, so the
# spawn count is measured rather than guessed. Applies to both implementations
# identically.
shim="$tmp/shim"
mkdir -p "$shim"
for exe in mv mkdir cp ln sed grep sort cut uniq xargs cat dirname head wc readlink; do
    cat >"$shim/$exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$exe" >>"\$GSA_FAKE_SPAWN_LOG"
exec /usr/bin/$exe "\$@"
EOF
    chmod +x "$shim/$exe"
done
for exe in mv mkdir cp ln sed grep sort cut uniq xargs cat dirname head wc readlink; do
    test -x "/usr/bin/$exe" || fail "fixture needs /usr/bin/$exe"
done

# The wrapper carries the contract the recipe provides this code: cwd is the
# srcdir, srcdir is set, and _collections lists the collections to split. (An
# array cannot cross into a new bash process, so it is written out.)
write_wrapper() { # write_wrapper <out-file> <section-file>
    # The section runs inside a function, as it does inside prepare(): its
    # refusal path is a `return 1`, which is only meaningful there.
    {
        printf '%s\n' 'set +e' 'srcdir=$PWD' 'export srcdir GSA_FAKE_SPAWN_LOG' \
            '_collections=(alpha beta gamma)' 'split_section() {'
        cat "$2"
        printf '%s\n' '}' 'split_section'
    } >"$1"
}

run_impl() { # run_impl <label> <section-file>
    local label=$1 section=$2 work="$tmp/run-$1"
    cp -a "$base" "$work"
    : >"$tmp/spawns-$label"
    write_wrapper "$tmp/wrapped-$label.sh" "$section"
    (
        cd "$work"
        GSA_FAKE_SPAWN_LOG="$tmp/spawns-$label" \
            PATH="$shim:$PATH" bash "$tmp/wrapped-$label.sh" \
            >"$tmp/out-$label" 2>"$tmp/err-$label"
        echo $? >"$tmp/rc-$label"
    ) || true
    return 0
}

run_impl legacy "$legacy"
run_impl live "$live_section"
legacy_rc=$(cat "$tmp/rc-legacy")
live_rc=$(cat "$tmp/rc-live")
[[ $legacy_rc == 0 ]] || fail "the frozen legacy implementation exited $legacy_rc: $(cat "$tmp/err-legacy")"
[[ $live_rc == 0 ]] || fail "the live implementation exited $live_rc: $(cat "$tmp/err-live")"

# ─── Identical results ─────────────────────────────────────────────────────
# Type, permissions, path and symlink target for every entry in the tree.
listing() {
    (cd "$1" && find . -printf '%y %m %p -> %l\n' | sort)
}
listing "$tmp/run-legacy" >"$tmp/list-legacy"
listing "$tmp/run-live" >"$tmp/list-live"
if ! diff -u "$tmp/list-legacy" "$tmp/list-live" >"$tmp/list.diff"; then
    fail "the rewritten split produced a different tree:$(printf '\n')$(head -40 "$tmp/list.diff")"
fi

# And byte-identical content for everything the split produced or moved.
hashes() {
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 md5sum | sort)
}
hashes "$tmp/run-legacy" >"$tmp/hash-legacy"
hashes "$tmp/run-live" >"$tmp/hash-live"
if ! diff -u "$tmp/hash-legacy" "$tmp/hash-live" >"$tmp/hash.diff"; then
    fail "the rewritten split produced different file content:$(printf '\n')$(head -20 "$tmp/hash.diff")"
fi

# Plus explicit anchors, so two identically wrong implementations still fail.
work="$tmp/run-live"
test -f "$work/texlive-alpha/texmf-dist/tex/alpha/one.sty" || fail "alphaone's library file was not split out"
test -f "$work/texlive-alpha/texmf-dist/tex/alpha/sub/two.tex" || fail "alphatwo's file was not split out"
test -f "$work/texmf-dist/doc/alpha/one.pdf" || fail "a runfiles doc entry must stay in texmf-dist"
test ! -e "$work/texlive-alpha/texmf-dist/doc/alpha/one.pdf" || fail "docs must not be split into a collection"
test -L "$work/alpha-bin/alphaone" || fail "the linked script was not staged in alpha-bin"
[[ $(readlink "$work/alpha-bin/alphaone") == ../share/texmf-dist/scripts/alphaone/alphaone.pl ]] ||
    fail "alpha-bin/alphaone points at $(readlink "$work/alpha-bin/alphaone")"
[[ $(cat "$work/packages-alpha") == $'alphaone\nalphatwo\nalphaone.ARCH' ]] ||
    fail "packages-alpha is: $(cat "$work/packages-alpha" | tr '\n' ' ')"
[[ $(cat "$work/depends-alpha") == "texlive-beta" ]] ||
    fail "depends-alpha is: $(cat "$work/depends-alpha")"
[[ $(cat "$work/pkgdesc-alpha") == "Alpha collection" ]] ||
    fail "pkgdesc-alpha is: $(cat "$work/pkgdesc-alpha")"
grep -q '^alphafmt pdftex' "$work/alpha.fmts" || fail "the AddFormat entry was not matched in fmtutil.cnf"
grep -q '^Map alpha.map' "$work/alpha.maps" || fail "the addMap entry was not matched in updmap.cfg"
grep -q 'beta.mixed.map' "$work/beta.maps" || fail "the addMixedMap entry was not matched in updmap.cfg"
grep -q 'alpha hyph-alpha.tex' "$work/alpha.dat" || fail "the hyphen rule was not copied from language.dat"
grep -q 'hyph-alpha.tex' "$work/alpha.dat.lua" || fail "the hyphen rule was not copied from language.dat.lua"
grep -q 'addlanguage{alpha}' "$work/alpha.def" || fail "the hyphen rule was not copied from language.def"
test -f "$work/texlive-beta/texmf-dist/tex/beta/one.sty" || fail "betaone's file was not split out"

# ─── Far fewer process spawns ──────────────────────────────────────────────
legacy_spawns=$(grep -c . "$tmp/spawns-legacy" || true)
live_spawns=$(grep -c . "$tmp/spawns-live" || true)
legacy_mv=$(grep -c '^mv$' "$tmp/spawns-legacy" || true)
live_mv=$(grep -c '^mv$' "$tmp/spawns-live" || true)
gamma_files=$(find "$work/texlive-gamma" -type f | wc -l)

# Sanity: the shim really intercepted a per-file implementation, and gamma's 600
# files were moved (not silently skipped).
(( gamma_files == 600 )) || fail "gamma moved $gamma_files files, expected 600"
(( legacy_mv >= 600 )) || fail "the legacy implementation issued only $legacy_mv mv calls for 600 files — shim not measuring"
(( live_spawns * 5 <= legacy_spawns )) ||
    fail "the rewrite spawns $live_spawns processes vs $legacy_spawns before — expected at least 5x fewer"
(( live_mv * 20 <= legacy_mv )) ||
    fail "the rewrite issued $live_mv mv calls vs $legacy_mv before — renames are not batched"

# ─── A split tree is refused instead of silently packaged ──────────────────
# Removing one runfiles entry simulates a tree that an interrupted run already
# split. The legacy implementation ignored this and produced a package with
# files missing; the live one must stop and say why.
depleted="$tmp/run-depleted"
cp -a "$base" "$depleted"
rm -f "$depleted/texmf-dist/tex/alpha/one.sty"
write_wrapper "$tmp/wrapped-depleted.sh" "$live_section"
(
    cd "$depleted"
    GSA_FAKE_SPAWN_LOG="$tmp/spawns-depleted" \
        bash "$tmp/wrapped-depleted.sh" >"$tmp/out-depleted" 2>"$tmp/err-depleted"
    echo $? >"$tmp/rc-depleted"
) || true
depleted_rc=$(cat "$tmp/rc-depleted")
(( depleted_rc != 0 )) || fail "a depleted tree was split without complaint (rc=0)"
grep -q 'runfiles are missing from texmf-dist' "$tmp/err-depleted" ||
    fail "the depletion error did not explain itself: $(cat "$tmp/err-depleted")"
grep -q "$depleted/texmf-dist/tex/alpha/one.sty\|texmf-dist/tex/alpha/one.sty" "$tmp/err-depleted" ||
    fail "the depletion error did not name a missing file"

printf 'texlive split fixture: PASS (%s spawns vs %s before — %sx fewer; mv calls %s vs %s)\n' \
    "$live_spawns" "$legacy_spawns" "$((legacy_spawns / (live_spawns > 0 ? live_spawns : 1)))" \
    "$live_mv" "$legacy_mv"
