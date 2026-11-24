import pathlib
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[2]


def changed_api_sources(base, head):
    paths = subprocess.check_output(
        ["git", "diff", "--name-only", "-z", "--diff-filter=ACMRT", base, head, "--", "apps/api/"],
        cwd=root,
    )
    return [p.decode() for p in paths.split(b"\0") if p.endswith((b".ts", b".tsx", b".js", b".mjs", b".cjs"))]


def check(name, budget, *command):
    start = time.monotonic()
    result = subprocess.run(command, cwd=root)
    elapsed = time.monotonic() - start
    print(f"{name}: {elapsed:.3f}s (budget {budget}s, exit {result.returncode})", flush=True)
    if elapsed > budget:
        print(f"::error::{name} exceeded its time budget.", flush=True)
    return result.returncode == 0 and elapsed <= budget


if __name__ == "__main__":
    files = changed_api_sources(*sys.argv[1:])
    results = [
        check("Oxlint", 1, "bun", "lint"),
        check("Next ESLint", 10, "bun", "run", "--cwd", "apps/api", "lint"),
        check("TypeScript 7", 5, "bun", "check"),
    ]
    if files:
        results.append(check("Oxfmt", 1, "bun", "fmt", *files))
    else:
        print("Oxfmt: no changed API source files")
    sys.exit(0 if all(results) else 1)
