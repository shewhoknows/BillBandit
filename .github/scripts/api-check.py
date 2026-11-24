import difflib
import pathlib
import re
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[2]


def api_edits(base, head):
    diff = subprocess.check_output(
        ["git", "-c", "core.quotePath=false", "diff", "--no-renames", "--unified=0",
         base, head, "--", "apps/api/"], text=True, cwd=root,
    )
    edits = {}
    file = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            file = line.removeprefix("+++ b/").rstrip("\t")
        elif line.startswith("+++ "):
            file = None
        elif file and file.endswith((".ts", ".tsx", ".js", ".mjs", ".cjs")):
            match = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            if match:
                start = max(0, int(match[1]) - 1)
                edits.setdefault(file, []).append((start, start + max(1, int(match[2] or 1))))
    return edits


def check_format(edits):
    start = time.monotonic()
    good = True
    for file, ranges in edits.items():
        source = (root / file).read_text()
        # oxfmt under Bun cuts stdout at 64 KiB when it is a pipe, so a large file
        # looked unformatted. Write to a temporary file instead.
        with tempfile.TemporaryFile("w+") as output:
            result = subprocess.run(
                ["bun", "run", "--bun", "oxfmt", "--stdin-filepath", file],
                cwd=root, input=source, text=True, stdout=output,
            )
            output.seek(0)
            formatted_text = output.read()
        if result.returncode:
            good = False
            continue
        actual = source.splitlines(keepends=True)
        formatted = formatted_text.splitlines(keepends=True)
        for op, first, end, _, _ in difflib.SequenceMatcher(None, actual, formatted, autojunk=False).get_opcodes():
            if op != "equal" and any(first < limit and low < max(first + 1, end) for low, limit in ranges):
                print(f"::error file={file},line={first + 1}::Format changed lines with Oxfmt.")
                good = False
    elapsed = time.monotonic() - start
    print(f"Oxfmt: {elapsed:.3f}s (budget 1s, {len(edits)} changed API files)")
    if elapsed > 1:
        print("::error::Oxfmt exceeded its time budget.")
    return good and elapsed <= 1


def check(name, budget, *command):
    start = time.monotonic()
    result = subprocess.run(command, cwd=root)
    elapsed = time.monotonic() - start
    print(f"{name}: {elapsed:.3f}s (budget {budget}s, exit {result.returncode})", flush=True)
    if elapsed > budget:
        print(f"::error::{name} exceeded its time budget.", flush=True)
    return result.returncode == 0 and elapsed <= budget


if __name__ == "__main__":
    edits = api_edits(*sys.argv[1:])
    results = [
        check("Oxlint", 1, "bun", "run", "--bun", "lint"),
        check("Next ESLint", 10, "bun", "run", "--cwd", "apps/api", "lint"),
        check("TypeScript 7", 5, "bun", "check"),
    ]
    results.append(check_format(edits))
    sys.exit(0 if all(results) else 1)
