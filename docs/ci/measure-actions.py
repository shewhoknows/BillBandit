import collections
import datetime
import json
import math
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
runs = json.loads((root / "runs.json").read_text())
buckets = collections.defaultdict(list)
wall = collections.defaultdict(list)
skipped = collections.Counter()
failure_steps = collections.Counter()
setup_steps = {
    "Set up job", "Run actions/checkout@v4", "Checkout", "Setup Node.js",
    "Install dependencies", "Generate Prisma client", "Install Railway CLI",
    "Configure Pages",
}


def seconds(start, end):
    return (datetime.datetime.fromisoformat(end) -
            datetime.datetime.fromisoformat(start)).total_seconds()


def percentiles(values):
    ordered = sorted(values)
    if not ordered:
        return "—"
    return f"{statistics.median(ordered):g} / {ordered[math.ceil(.95 * len(ordered)) - 1]:g}"


for run in runs:
    jobs = json.loads((root / f"jobs-{run['id']}.json").read_text())["jobs"]
    latest = [job for job in jobs if job["run_attempt"] == run["run_attempt"]
              and job["steps"]]
    if latest:
        start = min(job["created_at"] for job in latest)
        end = max(job["completed_at"] for job in latest)
        wall[run["name"], run["event"]].append(seconds(start, end))
    for job in jobs:
        key = run["name"], job["name"]
        if not job["steps"]:
            skipped[key, job["conclusion"]] += 1
            continue
        waiting = seconds(job["created_at"], job["started_at"])
        setup = sum(seconds(step["started_at"], step["completed_at"])
                    for step in job["steps"] if step["name"] in setup_steps
                    and step["started_at"] and step["completed_at"])
        duration = seconds(job["started_at"], job["completed_at"])
        buckets[key].append((waiting, setup, duration - setup, duration))
        for step in job["steps"]:
            if step["conclusion"] == "failure":
                failure_steps[key, step["name"]] += 1

print(f"{len(runs)} runs from {runs[-1]['created_at']} to {runs[0]['created_at']}")
print("| Workflow / job | Started | Waiting | Setup | Running | On runner |")
print("| --- | ---: | ---: | ---: | ---: | ---: |")
for (workflow, job), rows in sorted(buckets.items()):
    values = " | ".join(percentiles(column) for column in zip(*rows))
    print(f"| {workflow} / {job} | {len(rows)} | {values} |")
for (workflow, event), values in sorted(wall.items()):
    print(f"{workflow} / {event}: {len(values)} runs, {percentiles(values)} s")
print(f"Skipped: {dict(skipped)}")
print(f"Failed steps: {dict(failure_steps)}")
