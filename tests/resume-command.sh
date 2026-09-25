#!/usr/bin/env bash
set -euo pipefail

# The failure summary prints a copy-pasteable resume command. It used to carry
# only --lanes/--jobs/--intensity, so a resume of a run made with -i rebuilt the
# remaining packages WITHOUT installing them — while the tip printed directly
# below it said "add -s so already-built pkgs are skipped", and the code's own
# comment says to resume with "-s -i". Later packages then compile against the
# old installed ABIs, which is the rule-11 hazard -i exists to prevent.
#
# This fixture fails a middle package so a remainder exists, and requires the
# resume command to preserve the flags that change what the resume means.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-resume-cmd.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

make_workspace() { # $1 = sandbox dir
    local dir=$1
    mkdir -p "$dir/config/groups" "$dir/bin"
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
    for group in git stable core misc third-party app; do
        : >"$dir/config/groups/$group.list"
    done
    : >"$dir/config/packages.map"
    # Three independent packages: p2 fails, so p3 is never dispatched and the
    # summary has something to resume.
    for id in p1 p2 p3; do
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
[[ "${GSA_FAIL_PACKAGE:-}" == "$id" ]] && exit 1
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
args=()
for a in "$@"; do
    case $a in
    -n | -v | --) ;;
    *) args+=("$a") ;;
    esac
done
((${#args[@]})) || exit 0
exec "${args[@]}"
EOF
    chmod +x "$dir/bin/sudo"

    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FIXTURE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$dir/bin/pacman"
}

# run_expecting_failure <dir> <label> [builder flags...] -> RESUME_OUTPUT
run_expecting_failure() {
    local dir=$1 label=$2
    shift 2
    set +e
    RESUME_OUTPUT=$(
        PATH="$dir/bin:$PATH" \
            GSA_STATE_DIR="$dir/state" \
            GSA_FIXTURE_PACMAN_LOG="$dir/pacman.log" \
            GSA_FAIL_PACKAGE=p2 \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir/build-all.fish" "$@" p1 p2 p3 2>&1
    )
    local rc=$?
    set -e
    if ((rc == 0)); then
        printf '%s: the failing run unexpectedly succeeded:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if ! grep -q '^  build-all.fish ' <<<"$RESUME_OUTPUT"; then
        printf '%s: no resume command in the failure summary:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_CMD=$(grep '^  build-all.fish ' <<<"$RESUME_OUTPUT" | head -1)
}

# ─── A -i run must resume with --install, or it silently stops installing ────
dir="$fixture/with-install"
make_workspace "$dir"
run_expecting_failure "$dir" 'with -i' --install --no-deps --allow-broken-rustc --no-sync
for flag in --install --no-deps --allow-broken-rustc --no-sync; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -i: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -i: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A -fi run must resume with --forceinstall, keeping the force semantics ──
# -fi implies -i, so the resume must carry --forceinstall INSTEAD of --install
# (one flag preserving both halves) plus every other semantics-changing flag.
dir="$fixture/with-forceinstall"
make_workspace "$dir"
run_expecting_failure "$dir" 'with -fi' --forceinstall --no-deps --allow-broken-rustc --no-sync
for flag in --forceinstall --no-deps --allow-broken-rustc --no-sync; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -fi: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" == *"--install"* ]]; then
    printf 'with -fi: resume carries both --install and --forceinstall:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -fi: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A run without -i must NOT acquire --install on resume ──────────────────
dir="$fixture/without-install"
make_workspace "$dir"
run_expecting_failure "$dir" 'without -i' --no-deps --allow-broken-rustc
if [[ "$RESUME_CMD" == *"--install"* ]]; then
    printf 'without -i: resume command invented --install:\n  %s\n' "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'without -i: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

printf 'resume command fixture: PASS\n'
