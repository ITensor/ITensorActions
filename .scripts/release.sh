#!/usr/bin/env bash
#
# release.sh — tag a versioned release of the ITensorActions reusable
# workflows and composite actions.
#
# Usage:
#   .scripts/release.sh vX.Y.Z
#
# What it does:
#   1. Verifies the working tree is clean and we are on `main`.
#   2. Verifies the requested tag does not already exist.
#   3. On a detached HEAD off the current `main`, rewrites every
#      internal `ITensor/ITensorActions/.github/{workflows,actions}/...@main`
#      reference to point at the current `main` commit's SHA. This way
#      `@vX.Y.Z` callers get a consistent snapshot — the workflow file
#      they fetch has its own internal `uses:` lines pinned to a fixed
#      SHA rather than a moving `@main`.
#   4. Commits the rewrite (the rewrite commit is reachable only via
#      the tag — `main` itself stays unmodified, so day-to-day
#      development continues to use `@main`).
#   5. Tags the rewrite commit as `vX.Y.Z` (annotated, immutable).
#   6. Updates the mutable major-version tag (`vX`) to point at the
#      same commit, so callers can pin `@vX` for "latest in this
#      major version".
#   7. Prints the push commands; nothing is pushed automatically.
#
# Why this exists:
#   GitHub Actions resolves `uses:` references at workflow-execution
#   time. A reusable workflow tagged `v1.0.0` whose own internal
#   references say `@main` would still inherit whatever is on `main`
#   today, defeating the point of versioning. The rewrite step pins
#   those internal references at release time so the tagged release
#   is fully snapshot-stable.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 vX.Y.Z" >&2
  exit 2
fi

VERSION="$1"

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version: '$VERSION' (expected vN.N.N)" >&2
  exit 2
fi

MAJOR_VERSION="${VERSION%%.*}"  # strips ".Y.Z" → "vX"

# Verify clean working tree.
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit, stash, or revert before releasing." >&2
  exit 2
fi

# Verify on main.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "Must be on 'main', not '$CURRENT_BRANCH'." >&2
  exit 2
fi

# Verify tag does not already exist.
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Tag '$VERSION' already exists." >&2
  exit 2
fi

HEAD_SHA="$(git rev-parse HEAD)"
echo "Tagging $VERSION; internal refs will be pinned at $HEAD_SHA."

# Work on a detached HEAD so the rewrite commit doesn't pollute main.
git checkout --quiet --detach HEAD

# Rewrite internal `@main` refs in workflows and composite actions.
shopt -s nullglob
files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find .github/workflows .github/actions \
  -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)

rewritten=0
for f in "${files[@]}"; do
  if grep -qE 'ITensor/ITensorActions/\.github/(workflows|actions)/[^@[:space:]]+@main' "$f"; then
    # macOS sed needs `-i ''`; GNU sed accepts `-i` alone. Using `-i.bak`
    # is the most portable form.
    sed -E -i.bak \
      "s#(ITensor/ITensorActions/\\.github/(workflows|actions)/[^@[:space:]]+)@main#\\1@${HEAD_SHA}#g" \
      "$f"
    rm "$f.bak"
    rewritten=$((rewritten + 1))
    echo "  pinned internal refs in $f"
  fi
done

if [ "$rewritten" -gt 0 ]; then
  git add .github
  git commit --quiet -m "Pin internal references for $VERSION release"
fi

# Tag (annotated for the immutable release, lightweight for the major tag).
git tag -a "$VERSION" -m "Release $VERSION"

if git rev-parse "$MAJOR_VERSION" >/dev/null 2>&1; then
  echo "Updating existing $MAJOR_VERSION mutable tag."
  git tag -d "$MAJOR_VERSION" >/dev/null
fi
git tag "$MAJOR_VERSION"

# Return to the main branch so the rewrite commit is reachable only
# via the tags.
git checkout --quiet main

echo
echo "Created locally:"
echo "  $VERSION         (annotated, immutable)"
echo "  $MAJOR_VERSION              (lightweight, mutable; points at $VERSION)"
echo
echo "Push with:"
echo "  git push origin $VERSION"
echo "  git push --force origin $MAJOR_VERSION   # mutable tag intentionally moves"
