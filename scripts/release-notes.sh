#!/usr/bin/env bash
# Print the "## <version>" section of the vector-dev changelog on hassos-addons main.
# Fails if the section is missing or empty, so a release never goes out without notes.
#
# usage: release-notes.sh <addons repo> <version>
set -euo pipefail

repo=$1
version=$2

notes=$(gh api "repos/$repo/contents/vector-dev/CHANGELOG.md?ref=main" -H "Accept: application/vnd.github.raw" |
  awk -v h="## $version" '
    $0 == h { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

if [ -z "$notes" ]; then
  echo "ERROR: no entries under '## $version' in $repo vector-dev/CHANGELOG.md on main" >&2
  exit 1
fi

echo "$notes"
