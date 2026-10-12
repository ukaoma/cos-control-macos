import Foundation

@main
struct MeetingValueStoreCanary {
 @MainActor static func main() async throws {
  let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"]!).appendingPathComponent("ask")
  let model = ControllerModel(startBackgroundWork: false)
  let store = MeetingAskStore(root: root)
  let session = "meeting_canary_original"
  var submissions: [[String: Any]] = []
  var savedExchange: [String: Any]?
  let fixture: (String, Data) async throws -> Data = { operation, bytes in
   let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
   let payload = body["payload"] as! [String: Any]
   let value: [String: Any]
   switch operation {
    case "identity": value = ["pairingContext": "private-fixture"]
    case "config": value = ["protocolVersion": 2, "serverInstanceId": "fixture-server", "pairingContext": "private-fixture", "selected": ["engine": "claude", "model": "haiku"], "models": [], "capabilities": ["followUpReview": true]]
    case "history": value = ["exchanges": savedExchange.map { [$0] } ?? [], "files": []]
    case "transcript": value = ["ended": true, "source": "saved", "elapsedMs": 12000, "turns": [["id": 7, "elapsedMs": 11000, "speaker": "You", "text": "The rollout still needs approval."]], "notices": []]
    case "files": value = ["files": []]
    case "submit":
      submissions.append(payload)
      let exchange: [String: Any] = ["requestId": payload["requestId"]!, "sessionId": session, "serverInstanceId": "fixture-server", "action": "ask", "question": payload["question"]!, "status": "completed", "createdAt": "2026-10-12T12:00:00Z", "updatedAt": "2026-10-12T12:00:01Z", "selectedModel": ["engine": "claude", "model": "haiku"], "answer": "Approval is still needed [T1].", "sources": [], "notices": [], "throughMs": 12000, "files": []]
      savedExchange = exchange; value = ["exchange": exchange]
    case "context-status": value = ["memory": ["available": true, "total": 17], "threads": ["available": true, "total": 8]]
    case "context": value = ["orientation": ["domain": "hermit_crabs"]]
    default: throw NSError(domain: "unexpected-operation-" + operation, code: 1)
   }
   return try JSONSerialization.data(withJSONObject: value)
  }
  store.injectedTransport = fixture
  await store.open(session, model: model)
  await store.loadSavedSnapshot(session, model: model)
  precondition(store.savedSnapshots[session]?.validSaved == true)
  store.setDraft("Who needs to approve it?", session: session)
  store.askSaved(action: "ask", question: store.draft(session), session: session, model: model)
  for _ in 0..<100 { if !store.running.contains(session) { break }; try await Task.sleep(for: .milliseconds(20)) }
  precondition(submissions.count == 1)
  precondition(submissions[0]["elapsedMs"] as? Int == 12000)
  let turns = submissions[0]["turns"] as! [[String: Any]]
  precondition(turns.count == 1 && turns[0]["id"] as? Int == 7 && turns[0]["elapsedMs"] as? Int == 11000)
  precondition(store.records[session]?.exchanges.count == 1 && store.draft(session).isEmpty)
  await store.checkSources(session, model: model)
  precondition(store.sourceHealth[session]?.contains("17 available") == true)
  precondition(store.sourceHealth[session]?.contains("Last sync is not reported") == true)
  let restarted = MeetingAskStore(root: root); restarted.injectedTransport = fixture
  await restarted.open(session, model: model)
  precondition(restarted.records[session]?.exchanges.first?.answer == "Approval is still needed [T1].")
  restarted.askSaved(action: "ask", question: "No loaded snapshot", session: session, model: model)
  precondition(submissions.count == 1)
  print("PASS: actual native Store submits original ended turns/cutoff, persists answer across restart, refuses absent snapshot, and labels checked versus sync time without background work")
 }
}
