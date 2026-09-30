#!/usr/bin/env python3
"""0.5.253: an icon beside words that can wrap sits in the middle of them, never by their first line.

Miles, 2026-09-30 16:51 (with screenshots): "Center the refresh icon on Check for updates." and "There are several places
where that same top vertical alignment is happening." Labels take COSLabelStyle (Sources/COSBrand.swift). This fails when
a Sources file puts an icon (Image(systemName:) or a Label) as the first thing in an HStack aligned to the top or to a
text baseline, the shape that drew the icon by the first line. A list bullet placed on the first line on purpose (an
Image with its own .padding(.top, ...)) is allowed, and so is a file that sets a label style other than COS's nowhere.

    python3 Tests/label-alignment-guard.py [root]              the check
    python3 Tests/label-alignment-guard.py [root] --selftest   proves each rule fails on scratch text
"""
import pathlib, re, sys

TOP = re.compile(r"HStack\s*\(\s*alignment\s*:\s*\.(top|firstTextBaseline|lastTextBaseline)\b[^{]*\{")
ICON = re.compile(r"^\s*(Image\s*\(\s*systemName\s*:|Label\s*\()")

def code(text):
    """The text with comments blanked, line numbers kept."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))

def hits(name, text):
    text = code(text)
    out = []
    for found in TOP.finditer(text):
        rest = text[found.end():]
        first = next((line for line in rest.split("\n") if line.strip()), "")
        # The first child may start on the same line as the brace.
        if ICON.search(first) and ".padding(.top" not in first:
            line = text.count("\n", 0, found.start()) + 1
            out.append(f"  {name}:{line}: an icon first in an HStack aligned to .{found.group(1)}: use .center (COSLabelStyle's rule)")
    for found in re.finditer(r"\.labelStyle\(\s*\.(titleAndIcon|automatic)\s*\)|\.labelStyle\(\s*(?:TitleAndIcon|Default)LabelStyle\(\)\s*\)", text):
        line = text.count("\n", 0, found.start()) + 1
        out.append(f"  {name}:{line}: the system's label style puts the icon by the first line: use COSLabelStyle")
    return out

def check(root):
    found = []
    for path in sorted((root / "Sources").glob("*.swift")):
        found += hits(f"Sources/{path.name}", path.read_text(encoding="utf-8"))
    if found:
        sys.exit("an icon is aligned to the first line of its words again:\n" + "\n".join(found))
    brand = (root / "Sources/COSBrand.swift").read_text(encoding="utf-8")
    assert "struct COSLabelStyle: LabelStyle" in brand and "HStack(alignment: .center, spacing: Self.spacing)" in brand, "COSLabelStyle lost its centered HStack"
    print("COS Control: every icon beside words sits in their middle (0.5.253)")

def selftest():
    bad = [
        'HStack(alignment: .top, spacing: 8) {\n    Image(systemName: "info.circle")\n    Text(text)\n}',
        'HStack(alignment: .firstTextBaseline) {\n    Label("Open", systemImage: "x")\n}',
        'HStack(alignment: .lastTextBaseline, spacing: 2) { Image(systemName: "clock")\n Text(t) }',
        'Button("x", systemImage: "y") {}.labelStyle(.titleAndIcon)',
        'Label("x", systemImage: "y").labelStyle(DefaultLabelStyle())',
    ]
    good = [
        'HStack(alignment: .center, spacing: 8) {\n    Image(systemName: "info.circle")\n    Text(text)\n}',
        'HStack(alignment: .top, spacing: 9) {\n    Image(systemName: "circle").font(.system(size: 7)).padding(.top, 5)\n    Text(c)\n}',
        'HStack(alignment: .top) {\n    VStack { Text("a") }\n    Image(systemName: "x")\n}',
        '// HStack(alignment: .top) {\n//     Image(systemName: "x")\n',
        'Label("x", systemImage: "y").labelStyle(COSLabelStyle())',
    ]
    for index, text in enumerate(bad):
        assert hits("scratch.swift", text), f"selftest: banned form {index} was not caught: {text!r}"
    for index, text in enumerate(good):
        assert not hits("scratch.swift", text), f"selftest: allowed form {index} was flagged: {text!r}"
    print(f"COS Control: the label alignment guard fails on {len(bad)} banned forms and passes {len(good)} allowed ones")

if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else pathlib.Path(__file__).resolve().parent.parent)
    if "--selftest" in sys.argv:
        selftest()
    else:
        check(root)
