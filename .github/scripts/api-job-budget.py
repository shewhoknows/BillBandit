import datetime
import json
import os
import subprocess
import sys


def seconds_between(start, end):
    return (datetime.datetime.fromisoformat(end) -
            datetime.datetime.fromisoformat(start)).total_seconds()


def check(job_name, command_step):
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
    job = matches[0]
    command_start = next(step["started_at"] for step in job["steps"] if step["name"] == command_step)
    now = datetime.datetime.now(datetime.UTC).isoformat()
    metrics = [
        ("Waiting", seconds_between(job["created_at"], job["started_at"]), 68),
        ("Setup", seconds_between(job["started_at"], command_start), 15),
        ("Runner through budget check", seconds_between(job["started_at"], now), 35),
    ]
    passes = True
    for phase, elapsed, limit in metrics:
        inclusive = phase == "Waiting"
        comparison = "<=" if inclusive else "<"
        print(f"{phase}: {elapsed:.2f}s (limit {comparison} {limit}s)")
        if elapsed < 0 or elapsed > limit or (elapsed == limit and not inclusive):
            print(f"::error::{phase} exceeded the API job budget or has invalid timestamps.")
            passes = False
    return passes


if __name__ == "__main__":
    raise SystemExit(0 if check(*sys.argv[1:]) else 1)
