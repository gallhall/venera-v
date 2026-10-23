#!/usr/bin/env bash
# Writes the version of a release tag into pubspec.yaml and app.dart, so a
# release is built with the version of its tag.
#
# Usage: set_version.sh v2.0.1
#
# The build number is major * 100 + minor * 10 + patch, as pubspec.yaml has
# always used (2.0.1 -> 201). That only stays increasing while minor and
# patch are single digits, so other tags are refused.
set -euo pipefail

tag="${1:-}"
if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9])\.([0-9])$ ]]; then
  echo "Release tag must look like v2.0.1 (minor and patch 0-9), got '$tag'" >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
version="$major.$minor.$patch"
build=$((major * 100 + minor * 10 + patch))

root="$(cd "$(dirname "$0")/../.." && pwd)"
pubspec="$root/pubspec.yaml"
app="$root/lib/foundation/app.dart"

# perl rather than sed -i, which differs between the macOS and Linux runners.
perl -pi -e "s/^version: .*/version: $version+$build/" "$pubspec"
perl -pi -e "s/final version = \"[^\"]*\";/final version = \"$version\";/" "$app"

grep -q "^version: $version+$build\$" "$pubspec" \
  || { echo "Could not set the version in pubspec.yaml" >&2; exit 1; }
grep -q "final version = \"$version\";" "$app" \
  || { echo "Could not set the version in app.dart" >&2; exit 1; }
echo "Version $version+$build"
