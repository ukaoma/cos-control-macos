# Live transcript readability

Follow-up on the recording-indicators candidate, based on public Control 0.5.278. Not installed or published.

## Cause and change

Consecutive chunks sharing a speaker label were merged without a duration or size limit. A long stretch labeled Ext became a single wall of text with one timestamp.

The reducer now groups same-speaker chunks into sections spanning less than 30 seconds and no more than 600 characters (except a single oversized source chunk). Each timestamp is the actual first chunk's elapsed time. Oversized chunks get paragraphs of at most 420 graphemes, preferring sentence ends or whitespace. Breaking a large chunk does not invent timestamps for its internal paragraphs. The view uses a 700-point reading column, 14-point text, 4-point line spacing and larger gaps between sections.

This is deterministic formatting, with no LLM or server changes. All non-whitespace source characters stay in order. Raw chunks stay unchanged; copied text gets the same paragraph layout. Speaker names and recognition errors are not guessed or rewritten.

The same section allocator now avoids reusing an occupied negative row ID after a split (W-b). W-a's separate five-minute helper-failure polling cap remains outstanding.

## Validation

- Pure reducer suite: 90 checks, including a 15-minute same-speaker fixture, length/time bounds, real timestamps, append stability, raw content preservation, Unicode/no-space input, oversized chunks, copied layout and late-speaker row identities.
- Existing wiring pins: 102 passed; desktop-safety check passed.
- App-model fixture suite: 59 checks passed with the changed reducer and view. The whole app source (except its launch entry point) compiled with Swift 6 strict concurrency for macOS 14.
- An oversized-chunk render exposed text painting across the fixed header. The scroll body now has an explicit flexible height and clips its contents; the final light/dark renders verify the correction.
- Release-wide testing, signing, notarization and publication remain separate gates. No live recording or server was modified.

Final offscreen render build passed after freezing the source (an earlier rebuild correctly stopped when a comment changed during compilation). Reviewed [long same-speaker speech, light](transcript-readability/long-speaker-light.png), [dark](transcript-readability/long-speaker-dark.png), [oversized chunk, light](transcript-readability/oversized-chunk-light.png) and [dark](transcript-readability/oversized-chunk-dark.png). The header and Copy footer remain visible and the text is contained within the scroll body. All preview text is invented fixture content.
