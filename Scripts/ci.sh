#!/usr/bin/env bash
# Starts the CI workflow on GitHub and follows it until it finishes.
#
# Usage: Scripts/ci.sh [branch] [debug|release]
#   branch         defaults to the current branch (it must be pushed)
#   configuration  defaults to debug
set -euo pipefail

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
CONFIGURATION="${2:-debug}"

case "${CONFIGURATION}" in
  debug|release) ;;
  *) echo "usage: Scripts/ci.sh [branch] [debug|release]" >&2; exit 1 ;;
esac

if ! git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null; then
  echo "Branch '${BRANCH}' is not on GitHub. Push it first: git push -u origin ${BRANCH}" >&2
  exit 1
fi

gh workflow run ci.yml --ref "${BRANCH}" -f configuration="${CONFIGURATION}"
echo "Started CI (${CONFIGURATION}) on ${BRANCH}."

# The run takes a moment to show up in the list.
sleep 5
RUN_ID="$(gh run list --workflow ci.yml --branch "${BRANCH}" --event workflow_dispatch \
  --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "${RUN_ID}" --exit-status
