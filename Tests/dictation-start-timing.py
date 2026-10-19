#!/usr/bin/env python3
"""0.5.327: print the start numbers from the dictation timing file after Miles dictates. Numbers and codes only; the
file never holds words. Read-only.

    python3 Tests/dictation-start-timing.py [count] [timing file]

Defaults: the last 10 lines of ~/Library/Application Support/COS Control/dictation-timing.jsonl (and its .1).
A line from before 0.5.327 has no start numbers and prints "-" for them.
"""
import json, pathlib, sys

count = int(sys.argv[1]) if len(sys.argv) > 1 else 10
path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else \
    pathlib.Path.home() / "Library/Application Support/COS Control/dictation-timing.jsonl"
lines = []
for source in (path.with_name(path.name + ".1"), path):
    if source.exists():
        lines += [l for l in source.read_text(encoding="utf-8").splitlines() if l.strip()]
if not lines:
    sys.exit(f"no timing lines in {path}")
fields = ["pressToTaskMs", "permissionMs", "refreshMicsMs", "micListRead", "warmEngine", "engineStartMs",
          "pressToFirstBufferMs", "pressToSoundMs", "quietMs", "capturedSeconds", "transcribeMs", "outcome", "failReason"]
print("at (UTC)                  " + "  ".join(fields))
for line in lines[-count:]:
    try:
        row = json.loads(line)
    except ValueError:
        continue
    cells = []
    for f in fields:
        value = row.get(f, "-")
        cells.append(str(value).lower() if isinstance(value, bool) else str(value))
    print(f"{row.get('at', '?')[:23]:25} " + "  ".join(cells))
