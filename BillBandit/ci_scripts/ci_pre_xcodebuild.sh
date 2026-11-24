#!/bin/bash
set -euo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != test-without-building || -z "${BILLBANDIT_UI_FIXTURE_DIR:-}" ]]; then
  exit 0
fi

if [[ "$BILLBANDIT_UI_FIXTURE_DIR" != /tmp/billbandit-ui-fixtures || ! "${CI_COMMIT:-}" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'Set BILLBANDIT_UI_FIXTURE_DIR=/tmp/billbandit-ui-fixtures and run a source revision.' >&2
  exit 1
fi

umask 077
work=$(mktemp -d)
source="$work/repository"
git init -q "$source"
git -C "$source" fetch --depth=1 https://github.com/My-apps-factory/BillBandit.git "$CI_COMMIT"
git -C "$source" checkout --quiet FETCH_HEAD
test "$(git -C "$source" rev-parse HEAD)" = "$CI_COMMIT"

# The scripts run under Bun, but the Next.js and Prisma CLIs start with
# `#!/usr/bin/env node`, so the Next dev server still needs Node on PATH.
if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) < 22 ? 1 : 0)'; then
  brew install node@22
  export PATH="$(brew --prefix node@22)/bin:$PATH"
fi
if ! command -v pg_config >/dev/null || [[ ! -x "$(pg_config --bindir)/initdb" ]]; then
  brew install postgresql@16
  export PATH="$(brew --prefix postgresql@16)/bin:$PATH"
fi
if ! command -v bun >/dev/null || [[ "$(bun --version)" != 1.3.14 ]]; then
  case "$(uname -m)" in
    arm64) bun_platform=darwin-aarch64; digest=d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620 ;;
    x86_64) bun_platform=darwin-x64; digest=4183df3374623e5bab315c547cfa0974533cd457d86b73b639f7a87974cd6633 ;;
    *) echo 'Unsupported Xcode Cloud architecture.' >&2; exit 1 ;;
  esac
  bun_zip="$work/bun.zip"
  curl --fail --silent --show-error --location \
    "https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/bun-${bun_platform}.zip" -o "$bun_zip"
  printf '%s  %s\n' "$digest" "$bun_zip" | shasum -a 256 -c -
  unzip -q "$bun_zip" -d "$work"
  export PATH="$work/bun-$bun_platform:$PATH"
fi

cd "$source"
bun install --frozen-lockfile --ignore-scripts
bun run --cwd apps/api db:generate
nohup python3 -B .github/scripts/ios-fixture-server.py "$BILLBANDIT_UI_FIXTURE_DIR" \
  > "$work/fixture.log" 2>&1 < /dev/null &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
deadline=$((SECONDS + 110))
while [[ ! -f "$BILLBANDIT_UI_FIXTURE_DIR/ready" ]]; do
  if ! kill -0 "$pid" 2>/dev/null || (( SECONDS >= deadline )); then
    tail -25 "$work/fixture.log" >&2
    exit 1
  fi
  sleep 1
done
trap - EXIT
echo 'Disposable BillBandit UI fixtures are ready.'
