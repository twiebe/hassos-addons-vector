#!/usr/bin/env bash
# Wait for the GitHub Actions run of <workflow> on <sha> to finish and fail if it failed.
#
# usage: wait-build.sh <workflow file> <sha>
set -euo pipefail

workflow=$1
sha=$2

if ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated, not waiting for $workflow (run 'gh auth login')"
  exit 0
fi

echo "Waiting for $workflow run on ${sha:0:7}..."
for _ in $(seq 1 30); do
  id=$(gh run list --workflow "$workflow" --commit "$sha" --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$id" ] && break
  sleep 5
done

if [ -z "${id:-}" ]; then
  echo "No $workflow run found for ${sha:0:7}" >&2
  exit 1
fi

gh run watch "$id" --exit-status
