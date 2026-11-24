# Disposable iOS test fixtures

The full test scheme uses three fixture files. The repository can now
prepare all three from real API calls and a disposable local PostgreSQL
cluster. The fixture runner manages its own loopback proxy and API process.
An offline switch blocks API traffic until it is reset.

| File | What it provides |
| --- | --- |
| `ui-session.json` | One authenticated account with a username and no groups |
| `qa-session.json` | Alice and Bob with accepted friendship and distinct sessions |
| `overview-fixture.json` | One expense with different creator and payer, a recorded edit, and its canonical creation timestamp |

## Xcode Cloud

Use the full `BillBandit` test scheme for the main and merge-queue workflows.
In the workflow's environment, set
`BILLBANDIT_UI_FIXTURE_DIR=/tmp/billbandit-ui-fixtures`. Leave it unset for
PR smoke. The pre-build script starts the fixture runner only during
`test-without-building`. It fetches the exact public source revision and
starts the local services before the test action. The XCTest runner reads the
configured fixture directory. Legacy local replays can still use the
existing `.scratch` paths.

The proof on this Mac covers fixture preparation and the HTTP routes.
It does not cover Xcode Cloud's test host, process lifetime, file access, or
simulator networking. Check those in the first owner-started full Test action.
The action must produce its XCTest result bundle before enabling distribution.
[Apple's test action documentation](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)

## Local replay

Use a clean checkout with Bun 1.3.14, Node, Python 3 and PostgreSQL tools.
The fixture process refuses a checkout with local API environment files.

```sh
bun install --frozen-lockfile --ignore-scripts
bun run --cwd apps/api db:generate
mkdir -p .scratch/ci
python3 -B .github/scripts/ios-fixture-server.py .scratch/ci/ui-fixtures
```

The command remains running while the fixtures are in use. Stop that command
to stop its services and delete its fixture directory. The JSON files contain
temporary test tokens. Keep them out of uploads and Git.
