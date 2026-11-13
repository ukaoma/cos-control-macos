#!/usr/bin/env python3
"""Every swiftc list in the build and test scripts compiles what its files use (D4, 2026-11-12, after 0.5.391's hold).

    python3 Tests/compile-list-pins.py <root>

For each swiftc invocation in scripts/build-release.sh, scripts/build-*.sh, Tests/run.sh and Tests/run-*.sh: every Swift
type that a listed file uses, and that only one file in Sources/ declares at the top level, must be declared by a listed file
(Sources or a Tests stand-in). A Sources file left out of a list fails here, where a render that globs Sources/*.swift would
compile and hide it (Sources/MessageReplyView.swift, 4a275d9). Lists that name no Sources file are skipped.
"""
import os, re, sys, glob

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
DECL = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|final|nonisolated)\s+)*(?:struct|class|enum|actor|protocol)\s+([A-Z]\w*)", re.M)
def strip(src):
    src = re.sub(r'"""[\s\S]*?"""', '""', src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"/\*[\s\S]*?\*/", "", src)
    return re.sub(r"//[^\n]*", "", src)
def decls(path):
    try: return set(DECL.findall(open(path, encoding="utf-8").read()))
    except OSError: return set()
declared_in = {}
for f in glob.glob(os.path.join(root, "Sources", "*.swift")):
    for t in decls(f): declared_in.setdefault(t, set()).add(os.path.basename(f))
unique = {t: next(iter(fs)) for t, fs in declared_in.items() if len(fs) == 1}
uses_cache = {}
def uses(path):
    if path not in uses_cache:
        try: uses_cache[path] = set(re.findall(r"\b([A-Z]\w*)\b", strip(open(path, encoding="utf-8").read())))
        except OSError: uses_cache[path] = set()
    return uses_cache[path]

scripts = sorted(set(glob.glob(os.path.join(root, "scripts", "build-*.sh")) + [os.path.join(root, "Tests", "run.sh")]
                     + glob.glob(os.path.join(root, "Tests", "run-*.sh"))))
fails, lists, skipped = [], 0, 0
for script in scripts:
    text = open(script, encoding="utf-8").read().replace("\\\n", " ")
    for line_no, line in enumerate(text.split("\n"), 1):
        if "swiftc" not in line or line.lstrip().startswith("#"): continue
        files = re.findall(r'"?\$(?:ROOT|\{ROOT\})/((?:Sources|Tests|HelperSources)/[\w./+-]+\.swift)"?', line)
        if not any(f.startswith("Sources/") for f in files): continue
        # A list that compiles a file the script writes at run time ("$DIR/x.swift", cut from a Sources file) cannot be read
        # here; it is skipped and counted, never passed by default.
        if re.search(r'"\$(?!ROOT\b|\{ROOT\})[A-Z_]+/[\w./+-]+\.swift"', line):
            skipped += 1
            continue
        lists += 1
        listed = {os.path.basename(f) for f in files}
        declared = set()
        for f in files: declared |= decls(os.path.join(root, f))
        missing = {}
        for f in files:
            for t in uses(os.path.join(root, f)):
                home = unique.get(t)
                if home and home not in listed and t not in declared:
                    missing.setdefault(home, set()).add(t)
        for home, types in sorted(missing.items()):
            fails.append(f"{os.path.relpath(script, root)} (swiftc list {lists}): Sources/{home} is used ({', '.join(sorted(types)[:3])}) but not compiled")
if fails:
    print("\n".join("compile list pin FAILED " + f for f in fails)); sys.exit(1)
print(f"compile list pins: {lists} swiftc lists, every used Sources type compiled ({skipped} that compile a generated file skipped)")
