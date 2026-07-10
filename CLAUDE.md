# ITensorActions

Reusable GitHub Actions workflows shared across the ITensor Julia packages. Caller
repos pin these workflows at the major-version tag (e.g.
`ITensor/ITensorActions/.github/workflows/Tests.yml@v2`).

## Releasing (required after any behavior change)

Callers consume these workflows at the mutable `v2` tag, which does **not** follow
`main`. A change merged to `main` therefore reaches no caller until a release moves
`v2`. So after merging a PR that changes workflow behavior, cut a release:

- Run `.scripts/release.sh vX.Y.Z` from a clean `main` checkout. It tags the new
  version and moves the `v2` pointer to it (and pins the released commit's internal
  `@main` action references to a fixed SHA so the release is a stable bundle).
- Choose the bump per the SemVer rule in the README ("Versioning" section): patch
  for fixes or internal hardening, minor for additive behavior or new inputs, major
  for breaking caller-facing changes.
- Docs-only PRs (including edits to this file) need no release and must not move
  `v2`.
