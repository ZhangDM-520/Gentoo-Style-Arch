#!/usr/bin/env fish
# build-all.fish — Workspace package builder with dependency ordering
# Builds and optionally installs Arch Linux packages from PKGBUILDs in this workspace.

set -g SCRIPT_DIR (realpath (status dirname))
set -g CONFIG_DIR "$SCRIPT_DIR/config"
set -g PACKAGE_MAP_FILE "$CONFIG_DIR/packages.map"
set -g GROUP_CONFIG_DIR "$CONFIG_DIR/groups"
set -g DEP_CONFIG_FILE "$CONFIG_DIR/dependencies.conf"
set -g DEFAULT_CONFIG_FILE "$CONFIG_DIR/build-defaults.conf"
set -g _STATE_DIR "$SCRIPT_DIR/.state"
if set -q GSA_STATE_DIR; and test -n "$GSA_STATE_DIR"
    set -g _STATE_DIR "$GSA_STATE_DIR"
end
set -g LOG_DIR "$_STATE_DIR/logs"

# ─── Identity: root supervises, the invoking user builds ─────────────────
# Root-mode (sudo fish build-all.fish ...): installs run directly as root
# (no sudo timestamp to expire on long runs); makepkg + ALL workspace
# artifacts run as the invoking user — makepkg refuses root, and --asroot
# would scatter root-owned src/pkg files into the checkout plus root caches
# (~/.ccache, ~/.cargo, ~/.cache/go-build) into /root. build_package restores
# user ownership after each package so nothing root-owned ever lands in the
# workspace. Unprivileged mode: everything as before (sudo -n installs).
set -g _BUILD_USER (id -un)
set -g _ROOT_MODE 0
if test "$_BUILD_USER" = "root"
    if test -n "$SUDO_USER"; and test "$SUDO_USER" != "root"
        set -g _BUILD_USER "$SUDO_USER"
        set -g _ROOT_MODE 1
    else
        echo "Error: run as your normal user, or via 'sudo fish build-all.fish ...'"
        echo "(bare root has no invoking user to build as — makepkg refuses root)"
        exit 1
    end
end
set -g _BUILD_HOME ""
if command -v getent >/dev/null 2>&1
    set _BUILD_HOME (getent passwd "$_BUILD_USER" | cut -d: -f6)
end
if test -z "$_BUILD_HOME"; and test -n "$HOME"
    set _BUILD_HOME "$HOME"
end
if test -z "$_BUILD_HOME"
    echo "Error: cannot resolve the home directory for $_BUILD_USER"
    exit 1
end
# 1 = background lane job — suppress human-facing echoes (the parent renderer
# owns live output). Set per-build_package call, read by install_pkgs_now.
set -g _BUILD_QUIET 0

# Output is rendered by the parent dispatcher only. Fish's set_color emits
# ANSI sequences even when stdout is a pipe, so wrap the builtin and make
# colors follow the actual output destination.
set -g _OUTPUT_INTERACTIVE 0
if test -t 1; and test -n "$TERM"; and test "$TERM" != "dumb"
    set -g _OUTPUT_INTERACTIVE 1
end
function set_color
    if test "$_OUTPUT_INTERACTIVE" = "1"
        builtin set_color $argv
    end
end

set -g _UI_ICON_OK "✓"
set -g _UI_ICON_ERROR "✗"
set -g _UI_ICON_WARN "⚠"
set -g _UI_ICON_INFO "·"
set -g _UI_ICON_ACTIVE "→"
set -g _PACMAN_MUTEX "$LOG_DIR/.pacman-install.lock"
set -g _PACMAN_MUTEX_WAIT 300

function ui_heading
    set -l prefix (set_color cyan)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "━━━ " (string join ' ' -- $argv) " ━━━")
    echo "$prefix$message$suffix"
end

function ui_success
    set -l prefix (set_color green)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "$_UI_ICON_OK " (string join ' ' -- $argv))
    echo "$prefix$message$suffix"
end

function ui_warning
    set -l prefix (set_color yellow)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "$_UI_ICON_WARN " (string join ' ' -- $argv))
    echo "$prefix$message$suffix"
end

function ui_error
    set -l prefix (set_color red)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "$_UI_ICON_ERROR " (string join ' ' -- $argv))
    echo "$prefix$message$suffix"
end

function ui_info
    echo "$_UI_ICON_INFO "(string join ' ' -- $argv)
end

set -g _ACTIVE_LANE_PIDS
set -g _DASHBOARD_ROWS 0
set -g _DASHBOARD_ACTIVE 0
set -g _DASHBOARD_LAST_EVENT ""
set -g _DASHBOARD_LANE_BUSY
set -g _DASHBOARD_LANE_PKG
set -g _DASHBOARD_LANE_START
set -g _DASHBOARD_SPINNER_FRAMES '-' "\\" '|' '/'
set -g _DASHBOARD_SPINNER_INDEX 1
set -g _RL_BLOCKED 0
set -g _INTERRUPT_HANDLED 0

# ─── Project configuration ───────────────────────────────────────────────────
set -g _PACKAGE_MAP
set -g _PACKAGE_IDS
set -g _DEPS
set -g _GROUP_git
set -g _GROUP_stable
set -g _GROUP_core
set -g _GROUP_misc
set -g _GROUP_third_party
set -g _DEFAULT_LANES auto
set -g _DEFAULT_JOBS auto
set -g _DEFAULT_INTENSITY xhigh
set -g _MEMORY_PER_JOB_GIB 3
set -g _CORE_MEMORY_PER_JOB_GIB 4
set -g _RESERVED_MEMORY_GIB 2

function package_path -a package_id
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        if test "$fields[1]" = "$package_id"
            echo "$SCRIPT_DIR/$fields[2]"
            return 0
        end
    end
    return 1
end

function package_id_for_path -a package_path_value
    set -l resolved (realpath "$package_path_value" 2>/dev/null)
    test -n "$resolved"; or return 1
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l known (realpath "$SCRIPT_DIR/$fields[2]" 2>/dev/null)
        if test "$known" = "$resolved"
            echo "$fields[1]"
            return 0
        end
    end
    return 1
end

function assign_group -a group_name
    set -l values $argv[2..-1]
    switch "$group_name"
        case git
            set -g _GROUP_git $values
        case stable
            set -g _GROUP_stable $values
        case core
            set -g _GROUP_core $values
        case misc
            set -g _GROUP_misc $values
        case third-party
            set -g _GROUP_third_party $values
    end
    return 0
end

function intensity_is_valid -a intensity_level
    switch "$intensity_level"
        case low medium high xhigh max
            return 0
        case '*'
            return 1
    end
end

function configure_intensity -a intensity_level
    if not intensity_is_valid "$intensity_level"
        ui_error "intensity must be one of low, medium, high, xhigh, or max"
        return 1
    end

    switch "$intensity_level"
        case low
            set -g _INTENSITY_LANE_CAP 1
            set -g _INTENSITY_CPU_PER_LANE 16
            set -g _INTENSITY_MEMORY_PER_LANE 16
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 2
            set -g _INTENSITY_CORE_MEMORY_FACTOR 1.5
        case medium
            set -g _INTENSITY_LANE_CAP 2
            set -g _INTENSITY_CPU_PER_LANE 8
            set -g _INTENSITY_MEMORY_PER_LANE 8
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 1
            set -g _INTENSITY_CORE_MEMORY_FACTOR 1
        case high
            set -g _INTENSITY_LANE_CAP 3
            set -g _INTENSITY_CPU_PER_LANE 6
            set -g _INTENSITY_MEMORY_PER_LANE 6
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 0.6666666667
            set -g _INTENSITY_CORE_MEMORY_FACTOR 0.75
        case xhigh
            set -g _INTENSITY_LANE_CAP 4
            set -g _INTENSITY_CPU_PER_LANE 4
            set -g _INTENSITY_MEMORY_PER_LANE 4
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 0.5
            set -g _INTENSITY_CORE_MEMORY_FACTOR 0.625
        case max
            set -g _INTENSITY_LANE_CAP 6
            set -g _INTENSITY_CPU_PER_LANE 2
            set -g _INTENSITY_MEMORY_PER_LANE 2
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 0.3333333333
            set -g _INTENSITY_CORE_MEMORY_FACTOR 0.5
    end
end

function read_config_defaults
    test -f "$DEFAULT_CONFIG_FILE"; or return 1
    for raw_line in (cat "$DEFAULT_CONFIG_FILE")
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split -m 1 '=' -- "$line")
        test (count $fields) -eq 2; or return 1
        switch "$fields[1]"
            case lanes
                set -g _DEFAULT_LANES "$fields[2]"
            case jobs
                set -g _DEFAULT_JOBS "$fields[2]"
            case intensity
                set -g _DEFAULT_INTENSITY "$fields[2]"
            case memory_per_job_gib
                set -g _MEMORY_PER_JOB_GIB "$fields[2]"
            case core_memory_per_job_gib
                set -g _CORE_MEMORY_PER_JOB_GIB "$fields[2]"
            case reserved_memory_gib
                set -g _RESERVED_MEMORY_GIB "$fields[2]"
            case state_dir
                # State location is selected before config loading so an
                # explicit GSA_STATE_DIR always wins.
                if not set -q GSA_STATE_DIR; and test "$fields[2]" != auto
                    if string match -q '/*' -- "$fields[2]"
                        set -g _STATE_DIR "$fields[2]"
                    else
                        set -g _STATE_DIR "$SCRIPT_DIR/$fields[2]"
                    end
                    set -g LOG_DIR "$_STATE_DIR/logs"
                end
            case '*'
                return 1
        end
    end
    if set -q GSA_LANES; and test -n "$GSA_LANES"
        set -g _DEFAULT_LANES "$GSA_LANES"
    end
    if set -q GSA_JOBS; and test -n "$GSA_JOBS"
        set -g _DEFAULT_JOBS "$GSA_JOBS"
    end
    if set -q GSA_INTENSITY; and test -n "$GSA_INTENSITY"
        set -g _DEFAULT_INTENSITY "$GSA_INTENSITY"
    end
end

function read_group_config -a group_name
    set -l group_file "$GROUP_CONFIG_DIR/$group_name.list"
    test -f "$group_file"; or return 1
    set -l values
    for raw_line in (cat "$group_file")
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        string match -qr '^[A-Za-z0-9._+-]+$' -- "$line"; or return 1
        contains "$line" $_PACKAGE_IDS; or return 1
        contains "$line" $values; and return 1
        set -a values "$line"
    end
    assign_group "$group_name" $values
end

function load_project_config
    test -f "$PACKAGE_MAP_FILE"; or return 1
    test -f "$DEP_CONFIG_FILE"; or return 1
    if not read_config_defaults
        ui_error "invalid build defaults: $DEFAULT_CONFIG_FILE"
        return 1
    end
    for setting in _MEMORY_PER_JOB_GIB _CORE_MEMORY_PER_JOB_GIB _RESERVED_MEMORY_GIB
        set -l value $$setting
        if not string match -qr '^[1-9][0-9]*$' -- "$value"
            ui_error "invalid numeric build default: $setting=$value"
            return 1
        end
    end
    for setting in _DEFAULT_LANES _DEFAULT_JOBS
        set -l value $$setting
        if test "$value" != auto; and not string match -qr '^[1-9][0-9]*$' -- "$value"
            ui_error "invalid parallelism default: $setting=$value"
            return 1
        end
    end
    if not intensity_is_valid "$_DEFAULT_INTENSITY"
        ui_error "invalid intensity default: $_DEFAULT_INTENSITY"
        return 1
    end

    set -g _PACKAGE_MAP
    set -g _PACKAGE_IDS
    for raw_line in (cat "$PACKAGE_MAP_FILE")
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split '|' -- "$line")
        if test (count $fields) -ne 3
            ui_error "invalid package map record: $line"
            return 1
        end
        set -l id "$fields[1]"
        set -l relative_path "$fields[2]"
        if not string match -qr '^[A-Za-z0-9._+-]+$' -- "$id"; \
            or string match -q '/*' -- "$relative_path"; \
            or string match -q '*..*' -- "$relative_path"; \
            or not test -f "$SCRIPT_DIR/$relative_path/PKGBUILD"
            ui_error "invalid package map path: $line"
            return 1
        end
        contains "$id" $_PACKAGE_IDS; and return 1
        set -a _PACKAGE_IDS "$id"
        set -a _PACKAGE_MAP "$id|$relative_path"
    end

    for group_name in git stable core misc third-party
        if not read_group_config "$group_name"
            ui_error "invalid package group: $group_name"
            return 1
        end
    end

    set -g _DEPS
    for raw_line in (cat "$DEP_CONFIG_FILE")
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split -m 1 ':' -- "$line")
        test (count $fields) -eq 2; or return 1
        set -l pkg "$fields[1]"
        contains "$pkg" $_PACKAGE_IDS; or return 1
        for dep in (string split ',' -- "$fields[2]")
            test -n "$dep"; or continue
            contains "$dep" $_PACKAGE_IDS; or return 1
        end
        set -a _DEPS "$line"
    end

    set -l listed
    for group_name in git stable core misc third-party
        switch "$group_name"
            case git
                set -a listed $_GROUP_git
            case stable
                set -a listed $_GROUP_stable
            case core
                set -a listed $_GROUP_core
            case misc
                set -a listed $_GROUP_misc
            case third-party
                set -a listed $_GROUP_third_party
        end
    end
    for package_id in $_PACKAGE_IDS
        contains "$package_id" $listed; or return 1
    end
    topo_sort (string join ' ' $_PACKAGE_IDS) >/dev/null
    if test (count $_TOPO_BLOCKED) -gt 0
        ui_error "dependency configuration did not produce a complete order"
        return 1
    end
    return 0
end

# ─── Topological sort (Kahn's algorithm) ─────────────────────────────────────
function topo_sort -a pkgs_str
    # pkgs_str is a space-separated list of package IDs.
    set -l pkgs (string split ' ' $pkgs_str)
    set -g _TOPO_BLOCKED

    # Build dependency map: $dep_of[pkg] = "dep1 dep2 ..."
    set -l dep_of_pkg
    set -l all_deps
    for entry in $_DEPS
        set -l parts (string split ':' $entry)
        set -l pkg $parts[1]
        if test (count $parts) -ge 2 -a -n "$parts[2]"
            set -a dep_of_pkg "$pkg:"(string join ' ' (string split ',' $parts[2]))
        else
            set -a dep_of_pkg "$pkg:"
        end
    end

    # Kahn's algorithm
    # in_degree[pkg] = count of unprocessed deps that are in our build list
    set -l in_degree
    set -l queue
    set -l sorted

    # Initialize in-degrees
    for pkg in $pkgs
        set -l deps ""
        for entry in $dep_of_pkg
            set -l parts (string split ':' $entry -m 2)
            if test "$parts[1]" = "$pkg" -a -n "$parts[2]"
                set deps (string split ' ' $parts[2])
                break
            end
        end

        set -l deg 0
        for dep in $deps
            # Only count deps that are in our build list
            for p in $pkgs
                if test "$p" = "$dep"
                    set deg (math $deg + 1)
                    break
                end
            end
        end
        set -a in_degree "$pkg:$deg"

        if test $deg -eq 0
            set -a queue $pkg
        end
    end

    # Process queue
    while test (count $queue) -gt 0
        set -l pkg $queue[1]
        set -e queue[1]
        set -a sorted $pkg

        # Find packages that depend on this one
        for entry in $dep_of_pkg
            set -l parts (string split ':' $entry -m 2)
            if test (count $parts) -lt 2 -o -z "$parts[2]"
                continue
            end
            set -l deps (string split ' ' $parts[2])

            # Check if this pkg is a dep of the entry
            set -l is_dep 0
            for dep in $deps
                if test "$dep" = "$pkg"
                    set is_dep 1
                    break
                end
            end

            if test $is_dep -eq 1
                # Decrease in-degree
                set -l child $parts[1]
                for j in (seq (count $in_degree))
                    set -l iparts (string split ':' $in_degree[$j] -m 2)
                    if test "$iparts[1]" = "$child"
                        set -l new_deg (math $iparts[2] - 1)
                        set in_degree[$j] "$child:$new_deg"
                        if test $new_deg -eq 0
                            set -a queue $child
                        end
                        break
                    end
                end
            end
        end
    end

    # Append any remaining (cycles or missing deps) at the end
    for pkg in $pkgs
        set -l found 0
        for s in $sorted
            if test "$s" = "$pkg"
                set found 1
                break
            end
        end
        if test $found -eq 0
            set -a _TOPO_BLOCKED $pkg
            set -a sorted $pkg
        end
    end

    printf '%s\n' $sorted
    test (count $_TOPO_BLOCKED) -eq 0
end

# ─── Expand dependencies ─────────────────────────────────────────────────────
function expand_deps
    # Expand a package list to include all transitive dependencies from _DEPS
    set -l result
    set -l queue $argv

    while test (count $queue) -gt 0
        set -l pkg $queue[1]
        set -e queue[1]

        # Skip if already in result
        set -l already_seen 0
        for r in $result
            if test "$r" = "$pkg"
                set already_seen 1
                break
            end
        end
        if test $already_seen -eq 1
            continue
        end

        set -a result $pkg

        # Find deps of this pkg from _DEPS
        for entry in $_DEPS
            set -l parts (string split ':' $entry -m 2)
            if test "$parts[1]" = "$pkg" -a -n "$parts[2]"
                for dep in (string split ',' $parts[2])
                    if package_path "$dep" >/dev/null
                        set -a queue $dep
                    else
                        ui_error "missing local dependency: $pkg -> $dep" >&2
                        return 1
                    end
                end
                break
            end
        end
    end

    printf '%s\n' $result
end

# ─── Sync stable package version with Arch repos ─────────────────────────────
function sync_stable_version -a pkg_path
    # Only applies to recipes physically staged under packages/stable.
    string match -q "$SCRIPT_DIR/packages/stable/*" "$pkg_path"; or return 0

    # pkgver()-driven PKGBUILDs (Qt dev-branch builds) have NO stable pkgver=
    # line — inserting one would OVERRIDE pkgver() and pin the version to the
    # repo release, defeating dev tracking. Skip them; their describe-based
    # version is always ahead of the repo anyway (never-downgrade guard).
    if not grep -q '^pkgver=' "$pkg_path/PKGBUILD"
        return 0
    end

    set -l pkgbase (grep -m1 '^pkgbase=' "$pkg_path/PKGBUILD" | cut -d= -f2 | string trim -c "'" | string trim)
    if test -z "$pkgbase"
        set pkgbase (basename "$pkg_path")
    end

    # Candidate names to query: pkgbase first, then every split package name
    # (resolved in bash so comments/variables in pkgname=() don't break it).
    # E.g. hip-runtime's PKGBUILD builds pkgname=(hip-runtime-amd) — the repo
    # only knows the latter, so a pkgbase-only query would silently NEVER sync
    # and -Syu would replace the custom build with the newer stock one.
    set -l candidates "$pkgbase"
    for n in (bash -c "source '$pkg_path/PKGBUILD' 2>/dev/null && printf '%s\n' \"\${pkgname[@]}\"" 2>/dev/null)
        set -a candidates "$n"
    end

    # Query latest version from Arch repos
    set -l repo_info ""
    for c in $candidates
        set repo_info (pacman -Si "$c" 2>/dev/null)
        if test -n "$repo_info"
            break
        end
    end
    if test -z "$repo_info"
        return 0
    end

    set -l repo_ver_full (printf '%s\n' $repo_info | grep -m1 '^Version' | awk '{print $NF}')
    if test -z "$repo_ver_full"
        return 0
    end

    # Split "2.42.2-1", "7.2.4-1.1", or "1:7.1-1" (epoch) into epoch/version/release
    set -l repo_epoch 0
    set -l repo_v $repo_ver_full
    if string match -qr '^[0-9]+:' "$repo_v"
        set repo_epoch (string replace -r -- ':.*$' '' "$repo_v")
        set repo_v (string replace -r -- '^[0-9]+:' '' "$repo_v")
    end
    set -l repo_pkgver (string replace -r -- '-[0-9].*$' '' "$repo_v")
    set -l repo_pkgrel (string match -r -- '-([0-9].*)$' "$repo_v")[2]
    if test -z "$repo_pkgrel"
        set repo_pkgrel 1
    end

    # Read current version
    set -l cur_pkgver (grep -m1 '^pkgver=' "$pkg_path/PKGBUILD" | cut -d= -f2 | string trim -c "'")
    set -l cur_pkgrel (grep -m1 '^pkgrel=' "$pkg_path/PKGBUILD" | cut -d= -f2 | string trim -c "'")

    # Never downgrade the content version — repos can game vercmp with an epoch
    # (e.g. repo "1:7.1-1" vs local "7.2-1": 7.2 content is newer, keep it)
    set -l vercmp_res -1
    if type -q vercmp
        set vercmp_res (vercmp "$cur_pkgver" "$repo_pkgver")
    else if test "$cur_pkgver" = "$repo_pkgver"
        set vercmp_res 0
    end
    if test "$vercmp_res" -gt 0
        return 0
    end
    if test "$vercmp_res" -eq 0 -a "$cur_pkgrel" = "$repo_pkgrel"
        return 0
    end

    if test "$_BUILD_QUIET" != "1"
        ui_info "$pkgbase: $cur_pkgver-$cur_pkgrel → $repo_pkgver-$repo_pkgrel (synced with repo)"
    end

    # Update pkgver/pkgrel (+ epoch when the repo carries one — never inside pkgver,
    # makepkg rejects colons there)
    if not sed -i "s/^pkgver=.*/pkgver=$repo_pkgver/" "$pkg_path/PKGBUILD"
        return 2
    end
    if not sed -i "s/^pkgrel=.*/pkgrel=$repo_pkgrel/" "$pkg_path/PKGBUILD"
        return 2
    end
    if grep -q '^epoch=' "$pkg_path/PKGBUILD"
        if not sed -i "s/^epoch=.*/epoch=$repo_epoch/" "$pkg_path/PKGBUILD"
            return 2
        end
    else if test "$repo_epoch" -ne 0
        if not sed -i "/^pkgrel=.*/a epoch=$repo_epoch" "$pkg_path/PKGBUILD"
            return 2
        end
    end

    # Clean stale source/build artifacts
    if not rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
        return 2
    end

    return 1
end

# ─── List built package files for a PKGBUILD (all splits, current version) ───
# Multi-split packages (e.g. linux-firmware) produce several *.pkg.tar.zst —
# "ls -t | head -1" would install only one split. Filter by current
# pkgver-pkgrel so stale packages from previous builds are never installed.
function list_split_pkgs -a pkg_path
    set -l pv (grep -m1 '^pkgver=' "$pkg_path/PKGBUILD" | cut -d= -f2 | string trim -c "'")
    set -l pr (grep -m1 '^pkgrel=' "$pkg_path/PKGBUILD" | cut -d= -f2 | string trim -c "'")
    # find (not fish globs): an unmatched glob is a FATAL error in fish, and
    # 2>/dev/null does not suppress it. find -name returns 0 with no matches.
    if test -n "$pv" -a -n "$pr"
        find "$pkg_path" -maxdepth 1 -name "*$pv-$pr-*.pkg.tar.zst" 2>/dev/null | sort
        return
    end
    find "$pkg_path" -maxdepth 1 -name '*.pkg.tar.zst' 2>/dev/null | sort
end

# ─── Workspace-wide built-package helpers ────────────────────────────────────
function find_pkg_dirs
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        echo "$SCRIPT_DIR/$fields[2]"
    end
end

function find_audit_pkg_dirs
    find_pkg_dirs
end

# All current-version *.pkg.tar.zst across the workspace. Stale archives from
# previous pkgver/pkgrel builds are excluded (install-only; cleanup gets all).
function find_built_pkgs
    for d in (find_pkg_dirs)
        list_split_pkgs "$d"
    end
end

# -ia / --installall: install everything already built in ONE pacman
# transaction (inter-package deps resolve within the transaction).
# Extra args are forwarded to pacman, e.g.: build-all.fish -ia --overwrite '*'
function install_all
    if not require_command flock; or not require_command pacman
        return 1
    end
    if test "$_ROOT_MODE" != "1"; and not require_command sudo
        return 1
    end
    set -l pkgs (find_built_pkgs)
    if test (count $pkgs) -eq 0
        ui_warning "No built packages found."
        return 0
    end
    ui_heading "Installing "(count $pkgs)" packages"
    for p in $pkgs
        echo "  $p"
    end
    # $pkgs are absolute (find_pkg_dirs → $SCRIPT_DIR) — safe under any cwd.
    # Explicit if/else: fish rejects an all-variable command with empty $pre.
    if not mkdir -p "$LOG_DIR"
        ui_error "cannot create log directory: $LOG_DIR"
        return 1
    end
    set -l install_log "$LOG_DIR/install-all.log"
    if test "$_ROOT_MODE" = "1"
        run_pacman_locked "$install_log" pacman -U --noconfirm --ask 4 $argv $pkgs
    else
        run_pacman_locked "$install_log" sudo pacman -U --noconfirm --ask 4 $argv $pkgs
    end
    set -l irc $status
    if test $irc -ne 0
        ui_error "Install failed (rc=$irc)"
        return 1
    end
end

function run_pacman_locked -a log_file
    set -l command_name $argv[2]
    set -l command_args $argv[3..-1]
    if test -z "$command_name"
        ui_error "internal error: pacman command is empty" >&2
        return 2
    end
    printf '%s\n' "$_UI_ICON_INFO waiting for builder pacman mutex: $_PACMAN_MUTEX" >&2
    flock -x -w "$_PACMAN_MUTEX_WAIT" "$_PACMAN_MUTEX" \
        "$command_name" $command_args
    set -l rc $status
    if test "$rc" -eq 75
        printf '%s\n' "$_UI_ICON_ERROR builder pacman mutex timed out after $_PACMAN_MUTEX_WAIT seconds" >&2
    end
    return $rc
end

# -cc / --cleanup: delete every built package archive (including stale
# old-version files that list_split_pkgs would skip).
function cleanup_pkgs
    set -l pkgs (find "$SCRIPT_DIR/packages" -type f -name '*.pkg.tar.zst' \
        -not -path '*/src/*' -not -path '*/pkg/*' 2>/dev/null | sort)
    if test (count $pkgs) -eq 0
        echo "No built packages to remove."
        return 0
    end
    set -l size (du -ch $pkgs | tail -1 | cut -f1)
    echo "Removing "(count $pkgs)" package archives ("$size")"
    if not rm -v -- $pkgs
        ui_error "failed to remove one or more package archives"
        return 1
    end
end

# ─── Nuclear cleanup (-ccc / --nuclear) ──────────────────────────────────────
# Wipes everything makepkg pulled/built EXCEPT the built package archives
# (those are -cc's job). Per package dir this removes:
#   - src/, pkg/, build/ and _build/ staging dirs
#   - the source VCS checkouts makepkg created next to the PKGBUILD
#     (SRCDEST defaults to $startdir: cairo-git/cairo, packages/core/llvm-git/llvm-project,
#     texlive-texmf/texmf-dist, ...)
#   - downloaded source files (*.tar.* and *.whl, incl. .sig/.asc companions
#     and .part)
# Source names come from each PKGBUILD's source=() array, resolved in bash so
# entries like git+${url}.git, svn://…#revision=N or name::URL match exactly
# what makepkg fetches.
# Local support files (patches, hooks, keys/, .nvchecker.toml) are never touched.
# Symlinks are NEVER deleted nor followed: deliberately shared sources — e.g.
# llvm-project symlinked into spirv-llvm-translator-git to save storage — are
# listed as preserved and left intact.
function nuclear_cleanup
    if test "$_ROOT_MODE" != "1"; and not require_command sudo
        return 1
    end
    set -l all_targets
    set -l all_skipped

    for d in (find_pkg_dirs)
        set -l pkg_targets
        set -l pkg_skipped

        # Staging / build dirs (skip symlinks — may be deliberate links to
        # shared storage)
        for sub in src pkg build _build
            if test -L "$d/$sub"
                set -a pkg_skipped "$d/$sub"
            else if test -d "$d/$sub"
                set -a pkg_targets "$d/$sub"
            end
        end

        # Sources as makepkg sees them
        set -l sources (bash -c "source '$d/PKGBUILD' 2>/dev/null && printf '%s\n' \"\${source[@]}\"" 2>/dev/null)
        for s in $sources
            set -l name ""
            set -l url "$s"
            if string match -q '*::*' -- "$s"
                set -l parts (string split -m 1 '::' -- "$s")
                set name $parts[1]
                set url $parts[2]
            end

            if string match -q 'git+*' -- "$url"
                # VCS source → makepkg clones it as $SRCDEST/<name> (next to the PKGBUILD)
                if test -z "$name"
                    set name (string replace -r '^git\+' '' -- "$url" \
                        | string replace -r '[?#].*$' '' \
                        | string replace -r '/$' '' \
                        | string replace -r '\.git$' '')
                    set name (basename "$name")
                end
                if test -n "$name" -a "$name" != . -a "$name" != .. -a -d "$d/$name"
                    if test -L "$d/$name"
                        # Deliberate source sharing (e.g. llvm-project) — keep it
                        set -a pkg_skipped "$d/$name"
                    else
                        set -a pkg_targets "$d/$name"
                    end
                end
            else if string match -qr '^svn\+|^svn://' -- "$url"
                # SVN source → makepkg checks it out as $SRCDEST/<basename>
                # (get_filename: basename with the fragment removed), keeping
                # it in sync with `svn update -r` on rebuild. svn:// is used
                # without a svn+ prefix by some recipes, hence both matches.
                if test -z "$name"
                    set name (basename (string replace -r '/$' '' -- (string replace -r '[?#].*$' '' -- (string replace -r '^svn\+' '' -- "$url"))))
                end
                if test -n "$name" -a "$name" != . -a "$name" != .. -a -d "$d/$name"
                    if test -L "$d/$name"
                        set -a pkg_skipped "$d/$name"
                    else
                        set -a pkg_targets "$d/$name"
                    end
                end
            else if string match -qr '^(https?|ftp)://' -- "$url"
                # Remote file source → only downloaded archives; plain local
                # entries (patches, hooks, keyrings) never match a URL here
                set -l fname "$name"
                if test -z "$fname"
                    set fname (basename (string replace -r '[?#].*$' '' -- "$url"))
                end
                if string match -q '*.tar.*' -- "$fname"; or string match -q '*.whl' -- "$fname"
                    if test -f "$d/$fname"; and not test -L "$d/$fname"
                        set -a pkg_targets "$d/$fname"
                    end
                end
                for ext in sig asc sign
                    if test -f "$d/$fname.$ext"; and not test -L "$d/$fname.$ext"
                        set -a pkg_targets "$d/$fname.$ext"
                    end
                end
                if test -f "$d/$fname.part"; and not test -L "$d/$fname.part"
                    set -a pkg_targets "$d/$fname.part"
                end
            end
        end

        if test (count $pkg_skipped) -gt 0
            echo (set_color yellow)"$d — symlinks preserved"(set_color normal)
            for t in $pkg_skipped
                echo "  ↷ kept: $t"
            end
            set -a all_skipped $pkg_skipped
        end

        if test (count $pkg_targets) -gt 0
            # Dedupe (a sig file can be both a source entry and a companion)
            set pkg_targets (printf '%s\n' $pkg_targets | awk '!seen[$0]++')

            echo (set_color cyan)"$d"(set_color normal)
            for t in $pkg_targets
                set -l sz (du -sh "$t" 2>/dev/null | cut -f1)
                printf '  %-8s %s\n' "$sz" "$t"
                set -a all_targets "$t"
            end
        end
    end

    if test (count $all_targets) -eq 0
        if test (count $all_skipped) -eq 0
            echo "Nothing to clean — no pulled sources found."
            return 0
        end
        echo "Nothing to delete — all found sources are preserved symlinks."
        return 0
    end

    set -l total (du -sch $all_targets 2>/dev/null | tail -1 | cut -f1)
    echo ""
    echo (set_color red)"☢ NUCLEAR: will delete "(count $all_targets)" targets ("$total")"(set_color normal)
    if test (count $all_skipped) -gt 0
        echo (set_color yellow)"  "(count $all_skipped)" symlink(s) preserved."(set_color normal)
    end
    echo "  Built package archives are kept — run -cc to remove those too."
    read -P "Proceed? [y/N] " -l answer
    if not string match -qi 'y*' -- "$answer"
        echo "Aborted — nothing deleted."
        return 0
    end

    for t in $all_targets
        # Safety net: never touch anything outside the workspace
        if string match -q "$SCRIPT_DIR/*" -- "$t"
            if test "$_ROOT_MODE" = "1"
                if not rm -rf -- "$t"
                    ui_error "failed to remove cleanup target: $t"
                    return 1
                end
            else if not sudo rm -rf -- "$t"
                ui_error "failed to remove cleanup target: $t"
                return 1
            end
        else
            ui_warning "skipped cleanup target outside workspace: $t"
        end
    end
    ui_success "Nuclear cleanup complete."
end

# ─── Workspace audit (--audit) ───────────────────────────────────────────────
# Read-only inventory of migration drift. Historical NOTE.md entries and large
# source/build trees are reported separately from active control-file findings.
function audit_workspace
    if not require_command rg
        return 1
    end
    set -l old_dirs
    for name in .Static .Heavy .Heavyweight
        if test -e "$SCRIPT_DIR/$name"; and not test -L "$SCRIPT_DIR/$name"
            set -a old_dirs "$SCRIPT_DIR/$name"
        end
    end

    ui_heading "Workspace legacy audit"
    echo ""
    echo "Active legacy directories:"
    if test (count $old_dirs) -eq 0
        echo "  none"
    else
        for d in $old_dirs
            echo "  $d"
        end
    end

    echo ""
    echo "Active control-file references:"
    set -l refs (rg -n --hidden \
        --glob '!docs/**' --glob '!build-all.fish' --glob '!config/**' \
        --glob '!**/.state/**' --glob '!**/.git/**' \
        --glob '!**/src/**' --glob '!**/pkg/**' --glob '!**/build/**' \
        '(^|/)\.(Static|Heavyweight|Heavy)(/|$)' "$SCRIPT_DIR" 2>/dev/null \
        | head -100)
    if test (count $refs) -eq 0
        echo "  none"
    else
        for ref in $refs
            echo "  $ref"
        end
    end

    echo ""
    echo "Generated-artifact references:"
    set -l generated (rg -l --hidden \
        --glob '!docs/**' --glob '!build-all.fish' --glob '!config/**' \
        --glob '!**/.state/**' --glob '!**/.git/**' \
        --glob '!**/src/**' --glob '!**/pkg/**' --glob '!**/build/**' \
        '(^|/)\.(Static|Heavyweight|Heavy)(/|$)' "$SCRIPT_DIR" 2>/dev/null \
        | head -100)
    if test (count $generated) -eq 0
        echo "  none"
    else
        for path in $generated
            echo "  $path"
        end
    end

    echo ""
    echo "Legacy symlink targets:"
    set -l links (find "$SCRIPT_DIR" -path '*/.git' -prune -o -type l \
        -printf '%p -> %l\n' 2>/dev/null \
        | grep -E '(^|/)\.(Static|Heavyweight|Heavy)(/|$)' | head -100)
    if test (count $links) -eq 0
        echo "  none"
    else
        for link in $links
            echo "  $link"
        end
    end

    set -l listed $_GROUP_git $_GROUP_stable $_GROUP_core \
        $_GROUP_misc $_GROUP_third_party
    set listed (printf '%s\n' $listed | awk '!seen[$0]++')
    set -l actual $_PACKAGE_IDS
    set -l unlisted
    for d in $actual
        if not contains "$d" $listed
            set -a unlisted $d
        end
    end
    set -l missing
    for d in $listed
        if not contains "$d" $actual
            set -a missing $d
        end
    end

    echo ""
    echo "Package membership drift:"
    if test (count $unlisted) -eq 0
        echo "  unlisted: none"
    else
        echo "  unlisted:"
        for d in $unlisted
            echo "    $d"
        end
    end
    if test (count $missing) -eq 0
        echo "  listed-but-missing: none"
    else
        echo "  listed-but-missing:"
        for d in $missing
            echo "    $d"
        end
    end

    set -l bad_deps
    for entry in $_DEPS
        set -l parts (string split ':' $entry -m 2)
        set -l pkg $parts[1]
        if not contains "$pkg" $actual
            set -a bad_deps "$pkg (package missing)"
        end
        if test (count $parts) -ge 2 -a -n "$parts[2]"
            for dep in (string split ',' $parts[2])
                if not contains "$dep" $actual
                    set -a bad_deps "$pkg -> $dep"
                end
            end
        end
    end
    echo ""
    echo "Dependency graph:"
    if test (count $bad_deps) -eq 0
        echo "  all package and dependency paths resolve"
    else
        for dep in $bad_deps
            echo "  $dep"
        end
    end

    echo ""
    echo "Stale runtime/error artifacts:"
    set -l stale (find "$LOG_DIR" -maxdepth 1 -type f \
        \( -name '.lane*.result' -o -name '*.srcinfo.err' \) \
        -printf '%p\n' 2>/dev/null)
    if test (count $stale) -eq 0
        echo "  none"
    else
        for path in $stale
            echo "  $path"
        end
    end
    set -l package_errors (find "$SCRIPT_DIR/packages" -name '.srcinfo.err' \
        -not -path '*/src/*' -not -path '*/pkg/*' -printf '%p\n' 2>/dev/null)
    for path in $package_errors
        if not contains "$path" $stale
            echo "  $path"
        end
    end

    echo ""
    echo "Historical references in docs/NOTE.md are not treated as active"
    echo "configuration by this audit."
end

# ─── Shared-source linking (-ln / --link-sources) ────────────────────────────
# Deduplicates git source clones: groups every PKGBUILD's git+ sources by
# effective URL (fragments like #tag/#branch are stripped — one mirror can
# serve several refs) and symlinks the twins to one canonical mirror, e.g.
#   packages/core/llvm-git/llvm-project  ← packages/git/libclc-git/llvm-project-git
#   packages/core/rocm-llvm/rocm-llvm    ← packages/stable/hip-runtime/hip-runtime-hipcc
# Canonical selection prefers an existing valid mirror, then core paths.
# A missing canonical is fine: the twin symlink dangles until the canonical
# package's first build, where makepkg clones THROUGH the symlink into it.
# Also repairs canonical mirrors: remote.origin.url must equal the PKGBUILD
# URL (makepkg aborts "is not a clone of" otherwise) and remote.origin.fetch
# must exist (a missing refspec makes 'fetch --all' a silent no-op); warns
# about insteadOf redirects that mask where fetches actually go.
# makepkg uses `git clone -s` (alternates) for working copies, so deleting a
# twin clone also deletes its src/ working copy (recreated on next build).
function valid_source_mirror -a path
    test -d "$path"; or return 1

    # Do not let git discover the enclosing package repository when a stale
    # empty source directory is present (for example packages/core/llvm-git/llvm-project).
    set -l abs_path (realpath "$path" 2>/dev/null)
    test -n "$abs_path"; or return 1
    set -l git_dir (git -c safe.bareRepository=all -C "$path" \
        rev-parse --absolute-git-dir 2>/dev/null)
    test -n "$git_dir"; or return 1
    set git_dir (realpath "$git_dir" 2>/dev/null)
    test -n "$git_dir"; or return 1

    if test "$git_dir" = "$abs_path"; \
        and test (git -c safe.bareRepository=all -C "$path" \
            rev-parse --is-bare-repository 2>/dev/null) = true
        return 0
    end

    set -l top (git -c safe.bareRepository=all -C "$path" \
        rev-parse --show-toplevel 2>/dev/null)
    test -n "$top"; and test (realpath "$top" 2>/dev/null) = "$abs_path"
end

function link_sources
    set -l entries

    # Collect git sources as "effectiveURL|localName|pkgDir"
    for d in (find_pkg_dirs)
        set -l srcs (bash -c "source '$d/PKGBUILD' 2>/dev/null && printf '%s\n' \"\${source[@]}\"" 2>/dev/null)
        for s in $srcs
            set -l name ""
            set -l url "$s"
            if string match -q '*::*' -- "$s"
                set -l parts (string split -m 1 '::' -- "$s")
                set name $parts[1]
                set url $parts[2]
            end
            if not string match -q 'git+*' -- "$url"
                continue
            end
            set -l eff (string replace -r '^git\+' '' -- "$url" | string replace -r '[?#].*$' '')
            if test -z "$name"
                set name (string replace -r '\.git$' '' -- (basename (string replace -r '/$' '' -- "$eff")))
            end
            set -a entries "$eff|$name|$d"
        end
    end

    if test (count $entries) -eq 0
        echo "No git sources found."
        return 0
    end

    set -l urls (printf '%s\n' $entries | cut -d'|' -f1 | sort -u)
    set -l deletions
    set -l del_twins
    set -l n_ok 0
    set -l n_fix 0
    set -l n_error 0

    for u in $urls
        set -l members (printf '%s\n' $entries | grep -F -- "$u|")
        if test (count $members) -lt 2
            continue
        end

        # Rank members: valid real mirror > valid symlink > missing; core >
        # other paths. Existing non-git directories are never treated as
        # mirrors; an empty one can be replaced, while a populated one is
        # left untouched and reported below.
        set -l ranked
        for m in (printf '%s\n' $members | sort)
            set -l parts (string split '|' -- "$m")
            set -l p "$parts[3]/$parts[2]"
            set -l key 2
            if valid_source_mirror "$p"
                if test -L "$p"
                    set key 1
                else
                    set key 0
                end
            else if test -d "$p"; and not test -L "$p"
                set -l child (find "$p" -mindepth 1 -maxdepth 1 \
                    -print -quit 2>/dev/null)
                if test -n "$child"
                    set key 3
                end
            end
            if string match -q "$SCRIPT_DIR/packages/core/*" -- "$parts[3]"
                set key "$key"0
            else
                set key "$key"1
            end
            set -a ranked "$key|$m"
        end
        set ranked (printf '%s\n' $ranked | sort | cut -d'|' -f2-)

        set -l canon (string split '|' -- "$ranked[1]")
        set -l canon_dir "$canon[3]"
        set -l canon_path "$canon_dir/$canon[2]"

        echo (set_color cyan)"shared mirror: $u"(set_color normal)
        echo "  canonical: $canon_path"

        # Repair the canonical mirror when it is a real clone
        if valid_source_mirror "$canon_path"
            set -l origin (git -c safe.bareRepository=all -C "$canon_path" \
                config --get remote.origin.url 2>/dev/null)
            if test "$origin" != "$u"
                if git -c safe.bareRepository=all -C "$canon_path" \
                    remote set-url origin "$u"
                    echo (set_color yellow)"  ↻ fixed origin: '$origin' → '$u'"(set_color normal)
                    set n_fix (math $n_fix + 1)
                else
                    ui_error "cannot repair mirror origin: $canon_path"
                    set n_error (math $n_error + 1)
                    continue
                end
            end
            set -l refspec (git -c safe.bareRepository=all -C "$canon_path" \
                config --get-all remote.origin.fetch 2>/dev/null)
            if test -z "$refspec"
                if git -c safe.bareRepository=all -C "$canon_path" \
                    config remote.origin.fetch "+refs/*:refs/*"
                    echo (set_color yellow)"  ↻ added missing remote.origin.fetch refspec (fetch was a silent no-op)"(set_color normal)
                    set n_fix (math $n_fix + 1)
                else
                    ui_error "cannot repair mirror fetch refspec: $canon_path"
                    set n_error (math $n_error + 1)
                    continue
                end
            else if test (git -c safe.bareRepository=all -C "$canon_path" \
                config --get core.bare 2>/dev/null) = true; and test "$refspec" != '+refs/*:refs/*'
                echo (set_color yellow)"  ⚠ bare mirror with non-mirror refspec '$refspec' — won't fetch tags/pull refs"(set_color normal)
            end
            set -l io (git -c safe.bareRepository=all -C "$canon_path" \
                config --local --list 2>/dev/null | grep -i insteadof)
            if test -n "$io"
                echo (set_color yellow)"  ⚠ insteadOf redirect present — fetches do NOT go to '$u'"(set_color normal)
            end
        else if test -d "$canon_path"; and not test -L "$canon_path"
            set -l child (find "$canon_path" -mindepth 1 -maxdepth 1 \
                -print -quit 2>/dev/null)
            if test -z "$child"
                if rmdir "$canon_path"
                    echo (set_color yellow)"  ↻ removed stale empty mirror directory"(set_color normal)
                else
                    ui_error "cannot remove stale empty mirror directory: $canon_path"
                    set n_error (math $n_error + 1)
                    continue
                end
            else
                echo (set_color red)"  ✗ existing non-git mirror path is not replaceable: $canon_path"(set_color normal)
                continue
            end
        else if test -L "$canon_path"
            echo (set_color yellow)"  ⚠ canonical is itself a symlink (dangling until its target exists)"(set_color normal)
        else
            echo "  ℹ canonical missing — makepkg will clone it here on the next build of $canon[3]"
        end

        # Point every other member at the canonical
        for m in $ranked[2..-1]
            set -l parts (string split '|' -- "$m")
            set -l twin_dir "$parts[3]"
            set -l twin_path "$twin_dir/$parts[2]"
            if test -L "$twin_path"
                set -l want (realpath -m "$canon_path" 2>/dev/null; or echo "$canon_path")
                set -l resolved (realpath -m "$twin_path" 2>/dev/null)
                if test "$resolved" = "$want"
                    echo (set_color green)"  ✓ linked: $twin_path"(set_color normal)
                    set n_ok (math $n_ok + 1)
                    continue
                end
                echo (set_color yellow)"  ↻ relinking $twin_path (was → $resolved)"(set_color normal)
                rm "$twin_path"
            else if valid_source_mirror "$twin_path"
                echo (set_color red)"  ☢ duplicate clone: $twin_path ("(du -sh "$twin_path" 2>/dev/null | cut -f1)")"(set_color normal)
                set -a deletions "$twin_path"
                set -a deletions "$twin_dir/src"
                set -a del_twins "$twin_dir|$parts[2]|$canon_path"
                continue
            else if test -d "$twin_path"
                set -l child (find "$twin_path" -mindepth 1 -maxdepth 1 \
                    -print -quit 2>/dev/null)
                if test -z "$child"
                    if not rmdir "$twin_path"
                        ui_error "cannot remove stale empty source path: $twin_path"
                        set n_error (math $n_error + 1)
                        continue
                    end
                else
                    echo (set_color red)"  ✗ existing non-git source path is not replaceable: $twin_path"(set_color normal)
                    continue
                end
            else
                echo "  ℹ creating symlink for not-yet-cloned $twin_path"
            end
            set -l relative_canon (realpath --relative-to="$twin_dir" "$canon_path" 2>/dev/null)
            if test -z "$relative_canon"; or not ln -sfn "$relative_canon" "$twin_path"
                ui_error "cannot link shared source path: $twin_path"
                set n_error (math $n_error + 1)
                continue
            end
            set n_fix (math $n_fix + 1)
        end
    end

    if test (count $deletions) -gt 0
        echo ""
        echo (set_color red)"☢ Dedup will delete "(count $deletions)" paths:"(set_color normal)
        for t in $deletions
            test -e "$t"; or continue
            printf '  %-8s %s\n' (du -sh "$t" 2>/dev/null | cut -f1) "$t"
        end
        echo "  (each clone's src/ working copy uses git alternates and must go too)"
        read -P "Proceed? [y/N] " -l answer
        if not string match -qi 'y*' -- "$answer"
            echo "Aborted — deletions skipped, other fixes already applied."
            return 0
        end
        for t in $deletions
            if not rm -rf -- "$t"
                ui_error "failed to delete duplicate source: $t"
                set n_error (math $n_error + 1)
            end
        end
        for dt in $del_twins
            set -l dp (string split '|' -- "$dt")
            set -l relative_canon (realpath --relative-to="$dp[1]" "$dp[3]" 2>/dev/null)
            if test -z "$relative_canon"; or not ln -sfn "$relative_canon" "$dp[1]/$dp[2]"
                ui_error "cannot restore shared source link: $dp[1]/$dp[2]"
                set n_error (math $n_error + 1)
            else
                set n_fix (math $n_fix + 1)
            end
        end
        echo (set_color green)"✓ duplicates removed — twins now share the canonical mirrors."(set_color normal)
    end

    echo ""
    echo "Shared-mirror scan done: $n_ok verified link(s), $n_fix change(s) applied."
    if test "$n_error" -gt 0
        echo "Shared-mirror scan encountered $n_error error(s)."
        return 1
    end
end

# ─── Unattended install of built package files ───────────────────────────────
# One pacman transaction per call. --ask 4 auto-accepts removal of conflicting
# (e.g. stock) packages — the stock→-git swap prompt — so a run never blocks on
# a prompt. Returns 1 on failure so callers abort the chain: a package that
# failed to install means every later package would compile against the WRONG
# system state (the 2026-09-06 rust-git/minimal-llvm-git incident class).
function install_pkgs_now -a log_file
    # log_file: the package's build log — install output is appended there so
    # quiet (lane) mode keeps install forensics in the per-package log.
    set -l pkgs $argv[2..-1]
    if test (count $pkgs) -eq 0
        return 0
    end
    set -l irc 1
    # Install: root mode runs pacman directly (no timestamp to expire);
    # unprivileged quiet (lane) mode uses -n to fail fast — a background lane
    # has no tty, so a prompt would hang ~2 min and fail anyway. Explicit
    # if/else: fish REJECTS `$pre pacman` when $pre expands to nothing
    # ("expanded command was empty") — no empty-prefix tricks.
    if test "$_ROOT_MODE" = "1"
        if test "$_BUILD_QUIET" = "1"
            # Lane children must never write to the terminal; the dispatcher
            # owns all progress rendering. Keep pacman hooks and transactions
            # in the package log instead of tailing a line to stdout.
            run_pacman_locked "$log_file" pacman -U --noconfirm --ask 4 $pkgs >>"$log_file" 2>&1
            set irc $status
        else
            echo "  Installing: "(string join ' ' $pkgs)
            run_pacman_locked "$log_file" pacman -U --noconfirm --ask 4 $pkgs 2>&1 | tee -a "$log_file" | tail -3
            set irc $pipestatus[1]
        end
    else if test "$_BUILD_QUIET" = "1"
        # See the root quiet branch: no child output may race the dispatcher.
        run_pacman_locked "$log_file" sudo -n pacman -U --noconfirm --ask 4 $pkgs >>"$log_file" 2>&1
        set irc $status
    else
        echo "  Installing: "(string join ' ' $pkgs)
        run_pacman_locked "$log_file" sudo pacman -U --noconfirm --ask 4 $pkgs 2>&1 | tee -a "$log_file" | tail -3
        set irc $pipestatus[1]
    end
    if test $irc -ne 0
        if test "$_BUILD_QUIET" = "1"
            printf '%s Install failed (rc=%s) — stopping: later packages would build against the wrong system state\n' "$_UI_ICON_ERROR" "$irc" >>"$log_file"
            printf '  NOTE: with -i the BUILD may still have succeeded (archive exists); install later with -ia or resume with -s -i\n' >>"$log_file"
        else
            ui_error "Install failed (rc=$irc) — stopping: later packages would build against the wrong system state"
        end
        return 1
    end
    return 0
end

function sanitize_log_stream
    # Remove ANSI CSI sequences and terminal controls before log text reaches
    # either the dashboard or the interactive failure replay.
    sed -E 's#\x1b\[[0-9;?]*[[:alpha:]]##g; s#\r##g; s#\t#    #g; s#[[:cntrl:]]##g'
end

function dashboard_tail_rows -a pkg
    if test -z "$pkg"
        printf '%s\n' "  $_UI_ICON_INFO idle" "  $_UI_ICON_INFO idle" "  $_UI_ICON_INFO idle"
        return 0
    end

    set -l log_file "$LOG_DIR/"(basename "$pkg")".log"
    set -l lines (tail -n 3 "$log_file" 2>/dev/null | sanitize_log_stream)
    for i in (seq 3)
        set -l line ""
        if test $i -le (count $lines)
            set line "$lines[$i]"
        end
        if test -n "$line"
            printf '  > %s\n' "$line"
        else
            printf '%s\n' "  $_UI_ICON_INFO no output yet"
        end
    end
end

function print_log_tail -a log_file
    # Build tools may leave carriage-return progress lines in a log even when
    # their output is redirected. Never replay those controls into the tty.
    tail -n 15 "$log_file" 2>/dev/null | sanitize_log_stream | sed 's/^/    /'
end

# Normalize package references to package IDs. Both IDs and relative recipe
# paths are accepted so resumed commands remain easy to translate.
function canonicalize_pkg_ref -a pkg
    if contains "$pkg" $_PACKAGE_IDS
        echo "$pkg"
        return 0
    end
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        if test "$pkg" = "$fields[2]"
            echo "$fields[1]"
            return 0
        end
    end
    if test -d "$SCRIPT_DIR/$pkg"
        set -l id (package_id_for_path "$SCRIPT_DIR/$pkg")
        if test -n "$id"
            echo "$id"
            return 0
        end
    end
    echo "$pkg"
end

# ─── Build a single package ──────────────────────────────────────────────────
function build_package -a package_id install_flag clean_flag skip_flag no_sync_flag quiet_flag
    # quiet_flag=1: background lane mode — no human echoes; everything goes to
    # the per-package log; the parent dispatcher renders lane state.
    set -g _BUILD_QUIET (test "$quiet_flag" = "1"; and echo 1; or echo 0)
    # Absolute path consolidation: never depend on the ambient cwd
    set -l pkg_path (package_path "$package_id" | string collect)
    set -l pkg_name "$package_id"

    if test -z "$pkg_path"
        ui_error "package ID does not resolve: $package_id"
        return 1
    end

    if not test -f "$pkg_path/PKGBUILD"
        ui_error "PKGBUILD not found: $pkg_path/PKGBUILD"
        return 1
    end

    # Clean if requested (before skip check — clean forces rebuild)
    if test "$clean_flag" = "1"
        if test "$_BUILD_QUIET" != "1"
            ui_info "Cleaning build artifacts for $pkg_name..."
        end
        if not rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
            ui_error "failed to clean build artifacts for $pkg_name"
            return 1
        end
        if not find "$pkg_path" -maxdepth 1 -name '*.pkg.tar.zst' -delete 2>/dev/null
            ui_error "failed to remove old package archives for $pkg_name"
            return 1
        end
    end

    # Skip if already built (only when -s flag is set)
    if test "$skip_flag" = "1"
        # find with -printf: newest archive by mtime (fish globs would FATAL on
        # "no matches" for packages that have no built archive yet)
        set -l latest_pkg (find "$pkg_path" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)
        if test -n "$latest_pkg"
            set -l pkg_time (stat -c %Y "$pkg_path/PKGBUILD" 2>/dev/null)
            set -l built_time (stat -c %Y "$latest_pkg" 2>/dev/null)
            if test -n "$pkg_time" -a -n "$built_time" -a "$built_time" -ge "$pkg_time"
                if test "$_BUILD_QUIET" != "1"
                    ui_info "$pkg_name: already built ($(basename $latest_pkg))"
                end
                # -s + -i: the skip path installs too — topo order must hold
                # for already-built packages just the same.
                # ($log_file isn't defined yet here — use the canonical path.)
                if test "$install_flag" = "1"
                    install_pkgs_now (package_log_file "$package_id") (list_split_pkgs "$pkg_path"); or return 1
                end
                return 0
            end
        end
    end

    # Sync stable recipes with the latest Arch repository version
    set -l synced 0
    if test "$no_sync_flag" != "1"
        sync_stable_version "$pkg_path"
        set -l sync_rc $status
        if test "$sync_rc" -eq 0
            set synced 0
        else if test "$sync_rc" -eq 1
            set synced 1
        else
            ui_error "failed to synchronize stable metadata for $pkg_name"
            return 1
        end
    end

    if test "$_BUILD_QUIET" != "1"
        ui_heading "Building: $pkg_name"
    end

    if not mkdir -p "$LOG_DIR"
        ui_error "cannot create log directory: $LOG_DIR"
        return 1
    end
    set -l log_file (package_log_file "$package_id")
    # Lane supervisors append their own diagnostics to this same log. Truncate
    # it once here, then append every build stream so the outer redirection
    # cannot be reordered by a later makepkg redirection.
    if not printf '' >"$log_file"
        ui_error "cannot write build log: $log_file"
        return 1
    end

    # Build
    set -l makepkg_args -sf --noconfirm
    if test $synced -eq 1
        set -a makepkg_args --skipchecksums
    end

    # Full redirect to the log (2026-09-07): 'tee' to a lagging terminal
    # backpressures compiler output; file-only logging is cheaper and keeps
    # the terminal readable. Failure tails are printed by the caller.
    set -l start_s (date +%s)
    if test "$_BUILD_QUIET" != "1"
        echo "  makepkg $makepkg_args | log: $log_file"
    end
    if not pushd "$pkg_path" >/dev/null
        ui_error "cannot enter package directory: $pkg_path"
        return 1
    end
    if test "$_ROOT_MODE" = "1"
        # Root supervises, the invoking user builds. HOME is pinned to the
        # user's home so tool caches (~/.ccache, ~/.cargo, ~/.cache/go-build)
        # stay in THEIR home — nothing lands in /root. MAKEFLAGS/NINJAFLAGS
        # pass through explicitly (sudo strips the environment by default).
        set -l env_prefix env HOME=$_BUILD_HOME
        if test -n "$MAKEFLAGS"
            set -a env_prefix MAKEFLAGS=$MAKEFLAGS
        end
        if test -n "$NINJAFLAGS"
            set -a env_prefix NINJAFLAGS=$NINJAFLAGS
        end
        if set -q GSA_BUILD_JOBS; and test -n "$GSA_BUILD_JOBS"
            set -a env_prefix GSA_BUILD_JOBS=$GSA_BUILD_JOBS
        end
        if set -q GSA_TARGET_CPU; and test -n "$GSA_TARGET_CPU"
            set -a env_prefix GSA_TARGET_CPU=$GSA_TARGET_CPU
        end
        sudo -u "$_BUILD_USER" $env_prefix makepkg $makepkg_args >>"$log_file" 2>&1
    else
        makepkg $makepkg_args >>"$log_file" 2>&1
    end
    set -l rc $status
    if not popd >/dev/null
        ui_error "cannot restore working directory after building $pkg_name"
        return 1
    end
    set -l dur (math (date +%s) - $start_s)

    # Root mode: restore user ownership of everything this run touched in the
    # workspace (clean/sync ran as root; sed -i would leave root-owned
    # PKGBUILDs). Runs on BOTH success and failure — a failed build that
    # leaves root-owned src/build files poisons the retry with EACCES
    # (2026-09-08 gtk3-git: root-owned src/build/modules → meson OSError).
    if test "$_ROOT_MODE" = "1"
        if not chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR" 2>/dev/null
            ui_error "failed to restore ownership after building $pkg_name"
            return 1
        end
    end

    if test $rc -ne 0
        if test "$_BUILD_QUIET" != "1"
            ui_error "$pkg_name: BUILD FAILED (rc=$rc)"
            echo "  Log: $log_file"
            ui_warning "Last lines:"
            print_log_tail "$log_file"
        end
        return 1
    end

    if test "$_BUILD_QUIET" != "1"
        ui_success "$pkg_name: build succeeded ("(fmt_dur $dur)")"
    end

    # -i: install IMMEDIATELY, in topo order. A package must be installed
    # before its dependents compile, or they build/link against the old
    # system version (2026-09-06 rust-git vs minimal llvm-git incident).
    if test "$install_flag" = "1"
        if not install_pkgs_now "$log_file" (list_split_pkgs "$pkg_path")
            return 1
        end
    end

    return 0
end

# ─── Parallel build lanes ────────────────────────────────────────────────────
# run_lanes dispatches READY packages (all workspace deps already installed)
# to N background makepkg lanes. Rationale (2026-09-07): single-threaded
# final links leave cores idle; a second lane fills them with independent
# packages from the wide tail of the dependency graph.
#
# Concurrency design:
# - Heavy-group packages are LTO/RAM monsters — they run SOLO with the full
#   core count, never paired with another build (RAM contention).
# - Non-solo lanes share a CPU/RAM-derived per-lane job limit.
# - pacman installs happen inside background jobs (no tty): the dispatcher
#   keeps the sudo timestamp warm with a `sudo -v` keepalive, and a
#   builder-owned flock serializes transactions before pacman can contend on
#   its database lock.
# - Lane supervisors use isolated sessions and redirect their complete
#   stdout/stderr stream to the package log; only the parent renders status.
# - Result protocol: each lane job writes "pkgdir rc seconds" to its result
#   file; the dispatcher polls those files every 0.5 s.
# - lanes=1 preserves the old sequential semantics exactly (strict topo order).

set -g _lane_sorted
set -g _lane_done
set -g _lane_started

function deps_of -a pkg
    for entry in $_DEPS
        set -l parts (string split ':' $entry -m 2)
        if test "$parts[1]" = "$pkg"
            if test (count $parts) -ge 2 -a -n "$parts[2]"
                string split ',' $parts[2]
            end
            return
        end
    end
end

function fmt_dur -a secs
    printf '%dm%02ds' (math "floor($secs / 60)") (math "$secs % 60")
end

function package_log_file -a pkg
    echo "$LOG_DIR/"(basename "$pkg")".log"
end

function require_command -a command_name
    if not command -v "$command_name" >/dev/null 2>&1
        ui_error "required command '$command_name' is unavailable"
        return 1
    end
    return 0
end

function check_runtime_prereqs -a install_flag needs_stable_sync
    set -l required fish makepkg nproc ps awk tail sed getent
    if test "$install_flag" = "1"; or test "$needs_stable_sync" = "1"
        set -a required pacman
    end
    if test "$install_flag" = "1"
        set -a required flock pacman
        if test "$_ROOT_MODE" != "1"
            set -a required sudo
        end
    end
    for command_name in $required
        if not require_command "$command_name"
            return 1
        end
    end
    return 0
end

function write_lane_result -a result_file pkg rc dur
    set -l tmp_result "$result_file.tmp.$fish_pid"
    if not printf '%s %s %s\n' "$pkg" "$rc" "$dur" >"$tmp_result"
        rm -f -- "$tmp_result"
        return 1
    end
    if not mv -f -- "$tmp_result" "$result_file"
        rm -f -- "$tmp_result"
        return 1
    end
    return 0
end

function lane_result_valid -a expected_pkg result_line
    set -l fields
    for field in (string split ' ' -- "$result_line")
        if test -n "$field"
            set -a fields "$field"
        end
    end
    if test (count $fields) -ne 3
        return 1
    end
    if test "$fields[1]" != "$expected_pkg"
        return 1
    end
    if not string match -qr '^[0-9]+$' -- "$fields[2]"
        return 1
    end
    if not string match -qr '^[0-9]+$' -- "$fields[3]"
        return 1
    end
    return 0
end

function dashboard_width
    if test "$_OUTPUT_INTERACTIVE" != "1"
        echo 0
        return 0
    end

    set -l width ""
    set width (tput cols 2>/dev/null)
    if test (count $width) -eq 0; or not string match -qr '^[0-9]+$' -- "$width[1]"
        if test -n "$COLUMNS"; and string match -qr '^[0-9]+$' -- "$COLUMNS"
            set width "$COLUMNS"
        end
    end
    if test (count $width) -eq 0; or not string match -qr '^[0-9]+$' -- "$width[1]"
        set width 80
    else
        set width "$width[1]"
    end
    if test "$width" -lt 20
        set width 20
    end
    echo "$width"
end

function fit_dashboard_line -a text width
    # Keep one cell unused so a terminal never enters its pending-wrap state.
    set -l max_width (math "$width - 1")
    if test "$max_width" -lt 1
        set max_width 1
    end
    set -l text_length (string length --visible -- "$text")
    if test "$text_length" -le "$max_width"
        printf '%s' "$text"
    else
        set -l suffix ""
        set -l target_width "$max_width"
        if test "$max_width" -gt 3
            set suffix "..."
            set target_width (math "$max_width - 3")
        end
        set -l prefix ""
        for char in (string split '' -- "$text")
            set -l candidate "$prefix$char"
            if test (string length --visible -- "$candidate") -gt "$target_width"
                break
            end
            set prefix "$candidate"
        end
        printf '%s%s' "$prefix" "$suffix"
    end
end

function render_dashboard -a total dispatched succeeded failed stop_starting
    if test "$_OUTPUT_INTERACTIVE" != "1"
        return 0
    end

    set -l state RUNNING
    set -l state_icon "$_UI_ICON_ACTIVE"
    if test "$failed" -gt 0
        set state FAILED
        set state_icon "$_UI_ICON_ERROR"
    else if test "$stop_starting" -eq 1
        set state STOPPING
        set state_icon "$_UI_ICON_WARN"
    else if test "$succeeded" -eq "$total"; and test "$total" -gt 0
        set state DONE
        set state_icon "$_UI_ICON_OK"
    end

    set -l rows
    set -a rows "Progress: $dispatched/$total started | $succeeded done | $failed failed | $state_icon $state"
    for i in (seq (count $_DASHBOARD_LANE_BUSY))
        if test "$_DASHBOARD_LANE_BUSY[$i]" -eq 1
            set -l elapsed (math (date +%s) - $_DASHBOARD_LANE_START[$i])
            set -l lane_name (basename "$_DASHBOARD_LANE_PKG[$i]")
            set -l elapsed_fmt (fmt_dur $elapsed)
            set -a rows "Lane $i: $_UI_ICON_ACTIVE RUNNING $lane_name $elapsed_fmt"
            set -a rows (dashboard_tail_rows "$_DASHBOARD_LANE_PKG[$i]")
        else
            set -a rows "Lane $i: $_UI_ICON_INFO idle"
            set -a rows (dashboard_tail_rows "")
        end
    end
    if test -n "$_DASHBOARD_LAST_EVENT"
        set -a rows "$_DASHBOARD_SPINNER_FRAMES[$_DASHBOARD_SPINNER_INDEX] Event: $_DASHBOARD_LAST_EVENT"
    end

    set -l old_rows $_DASHBOARD_ROWS
    if test "$_DASHBOARD_ACTIVE" != "1"
        printf '\033[?25l'
    end
    if test "$old_rows" -gt 0
        printf '\033[%dA' "$old_rows"
    end
    set -l width (dashboard_width)
    for row in $rows
        printf '\r\033[2K%s\n' (fit_dashboard_line "$row" "$width")
    end
    # The row count is intentionally stable during a run, but clear any
    # remainder if a future state adds fewer rows.
    set -l new_rows (count $rows)
    if test "$old_rows" -gt "$new_rows"
        for i in (seq (math "$new_rows + 1") "$old_rows")
            printf '\r\033[2K\n'
        end
    end
    set -g _DASHBOARD_ROWS $new_rows
    set -g _DASHBOARD_ACTIVE 1
end

function finish_dashboard
    if test "$_DASHBOARD_ACTIVE" = "1"
        printf '\033[?25h'
        set -g _DASHBOARD_ACTIVE 0
        set -g _DASHBOARD_ROWS 0
    end
end

function abort_dashboard
    if test "$_DASHBOARD_ACTIVE" = "1"
        set -l rows $_DASHBOARD_ROWS
        if test "$rows" -gt 0
            printf '\033[%dA' "$rows"
            for i in (seq $rows)
                printf '\r\033[2K'
                if test "$i" -lt "$rows"
                    printf '\033[1B'
                end
            end
            if test "$rows" -gt 1
                printf '\033[%dA' (math "$rows - 1")
            end
        end
        printf '\033[?25h'
    end
    set -g _DASHBOARD_ACTIVE 0
    set -g _DASHBOARD_ROWS 0
end

function forget_lane_pid -a pid
    if test -z "$pid"; or test (count $_ACTIVE_LANE_PIDS) -eq 0
        return 0
    end
    for i in (seq (count $_ACTIVE_LANE_PIDS))
        if test "$_ACTIVE_LANE_PIDS[$i]" = "$pid"
            set -e _ACTIVE_LANE_PIDS[$i]
            return 0
        end
    end
end

function lane_processes -a lane_pid
    ps -eo pid=,pgid= 2>/dev/null | awk -v target="$lane_pid" '$2 == target {print $1}'
end

function lane_pid_alive -a lane_pid
    test -n "$lane_pid"; or return 1
    set -l process_state (ps -o stat= -p "$lane_pid" 2>/dev/null | string trim)
    test -n "$process_state"; or return 1
    string match -q '*Z*' -- "$process_state"; and return 1
    kill -0 "$lane_pid" 2>/dev/null
end

function stop_lane_process -a lane_pid
    if test -z "$lane_pid"
        return 0
    end
    set -l lane_process_ids (lane_processes "$lane_pid")
    for process_id in $lane_process_ids
        kill "$process_id" 2>/dev/null
    end
    for attempt in (seq 20)
        set lane_process_ids (lane_processes "$lane_pid")
        if test (count $lane_process_ids) -eq 0
            break
        end
        # A child that ignores TERM must not survive the interrupted build.
        if test "$attempt" -eq 10
            for process_id in $lane_process_ids
                kill -KILL "$process_id" 2>/dev/null
            end
        end
        sleep 0.05
    end
    wait "$lane_pid" 2>/dev/null
end

function cleanup_active_lanes
    set -l active_pids $_ACTIVE_LANE_PIDS
    for lane_pid in $active_pids
        stop_lane_process "$lane_pid"
    end
    set -g _ACTIVE_LANE_PIDS
    find "$LOG_DIR" -maxdepth 1 -name '.lane*.result' -delete 2>/dev/null
end

function check_rustc_sanity
    # Preflight ABI-skew probe (2026-09-07 incident): a trivial rustc compile
    # catches llvm-libs-git-vs-rust-git snapshot skew in ~2 s — BEFORE a run
    # wastes an hour building against a compiler that segfaults on any input.
    pacman -Q rust-git >/dev/null 2>&1; or return 0
    command -v rustc >/dev/null 2>&1; or return 0
    # Per-user probe files: /tmp has the sticky bit + fs.protected_regular=2,
    # so even ROOT cannot redirect over a file owned by another user — name
    # collisions between user-mode and root-mode runs must be impossible.
    # Sanitized: rustc derives the crate name from the output file, so only
    # [A-Za-z0-9_] may appear (dots/dashes in usernames break it).
    set -l user_tag (string replace -r '[^a-zA-Z0-9_]' '_' -- "$_BUILD_USER")
    set -l probe /tmp/build_all_rustc_probe_$user_tag
    if not echo 'fn main() {}' >"$probe.rs"
        ui_error "cannot create rustc sanity probe: $probe.rs"
        return 1
    end
    set -l ok 0
    if test "$_ROOT_MODE" = "1"
        if sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME rustc -o "$probe.bin" "$probe.rs" 2>/dev/null
            set ok 1
        end
    else
        if rustc -o "$probe.bin" "$probe.rs" 2>/dev/null
            set ok 1
        end
    end
    if not rm -f -- "$probe.rs" "$probe.bin"
        ui_warning "could not remove rustc sanity probe files under /tmp"
    end
    if test $ok -eq 0
        ui_error "rustc is BROKEN — segfaults/heap-corrupts on a trivial compile."
        echo "  Almost certainly llvm-libs-git is NEWER than rust-git (LLVM snapshots"
        echo "  have no stable C++ ABI — see NOTE.md 2026-09-07 evening). Every build"
        echo "  using rustc in this run would fail or miscompile."
        echo "  Recovery: downgrade-rebuild llvm-libs at the snapshot rust-git was built"
        echo "  against (old version in /var/log/pacman.log; procedure in NOTE.md), or"
        echo "  -g core once a working bootstrap exists."
        echo "  Bypass anyway: --allow-broken-rustc"
        return 1
    end
    return 0
end

function pick_next_ready -a solo_ok
    # Print the first unstarted package whose workspace deps are all done.
    # solo_ok=0 skips core-group packages (they are only dispatched solo).
    for pkg in $_lane_sorted
        if test (count $_lane_started) -gt 0; and contains "$pkg" $_lane_started
            continue
        end
        # Defensive: _lane_started is a superset of _lane_done in run_lanes,
        # but never re-dispatch a completed package even if that breaks.
        if test (count $_lane_done) -gt 0; and contains "$pkg" $_lane_done
            continue
        end
        set -l ok 1
        for dep in (deps_of $pkg)
            # Deps outside the build list are external — topo_sort ignores
            # them, the readiness check must too (they will never be "done").
            if not contains "$dep" $_lane_sorted
                continue
            end
            if test (count $_lane_done) -eq 0; or not contains "$dep" $_lane_done
                set ok 0
                break
            end
        end
        if test $ok -eq 0
            continue
        end
        if test $solo_ok -eq 0; and contains "$pkg" $_GROUP_core
            continue
        end
        echo $pkg
        return 0
    end
    return 1
end

function lane_job -a pkg_dir result_file total_jobs install_flag clean_flag skip_flag no_sync_flag
    # Runs in a separate fish process with its stdout/stderr redirected by the
    # parent: no tty for sudo, no shared mutable state — communicates by result file.
    set -gx GSA_BUILD_JOBS "$total_jobs"
    set -l make_flags
    if set -q MAKEFLAGS
        for flag in (string split ' ' -- "$MAKEFLAGS")
            if test -n "$flag"; and not string match -qr '^-j[0-9]*$' -- "$flag"
                set -a make_flags "$flag"
            end
        end
    end
    set -a make_flags "-j$total_jobs"
    set -gx MAKEFLAGS (string join ' ' $make_flags)
    set -l ninja_flags
    if set -q NINJAFLAGS
        for flag in (string split ' ' -- "$NINJAFLAGS")
            if test -n "$flag"; and not string match -qr '^-j[0-9]*$' -- "$flag"
                set -a ninja_flags "$flag"
            end
        end
    end
    set -a ninja_flags "-j$total_jobs"
    set -gx NINJAFLAGS (string join ' ' $ninja_flags)
    set -l start_s (date +%s)
    build_package $pkg_dir $install_flag $clean_flag $skip_flag $no_sync_flag 1
    set -l rc $status
    set -l dur (math (date +%s) - $start_s)
    if not write_lane_result "$result_file" "$pkg_dir" "$rc" "$dur"
        echo "✗ lane result write failed: $result_file" >&2
        exit 125
    end
    return $rc
end

function available_memory_gib
    if set -q GSA_MEMORY_GIB
        if not string match -qr '^[1-9][0-9]*$' -- "$GSA_MEMORY_GIB"
            ui_error "GSA_MEMORY_GIB must be a positive integer"
            return 1
        end
        echo "$GSA_MEMORY_GIB"
        return 0
    end
    if not test -r /proc/meminfo
        echo 0
        return 0
    end
    set -l memory_kib (awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    if test -z "$memory_kib"; or not string match -qr '^[0-9]+$' -- "$memory_kib"
        echo 0
        return 0
    end
    math "floor($memory_kib / 1048576)"
end

function available_cpu_threads
    if set -q GSA_CPU_THREADS
        if not string match -qr '^[1-9][0-9]*$' -- "$GSA_CPU_THREADS"
            ui_error "GSA_CPU_THREADS must be a positive integer"
            return 1
        end
        echo "$GSA_CPU_THREADS"
        return 0
    end
    nproc
end

function run_lanes -a lanes jobs_override intensity_level install_flag clean_flag skip_flag no_sync_flag
    # Remaining argv = the topo-sorted package list
    set -l sorted $argv[8..-1]
    if not command -v setsid >/dev/null 2>&1
        ui_error "setsid is required for isolated lane processes"
        return 1
    end
    set -g _RL_INTERRUPTED 0
    set -g _RL_BLOCKED 0
    set -g _lane_sorted $sorted
    set -g _lane_done
    set -g _lane_started

    set -l total (count $sorted)
    if test "$total" -eq 0
        ui_error "selection resolved to no packages"
        return 1
    end
    if not configure_intensity "$intensity_level"
        return 1
    end
    set -l needs_stable_sync 0
    if test "$no_sync_flag" != "1"
        for pkg in $sorted
            set -l pkg_path (package_path "$pkg")
            if string match -q "$SCRIPT_DIR/packages/stable/*" -- "$pkg_path"
                set needs_stable_sync 1
                break
            end
        end
    end
    if not check_runtime_prereqs "$install_flag" "$needs_stable_sync"
        return 1
    end
    set -l nproc_count (available_cpu_threads)
    if test $status -ne 0
        return 1
    end
    if test -z "$nproc_count"; or not string match -qr '^[0-9]+$' -- "$nproc_count"
        ui_error "nproc returned an invalid CPU count"
        return 1
    end
    set -l memory_gib (available_memory_gib)
    if test $status -ne 0
        return 1
    end
    if test "$memory_gib" -le 0
        set memory_gib 1
    end
    set -l normal_memory (math "max(1, $memory_gib - $_RESERVED_MEMORY_GIB)")
    set -l normal_memory_per_job (math "$_MEMORY_PER_JOB_GIB * $_INTENSITY_NORMAL_MEMORY_FACTOR")
    set -l normal_job_budget (math "max(1, floor($normal_memory / $normal_memory_per_job))")
    if test "$lanes" = auto
        set lanes (math "max(1, min($_INTENSITY_LANE_CAP, floor($nproc_count / $_INTENSITY_CPU_PER_LANE), floor($memory_gib / $_INTENSITY_MEMORY_PER_LANE), $normal_job_budget, $total))")
    else if not string match -qr '^[1-9][0-9]*$' -- "$lanes"
        ui_error "lane count must be a positive integer or auto"
        return 1
    end
    if test $lanes -gt $total
        set lanes $total
    end
    if test "$jobs_override" = auto
        set -l cpu_jobs (math "max(1, floor($nproc_count / $lanes))")
        set -l memory_jobs (math "max(1, floor($normal_job_budget / $lanes))")
        set lane_jobs (math "max(1, min($cpu_jobs, $memory_jobs))")
    else if string match -qr '^[1-9][0-9]*$' -- "$jobs_override"
        set lane_jobs "$jobs_override"
    else
        ui_error "jobs must be a positive integer or auto"
        return 1
    end
    set -l core_memory_per_job (math "$_CORE_MEMORY_PER_JOB_GIB * $_INTENSITY_CORE_MEMORY_FACTOR")
    set -l core_jobs (math "max(1, min($nproc_count, floor($normal_memory / $core_memory_per_job)))")
    ui_info "parallelism: $nproc_count CPU threads, $memory_gib GiB available, intensity $intensity_level, $lanes lane(s), normal -j$lane_jobs, core -j$core_jobs"

    set -l succeeded
    set -l failed
    set -l failed_rc
    set -l failed_dur
    set -l stop_starting 0
    set -l blocked 0
    set -l last_sudo (date +%s)
    set -l disp_count 0

    if not mkdir -p "$LOG_DIR"
        ui_error "cannot create log directory: $LOG_DIR"
        return 1
    end
    set -g _ACTIVE_LANE_PIDS
    set -l lane_busy
    set -l lane_pkg
    set -l lane_start
    set -l lane_pid
    for i in (seq $lanes)
        set -a lane_busy 0
        set -a lane_pkg ""
        set -a lane_start ""
        set -a lane_pid ""
    end
    set -g _DASHBOARD_LANE_BUSY $lane_busy
    set -g _DASHBOARD_LANE_PKG $lane_pkg
    set -g _DASHBOARD_LANE_START $lane_start
    set -g _DASHBOARD_SPINNER_INDEX 1
    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_INFO initializing"
    render_dashboard $total $disp_count 0 0 $stop_starting
    set -l last_status (date +%s)

    while true
        if test "$_INTERRUPT_HANDLED" = "1"
            cleanup_active_lanes
            abort_dashboard
            printf '\n'
            ui_warning "Build interrupted"
            set -g _RL_INTERRUPTED 1
            return 130
        end

        # Reap finished lanes
        for i in (seq $lanes)
            if test $lane_busy[$i] -eq 1
                set -l rf "$LOG_DIR/.lane$i.result"
                set -l res_raw (cat "$rf" 2>/dev/null)
                set -l expected_pkg "$lane_pkg[$i]"
                set -l result_ready 0
                set -l result_malformed 0
                if test (count $res_raw) -gt 0; and \
                    lane_result_valid "$expected_pkg" "$res_raw[1]"
                    set result_ready 1
                else if test (count $res_raw) -gt 0
                    set result_malformed 1
                end
                if test $result_ready -eq 0; and test $result_malformed -eq 0; and \
                    lane_pid_alive "$lane_pid[$i]"
                    # An absent or partial result is normal while the child
                    # is still running; atomic result publication prevents a
                    # finished child from looking partial here.
                    continue
                end

                set -l p "$expected_pkg"
                set -l rc 125
                set -l dur (math (date +%s) - $lane_start[$i])
                if test $result_ready -eq 1
                    # fish splits command substitution on NEWLINES only; the
                    # validated result line is explicitly split on spaces.
                    set -l res (string split ' ' "$res_raw[1]")
                    set p $res[1]
                    set rc $res[2]
                    set dur $res[3]
                else
                    set -l log_file (package_log_file "$p")
                    printf '%s\n' \
                        "$_UI_ICON_ERROR lane supervisor produced no valid result (pid=$lane_pid[$i])" \
                        "  Check the lane log: $log_file" >>"$log_file"
                    set stop_starting 1
                    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR lane lost $p"
                end

                rm -f -- "$rf"
                set -l finished_pid $lane_pid[$i]
                set lane_busy[$i] 0
                set lane_pkg[$i] ""
                set lane_start[$i] ""
                set lane_pid[$i] ""
                if test -n "$finished_pid"
                    if test "$result_malformed" -eq 1
                        stop_lane_process "$finished_pid"
                    else
                        wait "$finished_pid" 2>/dev/null
                    end
                    forget_lane_pid "$finished_pid"
                end

                set -a _lane_done $p
                if test $rc -eq 0
                    set -a succeeded $p
                    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_OK completed $p"
                else
                    set -a failed $p
                    set -a failed_rc $rc
                    set -a failed_dur $dur
                    set stop_starting 1
                    if test "$result_ready" = "1"
                        set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR failed $p"
                    end
                end
                set -g _DASHBOARD_LANE_BUSY $lane_busy
                set -g _DASHBOARD_LANE_PKG $lane_pkg
                set -g _DASHBOARD_LANE_START $lane_start
                render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
                if test "$_OUTPUT_INTERACTIVE" != "1"
                    if test $rc -eq 0
                        printf "  %s %s (%s)\n" "$_UI_ICON_OK" $p (fmt_dur $dur)
                    else
                        set -l log_file (package_log_file "$p")
                        printf "  %s %s: BUILD FAILED (rc=%s, %s) — log: %s\n" \
                            "$_UI_ICON_ERROR" $p $rc (fmt_dur $dur) "$log_file"
                        ui_warning "Last lines:"
                        print_log_tail "$log_file"
                        if test $install_flag -eq 1
                            ui_warning "(with -i the failure may be the INSTALL, not the build — check the log tail above; if the archive exists, install later with -ia or resume with -s -i)"
                        end
                    end
                end
            end
        end

        # Keep the sudo timestamp warm so background installs never hit a
        # password prompt (background jobs have no tty). -n = fail FAST instead
        # of hanging the dispatcher on a prompt nobody can answer; interval is
        # deliberately well inside the 5-min sudo timeout so a slow poll
        # iteration under heavy CPU load can't overshoot it (2026-09-07 llvm
        # incident: 70-min build, keepalive prompt timed out).
        # Root mode needs none of this — installs are direct pacman calls.
        if test $install_flag -eq 1; and test "$_ROOT_MODE" != "1"
            set -l now (date +%s)
            if test (math $now - $last_sudo) -gt 150
                if sudo -n -v >/dev/null 2>&1
                    set last_sudo $now
                else
                    abort_dashboard
                    ui_error "sudo timestamp expired and cannot be refreshed non-interactively — stopping dispatch"
                    echo "  In-flight lane installs will fail fast (no hang). After the run, from a"
                    echo "  terminal where sudo works: install with 'build-all.fish -ia', or resume with -s -i."
                    set stop_starting 1
                end
            end
        end

        if test "$_INTERRUPT_HANDLED" = "1"
            continue
        end

        # Dispatch to idle lanes
        if test $stop_starting -eq 0
            for i in (seq $lanes)
                if test $lane_busy[$i] -eq 1
                    continue
                end
                set -l other_busy 0
                set -l other_solo 0
                for j in (seq $lanes)
                    if test $j -ne $i; and test $lane_busy[$j] -eq 1
                        set other_busy 1
                        if contains "$lane_pkg[$j]" $_GROUP_core
                            set other_solo 1
                        end
                    end
                end
                # A running core build is SOLO: never start anything alongside
                # it (its full -j implies peak RAM; pairing defeats the guard)
                if test $other_solo -eq 1
                    continue
                end
                # Core = solo: needs every lane idle; otherwise fall back to
                # the first ready NON-core package so nothing idles needlessly.
                set -l next (pick_next_ready 1)
                if test -n "$next"; and contains "$next" $_GROUP_core; and test $other_busy -eq 1
                    set next (pick_next_ready 0)
                end
                if test -z "$next"
                    continue
                end
                set -l jobs $lane_jobs
                if contains "$next" $_GROUP_core
                    set jobs $core_jobs
                end
                set -a _lane_started $next
                set lane_busy[$i] 1
                set lane_pkg[$i] $next
                set lane_start[$i] (date +%s)
                set -l rf "$LOG_DIR/.lane$i.result"
                set -l child_log (package_log_file "$next")
                rm -f "$rf"
                # Clear before the child starts preflight/sync so the
                # dashboard never shows a previous run's tail for this lane.
                printf '' >"$child_log"
                set disp_count (math $disp_count + 1)
                # Fish executes a backgrounded function synchronously. Invoke
                # the hidden child mode as an external fish process so this
                # dispatch loop can continue filling idle lanes immediately.
                # Capture the complete child process boundary, not only the
                # makepkg call, so hooks/signals can never corrupt the dashboard.
                setsid --wait fish "$SCRIPT_DIR/build-all.fish" --lane-job \
                    "$next" "$rf" $jobs $install_flag $clean_flag \
                    $skip_flag $no_sync_flag >>"$child_log" 2>&1 &
                set lane_pid[$i] $last_pid
                set -a _ACTIVE_LANE_PIDS $last_pid
                set -g _DASHBOARD_LANE_BUSY $lane_busy
                set -g _DASHBOARD_LANE_PKG $lane_pkg
                set -g _DASHBOARD_LANE_START $lane_start
                set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ACTIVE started $next on lane $i"
                render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
                if test "$_OUTPUT_INTERACTIVE" != "1"
                    printf "  [lane %d] %s (%d/%d, -j%d)\n" $i $next $disp_count $total $jobs
                end
            end
        end

        # Termination: nothing running and (stopped on failure, or everything
        # started has been reaped). Packages that never became ready (cycle /
        # missing dep — topo_sort appends those at the end) are reported here.
        set -l active 0
        for i in (seq $lanes)
            if test $lane_busy[$i] -eq 1
                set active (math $active + 1)
            end
        end
        if test $active -eq 0
            if test $stop_starting -eq 1
                break
            end
            if test (count $_lane_started) -eq (count $_lane_done)
                set -l unstarted (math $total - (count $_lane_started))
                if test $unstarted -gt 0
                    set blocked $unstarted
                    abort_dashboard
                    ui_warning "$unstarted package(s) never became ready (dependency cycle or missing dep) — skipped:"
                    for pkg in $_lane_sorted
                        if not contains "$pkg" $_lane_started
                            echo "    ? $pkg"
                        end
                    end
                end
                break
            end
        end

        # Live status (multi-lane only): the interactive path redraws the
        # dashboard; pipes get plain append-only records.
        if test $lanes -gt 1 -a $active -gt 1
            set -l now (date +%s)
            if test (math $now - $last_status) -ge 10
                set -l parts
                for i in (seq $lanes)
                    if test $lane_busy[$i] -eq 1 -a -n "$lane_start[$i]"
                        set -l lane_name (basename "$lane_pkg[$i]")
                        set -l elapsed_fmt (fmt_dur (math $now - $lane_start[$i]))
                        set -a parts "lane $i: $lane_name ($elapsed_fmt)"
                    end
                end
                if test (count $parts) -gt 0
                    if test "$_OUTPUT_INTERACTIVE" = "1"
                        set -g _DASHBOARD_LANE_BUSY $lane_busy
                        set -g _DASHBOARD_LANE_PKG $lane_pkg
                        set -g _DASHBOARD_LANE_START $lane_start
                        set -g _DASHBOARD_LAST_EVENT "status update"
                        render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
                    else
                        printf "  STATUS: %s\n" (string join " | " $parts)
                    end
                    set last_status $now
                end
            end
        end

        # Keep the interactive dashboard alive while a package is quiet:
        # refresh tails and advance the event spinner on every dispatcher poll.
        if test "$_OUTPUT_INTERACTIVE" = "1"; and test $active -gt 0
            set -g _DASHBOARD_SPINNER_INDEX (math "$_DASHBOARD_SPINNER_INDEX % 4 + 1")
            set -g _DASHBOARD_LANE_BUSY $lane_busy
            set -g _DASHBOARD_LANE_PKG $lane_pkg
            set -g _DASHBOARD_LANE_START $lane_start
            render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
        end

        sleep 0.5
    end

    finish_dashboard
    if test "$_OUTPUT_INTERACTIVE" = "1"; and test (count $failed) -gt 0
        for i in (seq (count $failed))
            set -l p $failed[$i]
            set -l rc $failed_rc[$i]
            set -l dur $failed_dur[$i]
            set -l log_file (package_log_file "$p")
            printf "  %s %s: BUILD FAILED (rc=%s, %s) — log: %s\n" \
                "$_UI_ICON_ERROR" $p $rc (fmt_dur $dur) "$log_file"
            ui_warning "Last lines:"
            print_log_tail "$log_file"
            if test $install_flag -eq 1
                ui_warning "(with -i the failure may be the INSTALL, not the build — check the log tail above; if the archive exists, install later with -ia or resume with -s -i)"
            end
        end
    end

    # Expose results to main (lane jobs are forked processes — the dispatcher
    # is the only writer of these globals).
    set -g _RL_SUCCEEDED $succeeded
    set -g _RL_FAILED $failed
    set -g _RL_BLOCKED $blocked
    if test (count $failed) -gt 0 -o "$blocked" -gt 0
        return 1
    end
    return 0
end

# ─── Usage ───────────────────────────────────────────────────────────────────
function usage
    echo "Usage: build-all.fish [MAIN OPTIONS] [PACKAGE|RANGE...]"
    echo ""
    echo "Build and optionally install packages from this workspace."
    echo ""
    echo "Main options:"
    echo "  -g, --group GRP   Build package group(s) — A SELECTION IS REQUIRED:"
    echo "                    git, stable, core, misc, third-party (or package names)."
    echo "                    Multiple groups: repeat the flag or comma-separate,"
    echo "                    e.g. -g git -g core  /  -g git,core"
    echo "                    core = heavyweight, source-heavy, ABI-critical, and ROCm packages;"
    echo "                    auto-enables -i (installs immediately, rule 11)"
    echo "  -l, --list        List all packages and their dependency order"
    echo "  -n, --dry-run     Show build order without building"
    echo "  -ia, --installall Install ALL built packages in the workspace (pacman -U);"
    echo "                    extra args are passed through to pacman, e.g.:"
    echo "                      build-all.fish -ia --overwrite '*'"
    echo "  -cc, --cleanup    Remove ALL built package archives (*.pkg.tar.zst)"
    echo "  -ccc, --nuclear   Remove pulled sources: src/pkg/build dirs, source git"
    echo "                    clones, and downloaded source tarballs (asks first)"
    echo "  --audit           Read-only report of legacy paths, package drift, and"
    echo "                    stale runtime/error artifacts"
    echo "  -ln, --link-sources"
    echo "                    Dedup git source clones: symlink twins to one"
    echo "                    canonical mirror; repair origin/refspec; asks first"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Build options (apply when a build is actually started):"
    echo "  -i, --install     Install each package IMMEDIATELY after it builds,"
    echo "                    in dependency order (pacman -U --noconfirm --ask 4 —"
    echo "                    unattended). Install failure aborts the run."
    echo "  -si, --sepinstall DEPRECATED alias for -i (identical behavior)"
    echo "  --no-deps         Build ONLY the named packages — skip dependency-chain"
    echo "                    expansion (leaf rebuild with known-current deps)"
    echo "  -c, --clean       Clean build artifacts before building"
    echo "  -s, --skip        Skip packages where .pkg.tar.zst is newer than PKGBUILD"
    echo "  --no-sync         Don't auto-update stable package versions from repos"
    echo "  --lanes N|auto     Run N makepkg lanes, or choose from CPU/RAM (default "(string join '' -- "$_DEFAULT_LANES")"). Interactive"
    echo "                    terminals get a compact dashboard with active log tails;"
    echo "                    pipes use plain output. Packages start as soon as deps are installed;"
    echo "                    core-group builds run solo with a memory-aware job limit."
    echo "  --jobs N|auto      Set jobs per normal lane, or derive it from CPU/RAM"
    echo "                    (default "(string join '' -- "$_DEFAULT_JOBS")")."
    echo "  --intensity LEVEL  Automatic resource profile: low, medium, high, xhigh,"
    echo "                    or max (default "(string join '' -- "$_DEFAULT_INTENSITY")")."
    echo "                    Explicit --lanes/--jobs override automatic profile values."
    echo "  --allow-broken-rustc"
    echo "                    Skip the rustc sanity probe (llvm-ABI-skew guard); only"
    echo "                    for runs that don't compile Rust"
    echo "  Environment: GSA_STATE_DIR, GSA_LANES, GSA_JOBS, GSA_INTENSITY,"
    echo "               GSA_CPU_THREADS, GSA_MEMORY_GIB, GSA_TARGET_CPU"
    echo "               override runtime state, parallelism, and optional CPU tuning."
    echo ""
    echo "Range syntax (requires a -g group or package selection):"
    echo "  22..38            Build packages 22 through 38 from the sorted list"
    echo "  22..              Build from package 22 to the end"
    echo "  ..15              Build from the start through package 15"
    echo ""
    echo "Examples:"
    echo "  build-all.fish -g git               Build top-level -git packages in dep order"
    echo "  build-all.fish -g git,core          Build git + core groups (deduped union)"
    echo "  build-all.fish -g core               Build core packages (auto-installs)"
    echo "  build-all.fish -g git -i            Same, installing each package as it finishes"
    echo "  build-all.fish -g git --lanes 2     Two parallel makepkg lanes over the git group"
    echo "  build-all.fish -g git --lanes 2 -i  Parallel lanes + immediate installs"
    echo "  build-all.fish --no-deps niri-spicy-git"
    echo "                                      Rebuild ONE package, skip its dep chain"
    echo "  build-all.fish niri-spicy-git       Rebuild it + its whole dep chain (llvm, rust,"
    echo "                                      mesa, ...) — use --no-deps to avoid this"
    echo "  build-all.fish -g git 22..38        Build packages 22-38 of the git group"
    echo "  build-all.fish -n -g core           Dry-run: show the core build order"
    echo "  build-all.fish -n                   Show full build order (dry run)"
    echo "  build-all.fish -ia --overwrite '*'  Same, passing pacman options through"
    echo "  build-all.fish -cc                  Delete all built package archives"
    echo "  build-all.fish -ccc                 Wipe pulled sources (src/pkg/build,"
    echo "                                      git clones, tarballs) — asks first"
    echo "  build-all.fish -ln                  Dedup git clones into shared mirrors"
    echo ""
    echo "Package groups:"
    echo "  git       Top-level -git packages ("(count $_GROUP_git)" packages)"
    echo "  stable    Stable/version-synchronized packages ("(count $_GROUP_stable)" packages)"
    echo "  core      Heavyweight, source-heavy, ABI-critical, and ROCm packages ("(count $_GROUP_core)" packages;"
    echo "            auto-installs and runs core builds solo)"
    echo "  misc      Auxiliary packages ("(count $_GROUP_misc)" packages)"
    echo "  third-party  Additional package recipes ("(count $_GROUP_third_party)" packages)"
end

# ─── List packages ───────────────────────────────────────────────────────────
function list_packages
    echo "All packages in dependency order:"
    echo ""
    set -l all_grouped (printf '%s\n' \
        $_GROUP_git $_GROUP_stable $_GROUP_core $_GROUP_misc $_GROUP_third_party \
        | awk '!seen[$0]++')
    set -l all_pkgs (topo_sort (string join ' ' $all_grouped))
    set -l i 1
    for pkg in $all_pkgs
        printf "  %2d. %s\n" $i $pkg
        set i (math $i + 1)
    end
    echo ""
    echo "Groups:"
    echo "  git:      "(count $_GROUP_git)" packages"
    echo "  stable:   "(count $_GROUP_stable)" packages"
    echo "  core:     "(count $_GROUP_core)" packages"
    echo "  misc:     "(count $_GROUP_misc)" packages"
    echo "  third-party: "(count $_GROUP_third_party)" packages"
end

# ─── Resolve one group name to its package list ──────────────────────────────
# Prints the package list; returns 1 for an unknown group. `-g core`
# additionally auto-enables -i in the caller (rule 11 — core rebuilds are
# only sound with immediate installs).
function resolve_group -a grp
    switch $grp
        case git
            printf '%s\n' $_GROUP_git
        case stable
            printf '%s\n' $_GROUP_stable
        case core
            printf '%s\n' $_GROUP_core
        case misc
            printf '%s\n' $_GROUP_misc
        case third-party third_party 3rdp
            printf '%s\n' $_GROUP_third_party
        case '*'
            ui_error "unknown group '$grp'"
            echo "Available groups: git, stable, core, misc, third-party"
            return 1
    end
    return 0
end

# ─── Main ────────────────────────────────────────────────────────────────────
function main
    set -l install_flag 0
    set -l clean_flag 0
    set -l skip_flag 0
    set -l no_sync_flag 0
    set -l no_deps_flag 0
    set -l dry_run 0
    set -l lane_count "$_DEFAULT_LANES"
    set -l jobs_override "$_DEFAULT_JOBS"
    set -l intensity_level "$_DEFAULT_INTENSITY"
    set -l allow_broken_rustc 0
    set -l groups
    set -l packages
    set -l ranges

    # Parse arguments
    set -l args $argv
    while test (count $args) -gt 0
        switch $args[1]
            case -i --install
                # Install each package IMMEDIATELY after it builds, in topo
                # order (pacman -U --noconfirm --ask 4). End-of-run collective
                # install was removed 2026-09-07: mid-run packages compiled
                # against the OLD installed deps (rust-git vs minimal
                # llvm-git incident) even with correct build order.
                set install_flag 1
            case -si --sepinstall
                # Deprecated alias — behavior unified with -i 2026-09-07.
                ui_warning "-si/--sepinstall is deprecated — now identical to -i (immediate per-package install)"
                set install_flag 1
            case -c --clean
                set clean_flag 1
            case -s --skip
                set skip_flag 1
            case --no-sync
                set no_sync_flag 1
            case --lanes
                if test (count $args) -lt 2
                    ui_error "--lanes requires an argument"
                    return 1
                end
                set -l invalid_lanes 0
                if test "$args[2]" != auto
                    if not string match -qr '^[0-9]+$' -- "$args[2]"; or test "$args[2]" -lt 1
                        set invalid_lanes 1
                    end
                end
                if test $invalid_lanes -eq 1
                    ui_error "--lanes expects a positive integer or auto, got '$args[2]'"
                    return 1
                end
                set lane_count $args[2]
                set -e args[2]
            case --jobs
                if test (count $args) -lt 2
                    ui_error "--jobs requires an argument"
                    return 1
                end
                set -l invalid_jobs 0
                if test "$args[2]" != auto
                    if not string match -qr '^[0-9]+$' -- "$args[2]"; or test "$args[2]" -lt 1
                        set invalid_jobs 1
                    end
                end
                if test $invalid_jobs -eq 1
                    ui_error "--jobs expects a positive integer or auto, got '$args[2]'"
                    return 1
                end
                set jobs_override $args[2]
                set -e args[2]
            case --intensity
                if test (count $args) -lt 2
                    ui_error "--intensity requires an argument"
                    return 1
                end
                if not intensity_is_valid "$args[2]"
                    ui_error "--intensity expects low, medium, high, xhigh, or max; got '$args[2]'"
                    return 1
                end
                set intensity_level $args[2]
                set -e args[2]
            case --allow-broken-rustc
                # Escape hatch for check_rustc_sanity — for the rare case where
                # the skew is known/handled and rustc isn't needed by this run.
                set allow_broken_rustc 1
            case --no-deps
                # Build ONLY the named packages — no dependency-chain expansion.
                # Leaf rebuilds where the deps are known current (e.g. niri
                # without dragging in llvm/rust/mesa).
                set no_deps_flag 1
            case -n --dry-run
                set dry_run 1
            case -l --list
                list_packages
                return 0
            case -g --group
                if test (count $args) -lt 2
                    ui_error "--group requires an argument"
                    return 1
                end
                # Multiple groups: repeat the flag (-g git -g core) or
                # comma-separate (-g git,core). Deduped after parsing.
                for g in (string split ',' $args[2])
                    set -a groups $g
                end
                set -e args[2]
            case -h --help
                usage
                return 0
            case -ia --installall
                # Act immediately; everything after -ia is forwarded to pacman
                install_all $args[2..-1]
                return
            case -cc --cleanup
                # Act immediately; other options are ignored
                cleanup_pkgs
                return
            case -ccc --nuclear
                # Act immediately; other options are ignored
                nuclear_cleanup
                return
            case -ln --link-sources
                # Act immediately; other options are ignored. Git ops must run
                # as the user — root-owned .git files would break later builds.
                if test "$_ROOT_MODE" = "1"
                    ui_error "-ln does git operations — run it unprivileged (no sudo)."
                    return 1
                end
                if not require_command git
                    return 1
                end
                link_sources
                return
            case --audit
                audit_workspace
                return
            case '-*'
                ui_error "unknown option: $args[1]"
                usage
                return 1
            case '*..*'
                # Range syntax: 22..38, 22.., ..15
                set -a ranges $args[1]
            case '*'
                set -a packages $args[1]
        end
        set -e args[1]
    end

    # Determine packages to build — a selection is MANDATORY. The old default
    # (no options = build everything) was removed 2026-09-07: an unattended
    # full rebuild is exactly how the rust/llvm ABI break happened.
    set -l build_list
    if test (count $packages) -gt 0
        set -l canonical_packages
        for pkg in $packages
            set -a canonical_packages (canonicalize_pkg_ref "$pkg")
        end
        set packages $canonical_packages
    end
    if test (count $groups) -gt 0
        # Resolve every selected group; dedupe overlapping selections.
        set -l groups_dedup (printf '%s\n' $groups | awk '!seen[$0]++')
        for g in $groups_dedup
            set -l gl (resolve_group $g)
            if test $status -ne 0
                return 1
            end
            if test "$g" = core; and test $install_flag -eq 0
                # Rule 11: core rebuilds are only sound with immediate
                # installs — later packages must compile against freshly
                # installed core dependencies, not old ABIs in the system.
                set install_flag 1
                ui_warning "-g core: enabling -i (immediate per-package install) — core rebuilds without installs compile against old ABIs"
            end
            set build_list $build_list $gl
        end
        # Positional packages may be combined with groups
        if test (count $packages) -gt 0
            for pkg in $packages
                set -l pkg_path (package_path "$pkg")
                if test -z "$pkg_path"; or not test -f "$pkg_path/PKGBUILD"
                    ui_error "package recipe not found for ID '$pkg'"
                    return 1
                end
            end
            if test $no_deps_flag -eq 1
                set build_list $build_list $packages
            else
                set -l expanded (expand_deps $packages)
                if test $status -ne 0
                    return 1
                end
                set build_list $build_list $expanded
            end
        end
        set build_list (printf '%s\n' $build_list | awk '!seen[$0]++')
    else if test (count $packages) -gt 0
        # Validate specified packages
        for pkg in $packages
            set -l pkg_path (package_path "$pkg")
            if test -z "$pkg_path"; or not test -f "$pkg_path/PKGBUILD"
                ui_error "package recipe not found for ID '$pkg'"
                return 1
            end
        end
        # Expand to include transitive local dependencies — unless --no-deps:
        # build exactly the named packages (leaf rebuild with known-current deps).
        if test $no_deps_flag -eq 1
            set build_list $packages
        else
            set -l expanded (expand_deps $packages)
            if test $status -ne 0
                return 1
            end
            set build_list $expanded
        end
    else
        ui_error "no packages selected — pass -g GROUP and/or package names"
        echo "Groups: git, stable, core, misc, third-party   (see -h for examples)"
        return 1
    end

    # Topological sort
    set -l sorted (topo_sort (string join ' ' $build_list))
    if test (count $_TOPO_BLOCKED) -gt 0
        ui_error "selection contains a dependency cycle or unresolved dependency"
        for pkg in $_TOPO_BLOCKED
            echo "  blocked: $pkg"
        end
        return 1
    end

    # Apply range filters (e.g. 22..38, 22.., ..15)
    set -l range_offset 0
    set -l range_end 0
    if test (count $ranges) -gt 0
        set -l total (count $sorted)
        set -l indices
        for range in $ranges
            set -l parts (string split '..' $range)
            set -l start $parts[1]
            set -l end $parts[2]
            if test -z "$start"
                set start 1
            end
            if test -z "$end"
                set end $total
            end
            # Clamp to valid range
            if test $start -lt 1
                set start 1
            end
            if test $end -gt $total
                set end $total
            end
            for i in (seq $start $end)
                set -a indices $i
            end
        end
        # Deduplicate indices and sort
        set -l unique_indices (printf '%s\n' $indices | sort -nu)
        set -l filtered
        # Track offset and end for resume suggestions
        set range_offset (math (printf '%s\n' $unique_indices | head -1) - 1)
        set range_end (printf '%s\n' $unique_indices | tail -1)
        for i in $unique_indices
            set -a filtered $sorted[$i]
        end
        set sorted $filtered
    end

    if test (count $sorted) -eq 0
        ui_error "selection resolved to no packages"
        return 1
    end

    # Dry run
    if test "$dry_run" = "1"
        echo "Build order (dry run):"
        echo ""
        set -l i 1
        for pkg in $sorted
            printf "  %2d. %s\n" $i $pkg
            set i (math $i + 1)
        end
        echo ""
        echo "Total: "(count $sorted)" packages"
        return 0
    end

    # Build
    ui_heading "Workspace Package Builder"
    echo "Packages: "(count $sorted)
    echo "Install:  "(test "$install_flag" = "1"; and echo "yes"; or echo "no")
    echo "Clean:    "(test "$clean_flag" = "1"; and echo "yes"; or echo "no")
    echo "Lanes:    $lane_count"
    echo "Jobs:     $jobs_override (normal lanes; auto uses CPU/RAM)"
    echo "Intensity: $intensity_level"
    if test "$_ROOT_MODE" = "1"
        echo "User:     root (supervisor) — builds as $_BUILD_USER, installs as root"
    else
        echo "User:     $_BUILD_USER (installs via sudo, keepalive 150 s)"
    end
    echo "State:    $_STATE_DIR"
    echo ""

    if test "$_ROOT_MODE" != "1"; and test "$install_flag" = "1"
        # -- separator: args start with flags (-g …), which string join would
        # otherwise parse as its own options
        set -l rerun_args --lanes "$lane_count" --jobs "$jobs_override" --intensity "$intensity_level" --install
        set -a rerun_args $argv
        set -l rerun_prefix (set_color yellow)
        set -l rerun_suffix (set_color normal)
        echo "$rerun_prefix$_UI_ICON_INFO unprivileged run: for -i runs that will take longer than ~15 min, prefer:$rerun_suffix"
        echo "  sudo fish $SCRIPT_DIR/build-all.fish "(string join ' ' -- $rerun_args)""
        echo "  (makepkg still builds as YOU — only the installs gain root; no password expiry)"(set_color normal)
        echo ""
    end

    if not mkdir -p "$LOG_DIR"
        ui_error "cannot create log directory: $LOG_DIR"
        return 1
    end

    # Preflight: rustc sanity probe (llvm snapshot ABI-skew guard). Skipped on
    # dry runs — they build nothing. Bypass with --allow-broken-rustc.
    if test $allow_broken_rustc -eq 0
        if not check_rustc_sanity
            return 1
        end
    end
    if test "$_INTERRUPT_HANDLED" = "1"
        printf '\n'
        ui_warning "Build interrupted"
        return 130
    end

    # Parallel lane dispatcher (--lanes 1 = strict topo order, the old
    # sequential semantics). Installs happen inside lanes in readiness
    # order; a dependent never starts before all its deps are installed.
    run_lanes $lane_count $jobs_override $intensity_level $install_flag $clean_flag \
        $skip_flag $no_sync_flag $sorted
    set -l run_rc $status
    set -l succeeded $_RL_SUCCEEDED
    set -l failed $_RL_FAILED
    set -l blocked $_RL_BLOCKED

    if test "$_RL_INTERRUPTED" = "1"
        return 130
    end

    echo ""
    if test $run_rc -eq 0
        ui_heading "All builds succeeded!"
        echo "Built: "(count $succeeded)" packages"

        # With -i every package was installed right after its build, so there
        # is no collective end-install step anymore.
        return 0
    end

    # Failure summary — dispatch stopped on first failure and in-flight lanes
    # were drained, so anything unstarted is genuinely pending. With -i
    # everything built so far is ALREADY installed (resume with -s -i).
    set -l remaining
    for pkg in $sorted
        if not contains "$pkg" $succeeded; and not contains "$pkg" $failed
            set -a remaining $pkg
        end
    end
    ui_error "Build failed — stopped dispatching, drained in-flight lanes."
    echo ""
    echo "Successful builds: "(count $succeeded)
    echo "Failed builds:     "(count $failed)
    echo "Blocked:           $blocked"
    echo "Remaining:         "(count $remaining)
    if test (count $remaining) -gt 0
        echo ""
        echo "To resume, run:"
        echo "  build-all.fish --lanes $lane_count --jobs $jobs_override --intensity $intensity_level "(string join ' ' $remaining)""
        echo "(Tip: add -s so already-built pkgs are skipped.)"
    end
    return 1
end

if not load_project_config
    ui_error "project configuration is invalid under $CONFIG_DIR"
    exit 1
end

if test (count $argv) -gt 0; and test "$argv[1]" = --lane-job
    if test (count $argv) -ne 8
        echo "Error: --lane-job expects package, result file, job count, and four flags" >&2
        exit 2
    end
    if not string match -qr '^[1-9][0-9]*$' -- "$argv[4]"
        echo "Error: --lane-job received an invalid job count: $argv[4]" >&2
        exit 2
    end
    for flag in $argv[5..8]
        if not string match -qr '^[01]$' -- "$flag"
            echo "Error: --lane-job received an invalid flag: $flag" >&2
            exit 2
        end
    end
    lane_job "$argv[2]" "$argv[3]" "$argv[4]" "$argv[5]" "$argv[6]" "$argv[7]" "$argv[8]"
    exit $status
end

# ─── Signal handling ─────────────────────────────────────────────────────────
function handle_interrupt --on-signal INT --on-signal TERM
    set -g _INTERRUPT_HANDLED 1
end

main $argv
