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

if ! command -v npm >/dev/null; then
  brew install node@22
  export PATH="$(brew --prefix node@22)/bin:$PATH"
fi
if ! command -v pg_config >/dev/null || [[ ! -x "$(pg_config --bindir)/initdb" ]]; then
  brew install postgresql@16
  export PATH="$(brew --prefix postgresql@16)/bin:$PATH"
fi
if ! command -v bun >/dev/null || [[ "$(bun --version)" != 1.3.14 ]]; then
  npm install --prefix "$work/tools" --no-save bun@1.3.14
  export PATH="$work/tools/node_modules/.bin:$PATH"
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
