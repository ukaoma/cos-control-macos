#!/usr/bin/env python3
"""0.5.380 (preview engine phase 1, Miles's 11/08 Sessions reader screenshot): the Sessions reader shows an assistant reply's
local links as their cards' words and drops its local image tokens (Sources/SessionReplyLinks.swift), a port of the server's
link and image scanners. This reads BOTH repos:

  * the server rules the port depends on: linkTokens, isLocalTarget, splitLineAnchor, baseName, linkLabel and linkCardWords in
    server/lib/session-links.ts, imageTokens in server/lib/agent-session-output-images.ts (each by its regexes and limits,
    named, and by a fingerprint of the whole function, so any edit there asks for a re-port), the card name
    resolveLinkTarget derives, the projection's scan bound and filter, and the scan limits against the Swift constants;
  * the Swift table and golden replies (Tests/SessionReplyLinksChecks.swift, Tests/fixtures/session-reply-links-golden.json);
  * where the reader applies it (the assistant side of a Sessions turn, never what you typed, never Messages, never Copy),
    every app compile list, and the run.sh lane.

    session-reply-links-parity-pins.py <control root> [<server session-links.ts>]

The server file is the second argument, else COS_SERVER_SESSION_LINKS, else the first holding linkTokens of the 7.0.7 public
worktree, the 7.0.6 viewer worktree and the server checkout, under $HOME and the account's real home (the release runner
gives tests a private HOME). None found is a failure, never a skip: a pin that cannot read the server proves nothing.
Each failure names its behaviour as "pin failed [<behaviour>]".

After a deliberate server change: re-port it in Sources/SessionReplyLinks.swift (and Tests/session-reply-links-port/model.py),
run Tests/session-reply-links-port/harness.py --write to compare with the server and regenerate the golden fixture from the
server's functions, then update FINGERPRINTS below.
"""
import hashlib, json, os, pathlib, pwd, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")
    passed += 1


def code(rel):
    return "\n".join(re.sub(r"(^|\s)//.*$", "", line) for line in (root / rel).read_text(encoding="utf-8").split("\n"))


def function(src, head):
    i = src.find(head)
    pin(i >= 0, "server", f"{head!r} not found")
    j = src.find("\n}\n", i)
    pin(j > i, "server", f"the end of {head!r} not found")
    return src[i:j + 2]


# ── Find the server.
homes = []
for h in (pathlib.Path.home(), pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)):
    if h not in homes:
        homes.append(h)
candidates = [sys.argv[2]] if len(sys.argv) > 2 else []
candidates.append(os.environ.get("COS_SERVER_SESSION_LINKS", ""))
for home in homes:
    candidates += [str(home / "cos-worktrees/server-707-public/server/lib/session-links.ts"),
                   str(home / "cos-worktrees/server-706-viewer/server/lib/session-links.ts"),
                   str(home / "Documents/GitHub/cos-glasses-app/server/lib/session-links.ts")]
links_path = None
for c in candidates:
    p = pathlib.Path(c) if c else None
    if p and p.is_file() and "export function linkTokens(" in p.read_text(encoding="utf-8"):
        links_path = p
        break
pin(links_path is not None, "server", "no server/lib/session-links.ts with linkTokens found; pass it or set COS_SERVER_SESSION_LINKS")
images_path = links_path.parent / "agent-session-output-images.ts"
pin(images_path.is_file(), "server", f"{images_path} not found beside session-links.ts")
links = links_path.read_text(encoding="utf-8")
images = images_path.read_text(encoding="utf-8")
swift = code("Sources/SessionReplyLinks.swift")

# ── The scan limits, both repos.
def ts_const(src, name):
    m = re.search(r"export const " + name + r" = ([0-9 *]+)\n", src)
    pin(m is not None, "limits", f"server constant {name} not found")
    return eval(m.group(1), {"__builtins__": {}})


def swift_const(name):
    m = re.search(r"static let " + name + r" = ([0-9 *]+)\n", swift)
    pin(m is not None, "limits", f"Swift constant {name} not found")
    return eval(m.group(1), {"__builtins__": {}})


scan = swift_const("scanChars")
pin(ts_const(links, "LINK_SCAN_CHARS") == scan, "limits", "LINK_SCAN_CHARS differs from SessionReplyLinks.scanChars")
pin(ts_const(images, "OUTPUT_IMAGE_SCAN_CHARS") == scan, "limits", "OUTPUT_IMAGE_SCAN_CHARS differs from SessionReplyLinks.scanChars")
pin(swift_const("labelSpan") == 250 and swift_const("targetMax") == 4096 and swift_const("wordsMax") == 120, "limits",
    "the Swift label span, destination bound and word cut must be 250, 4096 and 120 (pinned below on the server side)")

# ── The server rules, by name. Each is a substring of the function the port copies.
link_tokens = function(links, "export function linkTokens(")
image_tokens = function(images, "function imageTokens(")
RULES = [
    (link_tokens, "inert regions", "/^(?: {4}| {0,3}\\t)/.test(text.slice(i, i + 4))"),
    (link_tokens, "inert regions", "/^( {0,3})(`{3,}|~{3,})/.exec(text.slice(i, i + 80))"),
    (link_tokens, "inert regions", "if (m) { if (!fence) fence = m[2]; else if (m[2][0] === fence[0] && m[2].length >= fence.length) fence = ''"),
    (link_tokens, "inert regions", "if (text[i] === '\\\\') { i++; continue }"),
    (link_tokens, "inert regions", "if (!inline) inline = n; else if (inline === n) inline = 0; i += n - 1; continue"),
    (link_tokens, "inert regions", "if (text.startsWith('<!--', i)) { const end = text.indexOf('-->', i + 4); if (end < 0) break; i = end + 2; continue }"),
    (link_tokens, "link token", "if (text[i] !== '[' || text[i - 1] === '!') continue"),
    (link_tokens, "link token", "if (close < 0 || close - i > 250 || text[close + 1] !== '(') continue"),
    (link_tokens, "link token", "if (label.includes('[') || label.includes('\\n')) continue"),
    (link_tokens, "link token", "if (end >= 0 && text[end + 1] === ')' && !text.slice(j + 1, end).includes('\\n'))"),
    (link_tokens, "link token", "while (j < text.length && j - start <= 4096) {"),
    (link_tokens, "link token", "if (!valid || !target || target.length > 4096 || /[\\u0000-\\u001f\\u007f]/.test(target)) continue"),
    (link_tokens, "link token", "const titled = /^(\\S+)\\s+\"[^\"]*\"$/.exec(target)"),
    (link_tokens, "link token", "const text = raw.slice(0, scanChars)"),
    (function(links, "export function isLocalTarget("), "local target",
     "if (!target || target.startsWith('#') || target.startsWith('//') || target.includes('\\\\')) return false"),
    (function(links, "export function isLocalTarget("), "local target", "if (/^file:\\/\\//i.test(target)) return true"),
    (function(links, "export function isLocalTarget("), "local target", "return !/^[a-z][a-z0-9+.-]*:/i.test(splitLineAnchor(target).path)"),
    (function(links, "export function splitLineAnchor("), "line anchor", "/^(.*?)#L(\\d{1,7})(?:C\\d+)?(?:-L?\\d{1,7})?$/"),
    (function(links, "export function splitLineAnchor("), "line anchor", "/^(.*?):(\\d{1,7})(?::\\d{1,5}|-\\d{1,7})?$/"),
    (function(links, "export function splitLineAnchor("), "line anchor", "if (m && m[1] && !/:$/.test(m[1]))"),
    (function(links, "export function splitLineAnchor("), "line anchor", "return { path: hash > 0 ? target.slice(0, hash) : target }"),
    (function(links, "export function baseName("), "base name", "source.split(/[\\\\/]/).filter(Boolean).pop() || ''"),
    (function(links, "export function baseName("), "base name", "return (clean || 'File').slice(0, 120)"),
    (function(links, "export function linkLabel("), "link words",
     "if (/^(?:file:\\/\\/|~\\/|\\/)/.test(clean) || /(?:^|[\\s(`'\"])(?:\\/Users\\/|\\/private\\/|\\/Volumes\\/|\\/var\\/folders\\/)/.test(clean)) return baseName(clean.replace(/^file:\\/\\//, ''))"),
    (function(links, "export function linkLabel("), "link words", "return clean.slice(0, 120)"),
    (function(links, "export function linkCardWords("), "link words", "return words === own || words === name ? words + ':' + line : words"),
    (function(links, "export function linkCardWords("), "link words", "const own = baseName(path.replace(/^file:\\/\\//i, ''))"),
    (image_tokens, "image token", "const text = raw.slice(0, OUTPUT_IMAGE_SCAN_CHARS)"),
    (image_tokens, "image token", "if (text.slice(i, i + 2) !== '![') continue"),
    (image_tokens, "image token", "if (endLabel < 0 || endLabel - i > 250 || text.slice(i, endLabel).includes('\\n')) continue"),
    (image_tokens, "image token", "if (end >= 0 && text[end + 1] === ')') { source = text.slice(j + 1, end); j = end + 2; valid = true }"),
    (image_tokens, "image token", "if (/^[a-z][a-z0-9+.-]*:/i.test(source) || source.startsWith('//') || source.includes('\\\\')) { i = j - 1; continue }"),
    (links, "card name", "const { path: written } = splitLineAnchor(rawTarget)"),
    (links, "card name", "if (/%[0-9a-f]{2}/i.test(written)) { try { const d = decodeURIComponent(written); if (d !== written) variants.push(d) } catch { /* keep as written */ } }"),
    (links, "card name", "const name = baseName(variants[variants.length - 1])"),
    (images, "projection", "const scanned = shortened ? raw.slice(0, raw.lastIndexOf('\\n', OUTPUT_IMAGE_SCAN_CHARS - 1) + 1) : raw"),
    (images, "projection", "const linked = linkTokens(scanned).filter(l => isLocalTarget(l.target) && !candidates.some(c => l.start < c.end && c.start < l.end))"),
    (images, "projection", "return '[' + linkCardWords(token.label, linkRefs[n].name, token.target) + '](cos-file:' + n + ')'"),
    (images, "projection", "const name = resolved.name"),
]
for src, behaviour, rule in RULES:
    pin(rule in src, behaviour, f"the server no longer reads {rule!r}; re-port it in Sources/SessionReplyLinks.swift")

# Every function the port copies, whole: any edit there (a new rule, a moved bound) fails here until it is re-ported.
FINGERPRINTS = {
    (links, "export function linkTokens("): "9dfc9bb5cb057d50",
    (links, "export function isLocalTarget("): "e4799381d96f007b",
    (links, "export function splitLineAnchor("): "b5b8d89470ad704e",
    (links, "export function baseName("): "6cd8b8494e0e1559",
    (links, "export function linkLabel("): "1719efaa104257ea",
    (links, "export function linkCardWords("): "860b31be41453386",
    (images, "function imageTokens("): "1ba75aed8b38ac98",
}
for (src, head), want in FINGERPRINTS.items():
    got = hashlib.sha256(function(src, head).encode("utf-8")).hexdigest()[:16]
    pin(got == want, "fingerprint", f"{head!r} changed on the server ({got}, ported {want}); re-port, regenerate the golden fixture, update the fingerprint")

# The Swift port names each rule it copies.
for name in ("static func linkTokens(", "static func imageTokens(", "static func isLocalTarget(", "static func splitLineAnchor(",
             "static func baseName(", "static func linkLabel(", "static func linkCardWords(", "static func cardName(",
             "static func decodeURIComponent(", "static func readerText("):
    pin(name in swift, "port", f"Sources/SessionReplyLinks.swift lost {name}")
pin("guard mayHaveToken(text) else { return text }" in swift and "if images.isEmpty && links.isEmpty { return text }" in swift,
    "port", "a reply with nothing local is returned as it came")

# ── The table and the golden replies.
checks = (root / "Tests/SessionReplyLinksChecks.swift").read_text(encoding="utf-8")
SW_LIT = r'"((?:[^"\\]|\\.)*)"'
m_in = re.search(r"^let MILES = " + SW_LIT + "$", checks, re.M)
m_out = re.search(r"^let MILES_READER = " + SW_LIT + "$", checks, re.M)
pin(m_in is not None and m_out is not None, "case table", "MILES and MILES_READER not found")
for part in ("![Preview test chart](/Users/", "- [Preview test note](/Users/", "- [preview-test-code.ts:7](/Users/"):
    pin(part in m_in.group(1), "case table", f"Miles's reply lost {part!r}")
for part in ("- Preview test note: ", "- Preview test page: ", "- Preview test table: ", "- preview-test-code.ts:7: "):
    pin(part in m_out.group(1), "case table", f"Miles's reply must read {part!r}")
pin("/Users/" not in m_out.group(1) and "![" not in m_out.group(1), "case table", "Miles's reply keeps no Mac path and no image token")
table = checks[checks.index("// CASES BEGIN"):checks.index("// CASES END")]
for needle, what in (("](docs/plan.md)", "a relative link"), ("](~/Desktop/", "a ~/ link"), ("](file:///", "a file:// link"),
                     ("`[a](b.md)`", "a link in a code span"), ("```\\n[a](b.md)", "a link in a fence"),
                     ("](https://example.com/a.md)", "a web link"), ("![logo](https://", "a web image"),
                     ("](</Users/x/Q3 Plan/", "an angle-wrapped target with spaces"), ("[/Users/x/plan.md](/Users/x/plan.md)", "a path label"),
                     ("![a](a.png)\\n![b](b.png)", "lines left empty"), ("Nothing to see.", "a no-op reply")):
    pin(needle in table, "case table", f"the table lost {what}")
pin("for (input, expected) in cases {" in checks and "check(same(out, expected)" in checks and "for row in golden {" in checks,
    "case table", "the Swift checks execute the table and the golden replies, unit for unit")
golden = json.loads((root / "Tests/fixtures/session-reply-links-golden.json").read_text(encoding="utf-8"))
pin(len(golden) >= 300 and all(isinstance(r, list) and len(r) == 2 for r in golden), "golden", "the golden fixture holds 300 [reply, reader] pairs")
pin(sum(1 for a, b in golden if a != b) >= 250, "golden", "most golden replies carry a local link or image")

# ── Where the reader applies it: the assistant side of a Sessions turn only.
window = code("Sources/ActivityWindow.swift")
pin(window.count("SessionReplyLinks.") == 1, "reader", "applied at exactly one place")
i = window.find("struct ClaudeSessionDetailPane")
pane = window[i:window.find("\nstruct ", i + 10)] if i >= 0 else ""
branch = re.search(r"if turn\.isUser \{\s*Text\(turn\.text\)[\s\S]*?\} else \{\s*COSMarkdownView\(text: SessionReplyLinks\.readerText\(turn\.text\)\)\s*\}", pane)
pin(branch is not None, "reader", "the Sessions reader's assistant turn goes through readerText; what you typed stays Text(turn.text)")
for rel in sorted(p.relative_to(root).as_posix() for p in (root / "Sources").glob("*.swift")):
    if rel in ("Sources/SessionReplyLinks.swift", "Sources/ActivityWindow.swift"):
        continue
    pin("SessionReplyLinks" not in code(rel), "reader", f"{rel} must not use it (Messages and Copy keep the stored text)")

# ── Every app compile list carries the new file, and run.sh runs the lane.
lists = {p.relative_to(root).as_posix() for d in ("Tests", "scripts") for p in (root / d).glob("*.sh")
         if '"$ROOT/Sources/SessionPreviews.swift"' in p.read_text(encoding="utf-8")}
for rel in ("Tests/run.sh", "scripts/build-release.sh", "scripts/build-foundation-lab.sh", "Tests/run-held-ui.sh", "Tests/run-merge-ui.sh",
            "Tests/run-markdown-ui.sh", "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh", "Tests/run-session-previews.sh"):
    pin(rel in lists, "compile lists", f"{rel} no longer compiles SessionPreviews.swift; follow the list")
for rel in sorted(lists):
    text = (root / rel).read_text(encoding="utf-8")
    pin(text.count('"$ROOT/Sources/SessionReplyLinks.swift"') == text.count('"$ROOT/Sources/SessionPreviews.swift"'), "compile lists",
        f"{rel} compiles SessionReplyLinks.swift wherever it compiles SessionPreviews.swift")
run_sh = (root / "Tests/run.sh").read_text(encoding="utf-8")
pin('zsh "$ROOT/Tests/run-session-reply-links.sh"' in run_sh, "lane", "run.sh runs the Swift checks (and this pin through them)")
lane = (root / "Tests/run-session-reply-links.sh").read_text(encoding="utf-8")
pin('"$ROOT/Sources/SessionReplyLinks.swift" "$ROOT/Tests/SessionReplyLinksChecks.swift" -o "$OUT/checks"' in lane
    and '"$OUT/checks" "$ROOT/Tests/fixtures/session-reply-links-golden.json"' in lane
    and '/usr/bin/python3 "$ROOT/Tests/session-reply-links-parity-pins.py" "$ROOT"' in lane, "lane",
    "the lane runs this pin, compiles the rules alone and passes the golden fixture")

print(f"session reply links parity pins: {passed} passed ({links_path})")
