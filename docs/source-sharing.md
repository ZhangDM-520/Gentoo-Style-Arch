# Shared source mirrors

`build-all.fish --link-sources` scans the `git+` entries in every `PKGBUILD`,
groups them by effective URL, and points duplicate local source names at one
canonical runtime mirror. Core paths are preferred for heavy shared sources.

The operation:

- accepts only a real Git working clone or bare mirror as an existing
  canonical source;
- repairs an origin URL or missing fetch refspec when safe;
- replaces stale empty directories but never overwrites a populated
  non-Git directory;
- preserves a missing canonical path as a dangling symlink so the first
  canonical build can populate it;
- asks before deleting duplicate clones and their dependent working copies.

Mirrors and symlinks are runtime state. They are intentionally absent from a
clean checkout and must remain ignored. Run source linking as the build user,
not under a root supervisor.
