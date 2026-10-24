#!/usr/bin/env python3
# 0.5.342: the running build number must survive a dotted CFBundleVersion. A local build stamped "394.2" made
# `Int("394.2")` nil, so currentBuild read 0 and the panel offered the older public 0.5.339 (build 393) as an update.
import re, sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
SRC = (ROOT / "Sources/ControllerModel.swift").read_text(encoding="utf-8")

class PinFailed(Exception): pass

def check(src):
    if 'static var currentBuild: Int { parseBuild(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) }' not in src:
        raise PinFailed("currentBuild must go through parseBuild")
    m = re.search(r"static func parseBuild\(_ raw: String\?\) -> Int \{\n(.*?)\n    \}", src, re.S)
    if not m: raise PinFailed("parseBuild is missing")
    if ".prefix(while: \\.isNumber)" not in m.group(1): raise PinFailed("parseBuild must keep the leading whole number")
    if re.search(r'Int\(Bundle\.main\.object\(forInfoDictionaryKey: "CFBundleVersion"\)', src):
        raise PinFailed("a second raw Int(CFBundleVersion) parse would read 394.2 as 0 again")

MUTANTS = [
    ("raw Int parse", 'static var currentBuild: Int { parseBuild(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) }',
     'static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }'),
    ("no prefix", ".prefix(while: \\.isNumber)", ""),
]
check(SRC)
for name, old, new in MUTANTS:
    if SRC.count(old) != 1: sys.exit(f"mutant '{name}' lands {SRC.count(old)} times")
    try: check(SRC.replace(old, new))
    except PinFailed as e: print(f"KILLED  {name}  <- {e}"); continue
    sys.exit(f"mutant '{name}' survived")
print(f"PASS build number pins: dotted local builds keep their number; {len(MUTANTS)} of {len(MUTANTS)} mutants caught")
