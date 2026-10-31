#!/usr/bin/env python3
"""Safety wiring assertions without creating NSApplication, views, windows or input events."""
import pathlib,sys
root=pathlib.Path(sys.argv[1]);views=(root/'Sources/Views.swift').read_text();controller=(root/'Sources/ControllerModel.swift').read_text()
naming=views.split('struct IntervalWordGroupNamingView: View {',1)[1].split('struct IntervalWordNameConfirmationView: View {',1)[0]
confirmation=views.split('struct IntervalWordNameConfirmationView: View {',1)[1]
assert r'_selected = State(initialValue: scope.kind == .human ? Set(scope.members.map(\.id)) : [])' in naming,'Only atomic human rename preselects all; anonymous and unresolved selection start empty'
assert 'ForEach(pageMembers)' in naming and 'selected.insert(member.id)' in naming,'Each paginated toggle selects an opaque word ID'
assert 'member.stamp' in naming and 'member.text' in naming,'Word selection shows text and exact range'
assert 'private let pageSize = 80' in naming and '.prefix(pageSize)' in naming and '.prefix(80)' in confirmation,'Every displayed word list is bounded'
assert 'scope.selectionRuns[runIndex]' in naming and 'rangeStart = member.id' in naming and 'rangeEnd = member.id' in naming,'Unresolved selection picks one server run and exact range endpoints'
assert 'model.openReview?.humanScope(for: action)' in views,'Human rename is bound to an explicit current action, independently of voice grouping'
assert 'previewIntervalWordName(scope, memberIds: memberIds, to: name)' in naming,'Naming view only previews selected IDs'
assert 'confirmIntervalWordName' not in naming,'Naming view cannot automatically confirm'
assert 'ForEach(pageMembers)' in confirmation and 'member.stamp' in confirmation,'Confirmation pages through the exact selected text and ranges'
assert 'Button("Save name")' in confirmation and 'model.confirmIntervalWordName(preview)' in confirmation,'Separate explicit save action'
assert 'Button("Undo") { model.undoIntervalWordName(action) }' in views,'Undo passes its own displayed action'
assert 'annotation.activeActions' in views,'Undo inventory comes from current server annotation'
assert 'intervalGroupScopes.first(where: { $0.matches(voice) })' in views,'Scope binding uses anonymous identity checks, never a human name string'
interval_controller=controller.split('    func previewIntervalWordName(',1)[1].split('    private func reviewRevisionArgs(',1)[0]
for unsafe in ('--force','--assign-voice-profile','rawChunkIndices','voice-merge','voice-enroll'):
 assert unsafe not in interval_controller,'Exact word controller cannot expand to raw/profile/global mutation: '+unsafe
assert interval_controller.count('await fetchReview(')>=4,'Refused/stale writes and successful writes refresh full source review'
assert 'model.openReview?.intervalHumanRecoveryRequired == true' in views,'Recovery UI requires exact server flag'
assert 'if model.intervalWordRecoveryArmed' in views and 'model.recoverIntervalWordNaming()' in views,'Recovery requires a separate explicit confirmation'
assert 'model.openReview?.intervalOriginalViewAvailable == true' in views and 'if model.intervalOriginalViewArmed' in views,'Original view requires explicit capability and separate confirmation'
assert 'model.useOriginalRecordingView()' in views,'Original recording view has an explicit confirmation action'
review_pane=views.split('struct SpeakerReviewPane: View {',1)[1].split('extension ControlPanel {',1)[0]
fragment_rows=review_pane.split('if !displayRows.shortFragments.isEmpty {',1)[1].split('// The write-up, BELOW the voice rows.',1)[0]
assert 'let displayRows = review.displayVoiceRows' in review_pane and 'displayRows.main.enumerated()' in review_pane,'Main list uses the conservative display partition'
assert 'DisclosureGroup(isExpanded: $shortFragmentsExpanded)' in fragment_rows and r'Short voice fragments (\(displayRows.shortFragments.count))' in fragment_rows,'Counted disclosure exists only for a nonempty fragment partition'
assert 'displayRows.shortFragments.enumerated()' in fragment_rows and 'VoiceRow(model: model, voice: voice)' in fragment_rows,'Every expanded fragment keeps its complete original VoiceRow and exact-word controls'
assert '@State private var shortFragmentsExpanded = false' in review_pane and '.onChange(of: model.openReview?.sessionId)' in review_pane,'Fragments start collapsed for each recording'
print('PASS interval word UI safety wiring: explicit selection, range preview, second click, own-action Undo; no UI instantiated')
