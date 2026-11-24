#!/bin/bash
set -euo pipefail

actual=$(xcodebuild -version)
printf '%s\n' "$actual"
version_line=${actual%%$'\n'*}
build_line=${actual#*$'\n'}
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
if [[ ! "$version_line" =~ ^Xcode[[:space:]]([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
  printf 'Expected a release Xcode version.\n' >&2
  exit 1
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
if [[ ! "$build_line" =~ ^Build[[:space:]]version[[:space:]][0-9]+[A-Z][0-9]+$ ||
      "$developer_dir" =~ [Bb][Ee][Tt][Aa]|[Pp][Rr][Ee][Vv][Ii][Ee][Ww]|-[Rr][Cc] ||
      "$major" -lt 27 || ( "$major" -eq 27 && "$minor" -lt 2 ) ]]; then
  printf 'Expected release Xcode 27.2 or later.\n' >&2
  exit 1
fi

if [[ -z "${CI_TAG:-}" ]]; then
  exit 0
fi

version=${CI_TAG#v}
if [[ ! "$CI_TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  printf 'Expected a release tag such as v1.2.3. Found %s.\n' "$CI_TAG" >&2
  exit 1
fi

project="$(dirname "$0")/../BillBandit.xcodeproj/project.pbxproj"
if ! awk -v version="$version" '
  /PRODUCT_BUNDLE_IDENTIFIER = com.billbandit.app;/ && previous == "MARKETING_VERSION = " version ";" { matches++ }
  { previous = $0; sub(/^[[:space:]]*/, "", previous) }
  END { exit matches != 2 }
' "$project"; then
  printf 'Release tag %s must match both app marketing versions in the project.\n' "$CI_TAG" >&2
  exit 1
fi
