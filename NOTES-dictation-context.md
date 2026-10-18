# Dictation context: notes for 0.5.323

Branch `claude/control-dictation-context` from Control main da6c1bb (0.5.321). No version bump, no Info.plist,
CHANGELOG.md or Resources/WhatsNew.json edits: the coordinator folds the text below into 0.5.323.

## CHANGELOG.md section (paste under the 0.5.323 heading)

Miles, 2026-10-17: "context should also be used inside of the dictionary suggestions and the corrections that are
being made". When he drops a prompt into a text box and then dictates into the same box, the prompt's names and terms
are evidence for how the dictation should be spelled, and for what belongs in the dictionary.

- Before COS types a dictation it reads the words already in the text box and spells a misheard name or term the way
  the box has it: "Ukoma" becomes "Ukaoma" when the box already holds "Ukaoma", "joule 360" becomes "Jewel360", "hub
  spot" becomes "HubSpot" (DictationFieldContext in Sources/MacDictationCore.swift; DictationInsertion.readContext in
  Sources/MacDictation.swift).
- The read is bounded: at most 3,000 UTF-16 units before the caret and 4,000 in all, after the selection (selected text
  is about to be replaced), by AXStringForRange with a 0.15 s timeout per read and 0.3 s for all of them, never AXValue.
  A slower or unreadable field is typed as heard. Never a password field, secure input or a terminal (its text is
  scrollback). The text stays in memory for that one dictation and the watch after it: never logged (the delivery line
  gains counts only: `context=read terms=N fixes=N ms=N`, or why it was skipped), never written, never sent.
- Terms are the box's distinctive words: a capital inside a word (iOS, HubSpot), letters with digits (Jewel360, 4BIS),
  a capitalized word in mid-sentence, an unknown capitalized word, an acronym (COS). Never a plain lowercase word (more
  often a typo than a term), nor paths, links, addresses or code. At most 64, the most frequent first.
- Corrections score at the Fix a word threshold (0.78) and are guarded, because a wrong fix is worse than none: a word
  the box already has exactly stays; a plain English word becomes only a spelled-on-purpose term, and one plain word
  only when the letters are the same, so "cloud" never becomes "iCloud", "and" never "Andy"; a capitals-only change
  needs a spelled-on-purpose term or a word the spell checker does not know; never across a line break or a mark
  between words; best match first, ties to the narrower span; punctuation kept. A dictation over 800 words is typed as
  heard.
- Learn from my edits uses the same context as evidence. When you fix a dictated word to a spelling the box also has
  outside the dictation (in the read before typing, or the window the watch reads around it), the pair qualifies even
  when the sound-alike score is below the 0.78 threshold, down to a floor of 0.6. The floor path also needs a spelling
  that is not plain English and a heard side that is not one plain word, so "market" never learns "Marktpos" (it would
  rewrite every "market"). Save automatically saves it like any learned pair; Suggest only suggests it.
- An edit of words COS spelled from the box (putting back what was heard, or changing COS's spelling to another) is
  never learned: its heard side is COS's guess, not the engine's.
- Each such suggestion carries its evidence, shown under the pair in Activity, Dictation (suggested and learned) and in
  Fix a word: "Also in the text around your dictation". It is saved with the suggestion; a 0.5.318 file loads with
  none, and an evidence kind this build does not know reads as none rather than dropping the file. The same pair seen
  again keeps the evidence an earlier sighting had.
- Settings, Dictation: "Spell words the way the text box has them", on by default, with the line "COS reads the text
  around the cursor before it types, keeps it only for that dictation and never saves or sends it. When you fix a word
  to a spelling that text already has, Learn from my edits takes it even if it sounds less alike. Never in terminals or
  password fields."
- Seam for the server's dictionary suggestions (server 6.77.0 transcript cleanup, not published yet): the model
  DictationServerSuggestion decodes its list (id `sug_` plus 16 hex digits, written, heard, status, count, inVocabulary,
  evidence with source, sessionId, heard, at, detail), DictationServerSuggestions.available reads `transcriptCleanup`
  protocol 1 with `suggestions: 1` from /api/transcribe/capabilities, and the helper verb `dictionary-suggestions`
  (list, accept or dismiss one id) validates its request and answers dormant without reading the token or sending
  anything. Nothing in Control calls it; no UI is wired to routes that do not exist yet.
- Tests: MacDictationChecks gains the context evidence (a term from the dropped-in text qualifies below the threshold
  and only with that evidence, the 0.6 floor inclusive, an unrelated rewrite, a plain spelling and one plain word never
  qualify, evidence is the exact spelling on word boundaries and never the dictation itself, secure fields and
  terminals give none, an edit of a context fix is never learned, evidence round-trips and survives old and future
  files), the bounded read plan, term selection, the insert-time corrections (present corrects, absent does not, the
  guards above, a number counted as a plain word, the 800-word bound) and the server seam decoding: 470 checks in all. Tests/dictation-wispr-pins.py
  pins the wiring (read after the measurement and before typing, every outcome carries what was typed, the plan decides
  secure and terminal, two bounded reads, budget, counts-only logging, nothing written or sent, the watch gets the read,
  the revert guard, the evidence on the row, the setting, the seam dormant and uncalled). Tests/
  transcription-dictionary-helper-checks.py covers the dormant verb (valid requests send nothing, invalid ids and
  operations are refused). Tests/mutate-mac-dictation-core.py gains 57 `context: ` mutants and takes `--only <prefix>`
  (several joined by `|`); two existing mutants ("rewordings learned", "the same pair listed twice") retargeted to the
  restructured lines. All 59 killed by a named check on a green baseline, each landing once. The gate now retries a
  compile that the bounded profile stopped for "shared compile lock busy" (at most four attempts) and names an
  infrastructure stop instead of printing an empty reason; before, a busy lane read as "did not compile".

## What's New (Resources/WhatsNew.json, 0.5.323)

Summary sentence:

Dictation reads the text box it types into: a name or term already written there comes out spelled the same way, and
when you fix a word to a spelling that text has, COS learns it.

Items:

- Before COS types a dictation, it reads the words already in the text box, so a name or term written there comes out
  spelled the same way. If the box says Ukaoma, a dictated Ukoma is typed as Ukaoma.
- When you fix a dictated word to a spelling the same text box already has, such as a name in a prompt you pasted,
  Learn from my edits takes it even when it sounds less alike. Its suggestion says why: Also in the text around your
  dictation.
- COS keeps that text only for the one dictation and never saves or sends it. Never in terminals or password fields.
  Turn it off in Settings, Dictation: Spell words the way the text box has them.

## For the coordinator

- Files: Sources/MacDictationCore.swift, Sources/MacDictation.swift, HelperSources/main.swift,
  Tests/MacDictationChecks.swift, Tests/dictation-wispr-pins.py, Tests/transcription-dictionary-helper-checks.py,
  Tests/mutate-mac-dictation-core.py. No new Swift file, so no compile list changed.
- Already in Tests/run.sh through Tests/run-mac-dictation.sh (core checks and pins) and the helper checks lane.
- Mutation gate for this set: `python3 Tests/mutate-mac-dictation-core.py <root> --only "context: |rewordings learned|the same pair listed twice"`.
