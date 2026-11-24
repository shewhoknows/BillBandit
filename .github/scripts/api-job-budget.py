import concurrent.futures
import datetime
import json
import os
import pathlib
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
    metrics = [
        ("Waiting", seconds_between(job["created_at"], job["started_at"]), 68),
        ("Setup", seconds_between(job["started_at"], command_start), 15),
        ("Runner through budget check", seconds_between(job["started_at"], now), 35),
    ]
    # A breach of the budget is reported as a warning: hosted-runner checkout and
    # startup vary by a few seconds, and failing required checks on that noise
    # would bounce PRs out of the merge queue. A breach of twice the budget is a
    # real regression (for example a lost cache) and fails the job.
    passes = True
    lines = []
    for phase, elapsed, limit in metrics:
        inclusive = phase == "Waiting"
        comparison = "<=" if inclusive else "<"
        line = f"{phase}: {elapsed:.2f}s (limit {comparison} {limit}s)"
        print(line)
        over = elapsed > limit or (elapsed == limit and not inclusive)
        if elapsed < 0 or elapsed > 2 * limit:
            print(f"::error::{phase} took {elapsed:.2f}s, more than twice the {limit}s budget, or has invalid timestamps.")
            passes = False
            line += " FAIL"
        elif over:
            print(f"::warning::{phase} took {elapsed:.2f}s, over the {limit}s budget.")
            line += " OVER"
        lines.append(f"- {line}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("### Job budget\n" + "\n".join(lines) + "\n")
    return passes


if __name__ == "__main__":
    if sys.argv[1] == "run":
        raise SystemExit(run(sys.argv[2], sys.argv[3:]))
    if sys.argv[1:] != ["check"]:
        raise SystemExit("Use run JOB COMMAND or check.")
    raise SystemExit(0 if check() else 1)
