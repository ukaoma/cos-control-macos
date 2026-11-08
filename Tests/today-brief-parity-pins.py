#!/usr/bin/env python3
"""QA 0.5.379: the Today summary numbers this app copies from the server, read from BOTH repos and compared.

The server owns them (server/lib/today-brief.ts): the 10-minute interval, 60 a day, the 30 s refresh floor, 40 session rows,
12 needs, the per-field text limits, the session key pattern, the source names, the 48 KiB body bound and the fields of
TodayBriefView. Control restates them in Sources/Models.swift (TodaySummary, its Settings blurb), HelperSources/main.swift
(the helper's stdin bound) and Tests/fixtures/today-running-now.json (the view's field list). A drift on either side fails.

    today-brief-parity-pins.py <control root> [<server today-brief.ts>]

The server file is the second argument, else COS_SERVER_TODAY_BRIEF, else the first that exists of the 7.0.4 release
worktree and the server checkout. None found is a failure, never a skip: a pin that cannot read the server proves nothing.
"""
import json, os, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
# The release runner gives tests a private HOME (/tmp/cos-native-*/home), so look under the account's real home
# (the password database) as well as $HOME. 0.5.379 run at 7558690 failed here with the file present.
import pwd
homes = []
for h in (pathlib.Path.home(), pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)):
    if h not in homes: homes.append(h)
candidates = [sys.argv[2]] if len(sys.argv) > 2 else []
candidates.append(os.environ.get("COS_SERVER_TODAY_BRIEF", ""))
for home in homes:
    candidates += [str(home / "cos-worktrees/server-tool-images-release-7.0.4/server/lib/today-brief.ts"),
                   str(home / "Documents/GitHub/cos-glasses-app/server/lib/today-brief.ts")]
server_path = next((pathlib.Path(c) for c in candidates if c and pathlib.Path(c).is_file()), None)
if server_path is None:
    sys.exit("FAIL: Today brief parity pin: server/lib/today-brief.ts not found; pass it or set COS_SERVER_TODAY_BRIEF")
ts = server_path.read_text(encoding="utf-8")
models = (root / "Sources/Models.swift").read_text(encoding="utf-8")
helper = (root / "HelperSources/main.swift").read_text(encoding="utf-8")
fixture = json.loads((root / "Tests/fixtures/today-running-now.json").read_text(encoding="utf-8"))
failures = []


def need(ok, what):
    if not ok:
        failures.append(what)


def ts_number(name):
    m = re.search(r"export const " + name + r" = ([0-9_ *]+)\n", ts)
    if not m:
        failures.append(f"server constant {name} not found")
        return None
    return eval(m.group(1).replace("_", ""), {"__builtins__": {}})  # digits, underscores, spaces and * only


def swift_int(name, text=models):
    m = re.search(r"static let " + name + r"(?:: \w+)? = ([0-9 *]+)\n", text)
    if not m:
        failures.append(f"Swift constant {name} not found")
        return None
    return eval(m.group(1), {"__builtins__": {}})


interval_ms = ts_number("TODAY_BRIEF_MIN_INTERVAL_MS")
cap = ts_number("TODAY_BRIEF_DAILY_CAP")
force_ms = ts_number("TODAY_BRIEF_FORCE_MIN_MS")
body_bytes = ts_number("TODAY_BRIEF_BODY_MAX_BYTES")

blurb = re.search(r'static let blurb = "([^"\n]*)"', models)
blurb = blurb.group(1) if blurb else ""
need(interval_ms is not None and f"at most every {interval_ms // 60000} minutes" in blurb, "the blurb's interval is the server's TODAY_BRIEF_MIN_INTERVAL_MS")
need(cap is not None and f"{cap} times a day" in blurb, "the blurb's daily count is the server's TODAY_BRIEF_DAILY_CAP")
need(cap is not None and f"statusCount ?? {cap}" in models, "the daily-cap line's fallback is the server's TODAY_BRIEF_DAILY_CAP")
need(force_ms is not None and f"at most every {force_ms // 1000} seconds" in blurb, "the blurb's refresh floor is the server's TODAY_BRIEF_FORCE_MIN_MS")
need(force_ms is not None and swift_int("refreshFloorSeconds") == force_ms // 1000, "refreshFloorSeconds is the server's TODAY_BRIEF_FORCE_MIN_MS")
need(body_bytes is not None and swift_int("bodyMaxBytes") == body_bytes, "TodaySummary.bodyMaxBytes is the server's TODAY_BRIEF_BODY_MAX_BYTES")
need(body_bytes is not None and swift_int("todayBriefBodyMaxBytes", helper) == body_bytes, "the helper's stdin bound is TODAY_BRIEF_BODY_MAX_BYTES")
need("readBoundedStdin(Self.todayBriefBodyMaxBytes)" in helper, "the helper reads stdin through that bound")

limits = re.search(r"const LIMITS = \{([^}]*)\}", ts)
limits = dict((k.strip(), int(v)) for k, v in (pair.split(":") for pair in limits.group(1).split(","))) if limits else {}
for server_key, swift_name in (("sessions", "sessionRowsMax"), ("needs", "needRowsMax"), ("title", "titleMax"), ("line", "lineMax"),
                               ("waiting", "waitingMax"), ("needTitle", "needTitleMax"), ("needWhy", "needWhyMax")):
    need(server_key in limits and swift_int(swift_name) == limits[server_key], f"TodaySummary.{swift_name} is the server's LIMITS.{server_key}")

key_ts = re.search(r"const SESSION_KEY = /(.+)/\n", ts)
key_swift = re.search(r'sessionKey = try! NSRegularExpression\(pattern: "(.+)"\)', models)
need(bool(key_ts and key_swift) and key_swift.group(1).replace("\\\\", "\\") == key_ts.group(1), "the session key pattern is the server's SESSION_KEY")

unread_ts = re.search(r"const UNREAD_NAMES = new Set\(\[([^\]]*)\]\)", ts)
unread_swift = re.search(r"unreadNames: Set<String> = \[([^\]]*)\]", models)
names = lambda m: sorted(re.findall(r"['\"]([^'\"]+)['\"]", m.group(1))) if m else None
need(names(unread_ts) is not None and names(unread_ts) == names(unread_swift), "the unread source names are the server's UNREAD_NAMES")

view = re.search(r"export interface TodayBriefView \{(.*?)\n\}", ts, re.S)
fields = re.findall(r"^\s+(\w+)\??:", view.group(1), re.M) if view else []
need(bool(fields) and sorted(fields) == sorted(fixture.get("fields", [])),
     f"Tests/fixtures/today-running-now.json fields are TodayBriefView's ({sorted(fields)} vs {sorted(fixture.get('fields', []))})")

if failures:
    for f in failures:
        print("FAIL: Today brief parity pin: " + f, file=sys.stderr)
    sys.exit(1)
print(f"PASS: Today brief parity with {server_path} (interval, daily cap, refresh floor, rows, text limits, key, names, 48 KiB, view fields)")
