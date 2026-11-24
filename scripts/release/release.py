import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
from time import monotonic

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUTPUT = HERE / "test-output"
ASC = "/opt/homebrew/bin/asc"
APP = "6792712181"
BUNDLE = "com.billbandit.app"
TEAM = "4JRB53LG5C"
APP_IDENTIFIER = f"{TEAM}.{BUNDLE}"
APPLE_SIGN_IN = "com.apple.developer.applesignin"
PRODUCTION = "https://billbandit-api.contenthelper.in"
RAILWAY_PROJECT = "0305c493-298b-4f7b-9c3e-e99aea9973c8"
RAILWAY_ENVIRONMENT = "033711af-f3a8-4187-ad78-8080f50e420b"
RAILWAY_SERVICE = "aa4c9178-adbf-411f-b6eb-487a908b8f9d"
CATALOG = Path.home() / "Library/Application Support/com.robotsandpencils.xcodes/available-xcodes.json"
VERIFIED_SDK_BUILDS = {"27B52": {"24B8118"}}


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def read(*args, env=None, timeout=8):
    result = subprocess.run(
        args, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout,
    )
    require(result.returncode == 0, f"{Path(args[0]).name} exited {result.returncode}")
    return result.stdout


def plist(path):
    with path.open("rb") as file:
        return plistlib.load(file)


def version_tuple(version):
    require(re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version), f"Invalid version {version}")
    parts = tuple(map(int, version.split(".")))
    return parts if len(parts) == 3 else (*parts, 0)


def xcode_info(developer, catalog):
    info = plist(developer.parent / "version.plist")
    version, build = info["CFBundleShortVersionString"], info["ProductBuildVersion"]
    entry = next((row for row in catalog if row["xcodeID"]["version"].endswith(f"+{build}")), None)
    require(entry, f"Xcode {version} ({build}) is absent from the xcodes release catalog")
    release_version = entry["xcodeID"]["version"].split("+")[0]
    require("-" not in release_version, f"Xcode {version} ({build}) is a prerelease")
    require(version_tuple(release_version) == version_tuple(version), "Xcode version metadata differs from the catalog")
    sdk_info = plist(developer / "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
                     / "System/Library/CoreServices/SystemVersion.plist")
    sdk = sdk_info["ProductBuildVersion"]
    released_sdks = {row["build"] for row in entry["sdks"]["iOS"] if row["release"].get("release") is True}
    require(sdk in released_sdks | VERIFIED_SDK_BUILDS.get(build, set()),
            f"iPhoneOS SDK {sdk} is not a known release SDK for Xcode {build}")
    return developer, version, build, sdk


def choose_xcode(only=None):
    require(CATALOG.is_file(), "xcodes release catalog is missing. Run xcodes list")
    catalog = json.loads(CATALOG.read_bytes())
    candidates = [only] if only else [app / "Contents/Developer" for app in Path("/Applications").glob("Xcode*.app")]
    rejected = []
    eligible = []
    for developer in candidates:
        try:
            eligible.append(xcode_info(developer, catalog))
        except (ReleaseError, OSError, KeyError, ValueError) as error:
            rejected.append(str(error))
    require(eligible, "No release Xcode with a verified iPhoneOS SDK. " + " / ".join(rejected))
    return max(eligible, key=lambda item: (version_tuple(item[1]), item[2]))


def xcode_env(xcode):
    return {**os.environ, "DEVELOPER_DIR": str(xcode[0])}


def tool_version(tool, minimum, *flags):
    actual = read(tool, *flags).decode().split()[0]
    require(version_tuple(actual) >= version_tuple(minimum), f"{actual} is older than {minimum}")
    return actual


def asc_api():
    result = json.loads(read(ASC, "apps", "view", "--id", APP))
    require(result["data"]["attributes"]["bundleId"] == BUNDLE, "ASC API returned another bundle")
    return f"API read succeeded for {BUNDLE}"


def asc_web():
    result = json.loads(read(ASC, "web", "auth", "status"))
    require(result.get("authenticated") is True, "Cached web session expired or unavailable")
    return "Cached web session authenticated"


def railway_target():
    projects = json.loads(read("railway", "list", "--json"))
    project = next((row for row in projects if row["id"] == RAILWAY_PROJECT), None)
    require(project, "BillBandit project unavailable. Check Railway CLI login and access")
    services = {edge["node"]["id"] for edge in project["services"]["edges"]}
    environments = [edge["node"] for edge in project["environments"]["edges"]]
    environment = next((row for row in environments if row["id"] == RAILWAY_ENVIRONMENT), None)
    require(environment and environment.get("canAccess"), "BillBandit production environment unavailable")
    instances = {edge["node"]["serviceId"] for edge in environment["serviceInstances"]["edges"]}
    require(RAILWAY_SERVICE in services & instances, "BillBandit API service unavailable in production")
    return "CLI authenticated and BillBandit API resolves in production"


def http(path):
    completed = read("curl", "--silent", "--show-error", "--max-time", "6", "--write-out",
                     "\n%{http_code}", PRODUCTION + path)
    body, code = completed.rsplit(b"\n", 1)
    require(code == b"200", f"HTTP {code.decode()}")
    return json.loads(body)


def production_health():
    require(http("/api/health").get("status") == "ok", "HTTP 200 but health status is not ok")
    return "HTTP 200, status=ok"


def reviewer_code():
    enabled = http("/api/mobile/auth/review-code").get("enabled")
    require(enabled is True, f"enabled={json.dumps(enabled)}. Owner must confirm a code of at least 16 characters")
    return "HTTP 200, enabled=true confirms the server's 16-character minimum"


def simulator_guard(xcode):
    require(xcode, "Cannot run Sim Guard without a release Xcode")
    guard = Path.home() / ".codex/skills/sim-guard/sim-guard.sh"
    env = {**xcode_env(xcode), "SIM_CAP": "2", "MIN_FREE_PCT": "25"}
    try:
        output = read(guard, "preflight", env=env).decode()
    except ReleaseError:
        raise ReleaseError("Sim Guard blocked. Run sim-guard.sh preflight for details") from None
    memory = re.search(r"Mac memory free: (\d+)%", output)
    devices = json.loads(read("xcrun", "simctl", "list", "devices", "booted", "--json", env=env))
    count = sum(row["state"] == "Booted" for rows in devices["devices"].values() for row in rows)
    require(memory and int(memory[1]) >= 25 and count < 2, "Sim Guard limits could not be confirmed")
    return f"Preflight passed with {count}/2 booted and {memory[1]}% memory free"


def free_disk():
    filesystem = os.statvfs(HERE)
    gb = filesystem.f_bavail * filesystem.f_frsize / 10**9
    require(gb >= 40, f"{gb:.1f} GB free. Need at least 40 GB")
    return f"{gb:.1f} GB free"


def git_state(expected):
    env = {**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"}
    branch = read("git", "branch", "--show-current", env=env).decode().strip()
    require(branch == expected, f"Expected {expected}, found {branch or 'detached HEAD'}")
    require(not read("git", "status", "--porcelain", env=env), "Working tree is dirty")
    head = read("git", "rev-parse", "HEAD", env=env).decode().strip()
    ref = f"refs/heads/{expected}"
    remote = read("git", "ls-remote", "--heads", "origin", ref, env=env).decode().split()
    require(remote == [head, ref], f"HEAD differs from origin/{expected}, or the remote branch is missing")
    return head


def app_store_profile(profile):
    entitlements = profile["Entitlements"]
    return (
        entitlements.get("application-identifier") == APP_IDENTIFIER
        and profile.get("TeamIdentifier") == [TEAM]
        and entitlements.get("get-task-allow") is False
        and "Default" in entitlements.get(APPLE_SIGN_IN, [])
        and not profile.get("ProvisionedDevices")
        and not profile.get("ProvisionsAllDevices")
        and profile["ExpirationDate"].replace(tzinfo=timezone.utc) > datetime.now(timezone.utc)
    )


def signing_profile():
    deadline = monotonic() + 12
    identities = read("security", "find-identity", "-v", "-p", "codesigning").decode()
    distribution = set(re.findall(r'\b([A-F0-9]{40}) "Apple Distribution: [^"\n]+\(' + TEAM + r'\)"', identities))
    require(distribution, f"No valid Apple Distribution signing identity for {TEAM}")
    library = Path.home() / "Library"
    folders = [library / "Developer/Xcode/UserData/Provisioning Profiles",
               library / "MobileDevice/Provisioning Profiles"]
    matches = []
    for filename in (file for folder in folders for file in folder.glob("*.mobileprovision")):
        remaining = deadline - monotonic()
        require(remaining > 0, "Timed out checking installed profiles")
        try:
            profile = plistlib.loads(read("security", "cms", "-D", "-i", filename, timeout=min(1, remaining)))
            if app_store_profile(profile):
                for cert in profile["DeveloperCertificates"]:
                    fingerprint = hashlib.sha1(cert).hexdigest().upper()
                    if fingerprint in distribution:
                        matches.append((profile["ExpirationDate"], profile["UUID"], fingerprint, profile["Name"]))
        except (ReleaseError, ValueError, OSError, KeyError, subprocess.TimeoutExpired):
            continue
    require(matches, f"No unexpired App Store profile for {BUNDLE} with Sign in with Apple and a matching identity")
    _, uuid, fingerprint, name = max(matches)
    return uuid, fingerprint, name


def checks(expected):
    try:
        xcode = choose_xcode()
        results = [("PASS", "xcode", f"Xcode {xcode[1]} ({xcode[2]}), SDK {xcode[3]}, DEVELOPER_DIR={xcode[0]}")]
    except (ReleaseError, OSError, KeyError, ValueError) as error:
        xcode = None
        results = [("FAIL", "xcode", str(error))]

    def check(name, action, severity="FAIL"):
        try:
            return "PASS", name, action()
        except (ReleaseError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            detail = str(error) if isinstance(error, ReleaseError) else (
                "Check timed out" if isinstance(error, subprocess.TimeoutExpired) else "Check unavailable or invalid response"
            )
            return severity, name, detail

    tasks = [
        ("asc", lambda: f"{tool_version(ASC, '7.1.0', '--version')} (minimum 7.1.0)"),
        ("asc-api", asc_api),
        ("asc-web", asc_web, "WARN"),
        ("xcodes", lambda: f"{tool_version('xcodes', '2.2.0', 'version')} (minimum 2.2.0)"),
        ("railway", railway_target),
        ("production-health", production_health),
        ("review-code", reviewer_code),
        ("sim-guard", lambda: simulator_guard(xcode)),
        ("disk", free_disk),
        ("git", lambda: f"Clean {expected} at origin/{expected} ({git_state(expected)[:12]})"),
        ("signing", lambda: f"{signing_profile()[2]} with matching Apple Distribution identity and Sign in with Apple"),
    ]
    with ThreadPoolExecutor(max_workers=len(tasks)) as pool:
        pending = [pool.submit(check, *task) for task in tasks]
        results.extend(item.result() for item in pending)
    return xcode, results


def print_checks(results):
    for state, name, detail in results:
        print(f"{state} {name} - {' '.join(detail.splitlines())}", flush=True)


def verify_ipa(ipa, xcode, version=None, build=None):
    with tempfile.TemporaryDirectory(prefix="verify-", dir=ipa.resolve().parent) as temp:
        read("/usr/bin/ditto", "-x", "-k", ipa, temp, timeout=60)
        apps = list((Path(temp) / "Payload").glob("*.app"))
        require(len(apps) == 1, "IPA must contain exactly one app in Payload")
        app = apps[0]
        info = plist(app / "Info.plist")
        actual_xcode, actual_sdk = info["DTXcodeBuild"], info["DTSDKBuild"]
        print(f"IPA toolchain DTXcodeBuild={actual_xcode} DTSDKBuild={actual_sdk}", flush=True)
        require((actual_xcode, actual_sdk) == xcode[2:],
                f"IPA toolchain differs from release Xcode {xcode[2]} and SDK {xcode[3]}")
        require(info["CFBundleIdentifier"] == BUNDLE, "IPA bundle ID differs from BillBandit")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "IPA is not an iOS device build")
        require(not version or info["CFBundleShortVersionString"] == version, "IPA marketing version differs")
        require(not build or info["CFBundleVersion"] == build, "IPA build number differs")
        read("/usr/bin/codesign", "--verify", "--deep", "--strict", app, timeout=60)
        signed = plistlib.loads(read("/usr/bin/codesign", "-d", "--entitlements", ":-", app))
        require(signed.get("application-identifier") == APP_IDENTIFIER
                and "Default" in signed.get(APPLE_SIGN_IN, [])
                and signed.get("get-task-allow", False) is False,
                "Signed IPA requires the BillBandit team, distribution signing and Sign in with Apple")
        embedded = plistlib.loads(read("security", "cms", "-D", "-i", app / "embedded.mobileprovision"))
        require(app_store_profile(embedded), "IPA does not embed a valid BillBandit App Store profile")
    print(f"PASS IPA - App Store signature and Sign in with Apple for {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})", flush=True)


def log_command(command, log, *, env=None, timeout=15, capture=False):
    print(f"$ {shlex.join(map(str, command))}", flush=True)
    with log.open("wb") as output:
        result = subprocess.run(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE if capture else output,
                                stderr=output, timeout=timeout)
        if capture:
            output.write(result.stdout)
    require(result.returncode == 0, f"{command[1]} {command[2]} exited {result.returncode}. See {log}")
    return json.loads(result.stdout) if capture else None


def apple_json(*args):
    return json.loads(read(ASC, *args, timeout=30))


def choose_build():
    data = apple_json("builds", "list", "--app", APP, "--platform", "IOS", "--paginate")
    uploads = apple_json("builds", "uploads", "list", "--app", APP, "--platform", "IOS", "--paginate")
    numbers = [row["attributes"]["version"] for row in data["data"]]
    numbers += [row["attributes"]["cfBundleVersion"] for row in uploads["data"]]
    require(all(re.fullmatch(r"[0-9]+", number) for number in numbers),
            "ASC contains non-integer build numbers. Specify --build")
    return str(max(map(int, numbers), default=0) + 1)


def version_record(version):
    return apple_json("versions", "view", "--app", APP, "--version", version,
                      "--platform", "IOS", "--include-build")["data"]


def build_record(version, build):
    rows = apple_json("builds", "list", "--app", APP, "--platform", "IOS", "--version", version,
                      "--build-number", build, "--processing-state", "all")["data"]
    require(len(rows) <= 1, "ASC returned more than one matching build")
    return rows[0] if rows else None


def upload_states(version, build):
    rows = apple_json("builds", "uploads", "list", "--app", APP, "--platform", "IOS",
                      "--cf-bundle-short-version", version, "--cf-bundle-version", build, "--paginate")["data"]
    return {row["attributes"]["state"]["state"] for row in rows}


def no_concurrent_xcodebuild():
    result = subprocess.run(["pgrep", "-x", "xcodebuild"], stdout=subprocess.DEVNULL, timeout=5)
    require(result.returncode == 1, "xcodebuild is active or could not be checked. Wait and rerun the same command")


def store_ipa(xcode, version, build, artifacts, log_dir):
    archive = artifacts / "BillBandit.xcarchive"
    ipa = artifacts / "BillBandit.ipa"
    env = xcode_env(xcode)
    if not archive.exists() and not ipa.exists():
        uuid, fingerprint, _ = signing_profile()
        pending = log_dir / archive.name
        command = [ASC, "xcode", "archive", "--project", str(ROOT / "BillBandit/BillBandit.xcodeproj"),
                   "--scheme", "BillBandit", "--configuration", "Release", "--destination", "generic/platform=iOS",
                   "--derived-data-path", str(artifacts / "DerivedData"), "--archive-path", str(pending),
                   f"--xcodebuild-flag=CURRENT_PROJECT_VERSION={build}",
                   f"--xcodebuild-flag=MARKETING_VERSION={version}",
                   "--xcodebuild-flag=CODE_SIGN_STYLE=Manual",
                   f"--xcodebuild-flag=CODE_SIGN_IDENTITY={fingerprint}",
                   f"--xcodebuild-flag=PROVISIONING_PROFILE_SPECIFIER={uuid}"]
        no_concurrent_xcodebuild()
        log_command(command, log_dir / "archive.log", env=env, timeout=1800)
        pending.rename(archive)
    if not ipa.exists():
        options = plist(ROOT / "BillBandit/ExportOptions-AppStore.plist")
        require(options.get("destination") == "export" and options.get("method") == "app-store-connect"
                and options.get("teamID") == TEAM and options.get("manageAppVersionAndBuildNumber") is False,
                "Export options must be for a local App Store export with the original build number")
        uuid, fingerprint, _ = signing_profile()
        options.update(signingStyle="manual", signingCertificate=fingerprint, provisioningProfiles={BUNDLE: uuid})
        export_options = log_dir / "ExportOptions.plist"
        export_options.write_bytes(plistlib.dumps(options))
        pending = log_dir / ipa.name
        no_concurrent_xcodebuild()
        log_command([ASC, "xcode", "export", "--archive-path", str(archive), "--ipa-path", str(pending),
                     "--export-options", str(export_options), "--timeout", "8m"],
                    log_dir / "export.log", env=env, timeout=510)
        verify_ipa(pending, xcode, version, build)
        pending.rename(ipa)
    else:
        verify_ipa(ipa, xcode, version, build)
    print(f"IPA {ipa}", flush=True)
    return ipa


def release(args):
    if args.verify_ipa:
        require(not (args.dry_run or args.skip_upload), "--verify-ipa only verifies an existing IPA")
        selected = os.environ.get("DEVELOPER_DIR")
        xcode = choose_xcode(Path(selected).resolve() if selected else None)
        verify_ipa(args.verify_ipa, xcode, args.version, args.build)
        return
    version = args.version or "1.0"
    only_local = args.dry_run or args.skip_upload
    xcode, results = checks(args.branch)
    print_checks(results)
    require(all(state != "FAIL" for state, _, _ in results), "Release preflight failed")
    revision = git_state(args.branch)
    build = args.build or choose_build()
    require(re.fullmatch(r"[1-9][0-9]*", build), "Build number must be a positive integer")
    log_parent = OUTPUT / "runs"
    log_parent.mkdir(parents=True, exist_ok=True)
    log_dir = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-"), dir=log_parent))
    (log_dir / "preflight.log").write_text("".join(f"{s} {n} - {d}\n" for s, n, d in results))
    print(f"Logs {log_dir}", flush=True)
    resume = [str(HERE / "release.sh"), "--version", version, "--build", build, "--branch", args.branch]
    if args.dry_run:
        resume.append("--dry-run")
    if args.skip_upload:
        resume.append("--skip-upload")
    print(f"Resume the same build with {shlex.join(resume)}", flush=True)
    key = f"{revision}-{xcode[2]}-{xcode[3]}"
    build_dir = OUTPUT / "artifacts" / f"{version}-{build}"
    build_dir.mkdir(parents=True, exist_ok=True)
    with (build_dir / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError("This build is already running in this worktree") from None
        artifacts = build_dir / key
        artifacts.mkdir(exist_ok=True)
        run_release(version, build, only_local, xcode, artifacts, log_dir, args.branch, revision)


def run_release(version, build, only_local, xcode, artifacts, log_dir, branch, revision):
    version_record(version)
    selection = [ASC, "versions", "attach-build", "--app", APP, "--platform", "IOS",
                 "--version", version, "--build-number", build]
    wait = [ASC, "builds", "wait", "--app", APP, "--platform", "IOS", "--version", version,
            "--build-number", build, "--poll-interval", "20s", "--timeout", "30m", "--fail-on-invalid"]
    record = None if only_local else build_record(version, build)
    states = set() if only_local or record else upload_states(version, build)
    submitted = artifacts / "upload-attempted"
    accepted = artifacts / "upload-accepted"
    if not only_local:
        require(not (record or states) or submitted.exists(),
                "Build number is already used on ASC outside this local release. Pick a new build number")
        require(not record or record["attributes"]["processingState"] in {"VALID", "PROCESSING"},
                "Existing build failed processing. Pick a new build number for the corrected source")
    ipa = store_ipa(xcode, version, build, artifacts, log_dir)
    require(git_state(branch) == revision, "Release source changed. Rerun from the intended revision")
    upload = [ASC, "builds", "upload", "--app", APP, "--platform", "IOS", "--version", version,
              "--build-number", build, "--ipa", str(ipa)]
    if only_local:
        print("External commands for a live release")
        for command in (upload, wait, selection):
            print(shlex.join(command))
        return

    if not record and not accepted.exists() and not states.intersection({"PROCESSING", "COMPLETE"}):
        require("AWAITING_UPLOAD" not in states,
                "ASC has an unfinished upload reservation. Wait for its state to change before retrying")
        submitted.touch()
        log_command(upload, log_dir / "upload.log", timeout=900)
        accepted.touch()
    if not record or record["attributes"]["processingState"] != "VALID":
        log_command(wait, log_dir / "processing.log", timeout=1830)
        record = build_record(version, build)
    require(record and record["attributes"]["processingState"] == "VALID",
            "ASC did not return a VALID build")

    version_info = version_record(version)
    if selected_build(version_info) != record["id"]:
        log_command(selection, log_dir / "selection.log")
        version_info = version_record(version)
    require(selected_build(version_info) == record["id"], "ASC readback did not confirm the selected build")
    print(f"PASS ASC - Version {version} has VALID build {build} selected")
    print(f"Owner step - Click Add for Review on BillBandit {version} in App Store Connect.")


def selected_build(version_info):
    return (version_info.get("relationships", {}).get("build", {}).get("data") or {}).get("id")


def main():
    mode = sys.argv[1]
    parser = argparse.ArgumentParser(prog=f"{mode}.sh")
    parser.add_argument("--branch", default=os.environ.get("RELEASE_BRANCH", "feat/release-scripts"))
    if mode == "release":
        parser.add_argument("--build", type=int)
        parser.add_argument("--version")
        parser.add_argument("--dry-run", action="store_true")
        parser.add_argument("--skip-upload", action="store_true")
        parser.add_argument("--verify-ipa", type=Path)
    args = parser.parse_args(sys.argv[2:])
    try:
        if mode == "preflight":
            _, results = checks(args.branch)
            print_checks(results)
            return int(any(state == "FAIL" for state, _, _ in results))
        if args.version:
            version_tuple(args.version)
        if args.build is not None:
            require(args.build > 0, "Build number must be a positive integer")
            args.build = str(args.build)
        release(args)
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
