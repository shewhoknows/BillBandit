import concurrent.futures
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys


def seconds_between(start, end):
    return (datetime.datetime.fromisoformat(end) -
            datetime.datetime.fromisoformat(start)).total_seconds()


def run_job(job_name):
    repo = os.environ["GITHUB_REPOSITORY"]
    run = os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    data = subprocess.check_output(
        ["gh", "api", f"repos/{repo}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100"],
        text=True,
    )
    matches = [job for job in json.loads(data)["jobs"] if job["name"] == job_name]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one job named {job_name}.")
    return matches[0]


def budget_data():
    return pathlib.Path(os.environ["RUNNER_TEMP"]) / "api-job-budget.json"


def run(job_name, command):
    start = datetime.datetime.now(datetime.UTC).isoformat()
    env = {key: value for key, value in os.environ.items() if key != "GH_TOKEN"}
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        job = pool.submit(run_job, job_name)
        result = subprocess.run(command, env=env)
        budget_data().write_text(json.dumps({"job": job.result(), "command_start": start}))
    return result.returncode


def check():
    data = json.loads(budget_data().read_text())
    job = data["job"]
    command_start = data["command_start"]
    now = datetime.datetime.now(datetime.UTC).isoformat()
    is_e2e = re.fullmatch(r"API E2E \([0-9]+\)", job["name"]) is not None
    metrics = [
        ("Waiting", seconds_between(job["created_at"], job["started_at"]), 68, None),
        ("Setup", seconds_between(job["started_at"], command_start), 20 if is_e2e else 15, 15 if is_e2e else None),
        ("Runner through budget check", seconds_between(job["started_at"], now), 40 if is_e2e else 35, 35 if is_e2e else None),
    ]
    passes = True
    for phase, elapsed, limit, prior_target in metrics:
        inclusive = phase == "Waiting"
        comparison = "<=" if inclusive else "<"
        target_label = f"; prior target < {prior_target}s" if prior_target is not None else ""
        print(f"{phase}: {elapsed:.2f}s (limit {comparison} {limit}s{target_label})")
        if prior_target is not None and elapsed >= prior_target:
            print(f"::warning::{phase} missed the prior {prior_target}s target ({elapsed:.2f}s).")
        if elapsed < 0 or elapsed > limit or (elapsed == limit and not inclusive):
            print(f"::error::{phase} exceeded the API job budget or has invalid timestamps.")
            passes = False
    return passes


if __name__ == "__main__":
    if sys.argv[1] == "run":
        raise SystemExit(run(sys.argv[2], sys.argv[3:]))
    if sys.argv[1:] != ["check"]:
        raise SystemExit("Use run JOB COMMAND or check.")
    raise SystemExit(0 if check() else 1)
