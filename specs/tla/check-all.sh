#!/bin/sh
# Re-run every "after fix" TLA+ model in specs/tla and print one line per model.
# Replay: sh specs/tla/check-all.sh   (needs Java 11+ and tla2tools.jar)
# Set TLA2TOOLS to the jar path. Set SKIP to a space list of cfg names to skip.
JAR=${TLA2TOOLS:-/home/claude/shared/tla2tools.jar}
ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$ROOT/check-all-results.txt}
: > "$OUT"
echo "revision: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) at $(date -u +%FT%TZ)" >> "$OUT"
for cfg in ${ONLY:-"$ROOT"/*/*after*.cfg "$ROOT"/*/*fixed*.cfg}; do
  name=$(basename "$cfg" .cfg); dir=$(dirname "$cfg"); slice=$(basename "$dir")
  case " $SKIP " in *" $name "*) echo "$slice/$name: SKIPPED" >> "$OUT"; continue;; esac
  # The spec is the .tla whose name starts the cfg name (Spec_after.cfg,
  # Spec-after.cfg); a folder with one .tla uses it.
  spec=""
  for t in "$dir"/*.tla; do
    b=$(basename "$t" .tla)
    case "$name" in "$b"_*|"$b"-*) spec=$t;; esac
  done
  [ -z "$spec" ] && spec=$(ls "$dir"/*.tla | head -1)
  # -deadlock turns off only the "no next step" check: these models end when
  # all work is done. Invariants and PROPERTIES are still checked.
  flags="-deadlock"
  log=$(mktemp)
  (cd "$dir" && java -XX:+UseParallelGC -Xmx3g -cp "$JAR" tlc2.TLC -workers 2 -metadir "$(mktemp -d)" $flags -config "$name.cfg" "$(basename "$spec")" > "$log" 2>&1)
  verdict=$(grep -hE 'No error has been found|is violated|were violated|Error:' "$log" | head -1)
  states=$(grep -hE 'distinct states found' "$log" | tail -1 | sed 's/.*generated, //')
  echo "$slice/$name ($(basename "$spec")): ${verdict:-NO VERDICT} | $states" >> "$OUT"
  rm -f "$log"
done
find "$ROOT" -name "*_TTrace_*" -delete
cat "$OUT"
