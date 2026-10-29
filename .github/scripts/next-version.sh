#!/usr/bin/env bash
# Computes the next SemVer from Conventional Commits since the last vX.Y.Z tag.
#   feat!: / BREAKING CHANGE  -> major
#   feat:                     -> minor
#   fix: / perf:              -> patch
#   anything else (docs:, chore:, ci:, ...) -> no release
# No tag yet -> first release = version in package.json.
# Outputs (GITHUB_OUTPUT): version, release (true|false), previous (last tag or empty)
set -euo pipefail

last=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)

if [ -z "$last" ]; then
  version=$(node -p "require('./package.json').version")
  bump="initial"
else
  IFS=. read -r major minor patch <<< "${last#v}"
  log=$(git log --format='%s%n%b' "$last..HEAD")
  if   grep -qE '^[a-z]+(\([^)]*\))?!:|BREAKING[ -]CHANGE' <<< "$log"; then bump=major; major=$((major+1)); minor=0; patch=0
  elif grep -qE '^feat(\([^)]*\))?:' <<< "$log";                       then bump=minor; minor=$((minor+1)); patch=0
  elif grep -qE '^(fix|perf)(\([^)]*\))?:' <<< "$log";                 then bump=patch; patch=$((patch+1))
  else bump=none
  fi
  version="$major.$minor.$patch"
fi

is_main_push=false
[ "${GITHUB_EVENT_NAME:-}" = "push" ] && [ "${GITHUB_REF:-}" = "refs/heads/main" ] && is_main_push=true

release=false
if [ "$bump" != "none" ] && [ "$is_main_push" = true ]; then
  release=true
else
  # Not a release: label the build as a pre-release of the would-be version (git-describe style)
  sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
  version="$version-dev.g${sha:0:7}"
fi

echo "last tag: ${last:-<none>}  bump: $bump  release: $release  version: $version"
{
  echo "version=$version"
  echo "release=$release"
  echo "previous=$last"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
