#!/usr/bin/env bash
# Publishes a release: starts the Release workflow on main, which builds both
# archives, creates the vX.Y.Z tag on main's head and attaches the zips.
#
# Usage: Scripts/release.sh X.Y.Z [--draft] [--prerelease]
#
# Before running it, main must already carry the version:
#   Scripts/set-version.sh X.Y.Z, a "## [X.Y.Z]" section in CHANGELOG.md,
#   merged into main.
set -euo pipefail

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Scripts/release.sh X.Y.Z [--draft] [--prerelease]" >&2
  exit 1
fi
shift

DRAFT=false
PRERELEASE=false
for arg in "$@"; do
  case "${arg}" in
    --draft) DRAFT=true ;;
    --prerelease) PRERELEASE=true ;;
    *) echo "unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

# Catch the usual mistakes here rather than ten minutes into the run.
git fetch -q origin main
REMOTE_VERSION="$(git show origin/main:VERSION)"
if [ "${REMOTE_VERSION}" != "${VERSION}" ]; then
  echo "main has VERSION ${REMOTE_VERSION}, not ${VERSION}. Run Scripts/set-version.sh ${VERSION} and merge it first." >&2
  exit 1
fi
# Read the file first: `git show | grep -q` makes git die of SIGPIPE when grep
# stops at the first match, and pipefail then reports a missing section.
CHANGELOG="$(git show origin/main:CHANGELOG.md)"
if ! grep -q "^## \[${VERSION}\]" <<< "${CHANGELOG}"; then
  echo "CHANGELOG.md on main has no '## [${VERSION}]' section." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/v${VERSION}" >/dev/null; then
  echo "v${VERSION} is already released." >&2
  exit 1
fi

gh workflow run release.yml --ref main \
  -f version="${VERSION}" -f draft="${DRAFT}" -f prerelease="${PRERELEASE}"
echo "Started the release of ${VERSION}."

sleep 5
RUN_ID="$(gh run list --workflow release.yml --event workflow_dispatch \
  --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "${RUN_ID}" --exit-status
gh release view "v${VERSION}" --json url --jq .url
