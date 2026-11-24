import argparse
import json
import re
import subprocess
import time
from urllib.parse import urlencode


XCODE_CLOUD_APP_ID = 117084


def verify(repo, sha, name, wait_seconds):
    query = urlencode({"app_id": XCODE_CLOUD_APP_ID, "check_name": name, "filter": "latest", "per_page": 100})
    endpoint = f"repos/{repo}/commits/{sha}/check-runs?{query}"
    deadline = time.monotonic() + wait_seconds
    while True:
        result = subprocess.check_output(["gh", "api", "--paginate", "--slurp", endpoint], text=True, timeout=15)
        checks = [
            check for page in json.loads(result) for check in page["check_runs"]
            if check["head_sha"] == sha and check["name"] == name
            and (check.get("app") or {}).get("id") == XCODE_CLOUD_APP_ID
        ]
        if checks:
            check = max(checks, key=lambda item: item["id"])
            if check["status"] == "completed":
                print(f"{name} for {sha}: {check['conclusion']}", flush=True)
                return check["conclusion"] == "success"
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(f"No completed Xcode Cloud Test check named {name!r} for {sha}.", flush=True)
            return False
        time.sleep(min(20, remaining))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("sha")
    parser.add_argument("check")
    parser.add_argument("--wait-seconds", type=int, default=1800)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        parser.error("Supply the exact commit SHA.")
    if not re.fullmatch(r"BillBandit \| [^|\r\n]+ \| Test - iOS", args.check):
        parser.error("Supply the native BillBandit Xcode Cloud Test - iOS check name.")
    if args.wait_seconds < 0:
        parser.error("The wait must be nonnegative.")
    raise SystemExit(0 if verify(args.repo, args.sha, args.check, args.wait_seconds) else 1)
