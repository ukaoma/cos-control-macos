#!/usr/bin/env python3
"""0.5.357 (server 6.96.3): where the Speakers display is wired. The rules run in Tests/VoiceDisplayChecks.swift and the naming run in
Tests/VoiceDisplayControllerChecks.swift; these pins read code only and name what those cannot reach: the views. Each failure names
its behaviour as "pin failed [<behaviour>]".

    python3 Tests/voice-display-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
views = (root / "Sources/Views.swift").read_text(encoding="utf-8")
model = (root / "Sources/ControllerModel.swift").read_text(encoding="utf-8")
models = (root / "Sources/Models.swift").read_text(encoding="utf-8")
helper = (root / "HelperSources/main.swift").read_text(encoding="utf-8")
run_sh = (root / "Tests/run.sh").read_text(encoding="utf-8")


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def code(text):
    return "\n".join(line for line in text.split("\n") if not line.strip().startswith("//") and not line.strip().startswith("///"))


def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


# The pane: the hint's list stands beside Codex's, never over it.
pane = code(between(views, "struct SpeakerReviewPane: View {", "extension ControlPanel {"))
branch = between(pane, "if let layout = review.voiceDisplayLayout {", "let displayRows = review.displayVoiceRows")
pin("VoiceDisplayList(model: model, layout: layout)" in branch and "} else {" in branch, "hint list beside the old list",
    "the hint's list and Codex's list are two branches of one if")
pin("VoiceSuggestBar(model: model, review: review)" in pane, "suggest bar mounted", "the button is in the pane the review opens")
for card in ("VoiceGroupNameConfirmationView(model: model, plan: plan)", "model.voiceGroupNamingProgress", "model.voiceGroupNamingOutcome"):
    pin(card in pane, "naming cards mounted", f"{card} is in the pane")

# The list: real VoiceRows, so words and correction paths are the same views.
lists = code(between(views, "private struct VoiceDisplayList: View {", "private struct VoiceSuggestBar: View {"))
pin(lists.count("VoiceRow(model: model, voice: voice, hintSeconds: layout.seconds[voice.label])") == 2, "rows are VoiceRows",
    "a single row and a short row are each the original VoiceRow")
pin("DisclosureGroup(isExpanded: $model.voiceDisplayShortExpanded)" in lists and "VoiceDisplayCopy.shortVoices(layout.short.count)" in lists, "fold",
    "one counted fold, its state on the model so a new meeting resets it")
merged = code(between(views, "private struct MergedVoiceRow: View {", "/// 0.5.357: the list when a display hint applies."))
pin("VoiceRow(model: model, voice: voice, hintSeconds: seconds[voice.label])" in merged, "merged members are VoiceRows", "expanding shows the original rows")
pin("VoiceDisplayCopy.machineGrouping" in merged, "machine grouping line", "the merged row says it is a machine grouping")
pin("model.openReview?.canNameTogether(row) == true" in merged, "naming gated", "naming a group needs every member on the plain path")
pin("confirmVoiceGroupName" not in merged, "preview before save", "the merged row can only preview; Save is on the card")
pin("model.previewVoiceGroupName(row, to: option.name, assignVoiceProfile: true)" in merged, "picked person adds samples", "as a single row")
pin("model.previewVoiceGroupName(row, to: newName, assignVoiceProfile: false)" in merged, "typed name is text only", "as a single row")
pin("!$0.isOwner" in merged, "wearer never offered", "a Mac voice is never offered the wearer's profile")

# Use this name only ever opens the normal card.
line = code(between(views, "private struct VoiceSuggestionLine: View {", "/// 0.5.357: one row for a machine grouping."))
pin('Button("Use this name", action: use)' in line, "use button", "the suggestion's one action")
pin("previewRename" not in line and "confirm" not in line.lower(), "line cannot name", "the line only calls what it is given")
row = code(between(views, "private struct VoiceRow: View {", "/// 0.5.357: \"Suggested: <name>\""))
pin("model.useVoiceNameSuggestion(suggestion, rowLabels: [voice.label])" in row, "row uses its suggestion", "VoiceRow shows a matching suggestion")
pin("model.useVoiceNameSuggestion(suggestion, rowLabels: row.labels)" in merged and "ForEach(model.voiceNameSuggestions(heldBy: row.labels))" in merged, "merged row shows every suggestion", "two names on one row both show")
use = code(between(model, "func useVoiceNameSuggestion(_ suggestion: VoiceNameSuggestion, rowLabels: [String])", "    /// What the batch offers right now."))
pin("confirm" not in use.lower().replace("requiresconfirmation", ""), "use only previews", "Use this name never reaches a save")
pin("previewRename(from: first.label, to: suggestion.name" in use and "previewVoiceGroupName(VoiceDisplayLayout.MergedRow(" in use, "use only previews", "both go to a preview")
batch = code(between(views, "private struct VoiceBatchBar: View {", "/// 0.5.357: the one Save for a whole merged row."))
pin("VoiceDisplayCopy.nameVoices(ticked.count)" in batch and "ticked.isEmpty" in batch, "confirm follows the ticks", "the Confirm counts ticks and is disabled at 0")
pin("VoiceDisplayCopy.nameVoices(candidates.count)" in batch, "button counts rows", "the entry button counts high-confidence rows")
pin(batch.count("model.confirmVoiceBatch()") == 1, "batch save is a click", "one Confirm")
pin(views.count("model.confirmVoiceBatch()") == 1 and views.count("model.undoVoiceBatch()") == 1, "batch save is a click", "one call site each")
pin('Toggle(isOn:' in batch and "COSCheckStyle()" in batch, "ticks", "each row has the COS checkbox")
pin("VoiceDisplayCopy.undoNames" in batch, "undo offered", "Undo these names is in the bar")
pin("model.voiceBatch.historyLine" in batch and "answer ?? history" in batch, "history above undo", "a reopened review says what the Undo would take back")
pin(".sheet(" not in batch and ".popover(" not in batch, "inline only", "the batch list is inline")
batch_run = code(between(model, "/// Confirm: the ticked rows and nothing else.", "/// Read the check's state when a review lands."))
pin('"meeting-relabel"' not in batch_run, "server does the batch", "the batch path never loops a relabel from Control")
pin(batch_run.count("await refreshAfterVoiceBatch(session: session, generation: generation)") == 2, "refresh after both", "Confirm and Undo both refresh the review")
confirm_view = code(between(views, "private struct VoiceGroupNameConfirmationView: View {", "/// Rows shown in the review card."))
pin('Button("Save") { model.confirmVoiceGroupName(plan) }' in confirm_view, "save is a click", "the only caller of the save")
pin(views.count("model.confirmVoiceGroupName(") == 1, "save is a click", "one call site")

# No new write route, and overlays stay inline.
run = code(between(model, "// MARK: - 0.5.357 Speakers display and Suggest names (server 6.96.3)", "    /// The suggestions this row holds and may use."))
pin('"meeting-relabel"' in run and "--force" not in run and "voice-merge" not in run and "meeting-group-relabel" not in run, "same route only",
    "a group naming uses meeting-relabel and never forces")
added = code(between(views, "/// 0.5.357: \"Suggested: <name>\"", "/// Rows shown in the review card."))
pin(".sheet(" not in added and ".popover(" not in added and ".alert(" not in added, "inline only", "overlays are inline, never sheets")

# Copy.
block = between(models, "/// 0.5.357 (server 6.96.3), Miles 10/30 16:59", "/// The readable meeting behind a speaker review")
for text in (block, added, run):
    pin("\u2014" not in text and "\u2192" not in text, "copy", "no em dash or arrow in the new block")
    for literal in re.findall(r'"[^"\n]*"', text):
        pin(" -> " not in literal, "copy", f"no typed arrow in {literal}")

# The helper route, and the lane.
pin('case "meeting-voice-suggestions": try emitMeetingVoiceSuggestions(args: args)' in helper, "helper route", "the command is wired")
pin('case "meeting-voice-batch", "meeting-voice-batch-apply", "meeting-voice-batch-undo": try emitMeetingVoiceBatch(args: args)' in helper, "helper route", "the batch commands are wired")
emit = between(helper, "private func emitMeetingSpeakers(args: [String]) throws {", "/// The readable meeting plus its two clipboard forms.")
pin('"review": body,' in emit, "voiceDisplay passes through", "meeting-speakers hands the server's body over whole, so voiceDisplay is not filtered")
pin('zsh "$ROOT/Tests/run-voice-display.sh" --helper "$TMP/cos-control-helper"' in run_sh, "lane wired", "Tests/run.sh runs this lane")
print("PASS voice display wiring pins")
