# lib/pgo.sh — the one PGO payload-verification gate.
#
# Sourced by each PGO recipe's PKGBUILD:
#
#     source "$startdir/../../../lib/pgo.sh"
#
# and called as the LAST statement of every package function, against that
# function's own staged payload (a split recipe gates each `package_*`
# function's `$pkgdir`):
#
#     verify_no_profile_instrumentation "$pkgdir" [extra-literal...]
#
# One implementation on purpose. The seven per-recipe copies had already
# drifted (mold-git carried stricter predicates than the rest) and mandated
# copy-paste was itself the recurrence engine of the 2026-09-20
# instrumented-archive incident. A new PGO family extends THIS module and
# earns a fixture (tests/pgo-lib.sh pins the behaviour here); recipes only
# ever call it. A missing file fails loudly at PKGBUILD parse time — desired:
# a clean checkout must never build a PGO recipe without the gate.
#
# Fatal gate, deliberately: any hit prints the offending binary plus the
# predicate that matched, then calls `exit 1`, which kills makepkg's function
# subshell and fails the build. The `|| return 1` convention this replaces was
# unenforceable: bash returns the status of a function's LAST command, so a
# bare mid-body call whose failure a later command overwrote was silently
# discarded — the mechanism behind "guards" that never guarded anything.
# `exit` cannot be discarded.
#
# Call it at the END of the package function: nothing may be added to the
# payload after the gate runs, and the symbol predicate is only meaningful
# before makepkg strips.
#
# Two predicates per candidate file, because they cover different artifacts:
#   * `readelf -sW` — `__gcov_*` / `__llvm_profile*` instrumentation symbols.
#     Sound only pre-strip.
#   * `strings -a` — absolute `.gcda`/`.profraw` destinations baked into
#     .rodata. The only evidence that survives stripping, so an installed
#     binary stays auditable (measured 2026-09-19: readelf reported clean on
#     a stripped Xwayland while strings found all 348 baked paths).
# Extra literal arguments (e.g. mold-git's `pgo-data` profile work directory)
# are matched verbatim with `strings`, for destinations that carry no suffix.

_pgo_fail() {
  if declare -F error >/dev/null 2>&1; then
    error "$*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

verify_no_profile_instrumentation() {
  local _root="$1"
  shift
  local _binary _extra
  local _who="${pkgbase:-${pkgname[0]:-package}}"
  while IFS= read -r -d '' _binary; do
    if readelf -sW "$_binary" 2>/dev/null | grep -Eq '__gcov_|__llvm_profile'; then
      _pgo_fail "$_who: final payload still contains profile instrumentation ($_binary; readelf symbol predicate)"
    fi
    # The char class excludes `/` and `*` for a reason: ctest legitimately
    # ships the glob literal `/*.gcda` in its own GCOV support, and a glob is
    # not a baked destination. Without the exclusion a correctly rebuilt
    # cmake-git fails its own guard.
    if strings -a "$_binary" 2>/dev/null | grep -qE '^/[^[:space:]/*][^[:space:]]*\.(gcda|profraw)'; then
      _pgo_fail "$_who: final payload still carries baked profile destinations ($_binary; strings path predicate)"
    fi
    for _extra in "$@"; do
      if strings -a "$_binary" 2>/dev/null | grep -qF "$_extra"; then
        _pgo_fail "$_who: final payload still carries the PGO work directory literal '$_extra' ($_binary; strings literal predicate)"
      fi
    done
  done < <(find "$_root" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0)
}
