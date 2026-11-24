#!/bin/bash
set -euo pipefail

expected=$'Xcode 27.2\nBuild version 27B52'
actual=$(xcodebuild -version)
if [[ "$actual" != "$expected" ]]; then
  printf 'Expected the release toolchain:\n%s\nFound:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi
printf '%s\n' "$actual"

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
