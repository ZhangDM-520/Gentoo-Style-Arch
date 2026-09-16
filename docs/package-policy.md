# Package policy

Each package directory is a small recipe module:

- `PKGBUILD` is the source of truth.
- `.SRCINFO` is committed metadata generated from that recipe.
- Local patches, hooks, install scripts, desktop files, configuration
  snippets, licenses, and readmes are retained when the recipe needs them.
- Remote Git repositories, release archives, signatures, key caches, source
  trees, package output, and build state are fetched or generated at build
  time and are not vendored.

Keep package-local upstream attribution and licenses. The root MIT license
does not relicense package recipes or bundled upstream material.

When trimming a recipe, remove the corresponding dead `makedepends`,
`depends`, split package, `_pick`, install, and check paths together. A
feature disabled in `build()` must not leave a packaging step that expects its
output. Validate with `bash -n` and `makepkg --printsrcinfo`.
