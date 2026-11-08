#!/usr/bin/env python3
"""0.5.380 (server 7.0.5, preview engine, Miles decision 2b): Settings, Sessions, "Extra folders for previews" on the Mac,
the list Control Web Settings' Extra folders changes. Pinned where the helper self-test cannot reach: the helper's dispatch
and transport, the store, the settings block, the hub card, the catalog row, the older-server 404 path that hides the row,
run.sh, and the copy and the limit read from BOTH repos (server/web-control/panes/settings.js and
server/lib/preview-folders-setting.ts). The exchange's rules execute in the helper self-test (previewFoldersExchange).
Comments never count. Each failure names its behaviour as "pin failed [<behaviour>]".

    python3 Tests/preview-folders-pins.py <root> [<server dir>]

The server folder (the one holding web-control and lib) is the second argument, else COS_SERVER_DIR, else the first that has
preview-folders-setting.ts of the 7.0.5 release worktree and the server checkout, under $HOME and the account's real home
(the release runner gives tests a private HOME). None found is a failure, never a skip.
"""
import os, pathlib, pwd, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def code(rel):
    return "\n".join(re.sub(r"(^|\s)//.*$", "", line) for line in (root / rel).read_text(encoding="utf-8").split("\n"))


def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")
    passed += 1


def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


def swift_text(s):
    return re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)


helper = code("HelperSources/main.swift")
window = code("Sources/ActivityWindow.swift")
views = code("Sources/Views.swift")
catalog = code("Sources/SettingsHubCatalog.swift")
run_sh = code("Tests/run.sh")

# ── The helper: dispatch, the body on stdin, the route, the exchange, and its self-test.
pin('case "preview-folders": try emitPreviewFolders(args: args)' in helper, "dispatch", "the helper dispatches preview-folders")
emit = between(helper, "private func emitPreviewFolders(args: [String]) throws {", "\n    }\n")
pin('if args.contains("--set") {' in emit and "Self.previewFoldersBody(try readBoundedStdin(Self.previewFoldersStdinMax))" in emit,
    "stdin", "--set reads { folders } from bounded stdin, never argv")
pin('request("/api/preview-folders/settings", method: method, token: token, body: body, timeout: 8, reviewCandidatePort: candidate?.port)' in emit
    and "Self.previewFoldersExchange(set: folders)" in emit, "bounded", "one bounded request to the contract's route, through the exchange")
exchange = between(helper, "static func previewFoldersExchange(", "\n    }\n")
pin('try ask(folders == nil ? "GET" : "POST", body)' in exchange, "methods", "a read is GET, a save is POST")
pin('if response.status == 404 { return ("Not available on this server", ["available": false]) }' in exchange, "older server",
    "a 404 is a server without the setting")
pin('(error?["code"] as? String) == "preview_folder_refused"' in exchange and '["available": true, "refused": true, "errors": errors]' in exchange,
    "refusal", "the server's refusal crosses with each folder's error")
pin('["available": true, "folders": names, "source": source]' in exchange and "prefix(previewFoldersMax)" in exchange, "contract keys",
    "only folders (at most 20) and source cross")
body = between(helper, "static func previewFoldersBody(_ data: Data) -> [String]? {", "\n    }\n")
pin("object.count == 1" in body and "raw.count <= previewFoldersMax" in body, "body", "the --set body is exactly { folders }, at most 20")
self_test = helper.split("private func selfTest() throws {", 1)[1] if "private func selfTest() throws {" in helper else ""
pin(self_test.count("Self.previewFoldersExchange(") >= 8 and self_test.count("Self.previewFoldersBody(") >= 6, "self-test",
    "the helper self-test runs the exchange and the body rules")

# ── The store: read on show, the 404 hides the row, a save sends the list on stdin, a refusal keeps the list.
store = between(window, "@MainActor final class PreviewFoldersSettingsStore: ObservableObject {", "\nstruct PreviewFoldersSettingsBlock")
load = between(store, "func load(model: ControllerModel) async {", "\n    }\n")
pin('model.todayHelper(["preview-folders"], timeout: 12)' in load, "read", "the list is read through the helper")
pin('guard response.ok, response.details["available"]?.bool == true, let list = response.details["folders"]?.array else {' in load
    and load.count("folders = nil") == 2, "older server", "no setting on the server (404) or a failed read: no row")
save = between(store, "private func save(_ next: [String], model: ControllerModel) async {", "\n    }\n")
pin('model.todayHelper(["preview-folders", "--set"], timeout: 12, stdinData: data)' in save
    and 'JSONSerialization.data(withJSONObject: ["folders": next])' in save, "save", "a change sends the whole list on the helper's stdin")
refused_at = save.find("refusals = PreviewFolders.refusals(response.details, sent: next)")
pin('if response.details["refused"]?.bool == true {' in save and -1 < refused_at < save.find("return", refused_at) < save.find("folders = list.compactMap"),
    "refusal", "a refusal shows each folder's reason and keeps the saved list (it returns before the list is replaced)")
pin("guard let current = folders, current.count < PreviewFolders.limit else { return }" in store, "limit", "never more than 20")
pin("panel.canChooseDirectories = true" in store and "panel.canChooseFiles = false" in store and "panel.allowsMultipleSelection = false" in store,
    "picker", "the picker chooses one folder")

# ── The block: only with a list; Add (the picker) below 20; Remove per folder; the reasons under the list.
block = between(window, "struct PreviewFoldersSettingsBlock: View {", "\n}\n")
pin("if let folders = store.folders {" in block and 'anchor: "item.PF-01"' in block, "row", "the row shows only when the server has the setting")
pin("if folders.count < PreviewFolders.limit {" in block and "store.chooseFolder()" in block, "add", "Add folder opens the picker, below 20")
pin("Task { await store.remove(at: index, model: model) }" in block and "ForEach(Array(folders.enumerated()), id: \\.offset)" in block,
    "remove", "each folder has its own Remove")
pin("ForEach(store.refusals) { refusal in" in block and "Text(refusal.line)" in block, "reasons", "the server's reason shows for each refused folder")
pin(".task { await store.load(model: model) }" in block, "read", "the block reads the list when it shows")
pin(views.count("PreviewFoldersSettingsBlock(model: model)") == 1
    and "PreviewFoldersSettingsBlock(model: model)" in between(views, 'hubCard("work.sessions") {', 'hubCard("work.chat"'), "hub",
    "the block is drawn once, in Work and agents, Sessions")
pin(re.search(r'\.init\("PF-01", "Extra folders for previews", [^\n]*?group: "work\.sessions",\s*advanced: false, mount: \.group', catalog) is not None
    and catalog.index('.init("PF-01"') < catalog.index("static let items: [SettingsHubItem] = ["), "catalog",
    "Extra folders for previews is a hub row in Sessions, found by search")

# ── Copy: Control Web's words, sentence case, no em dash or arrow.
enum = between(window, "enum PreviewFolders {", "\n}\n")
strings = [swift_text(s) for s in re.findall(r'"((?:[^"\\]|\\.)*)"', enum + block + store)]
pin(all("\u2014" not in s and "\u2192" not in s and "->" not in s for s in strings), "copy", "no em dash or arrow")
pin(not any(re.fullmatch(r"[A-Z][A-Z ]{3,}", s) for s in strings), "copy", "no all-caps label")
pin('static let label = "Extra folders for previews"' in enum and '"Add folder\\u{2026}"' in block and 'Button("Remove")' in block, "copy",
    "the row, Add folder and Remove read in sentence case")

# ── Both repos: the web's words and the server's limit.
homes = []
for h in (pathlib.Path.home(), pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)):
    if h not in homes:
        homes.append(h)
candidates = [sys.argv[2]] if len(sys.argv) > 2 else []
candidates.append(os.environ.get("COS_SERVER_DIR", ""))
for home in homes:
    candidates += [str(home / "cos-worktrees/server-preview-705/server"), str(home / "Documents/GitHub/cos-glasses-app/server")]
server = next((pathlib.Path(c) for c in candidates if c and (pathlib.Path(c) / "lib/preview-folders-setting.ts").is_file()), None)
pin(server is not None, "server", "server/lib/preview-folders-setting.ts not found; pass the server folder or set COS_SERVER_DIR")
lib = (server / "lib/preview-folders-setting.ts").read_text(encoding="utf-8")
web = (server / "web-control/panes/settings.js").read_text(encoding="utf-8")
limit = re.search(r"export const PREVIEW_FOLDERS_MAX = (\d+)\n", lib)
pin(limit is not None and f"static let limit = {limit.group(1)}\n" in enum and f"static let previewFoldersMax = {limit.group(1)}\n" in helper, "limit",
    "the Mac's 20 is the server's PREVIEW_FOLDERS_MAX")
web_rows = between(web, "function previewFoldersRows(pf) {", "\n  }\n")
for name, phrase in (("damaged", "Couldn\u2019t read the saved list, so no extra folder counts. Add a folder to save it again."),
                     ("some", "Sessions can also open files from these folders."),
                     ("none", "None. Sessions open files only from their own project folder."),
                     ("hint", "Add a project folder, like ~/cos-worktrees. Not your whole home or Documents folder.")):
    pin(phrase in web_rows and phrase in strings, "web copy", f"the {name} line is Control Web's, word for word")

pin('/usr/bin/python3 "$ROOT/Tests/preview-folders-pins.py" "$ROOT"' in run_sh, "lane", "run.sh runs these pins")

print(f"preview folders pins: {passed} passed")
