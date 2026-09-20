#!/usr/bin/env bash
set -euo pipefail

# A stable recipe tracks the Arch repository version: sync_stable_version
# rewrites pkgver/pkgrel in place from `pacman -Si`, and the committed sums are
# deliberately left describing the previous version.
#
# Two tempting ways out of the resulting staleness are both wrong. Re-hashing the
# fetch (updpkgsums on its own) records whatever arrived, verifying nothing.
# Passing --skipchecksums — which the builder used to do, silently, because
# build_package is only ever called quiet and every lane logs its own stream —
# builds and (with -i) installs sources nobody verified.
#
# The builder re-anchors the sums to the value *Arch* published for that version,
# from the .SRCINFO of the official packaging repo, and verifies the fetched
# sources against it. What makes that necessary is not the version bump itself
# but the *source* moving: 26 of the 28 stable recipes pin a literal version
# inside their source=() URLs, so a sync leaves their sums valid, and refusing
# those builds would be a false alarm.
#
#   1. the sync really happens (pkgver rewritten) — otherwise the rest is
#      vacuous, which is the trap this fixture exists to avoid;
#   2. --skipchecksums is never passed to makepkg;
#   3. the recipe's checksums really are re-anchored, and verification runs;
#   4. a source that DISAGREES with Arch's published checksum refuses the build,
#      restores the recipe, and never runs makepkg — the case that plain
#      auto-updpkgsums would have accepted, which is what makes this a test;
#   5. no official checksum at our version (404, or a repo carrying another
#      version): refuse, leaving the recipe untouched;
#   6. an entry Arch does not publish: refuse, naming the entry;
#   7. a version bump that does not move source=(): nothing is re-anchored and
#      the build runs against the sums already committed;
#   8. an official file publishing two algorithms for the same sources: still
#      anchored (the lists only line up within one algorithm);
#   9. a "name::url" override: the fetched file carries the override name, not
#      the URL basename, so it is found and verified;
#  10. the packaging repo has moved past our version: the version's own tag is
#      fetched instead of anchoring to a version that is not ours;
#  11. a VCS source: anchored, and verified the way makepkg verifies it
#      (`git archive --format tar <tag>` hashed, not a directory);
#  12. --no-sync disables the whole path.
#
# All four collaborators (pacman, curl, updpkgsums, makepkg) are stubs on PATH,
# so this runs with no network and never builds anything.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-stable-sync.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

command -v vercmp >/dev/null || {
    printf 'vercmp is required (it ships with pacman)\n' >&2
    exit 1
}
command -v sha256sum >/dev/null || {
    printf 'sha256sum is required\n' >&2
    exit 1
}
command -v git >/dev/null || {
    printf 'git is required (the VCS case recomputes git archive)\n' >&2
    exit 1
}

staged_version=1.0.0         # what the recipe pins
repo_version=2.0.0           # what the stub repo advertises
staged_sum=0000000000000000000000000000000000000000000000000000000000000000
staged_b2=11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111

# The bytes Arch published a checksum for, and different bytes the "fetch" will
# sometimes deliver instead.
published_payload="$fixture/published.tar.gz"
tampered_payload="$fixture/tampered.tar.gz"
printf 'the source Arch published a checksum for\n' >"$published_payload"
printf 'a different source entirely, same filename\n' >"$tampered_payload"
published_sha=$(sha256sum "$published_payload" | awk '{print $1}')
published_b2=$(b2sum "$published_payload" | awk '{print $1}')
tampered_sha=$(sha256sum "$tampered_payload" | awk '{print $1}')

fail() {
    printf '\nFAIL: %s\n' "$*" >&2
    exit 1
}

# ─── The sandbox ────────────────────────────────────────────────────────────
# $1 = dir · $2 = the version the stub repo advertises · $3 = source entry
# (default: one whose URL spells $pkgver out) · $4 = the staged sum arrays
make_workspace() {
    local dir=$1 repo_full=$2
    local source_entry=${3:-'https://example.invalid/s1-$pkgver.tar.gz'}
    local sum_lines=${4:-"sha256sums=('$staged_sum')"}
    mkdir -p "$dir/config/groups" "$dir/packages/stable/s1" "$dir/bin" "$dir/fake"
    cp "$root/build-all.fish" "$dir/build-all.fish"

    cat >"$dir/config/build-defaults.conf" <<'EOF'
lanes=1
jobs=2
intensity=low
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
    : >"$dir/config/dependencies.conf"
    for group in git stable core misc third-party; do
        : >"$dir/config/groups/$group.list"
    done
    printf 's1\n' >>"$dir/config/groups/stable.list"
    printf 's1|packages/stable/s1\n' >"$dir/config/packages.map"

    # $pkgver must stay literal here: the builder expands the array by sourcing
    # the recipe, so the value has to come from the recipe's own pkgver=. printf
    # writes the entry verbatim — a heredoc would either expand it now or need
    # escaping that survives into the file.
    {
        printf 'pkgname=s1\n'
        printf 'pkgver=%s\n' "$staged_version"
        printf 'pkgrel=1\n'
        printf 'arch=(any)\n'
        printf 'source=("%s")\n' "$source_entry"
        printf '%s\n' "$sum_lines"
    } >"$dir/packages/stable/s1/PKGBUILD"

    printf '%s\n' "$repo_full" >"$dir/fake/repo_version"

    # The stub repository: sync_stable_version runs `pacman -Si <name>`.
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : s1\nVersion         : %s\n' \
        "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
    chmod +x "$dir/bin/pacman"

    # Stands in for the fetch of gitlab.archlinux.org/.../.SRCINFO. An empty
    # fake/srcinfo is the 404 case: a recipe Arch does not carry. fake/srcinfo is
    # also the answer for the `main` ref; a tag ref is answered by
    # fake/srcinfo_tag, which is absent (404) unless a case sets it.
    cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while (($#)); do
    case $1 in
        -o) out=$2; shift 2 ;;
        --max-time|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >>"$GSA_FAKE_DIR/curl_calls"
if [[ $url == */raw/main/* ]]; then
    answer=$GSA_FAKE_DIR/srcinfo
else
    answer=$GSA_FAKE_DIR/srcinfo_tag
fi
[[ -s $answer ]] || exit 22
cp -- "$answer" "$out"
EOF
    chmod +x "$dir/bin/curl"

    # Stands in for makepkg's updater. It reproduces the three things the builder
    # depends on: the sources are fetched, a VCS source becomes a checkout at its
    # tag, and the sums are written in the recipe's own algorithms — from
    # whatever was fetched.
    cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
dir=$(pwd)
set -e
printf '%s\n' "$dir" >>"$GSA_FAKE_DIR/updpkgsums_calls"
[[ -s $GSA_FAKE_DIR/deliver ]] || exit 1          # nothing to fetch

mapfile -t sources < <(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${source[@]}"' _ "$dir/PKGBUILD")
mapfile -t algos < <(bash -c 'source "$1" >/dev/null 2>&1; for a in sha256 sha512 b2; do declare -p "${a}sums" >/dev/null 2>&1 && printf "%s\n" "$a"; done' _ "$dir/PKGBUILD")

file_of() {   # the name makepkg gives one source entry
    local e=$1 u
    if [[ $e == *::* ]]; then printf '%s' "${e%%::*}"; return; fi
    u=${e%%\?*}; u=${u%%#*}
    printf '%s' "${u##*/}"
}

for alg in "${algos[@]}"; do
    line=""
    for e in "${sources[@]}"; do
        f=$(file_of "$e")
        if [[ $e == *git+* ]]; then
            tag=${e##*#}; tag=${tag##*=}
            if [[ ! -d $dir/$f ]]; then
                mkdir -p "$dir/$f"
                git -C "$dir/$f" init -q .
                printf 'checkout of %s\n' "$tag" >"$dir/$f/f.txt"
                git -C "$dir/$f" add -A
                git -C "$dir/$f" -c user.email=t@t -c user.name=t commit -qm "$tag"
                git -C "$dir/$f" -c user.email=t@t -c user.name=t tag "$tag"
            fi
            sum=$(git -c core.abbrev=no -C "$dir/$f" archive --format tar "$tag" | "${alg}sum" | awk '{print $1}')
        else
            cp -- "$GSA_FAKE_DIR/deliver" "$dir/$f"
            sum=$("${alg}sum" "$dir/$f" | awk '{print $1}')
        fi
        line+="'$sum' "
    done
    sed -i "s|^${alg}sums=.*|${alg}sums=(${line% })|" "$dir/PKGBUILD"
done
EOF
    chmod +x "$dir/bin/updpkgsums"

    # Records the argv it was invoked with; on every refusal path it must never
    # be created at all.
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/makepkg_argv"
printf 'fake makepkg: %s\n' "$*"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
}

# The official .SRCINFO the "network" serves.
# $1 = dir · $2 = official pkgver · $3.. = body lines after pkgbase/pkgver/pkgrel
set_official_srcinfo() {
    local dir=$1 ver=$2
    shift 2
    {
        printf 'pkgbase = s1\n'
        printf '\tpkgver = %s\n' "$ver"
        printf '\tpkgrel = 1\n'
        printf '\tarch = any\n'
        printf '%s\n' "$@"
    } >"$dir/fake/srcinfo"
}

# $1 = dir · $2 = the file "updpkgsums" will fetch, or 'none'
set_delivery() {
    local dir=$1 payload=$2
    if [[ $payload == none ]]; then
        : >"$dir/fake/deliver"
    else
        cp -- "$payload" "$dir/fake/deliver"
    fi
}

# $1 = dir · $2 = label · $3 = expected rc (0 or 'fail') · extra args...
run_build() {
    local dir=$1 label=$2 expect=$3
    shift 3
    set +e
    output=$(
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_DIR="$dir/fake" \
        GSA_CPU_THREADS=4 \
        GSA_MEMORY_GIB=8 \
        fish "$dir/build-all.fish" --allow-broken-rustc --no-deps \
            --intensity low s1 "$@" 2>&1
    )
    rc=$?
    set -e
    printf '%s' "$output" >"$dir/out.txt"
    if [[ $expect == fail ]]; then
        ((rc != 0)) || fail "$label: the builder reported success; it was supposed to refuse"
    else
        ((rc == 0)) || fail "$label: the builder exited $rc"$'\n'"$output"
    fi
}

pkgfile() { printf '%s/packages/stable/s1/PKGBUILD' "$1"; }
recipe_log() { printf '%s/state/logs/s1.log' "$1"; }

# ─── Case 1: anchored and verified — the happy path ─────────────────────────
dir="$fixture/anchor"
make_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'anchor' 0

# Preconditions: the sync happened, and so did the anchoring — otherwise every
# assertion below could pass for the wrong reason.
grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail "the recipe was not version-synced, so this run cannot exercise the checksum path"
[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched, so nothing was anchored to'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'the sums were never rewritten'
[[ -s $dir/fake/makepkg_argv ]] || fail 'makepkg never ran on the success path'

# The weakening is gone: the build is checksum-verified, not skipped.
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'a synced build still passed --skipchecksums to makepkg'
fi

# The recipe now carries the hash of a file that matched Arch's published value,
# which is the whole point: not a hash of whatever arrived.
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'the recipe does not carry the checksum of the verified source'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'the log does not record that the checksums were re-anchored'

# ─── Case 2: a source that disagrees with Arch refuses the build ────────────
# This is the case that separates anchoring from rubber-stamping: hashing what
# arrived (updpkgsums alone) accepts this build.
dir="$fixture/tampered"
make_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$tampered_payload"
run_build "$dir" 'tampered' fail

[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched: this case is vacuous'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'the sums were never rewritten: this case is vacuous'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran for a source that disagrees with the checksum Arch published'
fi
grep -q 'does not match the official Arch checksum' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say that the source disagrees with Arch'
grep -q "$tampered_sha" "$(recipe_log "$dir")" \
    || fail 'the refusal does not name the hash the fetched source actually had'
grep -q "$published_sha" "$(recipe_log "$dir")" \
    || fail 'the refusal does not name the hash Arch published'
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was left carrying a hash of the tampered source'

# ─── Case 3: no official .SRCINFO at all (a recipe Arch does not carry) ─────
dir="$fixture/no-official"
make_workspace "$dir" "$repo_version-1"
: >"$dir/fake/srcinfo"                       # the fetch 404s
: >"$dir/fake/srcinfo_tag"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'no-official' fail

grep -q 'carries no revision of' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say that no official revision carries our version'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran without any anchor for the sums'
fi
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'updpkgsums rewrote the sums without an anchor — that is the rubber stamp'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although nothing could be anchored'

# ─── Case 4: the official repo carries a different version ──────────────────
# Anchoring to another version's checksums would be worse than not anchoring.
dir="$fixture/other-version"
make_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" '1.5.0' \
    '	source = https://example.invalid/s1-1.5.0.tar.gz' \
    "	sha256sums = $published_sha"
: >"$dir/fake/srcinfo_tag"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'other-version' fail

grep -q 'the official packaging repo carries 1.5.0' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say which version the official repo carries'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran against another version of the sums'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although the official version did not match'

# ─── Case 5: an entry the official file does not cover ──────────────────────
dir="$fixture/unanchored"
make_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.xz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'unanchored' fail

grep -q 'publishes no checksum for:' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say that an entry could not be anchored'
grep -q 's1-2.0.0.tar.gz' "$(recipe_log "$dir")" \
    || fail 'the refusal does not name the entry it could not anchor'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran although one source had no anchor at all'
fi
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'updpkgsums rewrote the sums although one source had no anchor'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although an entry could not be anchored'

# ─── Case 6: a bump that does not move source=() is not treated as stale ────
# 26 of the 28 stable recipes pin a literal version in the URL, so nothing they
# fetch changes and their committed sums still verify. Anchoring here would be a
# false alarm; re-hashing would be a gratuitous rewrite.
for variant in pkgrel-only static-pkgver; do
    dir="$fixture/$variant"
    if [[ $variant == pkgrel-only ]]; then
        make_workspace "$dir" "$staged_version-2"
    else
        make_workspace "$dir" "$repo_version-1" \
            "https://example.invalid/s1-$staged_version.tar.gz"
    fi
    set_official_srcinfo "$dir" "$repo_version" \
        "	source = https://example.invalid/s1-$repo_version.tar.gz" \
        "	sha256sums = $published_sha"
    set_delivery "$dir" "$published_payload"
    run_build "$dir" "$variant" 0

    if [[ -s $dir/fake/curl_calls ]]; then
        fail "$variant: official checksums were fetched although source=() did not move"
    fi
    if [[ -s $dir/fake/updpkgsums_calls ]]; then
        fail "$variant: the sums were rewritten although source=() did not move"
    fi
    if [[ ! -s $dir/fake/makepkg_argv ]]; then
        fail "$variant: the build was refused instead of being built"
    fi
    if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
        fail "$variant: the build disabled checksum verification"
    fi
    grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
        || fail "$variant: the committed sums were rewritten although the sources did not move"
done

# The pkgver variant must still have synced the version, or it proves nothing.
grep -q "^pkgver=$repo_version$" "$(pkgfile "$fixture/static-pkgver")" \
    || fail 'the static-source variant did not sync the version, so it tested nothing'

# ─── Case 7: an official file publishing two algorithms ─────────────────────
# The sums for one file list do not line up flat: fish has a single source with
# both a sha512 and a b2 sum, and reading them as one list refuses the build.
dir="$fixture/two-algorithms"
make_workspace "$dir" "$repo_version-1" \
    'https://example.invalid/s1-$pkgver.tar.gz' \
    "$(printf "sha256sums=('%s')\nb2sums=('%s')" "$staged_sum" "$staged_b2")"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha" \
    "	b2sums = $published_b2"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'two-algorithms' 0

[[ -s $dir/fake/updpkgsums_calls ]] || fail 'two-algorithms: the sums were never rewritten: this case is vacuous'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'two-algorithms: the sha256 sums were not anchored'
grep -q "^b2sums=('$published_b2')$" "$(pkgfile "$dir")" \
    || fail 'two-algorithms: the b2 sums were not anchored'

# ─── Case 8: a "name::url" override names the fetched file ──────────────────
# 'openshadinglanguage-….tar.gz::https://…/v1.15.3.0.tar.gz' downloads to the
# override. Looking for the URL's basename finds nothing (or, for util-linux's
# renamed LICENSE, an unrelated file that happens to share the name).
dir="$fixture/renamed"
make_workspace "$dir" "$repo_version-1" \
    's1-local.tar.gz::https://example.invalid/s1-$pkgver.tar.gz'
set_official_srcinfo "$dir" "$repo_version" \
    "	source = s1-local.tar.gz::https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'renamed' 0

[[ -s $dir/fake/updpkgsums_calls ]] || fail 'renamed: the sums were never rewritten: this case is vacuous'
[[ -f $dir/packages/stable/s1/s1-local.tar.gz ]] \
    || fail 'renamed: the stub did not fetch under the override name, so this case is vacuous'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'renamed: the sums were not anchored, so the override name was not resolved'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'renamed: the fetch of the override name was not verified against Arch'

# ─── Case 9: the packaging repo moved on — the version's tag is the anchor ──
# bash's main branch is 5.3.20 while the repos serve 5.3.15, so anchoring to main
# would anchor to a different version's files.
dir="$fixture/version-tag"
make_workspace "$dir" "$repo_version-1"
# main carries a different version, so it is no anchor; the version's own tag
# carries ours.
set_official_srcinfo "$dir" '1.5.0' \
    '	source = https://example.invalid/s1-1.5.0.tar.gz' \
    "	sha256sums = $published_sha"
cp -- "$dir/fake/srcinfo" "$dir/fake/main_answer"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
mv -- "$dir/fake/srcinfo" "$dir/fake/srcinfo_tag"
mv -- "$dir/fake/main_answer" "$dir/fake/srcinfo"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'version-tag' 0

grep -q "/raw/$repo_version-1/" "$dir/fake/curl_calls" \
    || fail 'the version tag was never tried, so main could not be the only candidate'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'the version-tag run did not anchor the sums'

# ─── Case 10: a VCS source is anchored and verified the way makepkg does ────
# A 'git+…#tag=' source has no file to hash: makepkg hashes git archive of the
# tag. Verifying it as a download reports "not fetched", and anchoring to a
# value that was never checked is the rubber stamp again.
dir="$fixture/vcs"
make_workspace "$dir" "$repo_version-1" \
    's1git::git+https://example.invalid/s1.git#tag=$pkgver' \
    "sha512sums=('$staged_sum')"
# The checkout exists before the run (updpkgsums reuses it), so the value Arch
# "published" is the one this machine computes — which is the property that makes
# a pinned tag anchorable at all.
checkout="$dir/packages/stable/s1/s1git"
mkdir -p "$checkout"
git -C "$checkout" init -q .
printf 'checkout of %s\n' "$repo_version" >"$checkout/f.txt"
git -C "$checkout" add -A
git -C "$checkout" -c user.email=t@t -c user.name=t commit -qm "$repo_version"
git -C "$checkout" -c user.email=t@t -c user.name=t tag "$repo_version"
published_vcs=$(git -c core.abbrev=no -C "$checkout" archive --format tar "$repo_version" | sha512sum | awk '{print $1}')
set_official_srcinfo "$dir" "$repo_version" \
    "	source = s1git::git+https://example.invalid/s1.git#tag=$repo_version" \
    "	sha512sums = $published_vcs"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'vcs' 0

[[ -d $checkout ]] || fail 'vcs: the checkout was not present, so this case is vacuous'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'vcs: the sums were never rewritten: this case is vacuous'
if [[ -s $dir/fake/makepkg_argv ]] && grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'vcs: the build disabled checksum verification'
fi
grep -q "^sha512sums=('$published_vcs')$" "$(pkgfile "$dir")" \
    || fail 'vcs: the checkout was not anchored to the git-archive value'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'vcs: the log does not record that the checkout was anchored'

# ─── Case 11: --no-sync disables the whole path ─────────────────────────────
dir="$fixture/no-sync"
make_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'no-sync' 0 --no-sync

grep -q "^pkgver=$staged_version$" "$(pkgfile "$dir")" \
    || fail '--no-sync rewrote the recipe version anyway'
if [[ -e $dir/fake/curl_calls ]]; then
    fail '--no-sync still fetched official checksums'
fi
if [[ ! -s $dir/fake/makepkg_argv ]]; then
    fail '--no-sync refused to build a recipe it did not rewrite'
fi
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail '--no-sync still disabled checksum verification'
fi

printf 'stable-sync fixture: PASS\n'
