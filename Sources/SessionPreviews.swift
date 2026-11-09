import AppKit
import Foundation

// 0.5.380, preview engine phase 1 (plan item 6): the Sessions pane shows the files and images a session made, as cards
// drawn from the SAME descriptors Control Web draws (`recent_turns` of the server's session detail: toolImages ti_,
// outputImages ai_, outputFiles af_, outputLinks al_). Before this the pane showed none of them (plan canary 18).
//
// One authorization path (plan decision 8a): opening a card asks the helper to fetch the bytes through the server's own
// routes, which re-authorize the id on every call, into a private copy under Control's cache. Control is never handed the
// real path. The copy is opened with Quick Look and deleted when Quick Look closes; leftovers are swept at launch.
//
// Previews off (Control Web, Settings, Privacy, "Show session files, screenshots and images") means no cards and no fetch:
// the server sends no ids or names, and this store refuses to fetch anything while the session says previews are off.
// A server without the descriptors (older than 6.99.28, or without recent turns) shows no cards and no error.

/// One card: a descriptor the helper checked key by key. Never a path.
struct SessionPreviewItem: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case image, file, link, tool }

    static let prefixes: [Source: String] = [.image: "ai_", .file: "af_", .link: "al_", .tool: "ti_"]
    static let secretReasons: Set<String> = ["secret_file", "blocked_name"]
    static let secretLine = "Not shown: this file may hold secrets."

    let id: String
    let source: Source
    let name: String
    let label: String?
    let kind: String
    let type: String
    let size: Int?
    let line: Int?
    let index: Int?
    let total: Int?
    let available: Bool
    let reason: String?

    static func validID(_ id: String, source: Source) -> Bool {
        guard let prefix = prefixes[source], id.hasPrefix(prefix), id.utf8.count == 67 else { return false }
        return id.utf8.dropFirst(3).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let raw = o["source"]?.string, let source = Source(rawValue: raw),
              let id = o["id"]?.string, Self.validID(id, source: source),
              let name = o["name"]?.string, !name.isEmpty, !name.contains("/") else { return nil }
        self.id = id
        self.source = source
        self.name = name
        label = o["label"]?.string
        kind = o["kind"]?.string ?? "file"
        type = o["type"]?.string ?? "File"
        size = o["size"]?.int
        line = o["line"]?.int
        index = o["index"]?.int
        total = o["total"]?.int
        let reason = o["reason"]?.string
        self.reason = reason
        // A name that may hold secrets never opens, whatever else the answer says.
        available = (o["available"]?.bool ?? false) && !Self.secretReasons.contains(reason ?? "")
    }

    init(id: String, source: Source, name: String, label: String? = nil, kind: String, type: String, size: Int? = nil,
         line: Int? = nil, index: Int? = nil, total: Int? = nil, available: Bool, reason: String? = nil) {
        self.id = id; self.source = source; self.name = name; self.label = label; self.kind = kind; self.type = type
        self.size = size; self.line = line; self.index = index; self.total = total
        self.reason = reason
        self.available = available && !Self.secretReasons.contains(reason ?? "")
    }

    var isSecret: Bool { Self.secretReasons.contains(reason ?? "") }
    var isPicture: Bool { kind == "image" }
    /// Opens with Quick Look: available, and a kind with bytes (a folder card or a claude.ai page has none here).
    var opens: Bool { available && kind != "folder" && kind != "artifact_link" }
    /// A picture route serves a small JPEG; a GIF or SVG sent as a file has none, so it shows its badge.
    var hasThumbnail: Bool {
        guard opens, isPicture else { return false }
        switch source {
        case .image, .tool: return true
        case .link: return ["png", "jpg", "jpeg", "webp", "heic", "heif", "avif"].contains((name as NSString).pathExtension.lowercased())
        case .file: return false
        }
    }

    var title: String {
        switch source {
        case .tool:
            if let index, let total, total > 1 { return "\(name) \(index) of \(total)" }
            return name
        case .link: return label ?? name
        case .image, .file: return name
        }
    }

    /// The short type on a file card's square.
    var badge: String {
        switch kind {
        case "pdf": return "PDF"
        case "html": return "HTML"
        case "markdown": return "MD"
        case "folder": return "DIR"
        case "artifact_link": return "WEB"
        default:
            let ext = (name as NSString).pathExtension.uppercased()
            return ext.isEmpty || ext.count > 4 ? "FILE" : ext
        }
    }

    /// "PDF · 1.2 MB · line 42", and the file's name under a link's own words.
    var meta: String {
        var parts: [String] = []
        if source == .link, label != nil { parts.append(name) }
        parts.append(type)
        if let size { parts.append(Self.bytes(size)) }
        if let line { parts.append("line \(line)") }
        return parts.joined(separator: " · ")
    }

    /// Why a card does not open, in the pane's words. nil when it opens.
    var unavailableLine: String? {
        if isSecret { return Self.secretLine }
        if opens { return nil }
        if available {
            return kind == "folder" ? "A folder. Open it on your Mac." : "Opens from the reply's link on the web."
        }
        switch reason {
        // Both permanent, both the same words as Control Web (the contract's): no path, no retry.
        case "missing", "outside_workspace": return "Not available on this Mac."
        case "too_large": return "Too large to open here."
        default: return "Not available right now. Reopen the session to check again."
        }
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(max(1, Int((Double(n) / 1024).rounded()))) KB" }
        let mb = Double(n) / 1024 / 1024
        return n < 10 * 1024 * 1024 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
    }
}

/// The cards of one server message (a reply, a tool step or a prompt with images).
struct SessionPreviewTurn: Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let at: String
    let items: [SessionPreviewItem]
    /// Images in that step past the server's per-step cap: counted, never given an id.
    let more: Int
    /// The message had files or images and previews are off: no names travel, nothing opens.
    let previewsOff: Bool

    init(id: String, role: String, at: String, items: [SessionPreviewItem], more: Int = 0, previewsOff: Bool = false) {
        self.id = id; self.role = role; self.at = at
        self.items = previewsOff ? [] : items
        self.more = previewsOff ? 0 : more
        self.previewsOff = previewsOff
    }

    init?(_ value: JSONValue?, index: Int) {
        guard let o = value?.object else { return nil }
        let off = o["previewsOff"]?.bool ?? false
        self.init(id: "p\(index)", role: o["role"]?.string == "assistant" ? "assistant" : "user", at: o["at"]?.string ?? "",
                  items: (o["items"]?.array ?? []).compactMap(SessionPreviewItem.init),
                  more: max(0, o["more"]?.int ?? 0), previewsOff: off)
        guard previewsOff || !items.isEmpty || more > 0 else { return nil }
    }
}

/// Where each server message's cards sit among the local transcript's turns.
struct SessionPreviewPlacement: Equatable, Sendable {
    var byTurn: [String: [SessionPreviewTurn]] = [:]
    var unplaced: [SessionPreviewTurn] = []

    struct LocalTurn: Equatable, Sendable {
        let id: String
        let role: String
        let timestamp: String
    }

    /// A server message lands on the local turn with its exact timestamp (the same transcript record), preferring the
    /// same role; else on the latest local turn written at or before it (a tool step belongs to the reply before it);
    /// else, with no time to go by or nothing earlier on screen, in the pane's closing group.
    static func place(_ turns: [SessionPreviewTurn], local: [LocalTurn]) -> SessionPreviewPlacement {
        var out = SessionPreviewPlacement()
        let clock = Clock()
        let dated: [(turn: LocalTurn, date: Date)] = local.compactMap { t in clock.date(t.timestamp).map { (t, $0) } }
        for turn in turns {
            let exact = turn.at.isEmpty ? [] : local.filter { $0.timestamp == turn.at }
            if let hit = exact.first(where: { $0.role == turn.role }) ?? exact.first {
                out.byTurn[hit.id, default: []].append(turn)
            } else if let at = clock.date(turn.at), let hit = dated.last(where: { $0.date <= at }) {
                out.byTurn[hit.turn.id, default: []].append(turn)
            } else {
                out.unplaced.append(turn)
            }
        }
        return out
    }

    /// ISO 8601 with or without fractional seconds (Claude writes them, Codex may not). Made once per placement.
    struct Clock {
        private let fractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let plain = ISO8601DateFormatter()

        func date(_ text: String) -> Date? {
            guard !text.isEmpty else { return nil }
            return fractional.date(from: text) ?? plain.date(from: text)
        }
    }
}

/// Two fetches at once, the server's own preview budget.
actor SessionPreviewGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let slots: Int

    init(slots: Int) { self.slots = slots; available = slots }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available = min(slots, available + 1) } else { waiters.removeFirst().resume() }
    }
}

@MainActor
final class SessionPreviewStore: ObservableObject {
    /// One helper call: arguments, stdin, and the answer's details.
    typealias Run = @Sendable (_ arguments: [String], _ stdin: Data?) async throws -> [String: JSONValue]

    static let thumbnailsPerSession = 24
    static let offLine = "Files and images from this reply are hidden. Previews are off in Settings, Privacy, on COS Control Web."

    @Published private(set) var turns: [SessionPreviewTurn] = []
    @Published private(set) var placement = SessionPreviewPlacement()
    @Published private(set) var previewsOff = false
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var opening: String?
    /// The copy Quick Look shows. Setting it to anything else (Quick Look closing sets nil) deletes the previous copy.
    @Published var quickLookURL: URL? {
        didSet { if let old = oldValue, old != quickLookURL { discard(old) } }
    }

    let root: URL
    private let run: Run
    private let gate = SessionPreviewGate(slots: 2)
    private var provider = ""
    private var sessionID = ""
    private var generation = 0
    private var localTurns: [SessionPreviewPlacement.LocalTurn] = []
    private var thumbnailsAsked = Set<String>()
    private var loadTask: Task<Void, Never>?

    init(root: URL = SessionPreviewStore.defaultRoot(), run: @escaping Run) {
        self.root = root.standardizedFileURL
        self.run = run
    }

    nonisolated static func defaultRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gotcos.COSControl", isDirectory: true)
            .appendingPathComponent("SessionPreviews", isDirectory: true)
    }

    /// At launch: every copy a crash or a quit left behind. Entries are removed, never followed.
    nonisolated static func sweep(root: URL = SessionPreviewStore.defaultRoot()) {
        let fm = FileManager.default
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        for entry in entries { try? fm.removeItem(at: entry) }
    }

    var hasCards: Bool { turns.contains { !$0.items.isEmpty || $0.more > 0 } }

    @discardableResult func load(provider: String, sessionID: String) -> Task<Void, Never>? {
        clear()
        self.provider = provider
        self.sessionID = sessionID
        return reload()
    }

    /// Reads the descriptors again for the same session (a new reply landed). Thumbnails already drawn are kept.
    @discardableResult func reload() -> Task<Void, Never>? {
        guard !provider.isEmpty else { return nil }
        loadTask?.cancel()
        let generation = generation, provider = provider, sessionID = sessionID
        let task = Task { [weak self, run] in
            let details = try? await run(["session-previews", "--provider", provider, "--session-id", sessionID], nil)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.apply(details ?? [:])
        }
        loadTask = task
        return task
    }

    /// The helper's answer. Anything but `ready` (an older server, a missing session, no server) is quiet: no cards, no error.
    func apply(_ details: [String: JSONValue]) {
        guard details["state"]?.string == "ready" else { turns = []; previewsOff = false; replace(); return }
        let parsed = (details["turns"]?.array ?? []).enumerated().compactMap { SessionPreviewTurn($0.element, index: $0.offset) }
        previewsOff = (details["previewsOff"]?.bool ?? false) || parsed.contains { $0.previewsOff }
        // Off means no cards: anything a mixed answer still carried is dropped with the marks kept.
        turns = previewsOff ? parsed.map { SessionPreviewTurn(id: $0.id, role: $0.role, at: $0.at, items: [], previewsOff: true) } : parsed
        replace()
    }

    /// The local transcript's turns, for placing the cards beside the reply that made them.
    func noteLocalTurns(_ turns: [SessionPreviewPlacement.LocalTurn]) {
        localTurns = turns
        replace()
    }

    private func replace() {
        placement = SessionPreviewPlacement.place(turns, local: localTurns)
    }

    func clear() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        quickLookURL = nil
        turns = []
        placement = SessionPreviewPlacement()
        previewsOff = false
        thumbnails = [:]
        notes = [:]
        opening = nil
        thumbnailsAsked = []
        localTurns = []
    }

    /// Fetch through the helper, then Quick Look on the private copy.
    @discardableResult func open(_ item: SessionPreviewItem) -> Task<Void, Never>? {
        guard !previewsOff, item.opens, opening == nil, !provider.isEmpty else { return nil }
        opening = item.id
        notes[item.id] = nil
        let generation = generation
        return Task { [weak self] in
            guard let self else { return }
            let result = await self.fetch(item, part: "raw")
            guard self.generation == generation else {
                if case .success(let url) = result { self.discard(url) }
                return
            }
            self.opening = nil
            switch result {
            case .success(let url): self.quickLookURL = url
            case .failure(let state): self.notes[item.id] = Self.refusalLine(state)
            }
        }
    }

    /// A picture's thumbnail, once per card, at most `thumbnailsPerSession` a session. The copy is deleted as soon as it
    /// is decoded.
    func loadThumbnail(_ item: SessionPreviewItem) async {
        guard !previewsOff, item.hasThumbnail, thumbnails[item.id] == nil, thumbnailsAsked.count < Self.thumbnailsPerSession,
              thumbnailsAsked.insert(item.id).inserted else { return }
        let generation = generation
        guard case .success(let url) = await fetch(item, part: "thumb") else { return }
        let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
        discard(url)
        guard self.generation == generation, let image else { return }
        thumbnails[item.id] = image
    }

    enum FetchResult: Equatable { case success(URL), failure(String) }

    private func fetch(_ item: SessionPreviewItem, part: String) async -> FetchResult {
        let request: [String: String] = ["provider": provider, "session": sessionID, "id": item.id, "part": part, "name": item.name]
        guard let stdin = try? JSONSerialization.data(withJSONObject: request) else { return .failure("invalid") }
        await gate.acquire()
        let details: [String: JSONValue]
        do {
            details = try await run(["session-preview-fetch"], stdin)
        } catch {
            await gate.release()
            return .failure("unavailable")
        }
        await gate.release()
        guard details["state"]?.string == "ready" else { return .failure(details["state"]?.string ?? "unavailable") }
        guard let path = details["path"]?.string else { return .failure("invalid") }
        guard let bytes = details["bytes"]?.int, let url = verified(path: path, bytes: bytes) else {
            // Not believed, so not shown; a copy inside our root is still ours to delete.
            discard(URL(fileURLWithPath: path))
            return .failure("invalid")
        }
        return .success(url)
    }

    /// The helper's copy, believed only when it is a regular file of the size it named, one folder inside our root.
    func verified(path: String, bytes: Int) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == root.path, url.path.hasPrefix(root.path + "/"),
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == bytes,
              let folderValues = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]), folderValues.isSymbolicLink != true else {
            return nil
        }
        return url
    }

    /// Deletes a copy's own folder. Only ever one folder inside our root.
    func discard(_ url: URL) {
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == root.path, folder.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Pure (string constants only), so it is `nonisolated`: callers off the main actor and function references (the
    /// checks' `.map`) compile under strict concurrency.
    nonisolated static func refusalLine(_ state: String) -> String {
        switch state {
        case "secret": return SessionPreviewItem.secretLine
        case "off": return "Previews are off. Turn them on in Settings, Privacy, on COS Control Web."
        case "missing": return "No longer in this session's recent replies. Reopen the session to refresh it."
        case "absent": return "Update the COS server to open this file here."
        case "too_large": return "Too large to open here."
        case "unauthorized": return "Not authorized. Refresh the pairing token in Settings."
        case "offline": return "The COS server is not answering."
        case "invalid": return "COS could not verify this file."
        default: return "Not available right now. Try again in a moment."
        }
    }
}
