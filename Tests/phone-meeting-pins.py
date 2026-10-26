#!/usr/bin/env python3
"""Source wiring + extracted grammar fixtures only. No Swift execution, devices, network or live data."""
import json
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
models = (root / 'Sources/Models.swift').read_text()
helper = (root / 'HelperSources/main.swift').read_text()
live = (root / 'Sources/LiveTranscript.swift').read_text()
views = (root / 'Sources/ActivityMeetings.swift').read_text()
controller = (root / 'Sources/ControllerModel.swift').read_text()
passed = 0
def check(value, message):
    global passed
    if not value: raise SystemExit('phone meeting pin FAILED: ' + message)
    passed += 1
def body(text, start, end):
    a=text.index(start); return text[a:text.index(end,a)]
def pattern(name):
    p=re.search(r'static let '+name+r' = #"([^"]+)"#',models)
    check(p is not None, name+' exists')
    return re.compile(p.group(1).replace(r'\z',r'\Z'))
id_rule, key_rule=pattern('idPattern'),pattern('contextPattern')
fixture=json.loads((root/'Tests/fixtures/phone-meeting/session.json').read_text())
id=fixture['sessionId']; uuid=id[-36:]
for good in [id,'phone_'+uuid]: check(id_rule.fullmatch(good) is not None,'strict phone form readable')
for bad in [id+'\n',id.upper(),id+'_recovery','phone_anything','phone_170000000000_'+uuid,'../'+id]: check(id_rule.fullmatch(bad) is None,'malformed phone ID refused')
for key in ['phone:'+id,'g2:meeting_'+uuid,'mac:mac_'+uuid,'ff:legacy_public_id']: check(key_rule.fullmatch(key) is not None,'valid canonical/legacy key')
for key in ['g2:'+id,'mac:'+id,'ff:'+id,'phone:meeting_'+uuid,'phone:mac_'+uuid,'phone:'+id+'\n']: check(key_rule.fullmatch(key) is None,'foreign phone alias refused')
for path,signature,end in [('Sources/Models.swift','nonisolated static func validContextKey','    let recordId:'),('Sources/WorkCardFiles.swift','nonisolated static func validMeetingKey','nonisolated static func meetingID')]:
    check('PhoneMeetingCapture.validContextKey(key)' in body((root/path).read_text(),signature,end),'files and library share one grammar')
check('"meetingctx:phone:"' in (root/'Sources/MeetingAsk.swift').read_text(),'file observer registers phone namespace')
check('sourceType == "iphone_microphone" && id == sessionId && PhoneMeetingCapture.validID(id)' in models,'phone saved Ask requires provenance')
check('PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) && !PhoneMeetingCapture.protected(id)' in models,'phone history excludes foreign-source IDs')
check('!PhoneMeetingCapture.protected(sessionId, sourceType: sourceType)' in models,'saved review excludes phone source')
check('!PhoneMeetingCapture.protected(sessionId) && !sessionId.hasPrefix("mac_")' in live,'glasses Stop excludes even malformed phone IDs')
check('LiveMeeting.statusLine(sessionId: id' in views,'live header uses source identity')
check('Text(PhoneMeetingCapture.stopNote)' in views,'owning-phone Stop explanation visible')
check('!PhoneMeetingCapture.protected(session), feed?.ended != true' in views,'phone policy controls absent')
check('!PhoneMeetingCapture.protected(open)' in controller,'phone never polls alternate provisional STT')
check('guard !PhoneMeetingCapture.protected(sessionId)' in body(controller,'func saveStranded(','func saveAllStranded('),'Control refuses direct phone finalization')
read=body(helper,'static func liveTranscriptRead(','private func emitMacDictation(')
check(read.index('phoneMeetingMetadata(path)') < read.index('if let knownStamp'),'registry/policy checked before unchanged fast path')
check('O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK' in body(helper,'static func phoneMeetingMetadata(','static func phoneMeetingSourceValid('),'metadata cannot follow links or block on FIFO')
check('NSDictionary(dictionary: phoneRegistry).isEqual(to: capture)' in read,'journal bound to exact registry')
check('policy["mode"] as? String == "anonymous"' in read,'changed/unreadable policy refused')
check('phoneMeetingSourceValid(object, sessionId: sessionId)' in body(helper,'static func liveTranscriptParse(','static func liveTranscriptLevels('),'phone journal validated before transcript projection')
check('!sessionId.hasPrefix("phone_")' in body(helper,'static func meetingStopRequestPath(','private func emitMeetingStopRequest('),'helper cannot send phone onto G2 bus')
check('guard !sessionId.hasPrefix("phone_")' in body(helper,'private func postMeetingSave(','static let liveCuesSettingsPath'),'helper cannot save a still-recording phone')
for method,end in [('emitMeetingRelabel','emitMeetingSpeakerPolicy'),('emitMeetingSpeakerPolicy','emitMeetingDeattribute'),('emitVoiceEnrollExt','emitVoiceHeldGroups')]:
    # Function boundary differs in older branches; only inspect until the next private function.
    section=helper[helper.index('private func '+method+'('):]; section=section[:section.find('\n    private func ',1)]
    check('guard !session.hasPrefix("phone_")' in section,'helper '+method+' refuses phone identity mutation')
check('phoneMeetingValidID(id)' in body(helper,'static func isRecoverableOrphan(','static func strandedItemProjection('),'orphan recovery requires strict phone ID')
check('provenanceState == "admitted"' in models,'orphan model preserves admission boundary')
check('phone_source_unavailable' in body(helper,'static func liveTranscriptStatusProjection(','private func emitLiveTranscriptStatus('),'old server status cannot authorize phone')
check(live.index('read.speakerPolicy == "anonymous"') < live.index('if endedAt != nil'),'rejected read cannot revive ended feed')
check('sourceType == "iphone_microphone" && validID(sessionId)' in body(models,'nonisolated static func contextKeys(','nonisolated static func askSession('),'files require explicit phone source')
check(views.count('row.resolvedContextKeys(detail: detail)') >= 2,'saved files and Ask use row-bound detail keys')
check('meeting.resolvedContextKeys(detail: detail)' in controller and 'meeting.resolvedContextSupported(detail: detail)' in controller,'detail remembered keys require row and source')
check(controller.count('row.resolvedContextKeys(detail: detail)') >= 2,'copy context and meeting file blocks use row-bound keys')
check('phone_parakeet' not in controller,'Control does not add transcription implementation')
print('phone meeting source/grammar pins: %d passed (no Swift/helper/device execution)'%passed)
