import argparse
import concurrent.futures
import json
import os
import pathlib
import platform
import random
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]
scripts = root / "apps/api/scripts"
self_hosted = {"polish-e2e.ts", "vietnam-trip-qa.ts"}


def select(suite, base):
    if not base:
        return suite
    paths = subprocess.check_output(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, "HEAD"], cwd=root
    ).decode().strip("\0")
    selected = set()
    for path in paths.split("\0") if paths else []:
        if path in {f"apps/api/scripts/{case}" for case in suite}:
            selected.add(pathlib.Path(path).name)
        elif not path.startswith(("docs/", "site/", "BillBandit/", "mockups/")):
            return suite
    return sorted(selected)


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run_case(case, database, scratch, evidence):
    work = scratch / case
    work.mkdir()
    api = work / "apps/api"
    shutil.copytree(root / "apps/api", api, ignore=shutil.ignore_patterns("node_modules", ".next", ".scratch", ".env*", "*.tsbuildinfo"))
    (work / "node_modules").symlink_to(root / "node_modules", target_is_directory=True)
    shutil.copy2(root / "package.json", work)
    logs = work / "logs"
    logs.mkdir()
    port = available_port()
    api_base = f"http://127.0.0.1:{port}"
    env = {key: value for key, value in os.environ.items() if key in {"PATH", "HOME", "LANG", "JAVA_HOME"}}
    env.update({
        "CI": "1",
        "TSX_TSCONFIG_PATH": str(api / "tsconfig.json"),
        "BILLBANDIT_CI_E2E": "1",
        "NEXT_TELEMETRY_DISABLED": "1",
        "DEV_DATABASE_URL": database,
        "DEV_API_BASE": api_base,
        "TEST_DATABASE_URL": database,
        "MOBILE_AUTH_MOCK_APPLE_SUBJECT": "ifi-e2e-apple-subject",
        "MOBILE_AUTH_MOCK_APPLE_EMAIL": "ifi-e2e@dev.billbandit.local",
        "START_POLISH_SERVER": "1",
        "POLISH_E2E_PORT": str(port),
        "POLISH_E2E_EVIDENCE_DIR": str(logs),
        "START_VIETNAM_TRIP_SERVER": "1",
        "VIETNAM_TRIP_BASE_URL": api_base,
        "VIETNAM_TRIP_EVIDENCE_DIR": str(logs),
    })
    server = None
    start = time.monotonic()
    result = 1
    with (logs / "run.log").open("w") as out, (logs / "api.log").open("w") as api_log:
        try:
            if case not in self_hosted:
                server = subprocess.Popen(
                    ["bun", "run", "scripts/dev-server.ts"],
                    cwd=api, env=env, stdout=api_log, stderr=api_log, start_new_session=True,
                )
                while "Ready in" not in (logs / "api.log").read_text():
                    if server.poll() is not None or time.monotonic() - start >= 12:
                        raise RuntimeError("The API did not become ready. See api.log.")
                    time.sleep(.05)
                if case != "identity-friends-import-e2e.ts":
                    for name in ("Kabir", "Aarav", "Zoya"):
                        subprocess.run(
                            ["bun", "run", "scripts/dev-data.ts", "friend", name],
                            cwd=api, env=env, stdout=out, stderr=out, check=True, timeout=4,
                        )
            result = subprocess.run(
                ["node", "--import", "tsx", f"scripts/{case}"] if case in self_hosted or case == "identity-friends-import-e2e.ts" else ["bun", "run", f"scripts/{case}"], cwd=api, env=env,
                stdout=out, stderr=out, timeout=30 - (time.monotonic() - start),
            ).returncode
        except (subprocess.SubprocessError, RuntimeError) as error:
            out.write(f"\n{error}\n")
        finally:
            if server:
                stop(server)
    elapsed = round(time.monotonic() - start, 3)
    for source in logs.iterdir():
        if source.suffix not in {".log", ".md"}:
            continue
        text = source.read_text(errors="replace")
        text = re.sub(r"eyJ[\w-]+\.[\w-]+\.[\w-]+", "[JWT redacted]", text)
        text = re.sub(r"(Bearer )[\w.+/=-]+", r"\1[redacted]", text, flags=re.IGNORECASE)
        (evidence / f"{case}-{source.name}").write_text(text)
    print(f"{case}: {elapsed}s, exit {result}", flush=True)
    return {"file": case, "seconds": elapsed, "exit": result, "within_budget": elapsed <= 30}


def run(args):
    suite = sorted({p.name for p in scripts.glob("*-e2e.ts")} | self_hosted)
    if any(not (scripts / case).is_file() for case in suite):
        raise ValueError("An E2E script is missing.")
    if args.workers < 1:
        raise ValueError("At least one worker is required.")
    chosen = select(suite, args.base)
    if args.case:
        chosen = [args.case]
        if args.case not in suite:
            raise ValueError(f"Unknown E2E case: {args.case}")
    if args.list:
        print(json.dumps(chosen))
        return True
    if args.postgres is None:
        args.postgres = pathlib.Path(subprocess.check_output(["pg_config", "--bindir"], text=True).strip())
    args.evidence.mkdir(parents=True, exist_ok=True)
    evidence = args.evidence.resolve()
    seed = args.seed if args.seed is not None else random.randrange(2**32)
    random.Random(seed).shuffle(chosen)
    summary = {
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "environment": platform.platform(),
        "bun": subprocess.check_output(["bun", "--version"], text=True).strip(),
        "expected": suite, "selected": chosen, "seed": seed, "results": [],
        "replay": f"python3 .github/scripts/api-e2e.py --seed {seed}" + (f" --base {args.base}" if args.base else "") + (f" --case {args.case}" if args.case else ""),
    }
    try:
        if chosen:
            with tempfile.TemporaryDirectory(prefix="api-e2e-", dir=evidence.parent) as temp:
                scratch = pathlib.Path(temp)
                port = available_port()
                data = scratch / "postgres"
                pg = [str(args.postgres / "pg_ctl"), "-D", str(data), "-w"]
                subprocess.run([str(args.postgres / "initdb"), "-D", str(data), "-U", "ci", "--auth=trust", "--no-sync"], check=True, stdout=subprocess.DEVNULL)
                subprocess.run([*pg, "-l", str(scratch / "postgres.log"), "-o", f"-h 127.0.0.1 -p {port} -k ''", "start"], check=True)
                try:
                    for index, _ in enumerate(chosen):
                        subprocess.run([str(args.postgres / "createdb"), "-U", "ci", "-h", "127.0.0.1", "-p", str(port), f"ci_case_{index}"], check=True)
                    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
                        jobs = [pool.submit(run_case, case, f"postgresql://ci@127.0.0.1:{port}/ci_case_{index}", scratch, evidence)
                                for index, case in enumerate(chosen)]
                        summary["results"] = [job.result() for job in jobs]
                finally:
                    subprocess.run([*pg, "-m", "fast", "stop"], check=True)
    finally:
        (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return (
        sorted(result["file"] for result in summary["results"]) == sorted(chosen)
        and all(r["exit"] == 0 and r["within_budget"] for r in summary["results"])
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="Limit PR feedback to files that the diff can reach")
    parser.add_argument("--case", help="Replay one existing script")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--seed", type=int)
    parser.add_argument("--workers", type=int, default=len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count())
    parser.add_argument("--postgres", type=pathlib.Path)
    parser.add_argument("--evidence", type=pathlib.Path, default=root / ".scratch/ci/api-e2e")
    raise SystemExit(0 if run(parser.parse_args()) else 1)
