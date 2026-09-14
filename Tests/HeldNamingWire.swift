import Foundation

/// Decode server-produced fixture JSON through the shipping Control models.
/// Files remain outside this repository when they contain real meeting data.
@main
struct HeldNamingWireContract {
    static func check(_ raw: [String: JSONValue]) {
        let receipt = HeldNamingReceipt(raw)
        precondition(receipt.kind == raw["kind"]?.string)
        precondition(receipt.profileEmbeddings == raw["profileEmbeddings"]?.int)
        precondition(receipt.enrolled == raw["enrolled"]?.int ?? 0)
        precondition(receipt.deleted == raw["deleted"]?.int ?? 0)
        precondition(receipt.members.count == raw["members"]?.array?.count ?? 0)
        precondition(receipt.memberOutcomes.count == receipt.members.count)
        precondition(receipt.meetings.count == raw["meetings"]?.array?.count ?? 0)
        for (index, meeting) in receipt.meetings.enumerated() {
            let source = raw["meetings"]!.array![index].object!
            let triples = (source["playback"]?.array ?? []).filter {
                $0.object?["position"]?.int != nil && $0.object?["chunkIndex"]?.int != nil
            }
            precondition(meeting.playback.count == triples.count)
            for (index, triple) in meeting.playback.enumerated() {
                precondition(triple.chunkIndex == triples[index].object?["chunkIndex"]?.int)
                precondition(triple.position == triples[index].object?["position"]?.int)
            }
            precondition(meeting.labelsNewerThanGraph == source["labelsNewerThanGraph"]?.bool ?? false)
            let receipts = source["receipts"]?.array ?? source["copies"]?.array ?? []
            precondition(meeting.copySummaries.count == receipts.count)
        }
        for (index, member) in receipt.memberOutcomes.enumerated() {
            let source = raw["members"]!.array![index].object!
            precondition(member.enrollmentStatus == source["enrollmentStatus"]?.string ?? "unknown")
            precondition(member.labelStatus == source["labelStatus"]?.string ?? "unknown")
            precondition(member.audioStatus == source["audioStatus"]?.string ?? "unknown")
            precondition(member.position == source["position"]?.int)
            precondition(member.reason == source["reason"]?.string)
        }
        if receipt.kind == "applied" || receipt.kind == "undone" {
            precondition(receipt.undoHandle != nil)
            precondition(!receipt.canApply, "a persisted result is not a preview")
        }
        print("\(receipt.kind): \(receipt.memberOutcomes.count) member outcomes, \(receipt.meetings.count) meetings, enrolled \(receipt.enrolled), retained profile \(receipt.profileEmbeddings.map(String.init) ?? "unknown")")
    }

    static func main() throws {
        precondition(CommandLine.arguments.count > 1, "Pass server-produced preview/applied/undone/history JSON fixtures")
        for file in CommandLine.arguments.dropFirst() {
            let raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            if let batches = raw["batches"]?.array {
                for value in batches {
                    guard let row = value.object, let batch = HeldNamingBatch(value) else { preconditionFailure("invalid history batch") }
                    check(row)
                    precondition(batch.memberOutcomes.count == row["members"]?.array?.count ?? 0)
                    precondition(batch.profileEmbeddings == row["profileEmbeddings"]?.int)
                    precondition(batch.needsReview == ["interrupted", "partial"].contains(row["status"]?.string ?? ""))
                }
                print("history: \(batches.count) persisted batches")
            } else { check(raw) }
        }
        print("COS Control: actual server naming wire decoded without losing counts, raw mappings, receipts or member outcomes")
    }
}
