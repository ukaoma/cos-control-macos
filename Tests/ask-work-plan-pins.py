#!/usr/bin/env python3
"""Ask integration wiring checks only. These do not replace the compiled behavior/helper/UI gates."""
from pathlib import Path
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
read = lambda name: (root / name).read_text()
chat = read('Sources/WorkTaskChat.swift')
helper = read('HelperSources/main.swift')
sheet = read('Sources/AskWorkPlan.swift')
window = read('Sources/ActivityWindow.swift')
composer = read('Sources/DropItViews.swift')
count = 0
def pin(ok, why):
    global count
    assert ok, why
    count += 1

prepare = chat.split('    func prepareAskProposal(', 1)[1].split('    /// Explicit review import only.', 1)[0]
importer = chat.split('    func importAskProposal(', 1)[1].split('    /// Plans only.', 1)[0]
snapshot = helper.split('    private func emitAskWorkSnapshot()', 1)[1].split('    private func emitWorkChat()', 1)[0]
plan = helper.split('    private func emitAskWorkPlan()', 1)[1].split('    /// Upload the real Control snapshot', 1)[0]
send_context = chat.split('    private func sendContext(', 1)[1].split('    /// Replaces one waiting', 1)[0]

pin('ask-work-plan-capabilities' in prepare and 'AskWorkPlan.offered(capabilities)' in prepare, 'prepare rediscovers capability')
pin('capabilities["controlSnapshot"]?.int == 1' in sheet, 'snapshot capability required')
for code in (prepare, importer):
    pin('handoff.submit' not in code and 'dispatch(' not in code and 'recordLensRound' not in code, 'proposal/import never send or impersonate lens')
    pin('orchestratorInput(' not in code and 'work-orchestrator-input' not in code, 'proposal/import never call the usage-probing input route')
    pin('uploadAskSnapshot(' in code, 'both stages upload genuine current Control snapshot')
    pin('Task.checkCancellation()' in code, 'cancel before committing local state')
    pin('if !persist() { record = current' in code, 'failed CAS restores unsaved memory state')
pin('round.askEvidence = encoded' in prepare and 'let evidence: Evidence' in sheet and 'let revalidatedEvidence: Evidence' in sheet, 'preserve both server evidence snapshots')
pin('round.askConversationID = conversation' in prepare and 'DropIt.call("thread")' in prepare, 'record real native conversation ID when supplied')
pin('WorkChatAssignment(sessionID:' in prepare and 'WorkChatAssignment(sessionID:' not in importer, 'receipt IDs minted once before import')
pin('if round.askImportedAt != nil { return true }' in importer, 'repeat import is idempotent')
pin('round.state = AskWorkPlan.pendingState' in prepare and 'next.rounds[index].state = round.assignments.isEmpty ? "Answered" : "Ready to send"' in importer, 'proposal/review states are distinct')
pin('round.revision = revision' in prepare and 'rounds[index].revision =' not in importer, 'never rebase original revision during import')
pin('askLocalContextDigest' in send_context and 'attachments.digest == round.attachmentDigest' in send_context and 'round.linkDigest' in send_context, 'send rechecks local context and original files/links')
pin('"ask-work-plan"' in helper and '"/api/ask/work-plan"' in plan and 'timeout: 220' in plan, 'bounded helper proposal route')
pin('"/api/work/orchestrator/snapshot"' in snapshot and '4_000_000' in snapshot, 'bounded snapshot-only route')
pin('result["serverInstanceId"] as? String == server' in snapshot and 'task.row["workRevision"] as? String == revision' in snapshot, 'snapshot binds server and canonical task revision')
pin('requireLiveWorkTransport()' in plan and 'requireLiveWorkTransport()' in snapshot, 'existing live transport gate remains')
pin('askWorkPlanRequest = AskWorkPlan.Request(question: words)' in window and '.sheet(item: $askWorkPlanRequest)' in window, 'COS composer opens native proposal sheet')
pin('Button("Plan for Work")' in composer and '!store.attachments.isEmpty' in composer, 'chat files cannot silently become Work evidence')
pin('COSDropdown("Work card"' in sheet and '@State private var selectedID = ""' in sheet
    and 'COSDropdownOption("", "Choose a card…")' in sheet and 'COSDropdownOption($0.workSourceID,' in sheet,
    'themed explicit card selection without guessed identity')
pin('operation?.cancel()' in sheet and '.interactiveDismissDisabled(chat.busy)' in sheet, 'pending requests retain cancellation ownership')

for folder in ('Tests', 'scripts'):
    for path in (root / folder).glob('*.sh'):
        for line in path.read_text().splitlines():
            if line.lstrip().startswith('"$ROOT/Sources/') and '"$ROOT/Sources/WorkTaskChat.swift"' in line:
                pin('"$ROOT/Sources/AskWorkPlan.swift"' in line, f'new source included in {path.name}')
print(f'Ask Work source pins: {count} passed (source wiring only; no Swift compile or execution).')
