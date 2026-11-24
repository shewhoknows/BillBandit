# BillBandit App Store release

1. Use a clean checkout at the same commit as its branch on `origin`. The scripts expect `feat/release-scripts` by default. After merge, set `RELEASE_BRANCH=main` for both commands.
2. Run `scripts/release/preflight.sh`. Fix each FAIL. The Xcode line gives the `DEVELOPER_DIR` for this release. If the Xcode catalog is missing or stale, refresh it with `xcodes list` and rerun. An expired App Store Connect web session is a warning. API authentication is required.
3. Run the TesterArmy reviewer flow once on a pool iPhone and once on a pool iPad. Use the same Xcode for both. Run Sim Guard preflight, acquire one simulator, and record its UDID. Release it before acquiring the other. If the approved pool has no iPad, arrange access to a pool iPad before the smoke test.
4. Run `scripts/release/release.sh --version 1.0`. The script sets the version and next build number in the archive, exports and verifies the IPA, uploads it, waits for VALID, and selects it on the existing App Store version.
5. The owner clicks **Add for Review** in App Store Connect. The owner also handles any action required on an existing rejected submission.

## Reviewer smoke test

Reuse the TesterArmy `release-review-flow.e2e.ts`, `part5.config.ts`, and `run-local.py` from the [build 34 replay](../../HANDOFF.md). The files are in `~/worktrees/billbandit-reviewer-login/.scratch/submit-20261122/e2e`. Copy the harness into release evidence. Point the test's source root at the release checkout and its database URL at a fresh, migrated **loopback-only** PostgreSQL database. The harness seeds and deletes synthetic review data. Build the signed Debug app for each acquired UDID using a separate DerivedData path. From the copied harness directory, set `PART5_APP` to that app and run:

```bash
export PART5_OUTPUT=/absolute/path/to/smoke-evidence
export PART5_SIM=acquired-udid PART5_DEVICE=acquired-udid PART5_KIND=iphone
python3 run-local.py tests/release-review-flow.e2e.ts --config part5.config.ts --output "$PART5_OUTPUT/iphone" --trace on
```

Repeat on the iPad with its UDID, `PART5_KIND=air`, and a separate output path. The historical iPad steps use coordinates for the 11-inch Air compatibility window. Use a matching device and confirm the layout before reuse. Save the traces and release both simulators through Sim Guard.

## Local proof and resume

```bash
scripts/release/release.sh --version 1.0 --dry-run --skip-upload
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
  scripts/release/release.sh --verify-ipa /path/to/BillBandit.ipa --version 1.0 --build 36
```

Either local-only flag archives, exports, and verifies. Both print the live upload, wait, and selection commands. The script uses installed signing assets and a local export. It applies build settings to the archive without editing the project file. The Xcode check matches the bundle's build ID to the xcodes release catalog and checks the installed SDK build. Xcode 27.2 build 27B52 also allows its verified bundled SDK 24B8118.

Use the printed resume command to keep the same build number. Keep the source commit, Xcode and SDK, and ignored `scripts/release/test-output/` directory. The script reuses completed artifacts, checks the existing Apple build or upload before retrying, and reads the version back after selection. If Apple shows only an unfinished upload reservation, inspect its status before retrying or choosing a new build number.

The owner sets the production reviewer code and enters it in App Review fields through a private session. Preflight reads only the public enabled flag. Verify real Sign in with Apple separately on a signed-in device. The simulator reviewer flow uses a local code, and IPA verification checks the entitlement. The owner controls submission after checking the selected build and review details.
