#!/usr/bin/env bash
# Sets the app version everywhere it is baked in.
#
# The VERSION file at the repository root is the single source of truth: this
# script writes it, and the release workflow checks the tag against it.
#
# Usage: Scripts/set-version.sh 1.3.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

VERSION="${1:-}"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Scripts/set-version.sh <major.minor.patch>   (got: '${VERSION}')" >&2
  exit 1
fi

echo "${VERSION}" > VERSION

echo "Version set to ${VERSION}: VERSION"
echo
echo "Next: commit, then tag v${VERSION} to publish the release."
