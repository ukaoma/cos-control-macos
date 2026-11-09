"""0.5.380: compare model.py (a line-for-line Python transliteration of Sources/SessionReplyLinks.swift) with the REAL server
functions (ref.mts runs session-links.ts and imageTokens through the server worktree's tsx) on the case table, three replies
past the scan limit and N generated replies. By hand, never in run.sh (it needs the server's node_modules):

    /usr/bin/python3 Tests/session-reply-links-port/harness.py [<server worktree>] [N] [--write]

--write regenerates Tests/fixtures/session-reply-links-golden.json from the server's answers (after a deliberate re-port).
Exit 1 on any difference."""
import json, os, random, re, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model as M

HERE = os.path.dirname(os.path.abspath(__file__))
ARGS = [a for a in sys.argv[1:] if a != "--write"]
WRITE = "--write" in sys.argv
SERVER = os.path.expanduser(ARGS[0] if ARGS else "~/cos-worktrees/server-707-public")
FUZZ = int(ARGS[1]) if len(ARGS) > 1 else 5000
CONTROL = os.path.dirname(os.path.dirname(HERE))


def swift_literal(name):
    src = open(os.path.join(CONTROL, "Tests/SessionReplyLinksChecks.swift"), encoding="utf-8").read()
    raw = re.search(r"^let " + name + r' = "((?:[^"\\]|\\.)*)"$', src, re.M).group(1)
    raw = re.sub(r"\\u\{([0-9A-F]+)\}", lambda m: chr(int(m.group(1), 16)), raw)
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), raw)


MILES = swift_literal("MILES")
CASES = [
    MILES,
    "See [plan](docs/plan.md) now.",
    "Saved to [notes](~/Desktop/notes.txt).",
    "[report](file:///Users/x/My%20Report.pdf)",
    "Open [](file:///Users/x/My%20Report.pdf) first.",
    "Run `[a](b.md)` and `![c](d.png)` here.",
    "```\n[a](b.md)\n![c](d.png)\n```",
    "See [docs](https://example.com/a.md) and [mail](mailto:x@y.z).",
    "![logo](https://example.com/logo.png)",
    "Open [the deck](</Users/x/Q3 Plan/deck final.pptx>) today.",
    "[/Users/x/plan.md](/Users/x/plan.md)",
    "[/Users/x/app.ts](/Users/x/app.ts#L42)",
    "Here:\n\n![a](a.png)\n![b](b.png)\n\nDone.",
    "- ![a](out/a.png)\n- [b](b.md)",
    "Nothing to see. [x] (y) and ](here).",
    "Chart ![c](c.png) above",
    "Chart: ![c](c.png)\nNext line.",
    'Read [spec](docs/spec.md "The spec").',
    "    [a](b.md)\n",
    "<!-- [a](b.md) -->",
    "\\[a](b.md)",
    "[top](#top)",
    "[app.ts](src/app.ts:42) and [the handler](src/app.ts:42)",
    "[site](https://x.com) and [file](a.md)",
    "Look: [plan](Q3%20plan.md)",
    "Look: [](Q3%20plan.md) and [](bad%zzname.md)",
    "![chart](</Users/x/My Charts/c.png>)\n\nThe chart above.",
    "Shot:\n\n![s](shot.png)",
    "1. ![a](a.png)\n2. [b](b.md)",
    "[b:](a/b::12) and [](docs/" + "n" * 125 + ".md:3)",
]


def long_cases():
    filler = ("word " * 15 + "\n") * 1800  # ~144K units
    a = "[early](a.md)\n" + filler + "[late](z.md)\n"
    b = "Intro\n\n![x](x.png)\n\n" + filler + "![y](y.png)\n"
    c = "x" * (128 * 1024 + 50) + "[a](b.md)"
    return [a, b, c]


FRAGS = ["[", "]", "(", ")", "![", "](", "<", ">", "`", "``", "```", "~~~", "\\", "\n", "\n\n", "    ", "\t", " ", "  ",
         "<!--", "-->", '"', ' "t"', "#", "#L4", "#L12-L20", "#L3C2", ":7", ":12:3", ":5-9", "-", "* ", "1. ", "- ",
         "http://a.b/c", "https://x.y", "mailto:q@r", "file://", "file:///Users/q/", "FILE://", "~/", "~", "/", "//",
         "/Users/u/", "/private/", "/var/folders/", "docs/", "a.md", "b.png", "c.ts", "x y.pdf", "%20", "%E2%82%AC", "%zz",
         "%C3", "%F0%9F%98%80", "%ED%A0%80", "label", "Plan", "é", " ", " ", "　", "﻿", "😀", "\r",
         "\u0001", "!", "x", "0", "42", ".", ")", "C"]


LABELS = ["", "Plan", "app.ts", "x y.pdf", "/Users/u/a.md", "file:///Users/u/b.md", "~/n.txt", "see (/private/x)", "a\u0001b",
          " c.ts ", "é", "\u00a0/Volumes/v/x.key", "`/Users/q`", "😀", "b:", "L" * 125, "/Users/u/" + "n" * 125 + ".md",
          "😀" * 61, "x" * 119 + "😀"]
TARGETS = ["a.md", "docs/plan.md", "/Users/u/x y.md", "<x y.md>", "</Users/u/A B/c.png>", "~/d.txt", "file:///Users/u/My%20F.pdf",
           "FILE:///x", "https://e.com/a.png", "mailto:a@b", "#top", "//host/x", "a\\b", "c.ts:42", "c.ts:0", "c.ts:12:3", "c.ts:5-9",
           "c.ts#L7", "c.ts#L7-L9", "c.ts#L3C2", "c.ts#x", ":12", "x::12", "a%20b.md", "a%zz.md", "%E2%82%AC.md", "%ED%A0%80.md",
           "%F0%9F%98%80.png", "%C3.md", "x (1).png", "x(1.png", 'p.md "T"', "p.md  'T'", "c:42", "s3:x", "x\u2028:7", "x.png",
           "a b.png", "", "x\ny.md", "<a\nb.md>", "q.ts:12345678", "q.ts#L12345678", "a/b::12",
           "a/b::7:3", "d/" + "N" * 125 + ".md:4", "d/" + "😀" * 61 + ".md"]


def fuzz(n, seed=380):
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        parts = []
        for _ in range(rnd.randint(1, 12)):
            r = rnd.random()
            if r < 0.45:
                bang = "!" if rnd.random() < 0.35 else ""
                parts.append(bang + "[" + rnd.choice(LABELS) + "](" + rnd.choice(TARGETS) + ")")
            else:
                parts.append("".join(rnd.choice(FRAGS) for _ in range(rnd.randint(1, 6))))
        out.append("".join(parts))
    return out


def norm(s):
    """What String(decoding:as:) shows: a lone surrogate becomes U+FFFD."""
    return M.from16(M.u16(s))


def main():
    inputs = CASES + long_cases() + fuzz(FUZZ)
    scratch = tempfile.mkdtemp(prefix="cos-reply-links-")
    src = os.path.join(scratch, "in.json"); dst = os.path.join(scratch, "out.json")
    json.dump(inputs, open(src, "w"))
    subprocess.run(["npx", "tsx", os.path.join(HERE, "ref.mts"), SERVER, src, dst], cwd=SERVER, check=True)
    ref = json.load(open(dst))
    shutil.rmtree(scratch, ignore_errors=True)
    ok_tokens = ok_text = 0
    bad = []
    for k, (s, r) in enumerate(zip(inputs, ref)):
        u = M.u16(s)
        cut = len(u)
        if len(u) > M.SCAN:
            cut = 0
            for q in range(M.SCAN - 1, -1, -1):
                if u[q] == M.NL: cut = q + 1; break
        scanned = u[:cut]
        imgs = M.image_tokens(scanned)
        lks = M.link_tokens(scanned)
        py_tok = {
            "images": [[a, b, M.from16(t)] for a, b, _, t in imgs],
            "links": [[a, b, M.from16(l), M.from16(t), M.is_local_target(t)] for a, b, l, t in lks],
            "words": [M.from16(M.card_words(l)) for l in lks if M.is_local_target(l[3]) and not any(l[0] < c[1] and c[0] < l[1] for c in imgs)],
        }
        js_tok = r["tokens"]
        js_tok = {"images": [[a, b, norm(t)] for a, b, t in js_tok["images"]],
                  "links": [[a, b, norm(l), norm(t), loc] for a, b, l, t, loc in js_tok["links"]],
                  "words": [norm(w) for w in js_tok["words"]]}
        if py_tok == js_tok: ok_tokens += 1
        else: bad.append(("tokens", k, s[:200], py_tok, js_tok))
        py_text = M.reader_text(s)
        js_text = s if r["text"] is None else norm(r["text"])
        if r["text"] is None and py_text is not s:
            # Swift returns `text` itself whenever the reference has nothing to change.
            if M.reader_units(M.u16(s)) is not None: bad.append(("identity", k, s[:200], py_text, None))
        if py_text == js_text: ok_text += 1
        else: bad.append(("text", k, s[:200], py_text, js_text))
    n = len(inputs)
    print(f"inputs {n} (cases {len(CASES)}, long 3, fuzz {FUZZ}); tokens match {ok_tokens}/{n}; reader text match {ok_text}/{n}")
    print("fuzz with a local link or image:", sum(1 for r in ref[len(CASES) + 3:] if r["text"] is not None))
    for b in bad[:8]: print(b)
    if WRITE and not bad:
        def lone(x):
            try: x.encode("utf-8"); return False
            except UnicodeEncodeError: return True
        fz = list(zip(inputs[len(CASES) + 3:], ref[len(CASES) + 3:]))
        rows = [(a, r["text"]) for a, r in fz if r["text"] is not None and not lone(a) and not lone(r["text"])][:250]
        rows += [(a, a) for a, r in fz if r["text"] is None and not lone(a)][:50]
        with open(os.path.join(CONTROL, "Tests/fixtures/session-reply-links-golden.json"), "w", encoding="utf-8") as f:
            f.write("[\n" + ",\n".join(json.dumps(list(r), ensure_ascii=False) for r in rows) + "\n]\n")
        print("wrote", len(rows), "golden replies")
    return 1 if bad else 0


sys.exit(main())
