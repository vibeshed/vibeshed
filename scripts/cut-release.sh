#!/usr/bin/env bash
# Cut a release from origin/main: tag it, wait for the Release workflow (which
# publishes the GitHub Release and updates the website, cask template and
# project.yml on main), then copy the cask to the Homebrew tap.
#
# Safe to rerun with the same version: it picks up wherever the last run stopped.
#
# Usage: scripts/cut-release.sh 0.2.0

set -euo pipefail

REPO="vibeshed/vibeshed"
TAP="idmitriev/homebrew-tap"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>  e.g. $0 0.2.0" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "Version must be semver (e.g. 0.2.0 or 0.2.0-rc1), got: $VERSION" >&2
  exit 1
fi

TAG="v${VERSION}"

git fetch --quiet origin main
git fetch --quiet --tags origin

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists, resuming."
else
  CI_RUN=$(gh run list --repo "$REPO" --workflow CI --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
  echo "Checking CI on main..."
  if ! gh run watch "$CI_RUN" --repo "$REPO" --exit-status >/dev/null; then
    echo "CI on main is red: https://github.com/$REPO/actions/runs/$CI_RUN" >&2
    exit 1
  fi

  echo "Tagging $TAG at $(git rev-parse --short origin/main)..."
  git tag -a "$TAG" -m "Release $TAG" origin/main
  git push --quiet origin "refs/tags/$TAG"
fi

RUN=""
for _ in {1..30}; do
  RUN=$(gh run list --repo "$REPO" --workflow Release --branch "$TAG" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [[ -n "$RUN" ]] && break
  sleep 2
done
if [[ -z "$RUN" ]]; then
  echo "No Release run appeared for $TAG." >&2
  exit 1
fi

echo "Waiting for the Release workflow: https://github.com/$REPO/actions/runs/$RUN"
if ! gh run watch "$RUN" --repo "$REPO" --exit-status >/dev/null; then
  echo "Release workflow failed. Fix it, then:" >&2
  echo "  gh run rerun $RUN --repo $REPO --failed" >&2
  echo "  $0 $VERSION" >&2
  exit 1
fi

if [[ "$VERSION" == *-* ]]; then
  echo "Prerelease $TAG published. The website and Homebrew stay on the last stable release."
  exit 0
fi

CASK=$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/scripts/Casks/vibeshed.rb")
DIGEST=$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name == \"Vibeshed-$VERSION.zip\") | .digest")
if ! grep -q "version \"$VERSION\"" <<<"$CASK" || ! grep -q "sha256 \"${DIGEST#sha256:}\"" <<<"$CASK"; then
  echo "Cask on main doesn't match $TAG (asset digest: $DIGEST). Not touching the tap." >&2
  exit 1
fi

CASK_BLOB=$(gh api "repos/$REPO/contents/scripts/Casks/vibeshed.rb" --jq .sha)
TAP_BLOB=$(gh api "repos/$TAP/contents/Casks/vibeshed.rb" --jq .sha)
if [[ "$CASK_BLOB" == "$TAP_BLOB" ]]; then
  echo "Homebrew tap already at $VERSION."
else
  gh api --silent -X PUT "repos/$TAP/contents/Casks/vibeshed.rb" \
    -f message="vibeshed $VERSION" \
    -f content="$(base64 <<<"$CASK" | tr -d '\n')" \
    -f sha="$TAP_BLOB"
  echo "Homebrew tap updated."
fi

echo "Released: https://github.com/$REPO/releases/tag/$TAG"
