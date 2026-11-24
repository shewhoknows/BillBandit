import argparse
import json
import re
import subprocess
import time


def asc(*args):
    return json.loads(subprocess.check_output(["asc", *args, "--output", "json"], text=True))


def wait_for_archive(workflow, tag, commit, deadline):
    while time.monotonic() < deadline:
        runs = asc("xcode-cloud", "build-runs", "list", "--workflow-id", workflow, "--sort=-number", "--limit", "25")
        matches = []
        for run in runs["data"]:
            attributes = run["attributes"]
            if (attributes.get("sourceCommit") or {}).get("commitSha") != commit:
                continue
            ref = ((run.get("relationships") or {}).get("sourceBranchOrTag") or {}).get("data")
            if not ref:
                raise RuntimeError("Xcode Cloud omitted the source reference.")
            gitref = asc("xcode-cloud", "scm", "git-references", "view", "--id", ref["id"])
            ref_name = gitref["data"]["attributes"]["canonicalName"]
            if ref_name == f"refs/tags/{tag}":
                matches.append(run)
        if len(matches) > 1:
            raise RuntimeError("More than one Cloud run matches the tag and commit.")
        if matches and matches[0]["attributes"]["executionProgress"] == "COMPLETE":
            run = matches[0]
            if run["attributes"]["completionStatus"] != "SUCCEEDED":
                raise RuntimeError(f"Cloud run {run['id']} failed: {run['attributes']['completionStatus']}")
            return run["id"]
        time.sleep(20)
    raise RuntimeError("The Cloud archive did not finish within the release staging window.")


def wait_for_build(run, app, version, deadline):
    while time.monotonic() < deadline:
        builds = asc("xcode-cloud", "build-runs", "builds", "--run-id", run)["data"]
        if len(builds) > 1:
            raise RuntimeError("The Cloud run returned more than one App Store Connect build.")
        if builds:
            build = builds[0]
            state = build["attributes"]["processingState"]
            if state in {"FAILED", "INVALID"}:
                raise RuntimeError(f"Build {build['id']} processing state is {state}.")
            if state == "VALID":
                candidates = asc("builds", "list", "--app", app, "--version", version,
                                 "--platform", "IOS", "--build-number", build["attributes"]["version"],
                                 "--processing-state", "VALID", "--exclude-expired")["data"]
                if [item["id"] for item in candidates] != [build["id"]]:
                    raise RuntimeError("The processed Cloud build does not match this app and version.")
                return build["id"]
        time.sleep(20)
    raise RuntimeError("App Store Connect did not process the Cloud build within the release staging window.")


def main(args):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+(?:\.[0-9]+)?", args.tag):
        raise ValueError("The release tag must be vMAJOR.MINOR or vMAJOR.MINOR.PATCH.")
    version = args.tag[1:]
    deadline = time.monotonic() + 45 * 60
    run = wait_for_archive(args.workflow_id, args.tag, args.commit, deadline)
    build = wait_for_build(run, args.app, version, deadline)
    print(f"Cloud run {run} produced validated build {build} for {version}.", flush=True)
    if args.dry_run:
        return
    asc("versions", "attach-build", "--app", args.app, "--version", version,
        "--platform", "IOS", "--build-id", build)
    subprocess.run(["asc", "validate", "--app", args.app, "--version", version,
                    "--platform", "IOS", "--strict", "--check-urls"], check=True)
    print(f"Selected build {build} for App Store version {version}.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--workflow-id", required=True)
    parser.add_argument("--dry-run", action="store_true")
    main(parser.parse_args())
