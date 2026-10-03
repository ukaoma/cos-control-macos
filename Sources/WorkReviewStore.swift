import Foundation
import SwiftUI

struct WorkReviewTaskLink: Identifiable, Sendable {
    let taskId: String
    let domain: String
    let title: String
    let evidence: String
    var id: String { domain + ":" + taskId }
}

struct WorkReviewRecord: Identifiable, Sendable {
    let id: String
    let title: String
    let domain: String
    let revision: String
    let status: String
    let markdown: String
    let error: String?
    let createdAt: String
    let taskLinks: [WorkReviewTaskLink]
    let canonicalMeetingId: String
    let descriptor: [String: String]
    let model: String
    let contextWarnings: [String]
    let inputTruncated: Bool
    var canPrepare: Bool { status == "ready" && !markdown.isEmpty }
    var source: WorkSource {
        WorkSource(id: "meeting:" + (canonicalMeetingId.isEmpty ? id : canonicalMeetingId), title: title, revision: revision, project: domain,
            context: "Meeting: \(title)\nDomain: \(domain)\nMeeting record: \(canonicalMeetingId)\n\nReviewed follow-up:\n\(markdown)",
            reviewID: id)
    }
    init?(_ value: JSONValue) {
        guard let row = value.object, let id = row["id"]?.string, !id.isEmpty,
              let source = row["source"]?.object else { return nil }
        self.id = id
        title = source["title"]?.string ?? "Meeting follow-up"
        domain = source["domain"]?.string ?? ""
        revision = source["revision"]?.string ?? ""
        status = row["status"]?.string ?? "unknown"
        markdown = row["markdown"]?.string ?? ""
        error = row["error"]?.string ?? row["error"]?.object?["message"]?.string
        createdAt = row["createdAt"]?.string ?? ""
        canonicalMeetingId = row["canonicalMeetingId"]?.string ?? ""
        descriptor = (source["descriptor"]?.object ?? [:]).compactMapValues(\.string)
        model = row["model"]?.string ?? ""
        contextWarnings = (row["contextWarnings"]?.array ?? []).compactMap(\.string)
        inputTruncated = source["inputTruncated"]?.bool == true
        taskLinks = (row["taskLinks"]?.array ?? []).compactMap { value in
            guard let link = value.object, let taskId = link["taskId"]?.string, !taskId.isEmpty else { return nil }
            return WorkReviewTaskLink(taskId: taskId, domain: link["domain"]?.string ?? "", title: link["title"]?.string ?? "Linked task", evidence: link["evidence"]?.string ?? "")
        }
    }
}

/// Projection of server-owned review jobs. Navigation never admits a provider run.
@MainActor final class WorkReviewStore: ObservableObject {
    typealias Transport = @Sendable ([String], Data?) async throws -> HelperResponse
    /// 0.5.254 resize pass: bumps on every change, the Work board's cue to rebuild its rows (WorkBoardMemo).
    @Published var reviews: [WorkReviewRecord] = [] { didSet { reviewsEpoch &+= 1 } }
    private(set) var reviewsEpoch = 0
    @Published var models: [WorkModelChoice] = []
    @Published var available = false
    @Published var busy = false
    @Published var error: String?
    @Published var selectedMeeting: LibraryMeeting?
    @Published var selectedReviewID: String?
    @Published var automaticAfterSync = false
    @Published private(set) var titleOverrides: [String: String] = [:]
    private let transport: Transport
    /// Nil in tests and the resize harness, so they never write Miles's review names.
    private let titlesURL: URL?
    init(transport: Transport? = nil, titlesURL: URL? = nil) {
        let helper = HelperClient()
        self.transport = transport ?? { args, data in try await helper.run(args, timeout: 90, stdinData: data) }
        let testing = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] != nil
            || ProcessInfo.processInfo.environment["COS_PERF_FIXTURES"] != nil
        let fixtureTitles = ProcessInfo.processInfo.environment["COS_WORK_FIXTURE_TEST"] == "1" ? ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("review-titles.json") } : nil
        self.titlesURL = titlesURL ?? fixtureTitles ?? (testing ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("COS Control/review-titles.json"))
        if let titlesURL = self.titlesURL, let data = try? Data(contentsOf: titlesURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            titleOverrides = saved
        }
    }

    func displayTitle(for review: WorkReviewRecord) -> String {
        let saved = titleOverrides[review.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? review.title : saved
    }

    func source(for review: WorkReviewRecord) -> WorkSource {
        let title = displayTitle(for: review)
        return WorkSource(id: review.source.id, title: title, revision: review.revision, project: review.domain,
            context: "Meeting: \(title)\nDomain: \(review.domain)\nMeeting record: \(review.canonicalMeetingId)\n\nReviewed follow-up:\n\(review.markdown)",
            reviewID: review.id, fullTitle: title)
    }

    @discardableResult func setTitle(_ title: String, for reviewID: String) -> Bool {
        let clean = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty, clean.utf16.count <= 180 else { error = "Review name must contain 1 to 180 characters."; return false }
        var next = titleOverrides; next[reviewID] = clean
        do {
            if let titlesURL {
                try FileManager.default.createDirectory(at: titlesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: titlesURL, options: .atomic)
            }
            titleOverrides = next; reviewsEpoch &+= 1; error = nil
            return true
        } catch { self.error = "Name was not saved: " + error.localizedDescription; return false }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { error = nil; try absorb(await transport(["work-reviews"], nil)) }
        catch { available = false; models = []; self.error = error.localizedDescription }
    }
    func review(meeting: LibraryMeeting, modelID: String) async {
        guard !busy, available, models.contains(where: { $0.id == modelID && $0.available }) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var descriptor: [String: String] = ["domain": meeting.domain, "month": meeting.month, "filename": meeting.filename]
            if !meeting.recordId.isEmpty { descriptor["recordId"] = meeting.recordId }
            let data = try JSONSerialization.data(withJSONObject: ["meeting": descriptor, "model": modelID])
            let response = try await transport(["work-review"], data)
            guard response.ok, let value = response.details["review"], let row = WorkReviewRecord(value) else {
                throw NSError(domain: "WorkReview", code: 1, userInfo: [NSLocalizedDescriptionKey: response.message])
            }
            let sameRecord = !meeting.recordId.isEmpty && row.canonicalMeetingId == meeting.recordId
            let sameDescriptor = row.descriptor["domain"] == meeting.domain && row.descriptor["month"] == meeting.month && row.descriptor["filename"] == meeting.filename
            guard sameRecord || (meeting.recordId.isEmpty && sameDescriptor) else {
                throw NSError(domain: "WorkReview", code: 3, userInfo: [NSLocalizedDescriptionKey: "The review response does not match the selected saved meeting. Refresh before trying again."])
            }
            reviews.removeAll { $0.id == row.id }; reviews.insert(row, at: 0)
            selectedReviewID = row.id; selectedMeeting = nil
        } catch { self.error = error.localizedDescription }
    }
    /// Refresh the canonical source fence immediately before a reviewed context
    /// can leave Work. A cached result alone is not current authority.
    func validateForHandoff(_ review: WorkReviewRecord) async -> Bool {
        guard !busy else { return false }
        await refresh()
        guard available, error == nil,
              let current = reviews.first(where: { $0.id == review.id }), current.canPrepare,
              current.canonicalMeetingId == review.canonicalMeetingId,
              current.revision == review.revision, current.markdown == review.markdown else {
            if error == nil { error = "This meeting review changed or is unavailable. Review the current saved source before sending." }
            return false
        }
        return true
    }

    private func absorb(_ response: HelperResponse) throws {
        guard response.ok else { throw NSError(domain: "WorkReview", code: 2, userInfo: [NSLocalizedDescriptionKey: response.message]) }
        let capabilities = response.details["capabilities"]?.object ?? [:]
        available = capabilities["manualReview"]?.bool == true
        automaticAfterSync = capabilities["automaticAfterSync"]?.bool == true
        models = (capabilities["reviewModels"]?.array ?? response.details["reviewModels"]?.array ?? []).compactMap { value in
            guard let row = value.object, let id = row["id"]?.string, let provider = row["provider"]?.string else { return nil }
            return WorkModelChoice(id: id, provider: provider, title: row["title"]?.string ?? id, available: row["available"]?.bool == true, reason: row["reason"]?.string)
        }
        reviews = (response.details["reviews"]?.array ?? []).compactMap(WorkReviewRecord.init)
        if !available { error = "Meeting review is not available on this server yet." }
    }
}
