#!/bin/sh
# Replay: sh specs/tla/ios-ledger-sync/run.sh  (from the repo root or this folder)
cd "$(dirname "$0")"
JAR=${TLA2TOOLS:-/home/claude/shared/tla2tools.jar}
for c in before_order before_selfconflict before_account noguard after; do
  java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 1 -deadlock -config $c.cfg LedgerQueueSync.tla > tlc-$c.txt 2>&1
  python3 -I tools/trace.py tlc-$c.txt > trace-$c.txt
done
for c in before_live after_live; do   # liveness: no -deadlock
  java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 1 -config $c.cfg LedgerQueueSync.tla > tlc-$c.txt 2>&1
done
rm -rf states *_TTrace_*.tla *_TTrace_*.bin trace-after.txt
grep -H "No error has been found\|is violated" tlc-*.txt
