#!/usr/bin/env python3
"""0.5.380 (Miles 2026-11-08, server 7.0.5 parity): the Messages pane structures a COS answer's inline numbered lists with
Sources/LensAnswerStructure.swift, a port of structureLensAnswer in the server's web-control/app.js. This reads BOTH repos:

  * the four patterns and the label limit against app.js's LA_STRUCTURED, LA_MARK, LA_END, LA_GUARD and LA_LABEL_MAX (the
    JavaScript \\d is written [0-9] and \\S is [^\\s\\x{0B}\\x{FEFF}] in Swift, because ICU's are wider and narrower);
  * every case in the web's lens-answer-structure-web.test.ts against the table in Tests/LensAnswerStructureChecks.swift,
    which executes them (a web case missing here, or expecting a different answer, fails);
  * where the pane applies it (the COS side of a turn in the recent reader and the archive chat, never your words), every
    app compile list, and the run.sh lane.

    lens-answer-parity-pins.py <control root> [<server web-control dir>]

The server folder is the second argument, else COS_SERVER_WEB_CONTROL, else the first holding structureLensAnswer of the
7.0.5 release worktree and the server checkout, under $HOME and the account's real home (the release runner gives tests a
private HOME). None found is a failure, never a skip: a pin that cannot read the server proves nothing.
Each failure names its behaviour as "pin failed [<behaviour>]".
"""
import os, pathlib, pwd, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")
    passed += 1


def code(rel):
    return "\n".join(re.sub(r"(^|\s)//.*$", "", line) for line in (root / rel).read_text(encoding="utf-8").split("\n"))


# ── Find the server's web-control folder.
homes = []
for h in (pathlib.Path.home(), pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)):
    if h not in homes:
        homes.append(h)
candidates = [sys.argv[2]] if len(sys.argv) > 2 else []
candidates.append(os.environ.get("COS_SERVER_WEB_CONTROL", ""))
for home in homes:
    candidates += [str(home / "cos-worktrees/server-preview-705/server/web-control"),
                   str(home / "Documents/GitHub/cos-glasses-app/server/web-control")]
web = None
for c in candidates:
    if c and (pathlib.Path(c) / "app.js").is_file() and "function structureLensAnswer(" in (pathlib.Path(c) / "app.js").read_text(encoding="utf-8"):
        web = pathlib.Path(c)
        break
pin(web is not None, "server", "no server web-control/app.js with structureLensAnswer found; pass its folder or set COS_SERVER_WEB_CONTROL")
app = (web / "app.js").read_text(encoding="utf-8")
web_test = (web / "lens-answer-structure-web.test.ts").read_text(encoding="utf-8")
swift = code("Sources/LensAnswerStructure.swift")
checks = (root / "Tests/LensAnswerStructureChecks.swift").read_text(encoding="utf-8")

# ── The patterns.
JS_TO_ICU = [(r"\d", "[0-9]"), (r"\S", r"[^\s\x{0B}\x{FEFF}]")]


def js_regex(name):
    m = re.search(r"var " + name + r" = /(.*)/([a-z]*);\n", app)
    pin(m is not None, "patterns", f"app.js {name} not found")
    source = m.group(1)
    for js, icu in JS_TO_ICU:
        source = source.replace(js, icu)
    pin("\\" not in re.sub(r"\\[tn.|*+?()\[\]{}^$/-]|\\s|\\x\{[0-9A-F]+\}", "", source), "patterns",
        f"app.js {name} has an escape this pin does not translate: {m.group(1)}")
    return source, m.group(2)


def swift_pattern(name):
    m = re.search(r"static let " + name + r' = #"(.*)"#\n', swift)
    pin(m is not None, "patterns", f"Swift {name} not found")
    return m.group(1)


for js, sw, flags, options in (("LA_STRUCTURED", "structuredPattern", "m", "[.anchorsMatchLines]"),
                               ("LA_MARK", "markPattern", "g", None),
                               ("LA_END", "endPattern", "g", None),
                               ("LA_GUARD", "guardPattern", "g", None)):
    source, js_flags = js_regex(js)
    pin(source == swift_pattern(sw), "patterns", f"{sw} is not app.js {js}: {swift_pattern(sw)!r} vs {source!r}")
    pin(js_flags == flags, "patterns", f"app.js {js} flags changed to {js_flags!r}: the Swift options need a look")
    var = {"structuredPattern": "structured", "markPattern": "mark", "endPattern": "end", "guardPattern": "codeSpan"}[sw]
    want = f"private static let {var} = try! NSRegularExpression(pattern: {sw}" + (f", options: {options})" if options else ")")
    pin(want in swift, "patterns", f"Swift compiles {sw} with the web's flags ({want})")
label = re.search(r"var LA_LABEL_MAX = (\d+);", app)
pin(label is not None and f"static let labelMax = {label.group(1)}\n" in swift, "label limit", "labelMax is app.js LA_LABEL_MAX")
pin("if (s.indexOf('. ') < 0 || LA_STRUCTURED.test(s)) return s;" in app
    and 'if whole.range(of: ". ", options: .literal).location == NSNotFound { return text }' in swift, "early exit",
    "no \". \" or any Markdown structure: the text comes back as it is, on both sides")
pin("if (lists && !first.colon) continue;" in app and "if lists > 0 && !first.colon { continue }" in swift, "after a list",
    "after a list only a Label: lead-in starts another")
pin("if (from >= 0 && first.ws - to <= LA_LABEL_MAX)" in app and "if from >= 0 && first.ws - to <= labelMax {" in swift, "label limit",
    "the lead-in gets its own line only when it is short")
pin("cur = c.n === 1 ? [c] : [];" in app and "cur = c.n == 1 ? [c] : []" in swift and "cur.length >= 2" in app and "cur.count >= 2" in swift,
    "runs", "runs start at 1, go up by one, and need two items")
pin("out.push(r !== lines[i] && i < lines.length - 1 ? r + '\\n' : r);" in app
    and 'out.append(index < lines.count - 1 ? listed + "\\n" : listed)' in swift, "blank line", "a line that became a list ends with a blank line")

# ── The case table: every web case is in the Swift table, with the same answer.
JS_LIT = r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\""
SW_LIT = r'"((?:[^"\\]|\\.)*)"'


def decode(s):
    out, i = [], 0
    while i < len(s):
        if s[i] != "\\":
            out.append(s[i])
            i += 1
            continue
        n = s[i + 1]
        if n in "ntr":
            out.append({"n": "\n", "t": "\t", "r": "\r"}[n])
            i += 2
        elif n in "\"'\\`":
            out.append(n)
            i += 2
        elif n == "u" and s[i + 2] == "{":
            j = s.index("}", i)
            out.append(chr(int(s[i + 3:j], 16)))
            i = j + 1
        else:
            pin(False, "case table", f"an escape this pin does not read: \\{n}")
    return "".join(out)


def js_lits(text):
    return [decode(m.group(1) if m.group(1) is not None else m.group(2)) for m in re.finditer(JS_LIT, text)]


web_cases = []
for m in re.finditer(r"expect\(f\((" + JS_LIT + r")\)\)\.toBe\((" + JS_LIT + r")\)", web_test):
    web_cases.append((js_lits(m.group(1))[0], js_lits(m.group(4))[0]))
for block in re.findall(r"const cases = \[\n(.*?)\n    \]", web_test, re.S) + re.findall(r"for \(const c of \[\n(.*?)\n    \]\)", web_test, re.S):
    web_cases += [(c, c) for c in js_lits(block)]
for m in re.finditer(r"const c = (" + JS_LIT + r")\n\s*expect\(f\(c\)\)\.toBe\(c\)", web_test):
    web_cases.append((js_lits(m.group(1))[0], js_lits(m.group(1))[0]))
t455 = re.search(r"const T455 = (" + JS_LIT + r")\n", web_test)
e455 = re.search(r"const E455 = (.*?)\n\n", web_test, re.S)
pin(t455 is not None and e455 is not None, "case table", "the web's T455 and E455 not found")
web_cases.append((js_lits(t455.group(1))[0], "".join(js_lits(e455.group(1)))))
pin(len(web_cases) >= 28, "case table", f"read only {len(web_cases)} web cases; the web test changed shape")

table = checks.split("// CASES BEGIN", 1)[1].split("// CASES END", 1)[0] if "// CASES BEGIN" in checks and "// CASES END" in checks else ""
swift_cases = set()
for line in table.split("\n"):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    m = re.fullmatch(r"\(" + SW_LIT + ", " + SW_LIT + r"\),", line)
    pin(m is not None, "case table", f"a Swift case line this pin cannot read: {line[:80]}")
    swift_cases.add((decode(m.group(1)), decode(m.group(2))))
t = re.search(r"^let T455 = " + SW_LIT + "$", checks, re.M)
e = re.search(r"^let E455 = " + SW_LIT + "$", checks, re.M)
pin(t is not None and e is not None, "case table", "the Swift T455 and E455 not found")
swift_cases.add((decode(t.group(1)), decode(e.group(1))))
for case in web_cases:
    pin(case in swift_cases, "case table", f"the web case {case[0]!r} -> {case[1]!r} is not in Tests/LensAnswerStructureChecks.swift")
pin("check(f(T455) == E455" in checks and "for (input, expected) in cases {" in checks and "check(out == expected" in checks,
    "case table", "the Swift checks execute the table")
pin("'x'.repeat(120)" in web_test and 'String(repeating: "x", count: 120)' in checks, "case table", "the label-limit case runs on both sides")

# ── Where the pane applies it: the COS side only, in the recent reader and the archive chat.
window = code("Sources/ActivityWindow.swift")
pin(window.count("LensAnswerStructure.structure(") == 2, "messages", "applied at exactly the two places a COS answer is drawn")
pin('messageBlock(label: "COS", text: LensAnswerStructure.structure(turn.text),' in window, "messages", "the recent reader's COS answer")
pin('messageBlock(label: "COS", text: LensAnswerStructure.structure(message.text),' in window, "messages", "the archive chat's COS answer")
# The COS chat (Drop it) answer card: the Mac side of the web chat card in Miles's 11/08 screenshot.
dropit = code("Sources/DropItViews.swift")
pin(dropit.count("LensAnswerStructure.structure(") == 1 and "COSMarkdownView(text: LensAnswerStructure.structure(answer))" in dropit, "messages", "the COS chat answer card")
pin('messageBlock(label: "You", text: turn.query,' in window and 'messageBlock(label: "You", text: message.query,' in window,
    "your words", "what you said is shown as you typed it")
model = code("Sources/ControllerModel.swift")
pin("LensAnswerStructure" not in model, "copy", "Copy turn reads the stored text, never the structured one")

# ── Every app compile list carries the new file, and run.sh runs the lane.
for rel in ("Tests/run.sh", "scripts/build-release.sh", "scripts/build-foundation-lab.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh",
            "Tests/run-markdown-ui.sh", "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh"):
    text = code(rel)
    pin(text.count('"$ROOT/Sources/LensAnswerStructure.swift"') == text.count('"$ROOT/Sources/SessionPreviews.swift"') >= 1, "compile lists",
        f"{rel} compiles LensAnswerStructure.swift wherever it compiles the app")
run_sh = code("Tests/run.sh")
pin('zsh "$ROOT/Tests/run-lens-answer.sh"' in run_sh, "lane", "run.sh runs the Swift checks (and this pin through them)")

print(f"lens answer parity pins: {passed} passed ({len(web_cases)} web cases)")
