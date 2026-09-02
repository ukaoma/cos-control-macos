## 0.5.185 (build 223)

Every message row says where it came from. With server 6.43.4 a run the Mac
started, the scheduled morning brief today and agent tasks next, carries a
ROUTINE or TASK label in the panel's recent messages, in the Activity window's
Messages list, and on the message detail line, beside the model that answered
and the first eight characters of the session. Unlabeled rows were started by
you; nothing is inferred from a missing label, so rows from an older server
render exactly as before. The helper passes four bounded keys through its
allowlist (modelPreference, origin, originId, messageEra) and drops anything
outside the server's two origin kinds or its id alphabet; the model applies the
same bounds again. The morning brief card now shows WHY the last brief failed,
so a server that refuses a submission is visible on the card.

## 0.5.184 (build 222)

Update Server no longer depends on one vendor's meter. The transactional
proof now tries every installed provider (Claude, Codex, and Cursor when its
agent is present), commits the update when at least one real query passes,
and records the others as skips with a named reason: "Codex (7s) proved ·
Claude skipped: session or usage limit". Zero proofs still fails closed, and
the Whisper and Kokoro gates are unchanged. On 2026-09-01 Claude's session
limit rolled six 6.43.1 updates back while Codex had proved in seven seconds.
With server 6.43.2 the reason comes from the server's failure code; older
servers are classified from their error sentence. The last proof's verdict is
carried in status as lastProofSummary.

## 0.5.183 (build 221)

The Morning brief card now shows what is behind each source. Under every
source in the Sources list is the line server 6.43.1 reports for it: meetings
stored and the newest month, memories and threads, events on today's calendar,
open tasks, the reflection log, whether the named skill exists. Green when
the well is reachable and non-empty, amber only when a probe that should
answer did not, plain when the COS reads it at run time (Slack, health,
dashboards). The last-run line reads "Delivered #74 · 3 of 4 sections ·
calendar not delivered" once the brief completes. On a 6.43.0 server the card
is unchanged.

## 0.5.182 (build 220)

Miles's three-session fight now keeps his feet under him through both retreat
beats instead of explaining depth with a shrinking figure. The repaired
footwork leads into the approved slash, the Force-thrown debris blocks the
incoming bolt without putting it through his hand, and the bottom-right droid
separates on contact before the larger destruction burst. The exact 2.86-second
loop, 110 ms shipping cadence, other session stories, idle scale, and every
custom character remain unchanged.

## 0.5.181 (build 219)

A Morning brief card, when the managed server is 6.43.0 or newer. The server
now composes a start-of-day brief on a schedule and drops it in the inbox as a
numbered reply; this card is where you say when and from what. Turn it on or
off, set the time and the weekdays, and open Sources to choose what goes in
(Calendar, recent-meeting decisions, tasks due, what is waiting on you, and the
optional set: knowledge graph, reflection, health, an opening reading, a
metrics pulse, one of your own skills such as /good-morning, or a custom
section), each with its own window. Apply saves the whole card in one change.
Run Now fires a brief immediately, five a day at most.

The card edits a draft. A background refresh never overwrites a half-typed
time, and every field goes to the server in one PUT rather than a stepper
saving on each click. The status line tells you when the next brief fires, or
why it will not: off while Background jobs are off, paused during maintenance.
The source list is capped and scrolls, so eleven sources with their options
cannot push the footer off the panel.

The helper carries three pass-throughs (`morning-brief`, `set-morning-brief`
with the change on stdin, `run-morning-brief`). Validation stays on the
server; a refused change comes back as the server's own sentence.

## 0.5.180 (build 218)

When two rows cannot be told apart, the pet shows the time instead of the
workspace. Sessions that share a name usually share a workspace too, so the
second line under the age was spending itself on a value that distinguished
nothing. A finished row now shows when it finished; a live one shows when it
opened. Rows with a name of their own are untouched, and so are rows that share
a name across different workspaces, where the workspace is already doing the job.

Clicking a Cursor row no longer opens the wrong agent. The jump presses the
Agents row whose title matches the session's name, which is only safe while the
name belongs to one agent. It does not always: two Cursor sessions here are both
called "COS glasses session update", and the press took whichever came first.
When the name is shared, Control now opens the Agents window, leaves the choice
alone, and tells you which one is yours by the time it started.

## 0.5.179 (build 217)

Finished rows lead with the session's name, the same as the live rows and the
Sessions tab. They led with the summary, and every resumed session carries the
same one, so the finished list repeated a single line of boilerplate where the
names should have been. What the session did moves to the second line.

The ledger bar shows its true colours. The bar's segments were painting through
the panel's material onto whatever was behind the window, so DONE came out a
duller, greener tan than the DONE button's own dot, even though both are set
from one value. The bar now sits on a solid floor like the buttons do.

## 0.5.178 (build 216)

The figure holds still when a list opens, and the lists keep their own width.

The window sizes itself from its content, and that kind of resize is anchored at
the top left, so opening a list grew the panel downward and pushed a
bottom-parked character off the screen. The panel now puts its bottom edge back
after every resize, so the menu opens upward from where you parked it. It still
moves down in one case only, when the pet sits so high that an open menu would
leave the top of the display.

The previous attempt at this turned the window's self-sizing off entirely. That
stopped the downward growth but also stopped the content tracking the window, so
the lists laid out at the wrong width and spilled out of their cards. That build
was withdrawn and never published.

Running rows lead with the session's name. They led with the live summary, and
every resumed session carries the same one, so several rows read identically
while the name that tells them apart sat underneath.

## 0.5.176 (build 214) — withdrawn, never published

This build tried to hold the figure still by trimming the panel's height. That
was the wrong lever and it was rejected in testing. The entry is kept so the
build numbers read straight; the behaviour it described is not in any shipped
release. 0.5.177 was withdrawn the same way, for changing how the window sized
itself, which made the lists lay out at the wrong width.

## 0.5.175 (build 213)

Double-clicking the figure opens and closes the menu again, and it remembers
where you were. It had been gated on having more than one running session, so
at one running session, which is most of the time, the gesture quietly did
nothing. It also only ever worked on the running list, so double-clicking while
the finished list was open looked broken. Now it closes whichever list is open
and reopens that same one, and the RUNNING and DONE buttons set what it reopens
too. It stays inert only when there is genuinely nothing to show.

Close all clears the finished list in one go. It sits between the list and the
figure while that list is open. Nothing is stopped or deleted; the rows just
stop being listed.

## 0.5.174 (build 212)

The session list stops cutting the ends off its right-hand column. Past three
items each list scrolls, and a scroll view clips whatever leaves its bounds, so
the rows' trailing column was being sliced rather than nudged: an age of seven
minutes rendered as "7", a workspace called mu-chief-staff rendered as
mu-chief-staf, and under the pointer the last of the three row actions lost its
right edge. Nothing there reached outside the list any more. The tucked edge is
now set by the list itself, and the resting text and the hover actions share one
trailing edge instead of being aligned by hand.

## 0.5.173 (build 211)

Miles moves through the Three and Four-plus fights with four additional bridge
poses at the seams that were still reading as jumps. Every approved V15 cel is
unchanged, and both stories keep their exact original loop length. The runtime
strip encodes the approved 110 ms bridges and 220 ms holds without blending,
camera movement or a new timing engine.

Idle is 1.45x, an 11.5 percent increase from 1.30x. It uses the same authored
eight-frame loop and changes only the character's pack-owned presentation
scale. Recognized stock Miles installs receive both updates automatically;
custom art and custom idle scales remain untouched.

Release packaging now adopts the stable COS Control signing identity whenever
it is available. A throwaway ad-hoc build can no longer replace a signed local
release and silently strand an existing Accessibility grant.

## 0.5.172 (build 210)

The session list keeps its right edge. The age, the workspace and the three row
actions were landing on the card border itself, so a resting row read as clipped
and the actions looked like they had slid off the panel. They sit 6pt in now,
still tucked well past the 10pt the list would hand them by default, and clear
of the 1px stroke they were touching.

Nothing else about the rows moved. Same sections, same hover crossfade, same
three actions in the same order, same fixed 57pt slot.

## 0.5.171 (build 209)

The session card tells you what happened. Every finished row used to print the
literal word "Finished", so two sessions forked off the same repo read as the
same three tokens no matter how long you looked at them. A row now leads with
what that session actually did, on its own line at the top of the row.

The card is wider, because the sprite was deciding how much room the reading
got. At the old width a finished title was 68pt, which is ten characters of the
font it is set in, and that is exactly the "You match…" you were looking at.
The title has 276pt now and the outcome line has 281pt.

Point at a row and it opens up. The three paths off a row, open it in the
platform, open the session view here, clear it, used to sit lit on every row,
spending 57pt of every line on controls you were not using. They now share the
fixed slot that carries the age and the workspace at rest, and cross over when
the pointer arrives. Nothing changes size, so the card never jumps. Right-click
reaches the same three, for when the pointer is not the input.

The outcome scrolls while you point at it, like a ticker, so a long sentence
can be read without the row growing. Only the row under the pointer moves, and
it waits a beat before it starts, so sweeping down the list moves nothing.

The trailing items sit on the card's edge now instead of 11pt inside it. Every
row was being inset to dodge a scroll indicator. The indicator is hidden, and
the 10pt went to the words.

Search by meaning moved out of the toolbar. It was sitting third in the panel,
between Activity and Server status, which is a lot of room for a switch most
people set once. It now sits at the end of the Messages search row, beside the
search it governs, and still says what it costs. When a search comes up thin
and the switch is off, the offer turns it on for you instead of sending you
somewhere else to find it.

## 0.5.170 (build 208)

One box searches recent messages and the archive. Two boxes meant "No recent
message contains thule" while the archive held thirty four hits one tap away,
and you had to retype the word to find that out. The line under the box now
carries both counts for the same term. The side you are on is a label, the
other side is a door, and crossing over runs the term for you.

The archive count never answers for a term you have moved on from. Until the
scan runs for what is actually in the box it says "press return" rather than
showing the last term's number as though it were live.

Search by meaning has a switch in the toolbar, and it is off. It is the one
thing in Control that spends model tokens, so it states what it costs in both
states rather than sitting there as a bare switch. Off is keyword only, no
model calls. On, Control offers to look for related days when a search comes
up thin, and asks only when you tap it. Twenty five a day.

Behind that switch, the model is pinned to Haiku, a breaker stops it after two
failures, and every day it proposes is checked against the real archive before
it reaches you. A date that holds nothing is dropped rather than shown, which
is what makes the layer safe without building an embedding index.

## 0.5.169 (build 207)

Recent messages are searchable. The newest turns were the one place you could
not look, so a phrase you remembered from an hour ago meant scrolling. The
box filters as you type and says how many of how many matched.

The search box stays put while you scroll. In an archived day and inside a
chat, the bar now sits above the list instead of scrolling away with it, so
what you searched for is still on screen when you reach the passage.

Matches are marked in the text itself, in yellow on dark and amber on light,
with dark ink either way. A tinted row told you the term was somewhere in
there; the mark tells you where.

## 0.5.168 (build 206)

Search results read like conversations again. The server cuts its snippets as
a raw window out of the archive file, so a hit near the top of a chat dragged
"sessionId", "exchanges" and "role" into the result with it. Snippets are
cleaned to the sentence a person actually said.

A search now opens on its matches. Finding one chat in eleven and then having
to flip a switch to see it buried the thing you asked for; the filter starts
on, and stays off when nothing matched so a day is never mysteriously empty.

Search tolerates a typo. "Thulle" finds Thule — one doubled or transposed
letter no longer makes a conversation look like it never happened. Short
words still match exactly rather than fuzzily, because at three letters
almost every word is one edit from another.

## 0.5.167 (build 205)

Updates moved to the top of the panel. The check used to be the very last
thing under everything else, so asking "am I current?" meant scrolling to the
bottom. The first card now answers it on every open: the version you are on
when you are current, an install offer when you are not, and the manual check
in both states. Quit stays at the bottom where it belongs.

Search now follows you all the way down. Finding the day got you a day;
finding the chat got you a transcript you still had to read by eye. An
archived chat now has its own find bar, seeded with the term that got you
there, with a match count, next and previous, and matched turns highlighted
in place — so a chat with forty-six mentions takes one keystroke to walk
rather than a scroll.

## 0.5.166 (build 204)

Archived days are searchable and readable. Finding the day a conversation
happened on used to end there: the day opened as "Chat 1" through "Chat 11",
and the term you searched for did not come with you, so you had to open every
chat to find the one you meant.

Each chat now leads with what it was actually about — the words that
conversation kept returning to, taken from your own side of it — instead of
an ordinal and an opening line that reads the same on every chat of the day.
The time, message count and chat number are still there underneath.

The search that found the day now carries into it. Chats that contain the
term are badged with their match count and show the passage that matched,
and a switch narrows the day to just those chats. Searching an archived day
costs one request, not one per chat.

## 0.5.165 (build 203)

Calm motion. An advanced character's multi-session fights are the whole
appeal for most people and motion sickness or plain distraction for others,
and until now the only alternative was macOS Reduced Motion, which freezes
the figure entirely. Turn on Calm motion in Session Pet settings and the
character rests on its gentle idle loop no matter how many sessions are
running — the same register as the still characters — while the bar below it
keeps reporting every count: running, waiting, finished. Lower motion costs
you nothing in status.

Alerts still reach the figure. An error or a jump that needs your attention
is not a motion preference, it is the app telling you it could not do
something, and both are brief. For no motion at all, macOS Reduced Motion
still freezes everything.

## 0.5.164 (build 202)

A large session now opens with its full history, not a sliver. 0.5.162 fixed
the refusal but read only the newest 8 MB, which on a 278 MB transcript
surfaced fifteen turns where the view can hold a hundred and twenty. The
window is now sized by measurement rather than guess: 64 MB fills the view's
turn budget on that same transcript in about a second, and reading further
buys nothing.

## 0.5.163 (build 201)

The agent rows now carry each platform's real logo instead of a stand-in:
the Anthropic sunburst for Claude, the OpenAI knot for Codex, and the Cursor
prism. They ship as monochrome vectors tinted like every other mark in the
app, so they stay legible in light and dark. A local model, which has no
brand mark, keeps its chip.

## 0.5.162 (build 200)

Large Codex and Cursor sessions open now. A transcript over 32 MB was
refused outright — "This Codex session is too large to open in Control",
behind a Retry button that could never succeed. Oversized transcripts are
windowed instead of refused: the head still supplies the working folder,
branch and title, and the newest turns come from the end of the file, which
is what you opened the row for. The middle is skipped and the session
subtitle says so. Nothing is refused for size any more.

Finished sessions on the pet now carry three paths instead of one: open the
session in its own platform, open the session view in Control, or clear the
entry.

## 0.5.161 (build 199)

Every agent row now carries its platform's mark, so you can tell Claude from
Codex from Cursor at a glance instead of reading the label: a spark for
Claude, a terminal prompt for Codex, a cube for Cursor, and a chip for a
local model, each in that platform's colour. The marks come from one shared
builder used by live rows, idle rows, and finished entries alike, so a
platform can never look like one thing in the list and another in the chips.

## 0.5.160 (build 198)

The live activity line is readable now. It was sharing the title column with
the age and workspace stack, which left it about 84 points — under twenty
characters, not enough for one whole word of a scrolling sentence. It now has
its own full-width line beneath the title, 209 points, and a slightly larger
face: 39 characters visible instead of 18, despite the bigger type.

## 0.5.159 (build 197)

Fixes found by an adversarial QA pass over everything shipped in the last
two days.

A session dropped from the list could become unreachable. The list is the
only home of the "Show dropped" restore row, but the poll closed it whenever
no sessions remained — so dropping your last row shut the list under the
cursor, and re-opening it lasted twenty seconds. It now stays open while
anything is left to show.

The live-line ticker mismeasured every non-Latin summary. Width was estimated
from a monospaced advance, which is exact for ASCII but up to 2.3x short for
CJK and emoji, because those glyphs come from fallback faces the mono font
does not cover. Overflowing text was judged to fit and silently clipped.
Non-ASCII text is now really measured. A line that does not scroll also ends
in an ellipsis instead of a hard cut — which is every running row when
Reduced Motion is on — and a line whose window narrows under it, as when the
drop control appears, now re-evaluates instead of staying frozen.

The bar's green segment kept breathing only if it was running when it first
appeared; a segment that became running while the bar was already on screen
sat still. The WAITING tooltip now says it opens the session rather than
promising a jump it no longer performs. The live list starts scrolling at
four rows rather than six, where the taller mission rows genuinely exceed
the scrolled height.

## 0.5.158 (build 196)

The WAITING pill now respects the choice. With one session waiting on you it
jumps straight in, as before. With two or more it opens the live list instead
of picking one arbitrarily and silently ignoring the rest — the state where
choosing matters most. Waiting sessions have their own amber section there.

## 0.5.157 (build 195)

The pet stays where you parked it. Opening a list grows the panel upward,
and when that would run past the top of the screen macOS slides the whole
panel down to keep it on screen — the pet then took that slid position as
its new home, so closing the list left it lower than it started. A pet
parked high on the screen walked 450 points down in a single open. Every
frame is now rebuilt from the spot you dragged the pet to, so a slide is
temporary and closing always returns it exactly. Dragging still re-parks it.

The live activity line is now a news ticker. A long summary scrolls through
a fixed window at a steady reading pace, so you can see what an agent is
actually doing instead of a truncated fragment. Text that already fits never
moves, a new summary restarts from the beginning, and Reduced Motion keeps
the line still.

## 0.5.156 (build 194)

Fixes the giant blank column 0.5.155's mission rows could open inside the
live list. The state rail was a bare shape sitting in the row, and a shape
accepts any height it is offered — under the panel's sizing probe one
running row absorbed hundreds of points of empty card. The rail now rides
as an overlay on the row content, which by definition takes the row's own
height and cannot stretch it. Rows are exactly as tall as what they say.

## 0.5.155 (build 193)

The live-session list is now mission rows, built to orchestrate a fleet at a
glance. One list, three weights: RUNNING rows carry a green rail, a two-line
title, a pulsing mono LIVE line saying what the agent is doing right now,
its workspace, and a colored age figure. WAITING ON YOU is its own amber
section that names what it waits on. Idle sessions recede to dim one-liners.
The LIVE line renders the per-session summary the helper has shipped all
along and the pet never displayed; the raw "user" wait token reads as
"needs you." The whole row still jumps, the drop x and restore row are
unchanged, and the scroll frame grew to fit the richer rows.

## 0.5.154 (build 192)

All four Jedi now have walking animations. Nia Solari, Elara Vale and Rowan
Vale gain separate eight-frame patrol cycles with alternating steps and coat
movement; Miles keeps his original walk. Nia also gains an eight-frame seated
meditation loop while waiting, with breathing and a rising electric aura.
Elara and Rowan retain their animated idle while waiting. Distinct calm clips
remain walking rests without duplicate playlist entries.

The 32 new frames are registered to each character's existing scale. All 76
previous PNGs, combat stories and Miles's 1.30x idle remain unchanged. Native
canary coverage checks all 12 calm-state paths, frame selection at four speeds,
Reduced Motion, transparent gutters and all 16 retained stock upgrade histories.
Art generation 17 upgrades untouched stock packs automatically; custom artwork,
pose metadata and saved character/size/speed preferences are preserved.

## 0.5.153 (build 191)

Nia Solari, Elara Vale and Rowan Vale now keep their eight-frame breathing,
glance and cloth-motion idle loops playing with quiet open sessions and while
waiting. Those real runtime states previously selected a legacy still, even
though the zero-session idle already animated. Reusing the same calm clip no
longer restarts it as a second playlist entry or changes its authored cadence.

Exact stock packs from 0.5.151/0.5.152 and earlier upgrade automatically.
Custom art, timing and scale are preserved. All image bytes, combat sequences,
Miles Windu's distinct ambient clips and 1.30x idle remain unchanged. Native
canary coverage exercises state resolution, playback, reduced motion, stock
migration, and the retained gallery fix before publication.

## 0.5.152 (build 190)

Fix the blank Nia Solari, Elara Vale and Rowan Vale previews in the character
gallery. Thumbnails now read the idle filename and frame count together from
each pack's state map, instead of slicing the old still using the new loop's
frame count. All four Jedi have pixel-checked gallery regression coverage.
Animation artwork, idle scales, selected character and saved settings are
unchanged.

## 0.5.151 (build 189)

Nia Solari, Elara Vale and Rowan Vale now have their approved combat stories
and eight-frame idle loops. The 223 new frames include connected defensive
reads, grounded strikes, Force pulls, visible droid defeats and recovery.
Each character keeps a distinct fighting style and an idle scale matched to
its own combat art. Miles Windu V15.4 and his 1.30x idle are unchanged.

Untouched bundled Jedi packs upgrade automatically, including the old still,
four-frame and V1/V1.1 releases. Recognition checks the entire state map and
retained image bytes. Custom artwork, pose timing or scale, selected character,
and saved global size/speed stay untouched. Versioned images land before the
state map changes, allowing safe retry after an interrupted write. Patrol,
waiting, success, error and attention keep their existing still fallbacks.

## 0.5.150 (build 188)

The pet is one surface family now. Both session lists, the terminal hint,
and notices ride the same blur material and 12pt rounded rect as the ledger
(notices are the error channel, so they sit on the heavier material — never
less legible than before). The floating focus dot is gone; the ledger's
colored segments already say it. A fully quiet pet keeps its IDLE capsule on
hover instead of revealing dead pills, while a pet whose only session was
dropped from the list still reveals the way back in. The RUNNING pill can
open a one-row list and the poll no longer closes it under the cursor; rows
keep one width whether or not the list scrolls; a finished list whose
entries age out or resume releases its pin instead of wedging the pet in
pills state; and the bar-to-pills crossfade animates on every path that can
flip it.

COS Control's own panel gets its first pass of the same discipline: eight
accumulated corner radii collapse to a 12/8/5 scale (cards 12, tiles 8,
small controls 5), with the few-pixel meter and legend radii kept as
proportional geometry.

## 0.5.149 (build 187)

Miles Windu V15.4 publishes the approved 26-frame four-plus-session story.
The rear-facing block turns through a foot-led underhand preparation into
the rising cut. An added slash follow-through bridges the upper droid's hit
and dissolve, the Force catch lifts the lower droid before the pull and
chest thrust, and the blaster advances with readable reaction time.

The stock idle scale is now 1.30x, bringing its apparent character size in
line with combat. Exact-stock older packs upgrade automatically; custom
artwork and non-stock pose scales stay untouched. The one-, two-, and
three-session strips, other characters, ledger UI and saved global size
and speed settings are unchanged. The swarm retains 0.22 seconds per
frame, for a complete 5.72-second loop at 100% speed.

## 0.5.148 (build 186)

The droids now agree with the ledger. Escalation used to read TOTAL alive
sessions, so three sessions with one running rendered a three-droid trio over
a "1 RUNNING" caption. The fight ladder now counts sessions in play — running
plus waiting, the same units the bar's colored segments show — so one running
is one droid, and idle-alive sessions read as patrol instead of summoning
opponents. Error, attention, amber waiting, and the completing flash keep
their precedence.

The clear x in an overflowing list no longer sits under the scroll indicator:
scrolling rows inset from the right edge where the indicator paints, in both
the live and finished lists. The ledger's blurred capsule is optically
re-balanced — it carried more air above the bar than below the caption.

## 0.5.147 (build 185)

Hover is pills-only now. The focused-session title card and the two circular
buttons are gone from the reveal: the RUNNING, DONE, and WAITING pills open
whatever is active, so a card naming one session and a second set of openers
were redundancy on screen (a single click on the figure still opens the
focused session). Hover no longer changes the panel's layout at all — the bar
cross-fades into the pills in its own slot, and only a pill click adds a list
above the figure.

Finished entries are now clearable: every row in the DONE list carries the
same x the live list has. Clearing removes that one entry and persists; it
returns only if the session runs and finishes again. Clearing the last entry
closes the list.

The ledger sits on its own blurred surface — a soft material capsule behind
the bar and caption — so the counts stay readable over busy wallpaper. With
Reduce Transparency the blur becomes a flat fill and the edge stroke keeps
the shape.

## 0.5.146 (build 184)

The ledger now sits UNDER the figure, a nameplate at its feet, instead of
riding its head. Character on top, bar and caption beneath, hover pills in
the bar's same slot. Both rows keep riding the panel's fixed bottom edge, so
nothing moves when the title card, actions, or lists unfold above the figure
on hover.

## 0.5.145 (build 183)

The ledger now hugs the character. The panel reserved the height of the
TALLEST pose for every pose — and with the stock idle at 3x, a 1x combat
figure sat under roughly two figure-heights of invisible headroom, leaving
the bar floating up to ~700px above the character's head. The panel now keeps
the stable envelope width (a poll never re-centers the pet) but takes the
CURRENT pose's height, so the bar, caption, pills, and hover reveals sit
directly above the figure in every state. The figure itself never moves: it
is bottom-aligned in a bottom-anchored panel, so a pose change repositions
only the chrome riding its head.

## 0.5.144 (build 182)

The consolidated public release: everything since 0.5.139 under one build
number. The ledger-bar pet chrome with its non-jumpy hover reveal, per-session
completion chips, the iTerm2/Terminal session jump, Miles Windu V15.2 stories
plus the approved 25-frame V15.3 swarm, the 25% to 200% character-speed
control, and the 3x stock idle. No code or art changes over 0.5.143 — one
version now names the combined interface and animation for the updater and
the site.

## 0.5.143 (build 181)

Miles Windu's approved V15.3 four-plus-session story now has 25 frames. The
clockwise spin flows directly into the lower-right droid strike without changing
the crossed-arm reverse grip. Contact, electrical breakup, wrist load, visible
saber release, flip, and catch form one continuous sequence. Force control,
pull-to-strike, defensive blocks, and complete droid dissolves remain intact.

The one-, two-, and three-session stories are byte-identical to V15.2. The swarm
keeps its authored 0.22-second cadence, with all 25 frames playing in 5.50 seconds
at 100% speed. Stock V15.2 and earlier packs upgrade automatically through an
exact-byte match; custom artwork and pose scales remain untouched. The ledger
bar, completion chips, terminal jump, speed control, and 3x idle are preserved.

## 0.5.142 (build 180)

The pet's chrome is now a ledger bar: a slim segmented health bar riding above
the sprite with a counted caption beneath it — amber for sessions waiting on
you (always at the front), green for running (with a slow breathe), gold for
finished. That is the whole idle footprint; the buttons, chips, chevron, count
badge, and status card are gone from the resting state.

Hovering the pet brings everything back: the bar cross-fades into three state
pills in its own slot, the focused session's title card and the two action
buttons unfold above. Click RUNNING to pin the live-session list, DONE to pin
the finished list, WAITING to jump straight to the session that needs you.
Zero-count pills sit dimmed. Click anywhere else to close a pinned list.

The motion is built not to jump: nothing above the sprite ever changes size
(the pills occupy the bar's exact slot), reveals grow upward from the pinned
bottom edge so the character never moves on screen, expansion waits a beat so
a cursor passing through triggers nothing, and collapse waits longer and fades
before it shrinks so leaving the pet never flickers. Hover arms even though the
app is not active — the sensor registers its own always-on tracking area, which
SwiftUI's own hover would not on a menu-bar app's nonactivating panel. macOS
Reduced Motion drops every slide and the bar's breathing, keeping plain fades.

## 0.5.141 (build 179)

The pet now tells you WHICH session finished, and takes you there. One of four
sessions finishing used to be invisible: the completion check was a fleet-wide
boolean, so any finish while others still ran never fired, and the 2-second
flash kept no record. Finishes are now detected per session, held as chips
behind a checkmark on the pet (unseen count in green), and survive a relaunch
for four hours, capped at eight. Clicking a chip opens that session in Control;
opening it anywhere marks it seen. A session that runs again drops its chip and
a re-finish is news again. Dropped rows and keep-warm sessions never emit.

Completing only flashes success when nothing else is still running or waiting,
and a session waiting on you now outranks the fight ladder: one waiting plus
three idle reads amber, not a five-droid swarm.

Clicking a Claude Code session that runs in a TERMINAL now raises that terminal
instead of Claude Desktop. Routing keys on the session's own recorded
entrypoint plus a two-terminal allowlist (iTerm2, Terminal) — never on tty
presence, which the 2026-08-30 census falsified when Claude Desktop itself
owned a tty. The activation sends no Apple Event and raises no extra windows;
a recycled pid is caught by a UTC-safe process-start comparison that fails
open. Desktop sessions keep their sidebar jump unchanged. Tab-level selection
inside the terminal is a later release.

An installed pack whose art is replaced by an update now takes the new art's
frame timing. Retention kept the previous cadence, which left the 17-frame
V15.2 duel playing a third slow against its authored 1.87-second loop.

## 0.5.140 (build 178)

Character speed now sits directly below Character size in Session Pet settings. The
saved 25% to 200% control slows or accelerates the animation without changing the
figure, card, buttons, or text; 100% remains each sprite pack's authored cadence.

Speed scales the animation clock rather than rewriting individual frame intervals.
That keeps complete combat stories and patrol rest beats intact at every setting, so
slow motion actually reveals every frame instead of cutting a sequence short. macOS
Reduced Motion still freezes the sprite regardless of the saved speed.

Miles Windu's bundled idle presentation is now 3× instead of 2×—an additional
1.5×—so idle, meditation, and patrol read at the same visual weight as the
multi-agent stories. Recognized stock installs migrate automatically while a
manually-authored pose scale remains untouched.

Miles's V15.2 active-session stories now contain 16, 17, 13, and 23 frames.
The two-session fight adds a rightward jump-roll, a clean landing beat, and a
visible replacement-droid entry. The three-session opening blocks three shots;
its ground and airborne attackers now aim at Miles rather than his blade.
The swarm mixes the cleaned single-blade backstab and visible rotating handoff
with Force control, a pull into a chest thrust, and complete droid dissolves.
Four counterclockwise turn beats lead into the visible behind-the-back chest
thrust; its compact pivot footwork keeps the final strike deliberate and readable.

The sprite pipeline now supports up to 32 frames so the longer stories retain
their exact cell boundaries instead of being silently sliced as 16. Versioned
assets and art generation 11 migrate byte-identical stock Miles packs to V15.2;
old assets remain available for recognition and custom art stays untouched.

## 0.5.139 (build 177)

Miles Windu now ships the approved V15.1 one-, two-, three-, and four-plus-session
stories reviewed in canary. Their six-pixel runtime gutter replaces the older V15
sheets that could crop effects at a frame edge, and existing unmodified Miles installs
upgrade automatically without touching custom sprite packs.

Miles's idle pose now renders at twice its prior size through pack-owned pose metadata.
Combat scenes and the user's global character-size setting stay unchanged, while the
shared viewport reserves enough room for the larger idle figure instead of clipping or
recentering it when session state changes.

Elara Vale's four active-session stories now use corrected V1.1 transparency. The
extractor preserves only the white blade core bracketed by both green saber rails, so
the broad white background matte no longer makes the saber look oversized. Existing
byte-identical Elara V1 installs upgrade automatically; customized packs remain intact.

## 0.5.138 (build 176)

Nia Solari, Elara Vale, and Rowan Vale now carry complete active-session stories at the
same bar as Miles Windu. One, two, three, and four-plus sessions play approved
16/12/13/16-frame sequences instead of a standing portrait followed by three four-frame
combat loops. Their attacks now establish each threat, show the block or strike, resolve
the droid on contact, and return to a readable loop seam.

Existing stock installs upgrade automatically. The app recognizes the exact retained
four-frame state map and byte-matches all four old assets before it writes anything; a
customized character is never touched. Versioned story files land and verify before the
state map switches, so an interrupted launch leaves the old pack readable and retryable.

## 0.5.137 (build 175)

Meetings to review can be read by date.

The list is a work queue: it puts meetings that still need speaker names on
top, so an unnamed meeting from Wednesday sits above everything captured
today. That is right when you are working through names and wrong when you
are looking for what you recorded this morning.

A sort control now sits next to Hide reviewed. Needs review first stays the
default. Newest first and Oldest first order purely by capture time and
ignore review state.

Rows now show the capture time alongside the date, because a dozen rows all
reading 2026-08-28 gave no way to see that a date sort had done anything.

Next unnamed is untouched. It still walks the review-priority queue, so
re-sorting the list to browse never reshuffles the naming order.

## 0.5.136 (build 174)

Turning the session pet on now asks for Accessibility, instead of waiting for a jump to
fail. That permission is what lets the pet open the session you clicked in Claude, Codex
or Cursor, and until now the first anyone heard of it was an error after a click that did
nothing. Settings also says plainly when the grant is missing, with a Grant button, and
clears the notice as soon as you allow it.

The permission is scoped and the panel says so: it gates the jump and nothing else.
Meetings, transcription, the server, Activity and search all work without it, so there is
no reason to allow it if you do not use the pet.

A failed jump now names the step that failed. Four different failures used to render one
sentence — a session name too short to match, no windows returned, a sidebar deeper than
the search limit, and a click the app refused — so a report from another machine said
nothing about which had happened. Each one now reports itself, with counts, and writes the
same detail to the log.

## 0.5.135 (build 173)

Miles Windu's four active-session stories now use the reviewed V15 artwork rendered from
the 2x masters. One session deflects the off-screen bolt, closes the distance and cuts
down the revealed droid. Two sessions restore the approved single-strike and backswing
deflection fight. Three sessions carry the rebuilt thirteen-frame three-droid sequence,
including the corrected final recovery with one attached purple saber instead of two.
Four or more sessions keep the full sixteen-frame swarm escalation.

Every strip keeps one authored scale for its whole loop, a transparent RGBA canvas,
cleared frame gutters and an exact opening composition at the seam. Runtime art is the
single final downsample from the reviewed 2x master.

Existing stock Miles V7 installs advance automatically to V15 on launch. The migration
recognizes only byte-identical bundled Miles artwork; custom sprites, OpenPets characters
and the three other bundled Jedi remain untouched.

## 0.5.134 (build 172)

Jedi Nia Solari, Jedi Elara Vale, and Jedi Rowan Vale now fight. Each carries authored
four-frame strips for the two, three, and four-plus session states: guard, the droids
fire, the blade lands on one of them, and that droid is knocked back with a cut scar and
its blaster down while the rest stay upright. Escalation reads from droid count, one then
three then five, the same way Miles Windu's loops do.

The other seven states keep the single portrait, which reads fine standing still. This is
the authored-frames answer to the motion 0.5.131 tried to fake and 0.5.132 reverted.

A shorter strip no longer plays faster. Frame rate was authored per pose against Miles
Windu's sixteen-cell strips, so a four-cell duel ran its whole loop in 0.44s instead of
1.76s. The loop duration is now what's held constant, and Miles Windu's own playback is
bit-for-bit unchanged.

Dropping an idle row is undoable again. `restorePetDismissals` had no caller, so a row
dropped by mistake was gone for good — the dismissal persists across relaunch. The list now
carries a "Show N dropped" control whenever anything is hidden, and Reset clears dismissals.

A dropped row also used to come back on its own within one poll. The pet applies sessions
twice per cycle, once from a snapshot only the Activity window refreshes, and pruning on
that stale pass retired the dismissal because the row was merely absent from an old list.
Only a list we know is current can retire a stamp now.

Two paths could destroy an installed character. Choosing a sprite over 8 MB cleared the pet
and then refused the replacement, leaving nothing; the file is validated before anything is
cleared. And a sprite pack that failed partway through the swap left a half-erased folder
whose state map pointed at files that never arrived; the outgoing character is now held
aside and restored if the copy fails.

Legacy packs draw at every session count. duel, trio and swarm fell back only to each
other, so a pack carrying none of the three resolved to nothing and painted the stock
figure once 0.5.130 stopped leaving the previous pack's art behind to cover for it.

Known and not fixed: the three Jedi are not scale-normalized against their own portrait,
so the character changes apparent size when combat starts. That needs a re-render.

## 0.5.132 (build 170)

Reverts the 0.5.131 procedural cadence. Translating and rotating a whole still
figure read as a sticker being wiggled, not as a character moving. The three
bundled Jedi go back to standing still until they have real sprite frames.

## 0.5.131 (build 169)

Gave characters that ship one image per state a procedural weight-shift cadence that
escalated with session load. Reverted in 0.5.132: sliding and rotating a whole static
figure read as a sticker being wiggled rather than a character moving. Recorded here
because it was published, and because 0.5.132 and 0.5.133 both refer to it.

## 0.5.130 (build 168)

Switching characters now actually switches. Installing a sprite pack, or picking
a single sprite from the gallery, used to layer on top of whatever was already
installed: every pose the incoming character did not declare stayed owned by the
outgoing one, and because a plain sprite is only the last-resort rung of the
pose lookup, choosing a legacy pet while one of the advanced Jedi packs was
installed could not change anything on screen. A pack is now built in a scratch
folder and swapped in whole, so a pack that fails halfway leaves the existing
character untouched instead of half-erased, and a stale combat strip can no
longer outlive the pack that wrote it and keep fighting under new artwork.

Legacy packs render every state again. The error and attention poses used to
fall back only to each other, so a pack carrying neither drew nothing at all for
both once the previous pack's leftovers stopped covering for it. Every fallback
chain now terminates at a pose a minimal pack actually declares.

Idle sessions can be dropped from the pet list. After ten minutes without
activity a row shows an x; clicking it removes the row from the list only. The
session keeps running, nothing is deleted, and the row returns on its own the
moment it does something. Four parked sessions no longer pin the pet in the
five-droid swarm while the one session actually working goes unseen.

Double-clicking the character opens the active-session list, so the chevron is
no longer the only way in. A single click still opens the focused session and
still never expands the list.

## 0.5.129 (build 167)

Session Pet settings now open as one compact section. State sprites and the
unified 304-character gallery each live behind their own disclosure, and the
four state-aware Jedi carry an Advanced badge inside the same grid as OpenPets.

Jedi Nia Solari, Jedi Elara Vale, and Jedi Rowan Vale join Jedi Miles Windu as
bundled choices. An enabled pet remains visible in idle when no session is
running. The collapsed pet reserves one lifecycle-wide viewport, and only its
chevron opens the active-session list, so poll-driven session-count changes no
longer move the character or expand the list under the pointer.

Miles's one-session work strip now tells one ordered story: sprint, brake, see
the incoming error, slash it with the purple saber, and return to the run. The
two-session strip uses the same running bridge around a two-droid counterattack:
brake, strike right, turn before the rear bolt arrives, deflect it, counter the
left droid, and sprint away. The three-session and four-plus strips were rebuilt
to keep Miles and every surviving droid present, use exactly one saber, show a
real block before contact, and remove enemies only after a visible hit/recoil.
All four loops close on a pixel-identical opening composition. Every internal
beat shares one measured camera scale, keeps 3px-or-greater cell gutters and true
alpha, and uses artwork-local scale, so arbitrary character packs are never
enlarged by a global combat transform.

Recognized older Miles installs refresh to the four new story assets once. The
check accepts the original stock pack or the retained prior one-/two-session
story pack only when all ten mapped assets remain byte-identical, then lands all
four strips before atomically updating their map records. A custom pose is
preserved, and an interrupted refresh retries on the next launch.

## 0.5.128 (build 166)

The archive opens.

Messages archived a day at a time and then counted history it could not show.
A date row said "24 chats, 256 messages" and did nothing when clicked, so
everything older than today was a number rather than something you could read.

Archive now drills through the way Recent already does. A date opens that day's
chats, and a chat opens its full transcript, paired question and answer, with
Copy turn on each one in the same clipboard format Recent uses. Back unwinds a
rung at a time: a chat returns to its day, the day returns to the list.

Search hits open too. A hit is a day, so finding a conversation by searching and
then not being able to open it was the same dead end reached a second way.

The server already served all three levels. Only Control was missing the last
two, so no server update is needed.

## 0.5.127 (build 165)

Miles is a character you can choose, not only the default you can restore.

The gallery now counts bundled animated characters and OpenPets community
stills together. With the current 300-item community catalog it reads
"Characters 301." Search covers both sources, including Miles, Black Jedi,
purple saber and droid terms. The Miles row says Use and retains the existing
replacement confirmation before it changes an installed pack.

Bundled characters now use a small registry with stable IDs, descriptions,
search terms and asset folders. Miles is the first entry. The next female and
male Jedi packs can join by adding their processed asset folder and one catalog
record without another gallery rewrite. COS-owned characters remain above the
OpenPets attribution so community licensing language stays correctly scoped.

The bundled Miles artwork also receives its final alpha polish. All eight
sprint frames have true transparency between the rear arm and coat, detached
paper specks are gone, and the patrol cycle no longer contains a split figure
or displaced fragment. The real importer and contrasting-background audit pass
all 74 frames with transparent cell edges.

## 0.5.126 (build 164)

Miles Windu is twice as readable without sacrificing the animation frame.

The character dial now defaults to 300% and reaches 600%. Existing preferences
migrate once, so a pet already maxed at 300% opens at 600% after the update and
stays there after restart. Oversized pet-size and character-scale combinations
fit the active display before rendering, while the saved preference remains
unchanged and returns at full scale on a roomier screen. The status card keeps
its own width as the transparent sprite envelope grows around the figure.

V4 duel, trio and swarm strips advance frame by frame instead of cross-fading
distinct combat poses into ghost overlays. Running and patrol settle only into
idle or meditation; success and attention keep their saber draws for the real
signal instead of repeating them during ambient playback.

The duel strip is rebuilt from the original artwork after importer validation:
the neighboring-frame droid no longer spills behind Miles, the opponent remains
fully inside its frame, and the white checkerboard regions between the fighters
are transparent without erasing the purple saber effects.

QA added executable coverage for first-load migration, restart idempotence and
maximum-size display fitting. The release gate's provider fixture is now
independent of whichever agent CLIs happen to be on the caller's PATH.

## 0.5.125 (build 163)

The default character is polished art, and the pet gallery can restore it.

Miles Windu V4 becomes the bundled default: rebuilt meditation frames with
corrected crossed-leg anatomy, the violet aura contained inside safe margins,
and body scale plus baseline normalised across every state. Validated through
the real importer — 74 of 74 declared frames preserved, and ZERO frames in any
of the ten poses now touch a frame boundary, where the previous pack had all
eight meditation frames cut through the character.

Frame cuts only leave the authored grid for a column that is empty, or clearly
cleaner than the grid column. A search that roamed a third of a cell for the
"emptiest" column carved through the figure whenever a strip had no real gaps.

The pet gallery gains a Restore row for the shipped character, above the
community gallery so its attribution still covers only its own art. Restore
deletes the installed pack, so it now asks first — installing a gallery pet,
which is less destructive, already did.

From a two-agent QA pass, all mutation-verified: the gallery thumbnail read
whichever pack owned idle, so the row labelled with the shipped character could
show someone else's art, and read raw it rendered an eight-frame strip into
44pt; restore wiped the installed pack BEFORE checking a replacement existed;
a partial copy reported success; the empty-column threshold was a fraction of
source height, so it meant one stray pixel on a short board and ten rows of ink
on a tall one; canvas padding took both axes from max(width, height), so one
wide effect frame shrank the figure everywhere. Three canaries that could not
fail were replaced with probes that do — proven by re-running each mutation.

## 0.5.124 (build 162)

Settled beats rotate through every solo clip.

Running and patrol already broke into bursts against a rest clip, but that clip
was always idle — so the meditation, the draw-and-flourish and the guard
sequences sat unused behind states that are rarely on screen. A settled beat now
picks among all of them (idle, waiting, success, attention), on a hash
independent of the action schedule so the two do not move together, and the
active pose is never used as its own rest. Measured across 1200 beats, no clip
is starved.

## 0.5.123 (build 161)

Running is a burst, not a treadmill — and the character holds its size.

A session is "working" almost all the time, so a sprint on a permanent loop
was what the pet did roughly 90% of the time. Running and patrol now play as
periodic bursts against the idle clip: settled most beats, breaking into the
action about 30% of the time, at most two beats in a row (a third would be a
loop again). The cadence is a pure function of the clock, so it never jumps
when the panel redraws, and it is irregular enough not to read as a pattern.
Fight poses are untouched — a duel should look like a duel for as long as it
lasts.

Each frame was cropped to its own ink and scaled to fill the same box, so a
crouched running frame was ENLARGED to match a standing one — the figure
appeared to grow and shrink mid-stride, and its feet drifted. A strip is now
normalised as a whole: one canvas, one scale, ink bottoms on a shared baseline.
Authored pose differences survive (a crouch stays shorter than a stand) while
the character itself holds its size. Measured on the V3 running strip: baseline
spread 0 px across all eight frames, down from per-frame drift.

## 0.5.121 (build 159)

The default character animates in every state.

Jedi Miles Windu V3 replaces the bundled default: 10 animated states, 74
frames, 6-8 per state — idle, patrol, waiting, running, success, error,
attention, duel, trio, and swarm. Every frame ran through the real install
pipeline (paper knockout, valley slicing, boundary-spillover suppression,
crop, 256px fit, equal-cell stitch) and all 74 survived it, with declared and
actual frame counts matching for all ten poses.

A pack's own animated duel, trio, or swarm strip now takes precedence over the
stitched cinematic ladder, so three and five sessions play their own
choreography instead of replaying the escalation sequence. A single-frame pose
still climbs the ladder, so V2-style packs are unchanged.

Thinking, reading, writing, searching, grepping, and stopped are not in the V3
live-state manifest and fall back to their related poses, as before.

## 0.5.120 (build 158)

Jedi Miles Windu ships as the default character, and the corner flash is gone.

The processed character is bundled with the app and seeded on a fresh install,
so the pet has real art without installing a pack. Seeding is gated on a
one-time flag rather than an empty folder, so choosing your own sprite or Use
COS figure is never undone.

Frame edges: a fragment CUT by the frame boundary is spillover from the
neighbouring scene, whatever its size. The combat board leaves a 540px blaster
bolt against the left edge — 5% of the figure and a few rows tall — which the
area rule and then the cut-face rule both kept, and which showed as a flash in
the pet's top-left corner. Anything reaching the boundary now goes; detail
composed inside the frame stays, because cropOpaque pads afterwards.

## 0.5.119 (build 157)

Character size is its own dial, and the fight stops blinking out.

**Character size** joins Pet size in Settings: Pet size is the card (buttons,
text, bubbles, list) and Character size scales only the figure, 100% to 300%,
default 150%. Growing the art no longer inflates the chrome around it.

Build 156 was cut but never published: retiring the cinematic strip on any
cinematic-pose install also deleted the strip a pack's own board had just
written, because a pack installs boards and pose strips in one pass. A pack
install no longer retires its own strip; choosing a single sprite still does.

The two-session duel played the combat board's droid-only scenes, so the
character vanished mid-loop. A story strip now drops the frames its subject is
absent from, measured by the strip's own colour content against its median
(hero scenes 0.21-0.43, droid-only 0.012-0.10) — relative, so a monochrome
pack keeps every frame, and never more than half a strip.

The panel and the sprite now compute their width from the SAME measured art.
The card reserved a fixed 2.6:1 cinematic aspect while the view measured the
real frames (0.97:1 as installed), so it claimed up to 2.7x the width the
figure needed — the card looked inflated around a small character, and at the
other extreme a wide scene rendered past the panel and clipped. Pixel art also
compares against the size it is drawn at now, so scaled-up art stays blocky.

Three sessions no longer look like five: the escalation strip is a ladder, and
each level plays it only up to its own rung instead of both trio and swarm
replaying the whole thing, patrol scene included.

From a four-agent QA pass on 0.5.110-0.5.116, in order of what could bite:

- The Cursor search fallback typed the session name after a fixed delay
  without proving a text field had focus. Keystrokes go to the process, so on
  a slow palette they could land in an open source file, which no Escape
  undoes. It now waits for a text-entry element and gives up silently instead.
- "File > New Agent" fired whenever activation was refused, not when the
  window was missing, so a jump to an already-open Agents window could spawn
  an empty composer. Window existence and activation are now separate facts.
- A pet notice never expired, and any notice reads as the attention state,
  which outranks every escalation pose — one failed jump pinned the pet in
  "alert, blade ignited" indefinitely. Notices now clear after 12 seconds.
- Edge-sliver suppression ran only on strips, never on the BOARD cells that
  showed the bleed, and judged by area: a bisected neighbour at 42% survived
  while a deliberate 1.6% blaster bolt was erased. It now runs on both paths
  and keys on the cut face (edge contact across 30% of the figure's rows).
- Choosing a sprite for patrol, duel, trio, or swarm retires the stale
  stitched strip that would otherwise keep rendering in its place.
- A lost state file no longer shreds a single-cell PNG into ten slivers, and
  the frame-count stepper is no longer hidden by the value it exists to raise.
- Cursor search text posts UTF-16, so an emoji in a session title cannot
  corrupt the query; the search walker reaches the same depth as the row
  walker; the search box is cleared after a successful jump; and a tab miss no
  longer claims the window failed to open when it is on screen.

## 0.5.116 (build 154)

Frame edges are clean, and the character stands at 1.5x.

A strip cut that lands inside a figure leaves a truncated sliver of the
neighbor frame's content at the edge — it flickered during playback and broke
the animation. An ink island touching the frame's first or last column that
is not the frame's primary island is now erased at install time
(contract-tested; the primary figure survives even when it reaches the edge).
Character scale rises from 1.35x to 1.5x; the chrome still does not move.

## 0.5.115 (build 153)

The character stands 35% taller; the chrome does not move.

The figure read small against its own buttons and bubbles. The sprite now
renders 1.35x the configured pixel size — applied only to the character
frame, so buttons, text, and the session list keep their sizes and the panel
grows just enough to hold the figure. Build 152 was cut but never installed
or published; its changes ship here.

## 0.5.114 (build 152)

Cinematic frames align to their cells, and the fight dissolves between scenes.

Playback guessed the cinematic strip's frame count from its aspect ratio —
996/256 rounds to 3 across a 4-cell strip, so every frame was cut mid-cell and
a half-droid bled in from the neighbor. installGrid now persists the true cell
count and playback slices by it (contract-tested; reinstalling a pack writes
the meta). Cinematic poses cross-dissolve over the last third of each frame
interval instead of hard-cutting, so patrol, duel, trio, and swarm play as a
flowing sequence.

## 0.5.113 (build 151)

The sprite pipeline is orientation-true, and the pet reads in dark mode.

Root cause of every recurring flip: the shared bitmap buffer applied a flip
transform, but a Quartz bitmap-context round trip is already orientation-true,
so each pass inverted the image once and upright-ness depended on how many
passes a path made — it also mirrored cropOpaque's bounding box, which is why
droids kept getting cropped out. The flip is deleted and an executable probe
in ModelsContract pins orientation through fitHeight, cropOpaque, and prepare.
Cell boards split on ink islands with narrow gaps merged (a detached bolt or
debris cloud rides with its scene) forced to the manifest cell count. Strips
keep their declared frame count, with each cut nudged to the emptiest nearby
column — the Windu fight scenes connect through 2px bolt bridges, so equal
cuts bisected droids and pure gap logic could not separate them at all.
Playback slices by the count that was stitched. Cinematic scenes render a
step larger.
Pet buttons use adaptive plate ink instead of fixed ink, ending black-on-black
in dark mode.

## 0.5.112 (build 150)

The three-droid fight loops, and the droids stay in frame.

Equal-width slices cut the escalation board through the droids, then a tight
crop shaved the rest. Three or more sessions now play the four fight scenes
as a loop in a wider pet. Install the pack again after this update.

## 0.5.111 (build 149)

Pack sprites sit upright and fill the pet.

0.5.109 wrote each installed PNG upside down and kept the empty board cell
around the figure, so Running and Duel shrank into a speck. Install the pack
again after this update.

## 0.5.110 (build 148)

A Cursor pet click survives contact with real Cursor.

Three breaks, all found by probing Cursor's live accessibility tree. Agents
rows expose their title as "Chat title. <name>", which defeated every matcher
branch; the matcher now strips that chrome (contract-tested). The closed-window
fallback pressed four menu items current Cursor no longer has; it now presses
File > New Agent, the one persistent command that opens the Agents window. The
Agents list is Electron-virtualized, so a scrolled-away row is absent from the
tree; a missing row is now driven through the window's own Search affordance.
The raise is verified against the frontmost app, the notice only says "Opened
Agents" when that is true, and every jump logs raised/fronted/window-titles to
Console so a field miss names its own cause.

## 0.5.109 (build 147)

The pet escalates from patrol to a five-droid swarm.

One quiet session patrols. A running turn sprints with the saber. Two sessions
duel a droid. Three fight a cluster. Four or more go full swarm. Error deflects
a red bolt. Attention ignites the blade. A V2 pack (core states, saber run,
droid combat, escalation) installs as a folder. A V1 combat strip still covers
a two-session duel.

## 0.5.108 (build 146)

The session pet can use a different sprite for each live state.

Idle, waiting, working, several sessions, and done each take their own PNG or
horizontal strip. A folder install maps a pack (idle, search, grep, combat,
done). Two or more live sessions play combat. One identity PNG still covers
every state that has no strip of its own.

## 0.5.107 (build 145)

The Accessibility grant survives updates, and the repair notice tells the truth.

macOS keys the Accessibility grant to each build's code signature. Ad-hoc
signing gave every build a new signature, so each update stranded the grant
while System Settings still showed COS Control enabled, and the old notice
("quit and reopen") could not fix that state. Local builds now sign with a
stable identity (`COS_LOCAL_SIGN_IDENTITY`), so a grant made once keeps
working across updates. The Claude and Cursor jumps share one Accessibility
gate; when it fails, the pet says to toggle COS Control off and on under
Accessibility and opens that Settings pane directly.

## 0.5.106 (build 144)

A Claude pet click opens that session.

0.5.105 opened the workspace folder, which only raises the last Claude tab.
Claude Desktop has no working link for an existing Code session. This build
turns on Claude's accessibility tree, then clicks the sidebar row whose title
matches the session name. It does not start a new Claude session.

## 0.5.105 (build 143)

A Codex pet click opens that thread.

0.5.104 showed the running Codex row, then opened the workspace folder, which
only raises the last Codex tab. This build opens `codex://threads/<id>`, the
link Codex Desktop documents for a local chat. It does not start a new thread.

## 0.5.104 (build 142)

The pet shows a Codex turn that is actually running.

The session list treated every Codex row as idle, so a live Codex thread never
made the pet. A transcript written in the last three minutes is now Running,
same window Cursor uses for file mtime. Clicking a Cursor row no longer raises
Cursor when this build cannot use Accessibility. Quit Control and open it
again after the Accessibility toggle. The Agents jump no longer activates
every Cursor window. That raise was the IDE.

## 0.5.103 (build 141)

The Cursor card selects that session's Agents tab.

0.5.102 opened Agents, then left whichever tab was already front. This build
still raises Agents first, then clicks the list row whose title matches the
session name. It does not match that name against Cursor window titles. That
raise is the IDE. Tab jump needs Accessibility for this Control build.

## 0.5.102 (build 140)

The Cursor card opens Cursor again.

0.5.101 named an Agents miss and then did nothing. The older jump already
brought Cursor forward. It was the IDE, not Agents. This build tries Agents
first. If that misses, it activates the running Cursor app. The pet says so.
It still does not spawn `--glass --new-window` while Cursor is already
running.

## 0.5.101 (build 139)

The pet names a Cursor Agents miss instead of opening another IDE window.

0.5.96 and 0.5.99 still raised the IDE when Cursor was already running. This
build does not spawn `--glass --new-window` in that case. The pet prints
whether Accessibility is on, which window titles it saw, and whether it
spawned. The session card stays clickable under that notice.

## 0.5.100 (build 138)

The pet session card opens the session.

The list row only changed which figure was focused. The square-arrow was the
only open. The whole card, including the empty space, now opens that session
the same way the arrow does. The focused status bubble does too.

## 0.5.99 (build 137)

The pet target opens Cursor's Agents Window, not the IDE.

`--glass` by itself is a Cursor architecture flag. A running Cursor treats it
as focus-the-last-window, which is the IDE. The jump now raises a window titled
Cursor Agents, uses Switch / Open or Focus / New Agents Window, and only then
launches `cursor --glass --new-window` with no folder.

## 0.5.98 (build 136)

The session pet comes back onto the screen.

0.5.97 grew Large downward from the bottom corner, and autosave parked the
panel under the display. An off-screen pet frame snaps back. Size still
follows Small, Medium, Large, or custom pixels.

## 0.5.97 (build 135)

The session pet has a size you can set.

Small, Medium, and Large are 25 percent off the original 64 px figure.
Custom types the sprite size in pixels (32 to 128). The rest of the pet
chrome follows that size. The target still opens Cursor's Agents Window.

## 0.5.96 (build 134)

The pet target opens Cursor's Agents Window.

`--chat` is a documented Cursor flag that the running app never reads, so
0.5.95 still raised the IDE. The target on a Cursor row now focuses an
existing Agents window, or opens one with `--glass`. Claude and Codex still
open that row in Activity. Open in platform for Cursor uses the same Agents
jump. Cursor still has no composer-id deep link, so that jump focuses Agents,
not one thread.

## 0.5.95 (build 133)

The pet follows the session that is actually working.

A Claude Desktop process that is still alive is not a turn in flight, so
Blocker Clearance no longer stays Running while Cursor is the live thread.
A Cursor agent that is still generating no longer drops off the pet just
because the transcript file went quiet. Open in platform for Cursor uses the
standalone chat window (`cursor --chat`) instead of opening the workspace
folder in the IDE. A minimized Claude or Cursor window comes back the way
clicking the Dock icon does. Cursor still has no composer-id deep link, so
that jump focuses Agents, not one thread.

## 0.5.94 (build 132)

Open in platform no longer quits Control.

0.5.93 handled the Cursor jump on Apple's Launch Services queue while the rest
of Control is main-actor, so the square-arrow control trapped and the app
exited. That open now waits on the async AppKit call, unhides the platform
window, and brings it forward. The pet prints Running, Waiting, or Idle. The
target opens that row in Activity. Two or more live sessions expand the list.

## 0.5.93 (build 131)

Gallery thumbs stay put while you scroll.

0.5.92 only kept 32 stills in memory, so loading the next row dropped ones
still on screen. Loaded thumbs now stay for the session, and a thumb already
on disk is not fetched again.

## 0.5.92 (build 130)

The OpenPets gallery is on the panel.

0.5.90 hid it behind a collapsed Pet gallery disclosure under Choose sprite, so
the only obvious path was the Mac file picker. Session pet now shows the
curated OpenPets thumbnails, with search, as soon as that toggle is on. Choose
sprite is still your own PNG.

## 0.5.91 (build 129)

The menu-bar eyeglasses keep their shape.

0.5.90 drew that symbol into a square so it could carry the update pip, and
the lenses went wide. The tray is the system eyeglasses glyph again. The pip
still appears on the corner when an update is waiting.

## 0.5.90 (build 128)

A gallery of community pet figures, without leaving Control.

Pet gallery next to Choose sprite loads the OpenPets thumbnail catalog (300
curated stills, not the zip packs). Picking one copies that thumb through the
same sprite store Choose sprite already uses. Sessions, prompts, and Open in
platform stay on COS. The closed-tray update pip from 0.5.89 is unchanged.

## 0.5.89 (build 127)

The closed tray shows when an update is waiting.

The eyeglasses glyph still says whether the server is up. A small pip appears
on that same icon only when the appcast has a newer Control build, so you do
not have to open the panel to know. Install stays the banner already in the
panel. An offline tick no longer wipes a real offer, and Check for updates
says it could not reach the feed instead of claiming you are current.

## 0.5.88 (build 126)

Open in platform from the session, and a sprite you picked.

The waveform still opens the Activity session. That split was right. What was
missing is the jump to Cursor, Claude Desktop, or ChatGPT from the session
itself, so the footer next to Copy session now says Open in platform. The pet
grows the same control. Choose sprite copies a PNG into Application Support
without resampling, so a 32x32 pixel figure stays blocky. Use COS figure puts
the original visor back.

## 0.5.87 (build 125)

Live sessions stay on the desktop when Activity is closed.

The Sessions list already knew which Claude, Cursor, and Codex threads were
Running or Waiting, but that knowledge lived inside a window you had to keep
open. The pet is a floating COS figure that appears only while those rows are
live, shows a count when more than one is, and jumps to the native app that
owns the thread — Cursor, Claude Desktop, or ChatGPT — without bringing
Control forward. Clicking the waveform is the fallback: it opens that same
row in Activity, because Cursor still has no composer deeplink. The toggle
sits with Launch at login; it never talks to the server.

## 0.5.86 (build 124)

The whole calendar square selects the day.

Picking a day in Meetings meant hitting the date number itself or the little
dot under it. Everything else inside the highlighted square did nothing, so
the target was an 11.5pt glyph and a 5pt dot instead of the cell you can see.
Under `.buttonStyle(.plain)` SwiftUI hit-tests only the RENDERED content, and
the cell's background is clear until the day is selected, so the surrounding
area was never a target at all. The cell now declares its own content shape
and the entire square is clickable. Days with no meetings stay disabled.

## 0.5.85 (build 123)

The message icon itself says what is attached.

The left-column bubble was the same for every row, so a video and a text-only
turn were identical until your eye reached the far side of the row. The bubble
now wears a small filled type mark on its corner: a camcorder for video, a
framed peak for photos, a folded page for files, and stacked cards when a turn
holds more than one kind. The bubble grows from 16 to 20pt INSIDE its existing
32pt frame, so nothing about row height or alignment moves.

The marks are filled rather than stroked, and that is the reason they work. A
first pass drew them as 1.15pt outlines and every one collapsed into an
indistinct speck at that size. Each shape was then rendered at 64pt to confirm
it is the thing it claims to be, which is how the original paperclip was caught
reading as a battery and became stacked cards instead. Colors come from the
Activity section palette, so the badge and the right-hand count badge agree.

## 0.5.84 (build 122)

The message list says WHAT is attached.

Every attachment badge rendered the same `photo` glyph, so a 75-second video
sat in the list wearing an image icon and there was no way to tell a video
from a picture from a file without opening the message. The badge now takes
its icon from what is actually attached: a video glyph for video, a document
glyph for files, a photo glyph for images, and a paperclip when a turn mixes
types rather than picking a winner among its parts. Hovering names it in
words -- "1 video", "2 files" -- because a 9.5pt glyph is a hint and the
tooltip is where the answer should be unambiguous.

## 0.5.83 (build 121)

The fourth filter. Video playback now actually works.

There were FOUR independent image-only gates between the server and the
screen, not three. 0.5.82 fixed the helper's byte verifier and I confirmed
the helper returned `state: ready, mime: video/quicktime` — then shipped
without tracing what the app did with that response. `fetchMediaFile` re-
checked the mime against a JPEG/PNG allowlist of its own and threw the
ready video away, so the poster still rendered and the click still failed.
The helper working was not the feature working.

That decision now lives in one place, on the attachment model, where the
contract test executes it rather than a grep asserting it. Also fixed in
the same pass: the agent handoff exported the full video under an
`image-NN.jpg` name (masked until now by its image-decode guard, which
rejected the video and printed "unavailable"). It exports the poster frame
instead, named `poster-NN.jpg`, because a poster is the only part of a video
another agent can actually inspect.

## 0.5.82 (build 120)

Playing a video actually plays it.

0.5.81 got the poster, the play badge and the duration onto the screen.
Clicking it still failed with "This image is unavailable", because the media
FETCH path carried a third image-only gate: it sniffed magic bytes with a
JPEG/PNG-only sniffer and refused anything else. That was the last of three
independent image-only filters between the server and the screen.

Fetched bytes are now verified against the type the server declared, per
family: images by magic bytes exactly as before, video by its ISO base media
`ftyp` container, PDF by its signature, and text by decoding as UTF-8, which
is the honest check for a family with no magic bytes. The declared-vs-actual
cross-check is KEPT and pinned in both directions -- a container declared as
a PNG is still refused, and so is a JPEG declared as video. The temp file is
now written with the extension its type implies, since LaunchServices routes
on that, and the full-size ceiling rises to the 100 MB the server's own video
contract already allows. The error copy no longer calls a video an image, and
a verification failure now says so instead of hiding behind "unavailable".

## 0.5.81 (build 119)

The video fix from 0.5.80, actually reaching the screen.

0.5.80 widened the app's attachment parser and shipped. It changed nothing
visible, because the helper has its OWN image-only allowlist sitting in
front of it: a video ref died in `normalizeAttachment` and the app received
`attachments: null`. Caught by querying the shipped 0.5.80 helper for the
real Message #29 rather than trusting that the change had worked. Both
filters now carry the same vocabulary, and the helper forwards the
`category`, `bytes` and `durationMs` the poster needs to say "1:16" and
"2.1 MB". Pinned by self-tests that run the actual #29 payload through the
normalizer, and by mutations that restore each half of the old behavior.

## 0.5.80 (build 118)

Readable timestamps, and your videos and files finally show up.

Every message row rendered a bare 24-hour clock. Thirty turns spanning
several days all looked like "19:15" over "18:31", with no way to tell today
from Monday, and no AM/PM on a machine whose locale uses it, because a
hardcoded date format ignores locale entirely. Rows now carry their day:
"Today 7:15 PM", "Yesterday 6:31 PM", "Aug 24, 2:19 PM". The time half is
locale-driven, so a 24-hour locale keeps 24-hour rather than having AM/PM
forced onto it.

Video and file attachments were being DROPPED IN SILENCE. Control's parser
accepted three image kinds crossed with JPEG and PNG, so a video ref failed
it and disappeared: no badge in the list, no asset in the detail, nothing to
click. The server had been sending the whole ref all along, including a
75-second video with 13 extracted frames. The parser now accepts the full
media contract, and because a video's thumbnail variant is already a real
JPEG poster frame, posters render through the existing path. Video shows a
play affordance and its duration; documents get a file glyph and size;
clicking either hands the file to QuickTime or Preview with an extension
derived from its MIME rather than from the server's untrusted label. Images
still open inline exactly as before.

## 0.5.79 (build 117)

Pick your local model, and pin it.

With more than one Ollama model pulled, the server's automatic selection
follows the NEWEST pull -- so pulling anything silently repoints the lens.
A "Local model" picker now sits in Settings beside the other server
switches: it lists the daemon's pulled tags, shows Automatic for what the
server does unpinned, and Apply writes COS_OLLAMA_MODEL through the same
restart transaction every other setting uses. A pin whose model is no
longer pulled still renders (marked "not pulled") rather than lying about
the configuration, and an unreachable daemon is a rendered state, not an
error. The tag charset is guarded so a pasted shell fragment can never
reach the LaunchAgent environment; the write shape is executed by
self-tests. Pairs with server 6.40.0, which scales local thinking with the
requested effort.

## 0.5.78 (build 116)

One environment key for server 6.39.3: COS_OLLAMA_THINK.

(Renumbered from a 0.5.77 collision: a parallel session published 0.5.77
with the Review speakers overflow fix while this entry was being cut. Two
different binaries must never share a version string.)

Server 6.39.3 turns local-model thinking off by default (a thinking-class
model spent 98 seconds of hidden reasoning on a two-second answer) and reads
COS_OLLAMA_THINK for anyone who wants it back ("1", or a budget: low, medium,
high, max). The helper builds the LaunchAgent environment from a fixed key
list, so without this entry an opted-in thinking budget silently vanished on
every Update Server. Pinned by a self-test assertion beside the
COS_OLLAMA_MODEL one from 0.5.73, which was this exact lesson.

## 0.5.77 (build 115)

Review speakers no longer runs off the window.

Add a voice lists the unrecognized audio the server is holding, and the server
holds it for 72 hours. With thirty-odd sessions that list grew without limit,
and because the card sits outside the voice directory's scroll area it pushed
the section header, the view picker and the breadcrumbs off screen. There was
no way back to navigation without resizing the window.

Past five held sessions the list now scrolls inside a fixed frame and the lead
line says how many are held, since a scrolling box hides its own length. Five
or fewer keeps its natural height. A test pins the cap and goes red if the
list ever renders uncapped again.

## 0.5.76 (build 114)

The refusal said "fork it." Now you can.

0.5.75 shipped the composer rendering the server's busy-thread copy — "Wait a
few seconds and try again, or fork it" — with no fork anywhere in Control, an
instruction with no affordance. Caught live in the first session. A "Fork with
this message" button now appears wherever the rendered copy recommends it:
your message runs in a copy of the thread, seeded with its history, while the
original stays byte-identical. The fork lands at the top of the Sessions list
(the server deliberately withholds the new thread's id). Cursor sessions
refuse with the server's own copy — bindable, not forkable.

The 0.5.75 fallback line ("Forking is not available in Control yet") never
rendered either: it matched capital-F "Fork" against copy that says "fork it".
The button's trigger matches case-insensitively, and that exact regression is
pinned red. The fork prompt travels over stdin like the send path.

## 0.5.75 (build 113)

Continue a session from the Sessions view — text in, reply back.

A composer now sits under every Claude, Codex, and Cursor session detail. Type
a message, and it lands in the real thread on this Mac through the same
attach/turn API the glasses' Continue ships on: attach a binding, post one
idempotent turn, poll to a terminal outcome, then show the session's newest
reply. Text only, by design — files and images wait until the text path has
earned them.

The poll classifier encodes the server's least obvious truth: a RUNNING turn
polls as 404, because the ledger records only terminal outcomes. Anything that
is not a 200 body carrying completed/refused/ambiguous stays pending, bounded
by wall clock — mapping it to a failure would invite the retry that double-
posts into a real conversation. Refusals render the server's copy verbatim
with the composer disabled; native_thread_changed gets an explicit Refresh /
Continue-anyway choice, and only that gesture ever sends an acknowledgement.
An attachable verdict with a live owner (a session that merely looks idle this
second) asks before the first send instead of showing a green light. The
prompt travels to the helper over stdin, never argv.

Also fixed: the Continue agent threads OFF toggle wrote nothing. It deleted
the environment key, which servers 6.37.0+ (default-ON) read as ENABLED — so
opting out silently re-enabled the feature and then stranded a stuck
transaction on the failed proof. Off now writes an explicit "0", which means
disabled on every server era, and the self-test executes the write.

## 0.5.74 (build 112)

The panel now says when a local Ollama model is live.

An "Ollama · {model}" row appears in About, and a matching line in Doctor, when
the server reports a local daemon ready with a pulled model -- and both vanish
entirely otherwise. No row is the correct render for "no local daemon": painting
a red mark on every Mac without Ollama would imply it is expected setup, and a
pre-6.39.0 server (which never reports the keys) must not look broken.

Three properties are pinned by helper self-tests: a healthy server with the
daemon down is not a provider capability failure; a pre-6.39.0 health body stays
clean; and the model tag never routes through version parsing, which would
truncate "qwen2.5-coder" to "2.5". The health read ignores the top-level
`ollama` key deliberately -- it is a spread check STRING ("fetch failed" on a
daemonless box), not a boolean.

## 0.5.73 (build 111)

Two environment keys for the new local-model support in server 6.39.0.

COS_OLLAMA_MODEL (pin a local model) and COS_OLLAMA_HOST (alternate loopback)
are now allowlisted into the LaunchAgent environment the helper writes. The
helper builds that plist from a fixed key list, so without this a user's Ollama
settings silently vanished on every Update Server. Pinned by two self-test
assertions so the keys cannot drop out of the list unnoticed.

## 0.5.72 (build 110)

Six months of conversation you could store but not reach.

COS archives every day's conversations. On a working install that is 175 day
files going back six months, and nothing in COS Control could open any of it --
no helper command touched the archive at all.

Messages now has a Recent / Archive switch. Archive lists every archived day with
its volume (chats and messages, not just a date, so a busy day is distinguishable
from an idle one at a glance) and searches the whole store by text. Search runs on
submit rather than per keystroke, because a wide window is a real multi-second
scan on the server, not a local filter.

A hit is attributed to a DAY, with the text around each match. Not to a chat: the
server scans day files as raw bytes and never materialises one, which is what
makes searching six months affordable at all.

OPENING THIS VIEW WILL NOT WAKE A SLEEPING GIANT. On a server predating the
archive index, GET /api/archive builds its summaries by parsing every day file --
1.2 GB on the real corpus, and 2.3 GB RSS for the largest single day, on the same
process running the wearer's live session. So the listing PROBES the search route
first and refuses with "update your server" rather than making the request. An
older server does not 404 for that probe; it falls the path through to
/archive/:date and answers 400 "Invalid date", which is the signature this checks
for. Verified live against 6.37.3.

Until a server carrying the archive routes is published, Archive shows that update
notice. Everything else in this build is unaffected.

Four guards pinned in Tests/run.sh, each mutation-verified red: the 400
fallthrough, probe-before-list ordering, search-on-submit, and the day list's
volume counts. Two of those pins were decoration when first written -- one loose
substring was satisfied by an unrelated row elsewhere in the same file, and one
mutation never applied at all -- and were tightened until the mutation actually
turned the suite red.

## 0.5.71 (build 109)

A way to tell people what they can now do.

The appcast can carry a `notice` block: an id, a title, a body, and a minBuild.
COS Control shows it as a dismissible banner at the top of the panel, beside the
update banner, and it is edited on the server rather than shipped in a build.

It is deliberately NOT gated on an update being available. Somebody who just
finished updating is up to date, and that is precisely the moment a "here is what
you can now do" message is worth reading. Gating it on `updateAvailable` would
hide it from the only audience it is for. It is parsed before the killSwitch,
malformed and requiresMacOS returns for the same reason, so those paths cannot
swallow it.

`minBuild` keeps it off builds that lack the feature being announced, so nobody
is told about something they cannot use. Dismissal is stored per notice id, so a
later notice still appears and a dismissed one never returns.

## 0.5.70 (build 108)

Named speakers failed silently, in the one panel built to fix them.

The 26 MB voiceprint model that separates speakers is fetched by Guided Setup and
by nothing else. Installing COS Control does not fetch it and neither does
Update Server: both stage the server with `npm install --ignore-scripts` and
never execute `bin/cli.cjs`, and the package ships no install hook. Without the
model, diarization falls back to wearer/Ext.

That produced the worst version of the failure. Open a five-person meeting in
Review speakers, see two voices called Me and Ext, and get no reason. The server
has reported `speaker_id` on /api/health the whole time. Control had never read
it.

Control now reads it and, when it is not `active`, the Review speakers card
carries a banner saying every voice stays Me or Ext until the model is
installed, with a button that opens Guided Setup. An older server that predates
the field reports nothing and the banner stays hidden, so upgrading does not
start nagging.

The field is read from the TOP LEVEL of the health body. health.ts assigns
`checks.speaker_id` but spreads `checks` into the response, so the nested path
the source implies is always nil. Wiring it from the assignment site would have
shipped a banner that could never appear. Verified against the live payload
first, and pinned in Tests/run.sh.

# Changelog

## 0.5.69 (build 107)

Two CTAs that read wrong.

DUPLICATE RECOVER. With exactly one recoverable capture the panel rendered two
buttons both reading "Recover": a bulk button whose label collapsed to the
singular, and the per-row button. Both fired the same recovery on the same
session — the bulk branch fell through to `recoverableOrphans.first` — one
appeared greyed because the row was mid-recovery, and nothing told the user which
was authoritative. The bulk button is now guarded on `count > 1`, and its
single-capture fallback is deleted with it since the guard makes it unreachable.
The per-row button already covers one capture AND carries the label and chunk
count that say what is being recovered.

FOOTER CTAs. "Check for updates" and "Quit" were `.buttonStyle(.link)` at
mono(10) with a secondary foreground and no spacing between them, in a panel
where every other action is a bordered chip with an SF Symbol. They read as one
run-on string, with nothing separating a harmless action from one that kills the
app. Now bordered chips with icons, on their own row beneath the version label —
the panel is a fixed 390pt and the label already wraps, so sharing a row would
have squeezed it further.

Both are pinned in Tests/run.sh, and both pins were mutation-verified: restoring
the singular Recover label or returning Quit to `.link` fails the suite.

## 0.5.68 (build 106)

The Meeting Turbo preview checkbox was lying.

It resolved its value as `== "1"`, and an absent environment key reads as nil,
so the box rendered OFF for every user who had never set the variable — while
the server had the feature ON the whole time (`COS_WHISPER_MEETING_PREVIEW` is
`!== '0'` server-side, and always has been). Turning it "on" changed nothing,
because it was already on. Seen on a first-time user's 6.36.28 install
reporting meetingPreviewEnabled:false against a server running the feature.

A checkbox that misreports a running feature is worse than no checkbox.

Three more gates flipped to default-ON in glasses-server 6.37.0 — Continue
agent threads, Reliable video uploads, Adaptive audio cleanup. Those read the
server's live health first, so a running server was already reported
correctly; their STOPPED-server fallbacks had the same `== "1"` mistake and are
fixed too.

All four now resolve through one `featureGateDefaultOn` helper, unit-tested in
the helper self-test (absent, empty, "1", a stray truthy value → ON; only a
literal "0" → OFF) with a Tests/run.sh assertion that every call site still
goes through it. Both layers mutation-verified.

Also allowlists COS_MEETING_SUMMARY and COS_MEETING_SUMMARY_DAILY_CAP in the
provider environment. `providerEnvironment` is filtered to that set on every
plist rewrite, so without them a user who enabled standalone meeting summaries
would find them silently off again after the next Install / Repair / Update
Server — the same failure that made COS_PROFILE_PATH stop surviving updates.

Idle Metal HQ and Show Claude sessions are unchanged: they are genuinely
opt-in server-side, so `== "1"` is correct for them.

## 0.5.67 (build 105)

A Check for updates button, in the footer.

The automatic check runs once at launch and then every 6 hours. That is the right
cadence for a background poll and the wrong one for a hotfix: a Control left
running -- which is the normal case for a menu-bar app -- can sit behind a release
for hours with no banner and no way to ask.

Measured today. A Control up since the previous afternoon was TWO builds behind,
0.5.64 against an appcast at 0.5.66, because every 6-hourly tick had landed
before the releases went out. The only remedy was to quit and reopen the app.

SILENCE IS THE WRONG CONTRACT FOR A BUTTON

`checkForAppUpdate()` deliberately swallows its failures, and that is correct for
a background check -- an offline laptop should not raise an error nobody asked
for. But a user who clicks and sees nothing cannot tell "you are up to date" from
"the check failed" from "the button is broken". That is the same
indistinguishable-outcomes problem that has cost this project real days.

So the manual check is a separate method rather than the same one wired to a
button, and every path reports: an update (the banner already offers it), up to
date (says so, with the version), or the failure (says what went wrong). It also
shows "Checking…" while in flight, which the background check never does.

Three guards in Tests/run.sh, all mutation-verified: removing the up-to-date
message fails, swallowing the failure fails, and a button that stops calling the
method fails.

## 0.5.66 (build 104)

Add a voice, from the Speakers pane. Closes the second half of #2.

Naming a voice already worked, but only INSIDE a meeting review, and that can
only ever rename a voice the system had already separated out. A user whose
whole transcript came back `[Ext]` has nothing to rename, and no reason to know
the glasses voice command exists. 0.5.65 told them what was wrong; this gives
them somewhere to click.

WHERE THE AUDIO COMES FROM

The server already holds unrecognized-speaker audio for 72 hours. Naming one of
those sessions builds a real profile from real meeting audio, which is better
training material than a cold 30-second sample and is exactly what a review
would have used.

SAFETY, all of it server behaviour rather than our guesses

- Always scoped to ONE session. The server treats the unscoped form as a
  profile-poisoning default -- it assumes one speaker across every held session
  and deletes them all -- and gates it behind `confirmAllSessions`. The helper
  never sends that flag and refuses a call without `--session`, so the dangerous
  form is unreachable from Control by construction, not by discipline.
- The panel says a held session can still contain MORE THAN ONE unknown speaker
  before the user commits. That is a real risk, not a hypothetical: it is why an
  earlier manual enrolment was declined.
- It says the audio is consumed on success. There is no undo.
- The expiry countdown is the server's own string, so it cannot drift from the
  retention actually enforced.

Shown in BOTH the empty and populated directory. A user with zero profiles is
precisely who needs it, and an empty state that only explains the problem is
what sent the original report to Discord instead of to the fix.

Four guards in Tests/run.sh, all mutation-verified. One of them was decoration
on the first pass: asserting the string `--session` appears only proved the flag
is mentioned, and a mutation that defaulted it to `""` sailed through. It now
pins the refusal message, which lives only in the guard's else branch.

## 0.5.65 (build 103)

Hotfix for issues #1 and #2. An empty speaker-review list told new users to do
the one thing that could not help.

Reported by Chelsie on 2026-08-24: server 6.36.28 (latest), `speaker_id: active`,
voiceprint model installed, 31-minute G2 meeting transcribed entirely as
`[Ext]`/`[Unknown]`, and no `voice-profiles.json` ever written. Speakers to
Meetings-to-review said "1 recent meeting predates speaker review. Update the
server to review new ones." She was already on latest. Hours lost.

Nothing was broken. She had zero enrolled voices.

- `voice-profiles.json` is created BY enrolment, so its absence is the initial
  state, not a fault.
- With zero profiles the server's `identifySpeaker` finds no match and labels
  every segment `Ext`. 170 `[Ext]` lines was correct behaviour.
- It cannot self-heal: `autoEnroll` needs a match against an EXISTING profile and
  explicitly skips `Ext`, so it can never create the first one.

The old message was wrong on its own terms too. `skipped` counts rows the helper
dropped for having no sessionId; it has nothing to do with the server version.

WHAT CHANGED

- `emptyReviewReason` asks the server for the enrolled count and reports the
  actual cause. Zero profiles now says so and names the fix. Rows dropped for a
  missing sessionId say that, and no longer blame the server version.
- The count is fetched rather than read from `voiceDirectory`, which a different
  subview loads and may never have run. Only on the empty path, so the normal
  case costs nothing. If the count cannot be established we say the honest thing
  instead of guessing — an unanswered probe is not evidence of zero.
- Both empty-state messages now name the action. Enrolment was already built and
  wired (a guided 30-second flow on the glasses) but reachable only by the voice
  command "enroll my voice", and Control's Speakers pane is view-only — so a user
  who read the accurate message still had nowhere to click.

Guards in Tests/run.sh, both mutation-verified: the misleading sentence cannot
return, and both empty-state messages must name the enrolment phrase. The first
guard is comment-aware — a plain grep matched the doc comment recording the old
wording, which is the "assertion satisfied by the file's own prose" failure, and
it was caught by running it.

Not fixed here: there is still no enrol action in Control, and the 72-hour
`ext-audio` recovery window is not surfaced anywhere. Both tracked in #2.

## 0.5.64 (build 102)

**"Show Claude sessions" was telling you it was off while it was on.**

The checkbox seeded from `model.claudeSessionsEnabled`, which only
`loadClaudeSessions()` sets -- and every caller of that lives in the Activity
window, never in the panel. Open the panel without visiting the Activity window's
Claude tab and the box rendered false regardless of the real setting. The setting
was on; Miles enabled it four times against a control that could only show him one
value. The comment above the line named the hazard ("only accurate once that has
loaded") and it shipped anyway.

It now reads `status.claudeSessionsEnabled`, which the panel refreshes on its own,
like every other toggle on that screen. Server 6.36.22 publishes it in
`health.features` -- a pure env read, free on a poll -- rather than the panel
paying for a 58-session listing to learn one boolean.

ONE SOURCE, no fallback to the old path. A second source is how this broke, and it
also defeated the new guard: the fallback mentioned `model.status` in a `== nil`
check, which satisfied the check while assigning from somewhere else.

Against a server older than 6.36.22 the field is absent and the toggle is left
alone rather than forced off.

**New guard: every panel toggle must be BOUND from status.** It took three
attempts to write one that could actually fail. Whole-line matching was satisfied
by that `== nil` guard; a four-line window was satisfied by the NEIGHBOURING
toggle's status read, because every seed in `onAppear` sits within four lines of
another. The check now requires the assigned value itself to come from status, and
lives in `Tests/panel-toggle-source.py` because inlining it in a heredoc mangled
its regexes into a syntax error that looked like a failing test.

## 0.5.63 (build 101)

**Every confirmation button in the panel was dead except Cancel.**

Inside `MenuBarExtra(.window)` a `.confirmationDialog`'s non-cancel button action
never runs. Clicking it dismisses the sheet and executes nothing. `role: .cancel`
DOES run, which is why this survived: the dialog appeared, Cancel closed it, and
the panel looked healthy from every angle including code review.

Nine dialogs were wired that way. Release fence, Reset live message count, Clear
stranded video uploads, Restart self-managed server, and Stop legacy and install
all did nothing when confirmed. Choose Again / View Examples / Recover all /
Save all / Install and reopen were on the same mechanism.

Proven on-device with `Tests/fence-canary`, which puts the presentations side by
side in a real menu-bar popover and logs a breadcrumb at every step:

    A  confirmationDialog + @State   Release NEVER fired; only Cancel dismissed
    B  confirmationDialog + model    Release NEVER fired; the setter ran TWICE
    C  inline overlay                fired, every time
    E  the shipped cosConfirm        fired, and the captured value came through

All ten confirmations now use `cosConfirm`, an inline overlay. The one surviving
`.alert` carries a lone cancel-role button, and a test now enforces that any
`.alert` may carry nothing else.

The fence release also captures its record while the confirmation is on screen.
`cosConfirm` dismisses before running the action and dismissal nils
`fencePendingRelease`, so an action that read the model would guard out and
release nothing. The previous code read the model inside the action while a
comment above it claimed the opposite.

Two test lessons are now enforced rather than written down. The 0.5.47 assertion
that guarded this exact button passed for months against a button that never
ran -- it checked that a capture preceded a `Task`, which was true and
irrelevant. It now asserts the invariant. And the new guards strip comments
before matching, because both files explain the rule in prose and a plain grep
would match the explanation.

`Tests/run.sh` is grep-over-source and cannot see whether a closure is entered,
which is how this shipped. The canary is committed alongside it and compiles the
shipped component rather than a copy, so a regression there fails here.

## 0.5.62 (build 100)

**RESET # no longer rotates the era when it cannot reach the server.** The disk
fallback ran whenever `request()` returned nil -- a timeout on a busy Mac was
enough -- and it writes `message-era.json` directly, bypassing the server's
confirm, in-flight and shutting-down refusals entirely. It also discarded the
result of its own `POST /api/archive/now`, so the snapshot silently failed for
exactly the reason the fallback triggered, and it still reported "Archived".
Transport failure now surfaces an error. The disk path is reserved for a genuine
404/405 -- a server too old to carry the route -- and fails closed if the
snapshot does not return 2xx.

**The confirmation dialog stopped describing behaviour that no longer exists.**
It said "Archives live messages" and "This does not delete anything." Against
server 6.36.20 nothing is archived, and against a phone older than 6.8.423 it
deletes the entire chat list, the prompt queue, the nav position and any
half-typed prompt. It now says what happens and names the version it needs.

## 0.5.61 (build 99)
- **RESET # stops claiming it archived anything.** Server 6.36.19 rotates the
  message era without ending live sessions, so `archived` is now always 0 and the
  old copy would have read "0 live sessions archived." The message now says what
  actually happens: next message is #1, older cards keep their numbers, history
  stays in ARCHIVE. The non-zero wording is kept for an older server.
- Requires server **6.36.19** and app **6.8.422** before resetting from any
  surface. On an older pair the reset still empties the chat.

## 0.5.60 (build 98)
- **Show Claude sessions is a switch again.** The helper has shipped
  `set-claude-sessions` for some time, writing both `COS_CLAUDE_SESSIONS_ENABLED`
  and `COS_CLAUDE_SESSIONS_SHOW_NAMES` through the manifest — but nothing in the
  app ever called it. The feature was reachable only by knowing an undocumented
  environment variable, so to a beta tester it looked broken. Advanced now has
  the toggle, and because it routes through the helper it survives Control
  rewriting the LaunchAgent, which a hand-set `launchctl setenv` does not.
- **A switched-off list says so.** Sessions are off by default — the endpoint
  projects another product's private 0700 state directory over a LAN-bound
  socket, so it is opt-in. When off, the pane showed the ordinary empty copy,
  which reads as "this is broken" rather than "this is turned off". It now names
  the setting and where to find it.
- Anyone who worked around this with a `launchctl setenv` login item can remove
  it; the toggle is the supported path and writes the same keys durably.

## 0.5.59 (build 97)
- **Meetings to review is a work queue.** Unnamed first, reviewed last. Hide
  reviewed keeps finished rows off the list. The review pane puts unnamed
  voices at the top, says how many still need names, and **Next to name**
  (⌘]) jumps to the next unfinished meeting. The Meetings library shows the
  same tags on G2 rows.

## 0.5.58 (build 96)
- **Speakers opens on Meetings to review.** Voices is the secondary tab.
- **New recordings, refresh needed, and review progress are visible on the list.**
  NEW tags meetings that arrived after the last baseline. Refresh turns amber
  with a count when a quiet poll finds sessionIds not on the current list —
  it does not shuffle the list while a meeting is open. Each row shows
  **N to name** or **REVIEWED** from server `voiceReview` (6.36.18+) and from
  the visit overlay after you leave a meeting.

## 0.5.57 (build 95)
- **Naming a new person in Speakers review now claims the voice profile it creates.**
  Server 6.36.17 enrols a wrong existing label → new name (Nick Gurney → Milo
  LeBaron). The confirm card says the name is not in profiles yet; after save the
  toast reports samples added, and the picker can use that name on the next
  cluster without retyping it as "new name." The this-meeting scope copy no longer
  pretends enrolment is unbuilt.

## 0.5.56 (build 94)
- **Activity cards are gotcos paper, not espresso with a corner smudge.** The public
  `.chapcard` treatment is a 9px gold stipple over the whole tile, faded 135° from
  the leading edge. Control had been drawing that screen onto a trailing glyph, so
  the gateway photographed as flat. The field is the card now; hover densifies it.
  Same Canvas layer as before — still not a `.drawingGroup()` mask.

## 0.5.55 (build 93)
- **The black lockup was in three places, and 0.5.54 fixed one.** The Activity header was
  corrected; the window toolbar and the menu-bar panel header still used `COSPalette.ink`, a
  fixed dark that renders black on espresso. All three are adaptive now, and the check sweeps
  every source file rather than the one instance that happened to be on screen.
- **The halftone is a field again, not a traced outline.** It was masking the dot screen to a
  glyph stroke, so ink only landed along a thin line and the plate read as a few specks. It is
  now an even field with the mark showing through as a density change, sized to bleed off the
  trailing corner instead of sitting in it, at .22 resting and .52 on hover.

## 0.5.54 (build 92)
- **The plate was invisible.** `.drawingGroup()` rasterises into an offscreen buffer, which
  does not survive being used as a mask, so the halftone composited to nothing. The stroke was
  also 1.6pt under a 5pt dot screen, which punches through nearly the whole line and leaves
  specks rather than an engraving. Stroke is 5pt now, and the resting opacity moved from .07
  to .16 — the .07 was tuned against a mock where the dots covered the whole card, not a
  single glyph.
- **The COS lockup rendered black on the dark panel.** It used `COSPalette.ink`, which is a
  fixed dark: correct on the brand tile it was written for, invisible on espresso. It takes an
  adaptive style now.
- **The counts were being scraped out of a sentence.** Leading digits became the number and
  the remainder became the label, so "50 of 5528" showed **50** over `OF 5528` — the smaller
  number promoted and the label left a fragment. Memories, Threads and Meetings now read
  `status.memoryCount`, `status.threadCount` and the library count directly.
- **Hover reads without depending on the plate.** A faint gold wash joins the border, lift and
  cascade, and the hover handler no longer clears state for a tile you have already left,
  which raced the enter event of the one you moved onto.

## 0.5.53 (build 91)
- **The Activity gateway is rebuilt, and the accent bar is gone.** That bar was a 3pt pill
  overlaid on a 16pt-radius card — a CSS `border-left` moved into SwiftUI without reconciling
  the geometry, so the card curved away and the bar stayed straight. Nothing sits on the edge
  now. Each tile carries its section's own mark as a ghosted, dot-screened plate, and the plate
  is a child clipped by the tile, so it follows the radius by construction rather than by care.
- **Six ad-hoc hues became one accent.** Gold marks hover and selection; nothing else on the
  gateway is colored. Semantic color inside the panes — provider, speaker, review state — is
  untouched, because there it carries information.
- **Marks paint themselves in, the way the gotcos lockup does.** Each glyph draws its outline
  on, each heading wipes in left to right, cascading 45ms per tile. Hover resolves a tile's
  layers in sequence rather than together, and the delay applies on the way in only, since a
  staggered exit reads as lag. Reduce Motion lands the finished frame rather than a half-drawn
  one — the pre-states here hide content, so leaving them stranded would blank the headings.
- **The tab indicator travels instead of blinking.** One gold underline slides between tabs
  rather than six colored ones toggling.
- **Three columns, two rows.** All six views sit above the fold in 266pt instead of 454pt.
- **Open panes match.** The tinted chip in pane headers and rows is now the same stroked mark
  as the gateway and the rail, at unchanged 32/42pt frames, so a pane no longer presents a
  second vocabulary for the same six things.

## 0.5.52 (build 90)
- **Activity is the first thing in the menu bar.** It sat below Restart / Stop /
  Update Server, so the main reason to open Control was the fourth block. It is
  now directly under the header. Each chip (Messages, Speakers, Meetings,
  Memories, Threads, Sessions) opens that tab. Open still restores the window
  without wiping a place you already had.

## 0.5.51 (build 89)
- **Install the update from the menu bar.** When gotcos.com advertises a newer
  Control build, the banner's Install button downloads the zip, checks the
  published SHA-256, verifies the signature and bundle identity, replaces this
  app, and reopens it. The glasses server is not drained, restarted, or
  rewritten. A meeting in progress refuses the install rather than interrupting
  it. This is the last unzip: later releases install in place from here.

## 0.5.50 (build 88)
- **`recent` stopped meaning Today.** That state is the server's "not running"
  bucket. Control printed it as a date word, so a session last touched 82 days ago
  sat in the list looking like it moved this morning. The chip is gone for that
  bucket. The row now always shows when it was actually updated — including
  same-day rows, which used to be suppressed unless the open→update span exceeded
  36 hours.
- **The list now says what the caps hid.** The server reports how many sessions
  the 7-day window, the 20-per-provider cap, and the Cursor 32 MB skip dropped.
  Control surfaces that as a sibling of the session array (the 12-key row
  projection is unchanged) and in the Sessions subtitle. Search still reaches
  past the 7-day window.

## 0.5.49 (build 87)
- **None of your pinned Claude sessions reached the Pinned view.** Two causes, both in
  Control. It compared pins against an 8-character session id when they are stored as full
  UUIDs, so the lookup was never true for Claude. And it built the list by walking
  `~/.claude/projects` only — six of seven pinned sessions have no file there, they live in
  the Claude Desktop store, and the desktop index was used to enrich a row's title but
  never to create one. Measured: 7 starred, 0 shown.
- **The Sessions list now comes from the server instead of a second local scanner.** The
  server already resolved both cases correctly and returned all 7 pins with the right
  titles; Control simply never asked it. Live status is still overlaid from the live-peers
  route, matched by prefix because those ids are the short form. If the server is
  unreachable the old local scan still runs, so the window is never empty — but it is the
  degraded path now, not the source of truth.

## 0.5.48 (build 86)
- **Session search stopped discarding the server's answer over 400ms.** The lookup used a
  2s client timeout on a route measured at 1.44-2.40s — the slowest of six consecutive
  calls already exceeded it, so whether you got the server's ranked, semantic answer or a
  local keyword scan came down to timing. Raised to 15s.
- **"This server is too old" was reported for four different failures.** A missing token,
  an unreachable server, a non-200 status and a genuinely absent route all emitted
  `server_too_old`, which sent you looking for an update that was never the problem. Each
  now reports what actually happened, and the hint under the search field says so.

## 0.5.47 (build 85)
- **The Release button on a fenced thread could silently do nothing.** Dismissing the
  confirmation dialog nils `fencePendingRelease`, and the button deferred its work into
  a `Task` that began `guard let record = fencePendingRelease else { return }`. If
  SwiftUI ran the dismissal setter first — an ordering this code must not depend on and
  cannot verify from source — the release returned with no request, no error and no
  note. That is the 0.5.17 dead-button shape, and no source grep can see it.
- The record is now a PARAMETER, captured synchronously in the button closure before the
  `Task`, which removes the dependency on the ordering rather than betting on it. Two
  mutations fail the suite: moving the capture back inside the `Task`, and re-reading the
  published property in the model.
- **Not verified on a real fence.** There has never been one on this machine
  (`GET /api/agent-sessions/fences` returns empty), so this path has still never been
  exercised end to end. The fix is correct under either ordering; that is the claim, not
  that it was observed working.

## 0.5.46 (build 84)
- **Forks were never missing — they were indistinguishable.** Miles: "I forked that COS
  glass server work, and now I can't see any of the forks. I do see the original running,
  though." Both forks were in the list the whole time. A Claude fork is
  `--resume <id> --fork-session`, which inherits the parent's history, so the derived title
  is IDENTICAL. Measured 2026-08-18: two live sessions both named "COS-glasses Server work
  (meetings)" with distinct ids (31732572… / a4b2b4dd…), same workspace, same state — the
  rows were pixel-identical, and 8 duplicate-title groups existed across 69 rows.
- When a title appears more than once on screen, the row now shows when that session was
  opened — the one field that actually differs and that a person can act on. Applies to the
  list and to search, because both share `sessionRow`.
- The duplicate detection is a pure static helper (`ClaudeSession.ambiguousTitles`) so it is
  covered by execution rather than by reading the view; four wiring assertions pin that the
  row actually consults and renders it. Four mutations, four caught.
- Note: two untitled sessions in the same workspace legitimately share a title (`title`
  falls back name → workspace → id) and ARE flagged. A test asserting otherwise was wrong
  and the suite caught it.

## 0.5.45 (build 83)
- **The durable-fence flag now survives an update.** `COS_THREAD_FENCE_DURABLE` was
  not in `providerEnvironmentKeys`, and Control FILTERS the LaunchAgent environment
  to that set on every plist rewrite — so setting it by hand would have been dropped
  by the next Update Server, silently reopening every fenced thread. Same seam that
  stopped `COS_PROFILE_PATH` from surviving updates. A test now fails if the key
  leaves the allowlist.

## 0.5.44 (build 82)
- **Fenced threads are visible and releasable from Control.** A fence shuts a native
  thread that may already hold an undelivered COS turn, so a prompt cannot be
  double-delivered into a real conversation. Until glasses-server 6.36.10 it was
  in-memory only, wrote no log line, and the only thing that cleared it was
  restarting the server. A new card lists fenced threads with when each was fenced,
  and a Release action reopens one after a confirmation.
- **The card is conditional, like Doctor.** Normally there are no fences and the card
  is absent; a permanently empty card teaches you to skim past the one time it
  matters. It loads when the panel opens, because a card gated on a non-empty list
  cannot appear if nothing looks.
- **Releasing is two deliberate actions.** The server fails closed and answers 400
  with a preview of what it would reopen; only the confirmed call carries `confirm`.
  Control shows a confirmation dialog first, the same pattern as the legacy-restart
  and managed-install actions. A fence is addressed by digest, never by the raw
  target key, which embeds the private native thread id.
- **A release that could not be durably recorded is not reported as success.** The
  server answers 500 and keeps the fence; Control says so rather than claiming the
  thread is open. If the server's own fence writes are failing, the card says these
  will not survive a restart — a memory-only fence behaves identically until then.
- **Requires glasses-server 6.36.10** for the `/api/agent-sessions/fences` routes.
- Seven assertions pin the chain: helper commands exist, the release is confirm-gated,
  the helper does not throw on the server's 400 gate, the card is mounted, its rows
  call the opener, the dialog is bound to what the opener writes, and the panel loads
  fences on appear. Each was mutation-tested. Three of them initially passed against a
  broken tree because a bare grep matched an identical line in another function, so
  those are now scoped to the block they are about.

## 0.5.43 (build 81)

- **Continue an agent thread survives Update Server.** Glasses server 6.29.0 gates
  the Continue write path behind `COS_THREAD_ATTACH_ENABLED`, which it reads
  straight off `process.env` and never parses out of a `.env` file. The
  LaunchAgent plist is therefore the only channel that reaches it, and Control
  rebuilds that plist from its own allowlist on every Install, Repair, and Update
  Server. The key was not on that allowlist, so a hand-set flag was silently
  dropped by the next update and Continue vanished from the session menu with no
  message and nothing to point at. Same failure that lost `COS_PROFILE_PATH`. The
  key is now allowlisted, and a self-test executes the real capture path to prove
  it carries through.
- **A toggle for it, in Tools.** "Continue agent threads" appears only when the
  running server says it supports the feature, which that server now publishes
  itself rather than having it inferred from a version number. Off by default.
- **Off REMOVES the setting rather than writing a zero.** Continue defaults off,
  so an absent key already means disabled, and the server states that contract
  directly: absent means disabled, never enabled. Removing the key returns the
  LaunchAgent to its untouched default instead of leaving a value behind to be
  maintained forever, and it makes the off state provable by absence. This is
  deliberately the opposite of Meeting Turbo preview, which defaults ON and must
  write an explicit zero, because for that flag an absent key means enabled and a
  delete would quietly disarm its rollback.
- Applying the change is verified two independent ways before it reports success:
  what launchd actually handed the service, and what the running build says it did
  with it. Either one alone can be wrong.
- Both new guards are mutation-verified against a green baseline. Dropping the key
  from the allowlist, and changing Off to write a zero, each fail the suite while
  still compiling.

## 0.5.42 (build 80)

- **COS Data never switches your tier on its own.** Choosing a folder used to
  re-derive which store you get from what that folder contains, preferring the
  Python bridge whenever a workspace held both. So a user on plain markdown notes
  who re-picked their own folder — after moving it, or because an error told them
  to choose it again — was silently moved onto the pipeline. The two tiers serve
  DIFFERENT data and never merge: a working bridge means the server stops reading
  `memory/` and `threads/` entirely. Measured on a real install, that swap traded
  11 memories and 6 threads for 21 and 5 sharing no content.
- Resolution now happens WITHIN the tier you are already on. Nothing new is
  stored: the preference was always durable as which env key is set, and the bug
  was that resolution ignored it. Existing installs keep their tier by
  construction. A brand-new install gets plain notes — no venv, no Python — and
  the bridge is an explicit choice rather than something that happens to you.
- Asking for the bridge in a folder that has none now says so, instead of quietly
  handing back the other tier. A silent downgrade is the same surprise as the
  silent upgrade.
- **"This COS workspace uses an older Memory and Threads bridge" is gone.** It was
  thrown for ANY non-zero exit from the bridge, and the common cause by far is
  Qdrant being unreachable after Docker fails to restart. That wording sent three
  separate sessions chasing a version problem, and it told the user to re-pick
  their folder — which, before the fix above, is what swapped their tier. It now
  reports the actual exit code and output and names Docker as the usual cause.
- **A symlinked `memory/` or `threads/` is recognised again.** The check rejected
  symlinks while the server follows them, so Control reported "no root" for a
  store it was simultaneously reading 11 memories and 6 threads out of — then
  offered "Create Folders" over folders that already existed.
- Three execution self-tests cover these, alongside the ones added for the
  2026-08-08 meetings-library case. Both guards are mutation-verified: restoring
  bridge-first preference and re-rejecting symlinks each fail the suite while
  still compiling.

## 0.5.41 (build 79)

- **Lookup Recency next to Domain.** Meetings, Sessions, Memories, and Threads
  search can sort Newest (default), Oldest, or Best match. Newest uses last
  made/edited time so this morning's call beats an older higher-score hit.
  Changing Recency re-sorts the hits already on screen.

## 0.5.40 (build 78)

- **Sessions lookup reads recent transcript bodies.** Keyword search still
  matches titles first. It then peeks the newest 80 Claude, Codex, and Cursor
  transcripts from the last 7 days (96 KB each), so a term like EWIC in the
  first user turn hits even when the sidebar title does not. Full-history
  body scan is what hung before; this does not do that.

## 0.5.39 (build 77)

- **Sessions lookup no longer hangs.** Titles already in the open list match as
  you type. The helper scores sidebar names instead of re-reading every
  transcript, and lookup cannot spin forever.
- **Claude Code sidebar titles on live rows.** Activity uses the Desktop
  `title` (the name in the Claude Code sidebar), so chats like "POS complexity
  and competitive challenges" show as that instead of the first prompt.

## 0.5.38 (build 76)

- **Sessions lookup.** Search titles, sidebar names, first prompts, and
  transcript text — including chats older than the 7-day list. Keyword plus
  meaning, same pattern as Meetings. Keyword works on this Mac even before
  the server ships the lookup route; meaning needs that update and an
  OpenAI key.

## 0.5.37 (build 75)

- **GOT COS lockup in the open panels.** The menu bar still uses eyeglasses
  for a quick running/offline glance. Once Control or Activity is open, the
  official COS lockup is the brand, at a quieter size. Headings use Fraunces,
  UI copy uses DM Sans, and chrome numbers use JetBrains Mono — the same
  trio as gotcos.com.

## 0.5.36 (build 74)

- **Pinned now includes Claude Desktop stars and Cursor sidebar pins.** Claude
  `starred-local-code-sessions` and Cursor `pinnedComposers` use the same rule
  as ChatGPT `pinned-thread-ids`: they show on Pinned at any age. Desktop-only
  Claude chats (no `~/.claude` jsonl) still list by their Desktop title.

## 0.5.35 (build 73)

- **Pinned is its own Sessions clock.** Updated / Opened / Pinned. Codex/ChatGPT
  `pinned-thread-ids` (Markt POS, Jewelry, G2, …) show there at any age. Cursor
  and Claude pins were added in 0.5.36.
- **Keep-warm `ready` rows stay out.** Claude CLI pre-warm (`ready`) and Control
  provider-proof prompts are not real sessions; they no longer eat the list.

## 0.5.34 (build 72)

- **Cursor sidebar titles, not last user_query.** Sessions uses
  `composerHeaders.name` so "V2 verification and performance" shows as that,
  not the summarizer prompt. The `empty-window` copy of the same chat is
  dropped.
- **Pinned Codex threads stay visible.** ChatGPT `pinned-thread-ids` (Jewelry,
  G2, ThriftCart, …) list even when the jsonl is weeks old. Updated vs Opened
  picker is unchanged.

## 0.5.33 (build 71)

- **Sessions clocks: Updated vs Opened.** Default is last write in 7 days, so
  pinned Codex/ChatGPT threads (Markt POS 2.0 build still lives in the May 8
  rollout) show up when they get a new turn. Opened keeps the same window on
  session start. Codex titles come from `session_index.jsonl`. Files over 32 MB
  list; opening the full transcript is still capped.

## 0.5.32 (build 70)

- **Sessions look back 7 days.** Same Claude / Codex / Cursor mix. Codex day
  folders now cover a week, not three calendar days. Empty copy says last 7
  days.

## 0.5.31 (build 69)

- **Sessions lists Claude, Codex, and Cursor.** Same 48-hour window. Each row
  is badged. Click and Copy session still work per provider. Codex subagents
  and Cursor `subagents/` folders stay out. Files over 32 MB are skipped.
  Cursor titles use the latest user query, not system-prompt wrappers.

## 0.5.30 (build 68)

- **Session history on click.** Activity → Sessions opens the local Claude Code
  jsonl as a read-only You / Assistant transcript. Tool calls, tool output,
  thinking, and subagent sidechains stay out.
- **Copy session.** Same pane. Puts a kickstart brief on the clipboard for
  another agent (Cursor, Codex, a new Claude chat). That is a paste, not a
  Claude Code resume. Secrets matching known token shapes are redacted.
  Huge sessions keep the original request and the newest turns.

## 0.5.29 (build 67)

- **Save still-live captures from Control.** Stranded G2 sessions (phone never
  saved) now have Save / Save all. That is POST `/api/meeting/save`, not Recover
  all — Recover all only works after the 4-hour quarantine cutoff. Session files
  become meetings; they are not deleted.
- **Sessions tab shows /rename titles and today’s conversations.** Live presence
  used the workspace folder name, so "Fireflies meeting sync" rendered as
  "MU-Chief-Staff" or as empty if Claude Desktop had just launched. The helper
  now reads `custom-title` from the project jsonl and lists conversations from
  the last 48 hours.

## 0.5.28 (build 66)

- **Unsaved captures row hides when nothing is recoverable.** Recovered
  quarantine leftovers no longer show an amber "None" with no Recover button.
  Stranded live sessions still surface.

## 0.5.27 (build 65)

- **One-click orphan recovery.** Status card Recover / Recover all turns
  unsaved captures into meetings, one at a time. Session files are not
  deleted. Curl copy is gone.
- **Sessions in Activity.** Sixth read-only view: Claude Code workspace
  basename plus waiting / running / stale. Off until
  `COS_CLAUDE_SESSIONS_ENABLED=1` on the server.
- **Run sync now.** Button next to Meeting sync runs
  `cos_python sync_meetings.py` from `COS_SCRIPTS_DIR`. Disabled while HQ
  polish is active. Does not pass `--force`.
- **Memories and Threads lookup.** Same keyword + meaning pattern as Meetings.
  Memories meaning uses the existing `cos_memory` index; threads are keyword
  only. Needs the 6.27.6 `/api/memory/search` and `/api/threads/search`
  hotfix.

## 0.5.26 (build 64)

- **Meetings on the home Activity card.** The panel still listed four chips after
  Meetings shipped as a fifth Activity view. Chips now come from the same
  section list as the Activity window, so Meetings is visible without opening.

## 0.5.25 (build 63)

- **Meeting lookup.** Search field on Meetings: keyword over title/summary plus
  meaning search against the existing COS meeting index (one query embedding, no
  LLM). Results span every stored month, not just the open calendar day. Badge
  shows Keyword / Meaning / both. Needs the 6.27.6 `/api/meetings/search`
  hotfix; without it the field still runs, but the helper will error.

## 0.5.24 (build 62)

- **Meetings in Activity.** Fifth peer view next to Speakers. Month pager and
  day calendar over the saved-call library, with domain, duration, full
  transcript, summary, and copy (summary / transcript / as context). Speakers
  still owns identity correction — "Meetings to review" is unchanged. Needs the
  6.27.6 meeting-list `month`/`day` hotfix; older servers still list the latest
  50 rows.

## 0.5.23 (build 61)

- **Reset live message count.** Toolbar archive-box next to Refresh. Confirms,
  then archives live glasses messages and starts numbering at #1. History stays
  in ARCHIVE / Message History. Talks to `POST /api/message-era/reset` on a
  hotfixed 6.27.6; if that route is missing it snapshots via `/api/archive/now`
  and writes `message-era.json` itself. Reopen the phone companion if Control
  did the reset while the app was already open.

## 0.5.22 (build 60)

- **Clear stranded video uploads.** Sideload or a killed composer can leave a
  `receiving` draft for 4 hours. That draft is what Control shows as
  "Video uploads · N active", and it holds `blocksRestart` so Repair and Update
  stall on it. Repair does not cancel these. Clear stranded does: receiving
  drafts with no bytes for 60 seconds. In-progress uploads and compressing
  videos are left alone. Talks to server 6.27.7 when present; on 6.27.6 it
  DELETEs the same drafts from disk.

## 0.5.21 (build 59)

- **A blocked update now tells you what is blocking it.** The drain only ever
  read `lifecycle.activeByKind`, and when that was empty it printed the literal
  string "restart proof" — naming nothing. It now names the actual cause: a
  video upload holding the restart (with its receiving/finalizing counts), the
  server shutting down, a blocked gate, which specific proof field mismatched,
  or a changed server identity. Stale sessions are shown as context and marked
  as not blocking.
- This cost over an hour across two sessions on 2026-08-12. One abandoned video
  upload, stuck in `receiving` for three hours after a client-side bug, held
  `blocksRestart` — and the server reported it in the very same payload the
  drain was already reading. Three wrong root causes were proposed before
  anyone looked at the right field.

## 0.5.20 (build 58)

Reliable video uploads is a private, machine-wide canary for server 6.27.3 and
companion 6.8.343. When enabled, every MP4/MOV uses the restart-safe resumable
transport rather than relying on a single long request. Control reports active
drafts, finalization, and unacknowledged receipts; disabling the canary restores
the prior transport without hiding already accepted uploads.

Server updates and ordinary restarts remain allowed after publication, but Control
refuses a binary downgrade below 6.27.3 while any V2 draft or unacknowledged receipt
still exists. The transaction verifies the loaded LaunchAgent environment and the
authenticated health/maintenance contract before committing. Phone frame extraction
is deliberately not enabled: the original MP4/MOV and proven Mac validation/extraction
pipeline remain canonical until a physical iPhone benchmark proves a material gain.

## 0.5.19 (build 57)

COS Activity moves Messages, Speakers, Memories, and Threads out of the narrow
menu-bar popover and into one durable, resizable window. Peer tabs, Home, Back,
and a scoped breadcrumb make it clear where you are without throwing away the
place you came from. Closing the window now cancels detail work and stops voice
playback; late server responses cannot overwrite a newer selection.

Speakers is now a Voice Directory instead of a list of meeting titles. Enrolled
people show training-sample provenance, attributed and review segments, meeting
count, last seen, and a segment-weighted **observed match** with its evidence
basis. A voice detail opens its recent meeting appearances, while Meetings to
review remains a peer view for corrections. Unidentified meeting-local voices
stay separate and are never presented as one global person. Requires the new
voice-directory route for history; older servers still show honest profile-only
coverage and an update explanation.

Server updates resolve correctly when COS Control is launched from Finder or at
login. Control previously found Homebrew's `npm` executable, then launched it
with macOS's minimal GUI `PATH`; npm's `#!/usr/bin/env node` launcher could not
find Node and the UI collapsed that failure into “Could not resolve the latest
npm server release.” The resolver now supplies the discovered Node directory,
suppresses non-JSON npm update notices, and keeps the existing transactional
update and rollback path unchanged.

Repair also restores a previously committed, integrity-verified generation
without re-running that older server's provider verifier. Ownership, package
integrity, health, local Whisper, and the credentialed maintenance handoff remain
mandatory; every new candidate still runs the full real-query proof before commit.

## 0.5.18 (build 56)

Review Memories and Review Threads actually work. In 0.5.17 they did nothing.

- **The click was dead.** The buttons set `contextBrowseKind`, but the pane was
  mounted inside `if model.reviewRouteActive` — a flag only the speaker-review flow
  ever sets — so state changed and no view was watching. It compiled, the helper
  worked, and 110 self-test assertions passed, because nothing connected the opener
  to the render condition.
- **Rebuilt in the shape it should have had:** a titled list card in the main panel
  with its own Refresh and chevron rows, and a click that routes the whole panel to
  a detail view. The same pattern as Review speakers, which is what was asked for.
- **The buttons are gone from the controls row.** Five buttons plus a path did not
  fit 390pt and truncated to "CO…", "Revi…", "Revi…", "Cre…". Lists belong in cards.
- Detail shows the full body selectable, the record id, Copy as Context, and Reveal
  in Finder for file-tier records. A detail-fetch failure annotates the record
  rather than clearing it, so a click always leaves something on screen.
- **A dead click is now a test failure.** Four assertions tie every `*RouteActive`
  flag to a view that reads it, require the context pane to be gated on its own flag
  ALONE, and require the route flag to read the exact variable the opener writes.
  Re-creating the original bug fails the suite.

## 0.5.17 (build 55)

Review Memories and Review Threads, on the desktop.

- Two new buttons open the SAME read-only records the glasses browse, using the
  authenticated routes that already existed. No new server surface, no mutation.
- **Copy as Context** puts the record on the clipboard quoted and labelled with its
  id — the same data-not-instructions contract the glasses use when attaching a
  reference — ready to paste into whatever you are already typing.
- **Reveal in Finder** appears for file-tier records, where a memory IS a file. That
  is something the glasses cannot do, and the reason a desktop view earns its place
  rather than just mirroring the lens.
- No send path was added. Control has never had one, and arming a reference for the
  next prompt needs a write route the amendment design does not have yet. Copying
  grounded context does the same job today without inventing a mutation surface.
- The headline separates the page from the store: a live probe returned "4 threads"
  beside "11 active", because the server sends a limited page with full-store counts.
  It now reads "Showing 4 · 11 active".
- `/api/memory` returns a TOP-LEVEL ARRAY for released-companion compatibility, which
  a dictionary-only reader sees as empty. Queen's own probe hit that and read working
  data as a failure, so the response reader handles both shapes and a test pins it.

## 0.5.16 (build 54)

Queen installed server 6.22.0 and hit "Memory & Threads: Setup needed" with a hint
that sent her to the COS Data picker. The picker was the wrong control: her
`COS_OPERATIONS_DIR` was already correct and would have resolved immediately. The
only problem was that `memory/` and `threads/` did not exist, and nothing created
them or said what they were. Her words: "choosing COS Data is not what fixes it.
What fixes it is creating two directories."

- **Create Folders.** One button makes `memory/` and `threads/` in the folder COS
  would already look in, each with a README explaining that any markdown file
  dropped in becomes browsable. Idempotent. A created-and-empty store reports
  READY, not setup-needed — collapsing empty with missing is what caused the
  wrong turn.
- **The panel says where it looked.** It now shows the resolved root path, or the
  candidate roots it tried when nothing resolved. That entire diagnosis previously
  required reading the server source.
- **A dormant Python bridge is called out.** `COS_SCRIPTS_DIR` is written in exactly
  one place, the COS Data picker, so anyone who set up through the meetings picker
  has a complete venv and `cos_api_bridge.py` sitting unused with no indication.
  Control now detects that and says so.
- **It is NOT applied automatically, deliberately.** Setting `COS_SCRIPTS_DIR` flips
  an install from the file tier to the bridge tier, and the server stops consulting
  the file tier entirely once a bridge resolves, so notes being browsed today would
  silently stop appearing. Queen flagged this herself. It stays a visible choice.
- The hint text now names the button instead of pointing at a picker that cannot
  help.

Resolution order is mirrored from the server's `resolveContextFilesRoot()` so the
path can be shown without putting filesystem paths on the API. The order and the
accepted folder spellings are asserted in the self-test so the two implementations
cannot drift quietly.

## 0.5.15 (build 53)

- COS Data accepts a folder of markdown notes, not only a Python bridge. A folder
  holding `memory/`, `memories/`, `threads/` or `thread/` — at the folder chosen or
  one level down in `operations/` — applies `COS_CONTEXT_DIR` and requires server
  6.22.0. A workspace with a working bridge still resolves to the bridge and still
  requires 6.21.35, so an existing install is not downgraded to browse-only.
- Switching tiers removes the other tier's environment key. The server prefers the
  bridge whenever `COS_SCRIPTS_DIR` resolves, so leaving it behind would make
  choosing a notes folder appear to do nothing.
- The panel names the tier — "Bridge:" or "Notes:" — instead of a bare path, so a
  file-backed install cannot be mistaken for a vector pipeline. Copy Report carries
  both, redacted.
- The Memory and Threads hint says what to do next and branches on why it is
  unavailable. It read "Choose COS Data below. Empty stores are healthy", which is
  true and useless to someone who has no COS workspace.
- The refusal message offers the notes path first instead of demanding
  `cos_api_bridge.py` and `venv/bin/python3`.

## 0.5.14 (build 52)

- Adds a separate COS Data picker for Memory and Threads. It accepts a COS
  workspace or `operations/scripts`, validates bridge protocol 1, then applies
  `COS_SCRIPTS_DIR` with the same reversible restart transaction as other settings.
- Reports authenticated Memory and Threads readiness and counts without exposing
  paths or store metadata on public health.
- Redacts Work, Meetings, and COS Data directory paths from copied support
  reports while retaining useful configured/not-configured diagnostics.
- Doctor distinguishes healthy empty stores from setup needed, a degraded
  dependency, or an outdated workspace bridge.
- Keeps Work Folder, Meetings Library, and COS Data as three independent paths.

Requires glasses-server 6.21.35. This binary is build 52.

## 0.5.13 (build 51)

- Makes an existing month-based meeting folder the recommended setup path:
  choose the folder that directly contains `YYYY-MM/*.md` and COS uses it
  without moving or renaming anything.
- Keeps multi-folder organization optional and fully customizable. Any safe
  folder names work when each contains `meetings/YYYY-MM/*.md`; COS roles never
  dictate filesystem names.
- Replaces internal "multi-domain" terminology and role-specific examples with
  plain guidance for one folder or multiple custom-named folders.
- Improves invalid-folder recovery messages so users can correct the selected
  level without rebuilding an existing library.
- Requires glasses-server 6.21.33. This binary is build 51.

## 0.5.12 (build 50)

- **Existing meeting folders now work directly.** Choose a folder that contains
  `YYYY-MM/*.md`, or choose a multi-domain operations folder containing
  `<domain>/meetings/YYYY-MM/*.md`.
- **The picker explains both supported layouts.** Invalid selections show
  actionable examples, let the user choose again, or allow setup to continue
  without a meeting library.
- **Browse and write responsibilities stay separate.** Direct libraries are
  read-only. Existing operations roots keep enrichment, new G2 output, and
  speaker edits. Mixed results prefer the canonical enriched copy.
- **Activation is transactional.** Control removes stale conflicting keys,
  restarts through launchd, verifies the authenticated effective root and
  layout, and restores the exact prior environment on failure.

  Requires glasses-server 6.21.33. This binary is build 50.

## 0.5.11 (build 49)

- **Adaptive audio cleanup is visible and reversible.** Server 6.21.32 adds a
  default-off, retained-playback-only canary. Control exposes one plain toggle,
  reports `Adaptive replay` versus `Raw replay`, and transactionally restarts
  the managed or adopted LaunchAgent with an explicit `1` or `0`.
- **Activation proves the real server contract.** Apply succeeds only when
  health reports the selected value, `retained_replay_only` scope, and raw WAV
  preservation. A failed activation restores and verifies the prior server.
- **Stop and rollback win timing races.** Closing review or pressing Stop now
  cancels a pending first-play fetch, and adopted-server verification retains
  its rollback transaction until the health proof passes. The server's raw
  fallback deadline is shorter than Control's bounded media request.
- **The label states the boundary.** Cleanup runs only after a reviewer presses
  Play. It does not enter live preview, canonical transcription, speaker
  attribution, save, HQ polish, or meeting sync. Off immediately restores raw
  replay after the normal safe restart.

  Requires glasses-server 6.21.32. The previously shipped 0.5.10 binary remains
  build 48; this different binary is build 49 so the updater never confuses the
  two artifacts.

## 0.5.10 (build 48)

- **The Meetings Library picker no longer requires you to be Miles.** The
  validator hardcoded `["quilt","sprocket_rocket","hermit_crabs","personal"]` —
  one user's business domains — directly beneath a comment reading "Each COS
  layout can differ". Queen set up her own COS and every folder she chose was
  rejected with a message telling her to supply a `quilt/meetings` tree she has no
  reason to own. Domains are now discovered: any subfolder holding a `meetings/`
  folder counts, whatever it is named, spaces included.

- **The rejection message says what is actually wrong.** It was a dead end. Now it
  distinguishes the three real cases: you picked a `meetings/` folder itself, so
  choose its parent; the folder has no subfolders; or none of the subfolders hold a
  `meetings/` folder, and here are the ones it found. The picker's own instructions
  stopped naming someone else's domains too.

  Requires glasses-server 6.21.31, which discovers domains the same way. The picker
  and the server had to move together, or the picker would validate a shape the
  server then refuses to list.


## 0.5.9 (build 47)

- **A name you removed is called out above the write-up.** De-attribution rewrites
  the sidecar, the attendee list and the transcript labels, but deliberately leaves
  narrative prose alone, so a person you removed can still be named in the LLM
  summary shown right below the voice rows.

  2026-08-07: "Clem Ukaoma" was removed from a personal call that was only Miles
  and Queen — his father's voice had matched a similar profile. All 8 label sites
  were rewritten correctly and the panel still read "Miles, Queen, and Clem talk
  through the fallout", with nothing to indicate the removal had taken. The panel
  now shows, in orange above the write-up: *"You removed "Clem Ukaoma" from this
  meeting. The write-up below was written before that and still uses the name."*

  Needs glasses-server 6.21.30, which publishes `removedNames`. Older servers omit
  the field and the panel simply shows no warning.


## 0.5.8 (build 46)

Second adversarial-review pass before this ever shipped. gotcos.com still
advertises 0.5.6, so neither 0.5.7 nor 0.5.8 has reached anyone; build 45 exists
only as a local install here, which is why this is build 46 rather than a second
binary wearing the same number.

- **The panel drew per-voice shares with no coverage gate at all.** The clipboard
  has always suppressed shares below 60% coverage, and this file's own comment
  claimed the panel did too — "Say the coverage instead of drawing shares", above
  code that drew them unconditionally. The only `0.6` comparison in the app
  changed a caption's colour. Measured across 355 real reviews, the panel showed a
  share the clipboard refused on **170** of them. The floor now lives inside
  `shareOfIdentified`, so a future row cannot forget it, and it fails CLOSED on
  unknown coverage exactly as the server does — an `if let` would have shown a
  share on the one path where we know least.

- **"Full (1 KB)" on a 54 KB clipboard.** `fullChars ?? 0` labelled every button
  1 KB against published server 6.21.28, which serves `/content` without the size
  fields; real payloads measured 54,451 / 43,815 / 39,334 characters, and the
  confirmation then read "Copied full meeting (1 KB)". Both counts now fall back
  to the length of the string actually received.

- **The inline write-up is bounded.** It renders inside the sheet's own
  ScrollView, so it cannot have a bounded scroll view of its own without the two
  fighting for one gesture — the text is capped instead, at a word boundary, with
  the remainder stated rather than hidden. A 5,000-character write-up measured
  ~1,448pt and the worst real one ~2,700pt inside a 640pt pane.

- Panel seconds are rounded, matching the server, so the two no longer differ by
  a second on 456 voice rows; `2**3` and `**/blog` survive the markdown softener
  (18 real occurrences); and the sections list is keyed by position, because one
  real scribe repeats three of its own headings and recovered extras made that
  reachable.

- The pass-through of the clipboard strings is now asserted by EXECUTION rather
  than by grepping for an assignment's exact spelling. That grep broke on a
  refactor that changed nothing about the behaviour, which is how a shape test
  teaches you to edit the test instead of the code.

### Originally in build 45

- **The write-up now sits BELOW the voice rows.** Measured with AppKit at the
  real 358pt content width, placing it above pushed the rows this sheet exists
  for one to two full screens down on 7 of 8 of one day's meetings, worst case
  5.3 screens.
- **An older server is told so instead of hiding the feature.** A 404 from
  `/content` is classified as "server too old" and names the version needed; any
  other failure says it could not load. Previously both rendered as silence.
- Markdown markers are softened for the popover, since `Text(_: String)` does not
  parse markdown and rendered `###`, `- [ ]` and `**` literally.
- Both copy labels are sized from the SAME string the server measured. The button
  and the confirmation previously quoted different numbers on 81% of meetings.
- Unrecognised scribe sections appear in the panel rather than being dropped.
- The copy confirmation clears when the review reloads, so it can no longer
  assert a clipboard that a relabel has invalidated.
- Guards: the previous four pinned that code existed, and /qa proved two
  feature-killing mutations kept the suite green. The message decision is now a
  pure function covered by execution in ModelsContract, and the wiring greps are
  anchored to line start so a commented-out call cannot satisfy them.
- Requires glasses-server 6.21.28+.

## 0.5.7 (build 44)

- **Review the whole meeting, not just its voices.** The speaker sheet now shows
  the write-up — summary, topics, decisions, action items — above the speaker
  rows. Empty sections are omitted rather than rendered as bare headings, and a
  meeting with no write-up on disk says so instead of leaving blank panel.
- **Two copy buttons.** Summary for pasting into Slack or email; Full for pasting
  the whole meeting including the transcript into a model. The button shows the
  full size (measured 28 KB on a 26-minute meeting) so you know what you are
  putting on the clipboard.
- Both strings come from the server with the display floor already applied to
  the attendee list. The scribe's own `## Attendees` applies none — one real
  26-minute meeting lists 15 people, including a name already confirmed absent —
  so copying it verbatim would carry a guess into whatever you paste it into.
  Only named voices appear; the rest collapse into one honest line.
- Requires glasses-server 6.21.28+. Older servers omit the write-up and the copy
  buttons; the speaker rows are unaffected.

## 0.5.6 (build 43)

- **Talk time per voice in the speaker sheet.** Minutes and share of voice
  beside each row, shown ONLY for a voice the panel actually names — minutes
  next to an unnamed row would assert an identity by the back door, which is
  exactly what the display floor exists to prevent.
- Shares are a share of NAMED speech and total 100%. The denominator is the sum
  of named voices, not the server's `attributedSpeakingMs`: that field is a
  union with crosstalk counted once, and dividing by it rendered "MU 66% ·
  Edward Addo 39%" on a real meeting.
- Below 60% identified, the header says so instead of drawing shares.
  Corpus-wide 44.8% of speaking time is unattributed and 17% of meetings name
  nobody; a percentage there invites reading the missing majority as a person.
- Requires glasses-server 6.21.27+. Older servers omit the numbers rather than
  showing zeros.

## 0.5.5 (build 42)

- **The speaker sheet now says how much of the meeting carries a name.** The
  header showed only "N segments · M voices", and the server's only coverage
  signal was a boolean that goes false at 100% unidentified — so a meeting where
  295 of 299 chunks matched nobody rendered as though it were normally
  attributed. Measured across 14 retained sessions, unidentified share ran from
  24% to 100%, all of it collapsing onto that one boolean.
- The number counts segments whose voice row is actually shown with a name, not
  chunks carrying a person-shaped label. Those diverge: on one real session the
  label count is 287 of 379 while only 177 are displayed as names, so a header
  built on labels would claim high coverage above rows reading "Unidentified
  voice".
- Requires glasses-server 6.21.26+. Against an older server the line is omitted
  rather than shown as zero.

## 0.5.4 (build 41)

- **You can now finish naming a voice.** Typing a name and picking a scope had
  no Save — the commit action was clicking a suggested profile, and in the most
  common case no suggestion could ever appear. Two dead ends are closed:
  - **"Yes, this is <name>"** on a row the system demoted. When the identifier
    proposes a name it is not confident enough to show, that name IS the row's
    label, so renaming it to itself is impossible. This vouches for it instead
    and rewrites nothing.
  - **"Use '<name>'"** when what you typed is not an enrolled profile. Before,
    a voice could only be named after someone already enrolled, so a new person
    could not be named at all.
- A confirmed voice keeps its caveats. If it swaps with another speaker, the
  panel still says so — the name is asserted, the evidence is not hidden.

Requires server 6.21.25 for the confirm action. Older servers keep working and
simply never show it.

## 0.5.3 (build 40)

- **The meeting list shows 15 and scrolls.** It showed 12 before — and asking
  the server for 15 would have returned 10 to 12, varying by day, because rows
  without a G2 session are filtered out after the limit is applied. The helper
  now over-requests so 15 actually render, and the header states the count so
  hidden rows are stated rather than implied.
- **Each row shows what is in the meeting**: topics, decisions, actions and
  attendees, on their own line. The server was already sending these counts and
  the helper was discarding them, so this costs no extra request. Zero counts
  are omitted, and a meeting with none falls back to how it was captured.
- The list only scrolls once it is long enough to need to. Height follows
  content up to a cap, so a light day reserves no empty space.

## 0.5.2 (build 39)

- **You can now name an unidentified voice.** The row said "This voice was
  never named. Give it one from the list above" and then offered no control to
  do it — the panel instructed an action it refused to perform. The server
  always supported this; `canRename` simply excluded unattributed rows. Naming
  one now opens the same scope picker and confirm preview as every other
  correction.
- The confirm card says what a name assignment actually does. An unattributed
  row is a cluster the identifier could NOT match, so nothing established it is
  one person, and a large cluster on a G2 microphone is frequently several.
  Saving labels every one of its segments, and the card now states the count
  and that caveat before the click rather than after.
- The wearer still cannot be renamed. That guard is the reason the check
  existed; only the unattributed half was wrong.

## 0.5.1 (build 38)

- Add an **Idle Metal HQ** control for powerful Macs running glasses-server
  6.21.20 or newer. It only enables Metal for sealed post-meeting HQ work when
  the server is idle; live and progressive transcription keep their existing
  protected paths.
- Turning the setting off writes both `COS_BATCH_HQ_METAL=0` and the explicit
  `COS_BATCH_HQ_FORCE_CPU=1` rollback. Turning it on clears that override. Both
  values are applied through Control's safe drain, restart, verification, and
  rollback transaction instead of by editing a LaunchAgent by hand.
- Show the active policy in the status card as `On · preemptible`, `Force CPU`,
  or `Off · CPU`. Public installs remain CPU-first unless the user opts in.

## 0.5.0 (build 37)

- Hotfix: the speaking timeline drew an empty bar on a server older than
  6.21.18, under a heading, with "Hover the bar to see who is speaking"
  underneath — for a bar that was not there. The block is now hidden entirely,
  replaced by a line saying the timeline needs a newer server and to use Update
  Server.

## 0.5.0 (build 36)

- **Renaming a voice now corrects one meeting, not your whole history.** Until
  now the panel only ever called the global merge, so fixing one call rewrote
  every meeting that person appears in. A scope control sits above the name, set
  to "Just this meeting" by default, with "Every meeting" as an explicit choice.
- **Remove a voice that was not in the room.** There was no way to undo a wrong
  name — only to replace it with another. "Not in this meeting" un-attributes the
  voice and also retracts the training samples that meeting contributed to that
  person's profile, so the mistake stops reinforcing itself. It reports what it
  cannot reach: samples recorded before meeting-level provenance existed.
- **A name has to be earned before it is shown as a name.** The identifier
  accepts a match at 0.55, so a single segment could arrive wearing somebody's
  full name. Rows below the floor now read "Unidentified voice" with the closest
  match and the reason it did not qualify — 1 segment, or similarity 0.58, or it
  swaps with another voice every few segments.
- **Play the voice.** A speaker button plays what the stored profile sounds like,
  which settles an identity question faster than any score. Meeting audio is kept
  for a week, so a segment can be played back during review; after that the panel
  says the audio is no longer held rather than looking broken.
- **Play the line you are looking at.** Each quoted phrase gets a play button
  that plays that exact segment of the meeting, so you hear the voice before
  deciding who it was. The button appears only where the server still holds the
  audio, so a click never fails; after the seven-day window the row simply has no
  button. An earlier build played a stored profile sample instead, which does not
  exist for 71 of 77 profiles because training audio is deleted once enrolled.
- **You are no longer labelled "Unidentified voice" in your own meetings.** The
  wearer is verified at exactly the confidence floor, so any confusion between two
  voices flipped you below it — measured on four of nine recent meetings, one with
  285 of your own segments. The confusion warning still shows.
- **Removing several wrong names keeps those voices apart.** They become
  "Unidentified 1", "Unidentified 2" and so on rather than merging into one row,
  so you can still tell them apart and play each one back.
- **Saving now reports what actually happened.** A refused correction said
  "Removed X from this meeting" while the server changed nothing. If an earlier
  correction on that meeting never finished, there is now an "Apply anyway"
  button instead of a dead end.
- **The ribbon is a real timeline.** It used to draw one rectangle per voice sized
  by share of segments while labelled "who spoke, in order" — there was no
  ordering in it, and a voice that spoke twice appeared once. It now reads the
  server's spans, so widths are durations, a voice can appear more than once, and
  hovering says who is speaking at that point. Added a legend mapping each colour
  to a speaker, and hovering a legend entry finds that speaker on the bar. The bar
  aggregates into fixed columns so a long meeting fits: drawn one-rectangle-per-turn
  it needed three times the panel width, and the later half of every long meeting
  was simply clipped off.

## 0.4.2 (build 34)

- Fix a suggested name doing nothing when clicked. When two voices are too far
  apart to be the same person the server declines and explains why, and that
  explanation was being treated as a failure and discarded — so the click had no
  visible effect at all.
- Show the outcome instead: the measured voice similarity, the threshold it fell
  under, and a plain statement that nothing was applied.
- Add a Save button, and show progress while a name is being checked, so it is
  clear the click was received.
- Say what saving actually does. Applying a name folds one profile into another
  across every meeting, not just the one on screen.

## 0.4.1 (build 33)

- Fix the panel closing itself when an overlay opened. Speaker review and the
  photo preview were presented as sheets, and a sheet makes a new window key —
  which a menu-bar panel treats as a signal to dismiss. The panel disappeared
  mid-interaction, so controls stopped responding as they were clicked.
- Both now open in place inside the panel with a Back button, so nothing ever
  leaves the panel's own window.
- Fix a stale route condition: the speaker review's visibility depended on a
  value the view could not observe, so it could read the wrong answer and fail
  to redraw.

## 0.4.0 (build 32)

- Review who spoke in a saved meeting. Recent Glasses gains a Review speakers
  card; opening a meeting shows each voice with two to three of its own verbatim
  lines, timestamped. The lines are the point: a similarity score cannot tell you
  who someone is, and a sentence you remember can.
- Show the shape of the conversation before any name. The ribbon draws each
  voice's share in order, so a voice that swaps labels every few segments reads as
  fine stripes rather than a block.
- Mark a voice unreliable when it swaps with another every few segments. Two
  labels that trade the floor that fast are one identifier oscillating mid-turn,
  which means those profiles cannot be told apart and a name applied to either
  would be a guess. A high confidence score does not override this.
- Correct a voice by folding it into the right person. The merge is always shown
  as a preview first, with the measured voice similarity, and the server refuses
  a pair that is too far apart to be the same person.
- Never offer to absorb your own profile, and say plainly when an unidentified
  voice cannot be named because its audio is no longer held.

Requires server 6.21.13 or newer.

## 0.3.9 (build 31)

- Show Early meeting sync, tier-aware HQ prefill progress, and durable
  finalization recovery reported by server 6.21.8.
- Preserve the private canary flags across managed updates without enabling them
  for public users. Balanced caps progressive HQ at two CPU threads for M1/M2
  Air-class hardware; Max defaults to six on stronger Macs.
- Keep Early Sync available to both tiers because it performs stable-identity
  handoff rather than transcription compute.

## 0.3.8 (build 30)

- Add a machine-wide Meeting Turbo preview control for server 6.21.7+. It
  persists `COS_WHISPER_MEETING_PREVIEW` through Control's managed provider
  environment instead of relying on a hand-edited LaunchAgent.
- Apply uses the existing drain, bootout/bootstrap, lifecycle proof, and
  rollback transaction. Control verifies the replacement launchd process
  loaded the requested setting before reporting success.
- Show the active meeting-preview policy in the health card. Turbo provisional
  text remains cosmetic; Large-v3 stays canonical and speaker-attributed.

## 0.3.7 (build 29)

- Add a machine-wide Background jobs control. It writes the existing
  `COS_DURABLE_QUERY_JOBS` policy through Control's transactional provider-env
  path, drains active work, restarts under launchd, verifies authenticated
  capability truth, and rolls back automatically if proof fails.
- Show Background jobs status in the main health card. On is the server 6.21.6
  default; Off remains the immediate machine-wide rollback for new prompts.
- Keep one policy owner: COS Control changes the server capability, and every
  companion follows that authenticated result. No per-device opt-out can drift
  between phones; accepted jobs remain recoverable and cancellable.

## 0.3.6 (build 28)

- **Photo-aware Recent Glasses.** Turns now show bounded thumbnails for user
  photos and answer images. Select one for a larger local preview without
  exposing the pairing token or server storage paths to the app.
- **Explicit media handoff.** “Copy + images” creates a private local bundle
  with the turn text and up to five images so Cursor, Codex, or Claude can
  inspect the original visual context. Bundles older than 24 hours are pruned
  on the next Control launch or image export. “Copy turn” remains text-only.
- **Fail-closed media transport.** Helper downloads are authenticated, capped,
  MIME/signature checked, written with private permissions, and cleaned up.
  Missing or expired media stays visibly unavailable without breaking the row.
- Verified against `@gotcos/glasses-server` 6.21.4.

## 0.3.5 (build 27)

- **Fast, truthful Claude readiness.** Server 6.21.1 uses Haiku for the
  no-tool transactional proof and returns within a 45-second bound instead of
  inheriting a potentially heavyweight user default such as Opus.
- **Correct timeout errors.** Provider timeout/close races no longer surface as
  the misleading “provider process exited before launch.”
- **Truthful transaction state.** While Control itself owns a live change, the
  panel says the change is in progress and recovery is armed. “Interrupted” is
  reserved for persisted transactions with no active helper.
- Same public Control version, higher build number, so existing 0.3.5 build 26
  installs can discover this replacement through the appcast.
- Verified against `@gotcos/glasses-server` 6.21.1.

## 0.3.5 (build 26)

- **Balanced and Max transcription presets.** Control owns one machine-wide
  setting instead of asking users to hand-edit three environment variables.
  Balanced keeps Small.en preview, Turbo live commit, and Large-v3 polish. Max
  reuses Large-v3 for preview and commit; it never creates a third worker.
- **Transactional tier changes.** Managed and adopted in-place LaunchAgents are
  restarted with bootout/bootstrap, authenticated health is checked, and the
  prior environment is restored if the requested policy is not reported.
- **Truthful tier status.** The panel shows requested/effective policy and a
  visible Turbo fallback when Max weights are missing. Older servers hide the
  controls and direct the user to update instead of guessing.
- **Independent safety diagnostics.** A missing Turbo recovery model warns on
  Max without falsely labeling its active Large-v3 preview as a fallback.
- **Tier-aware Guided Setup.** Users choose Balanced (recommended) or Max before
  provisioning. The setup command downloads the matching models, then Control
  performs the verified activation.
- **Cursor version for support.** The Agent CLIs caption now uses Control's
  local Cursor probe, so it can show Cursor's real build even when server
  health only returns “About Cursor CLI.”
- Verified against `@gotcos/glasses-server` 6.21.0.

## 0.3.4 (build 25)

- **No false update rollback on healthy providers.** Candidate startup keeps its
  60-second ownership/health deadline, but real Claude, Codex, and Kokoro
  transactions now use their own existing bounded timeouts. A normal 38-second
  Codex proof can no longer inherit only the seconds left after startup and
  Claude, then falsely reject an otherwise healthy server update.
- **Mixed-version status stays truthful.** A server that reports HQ capability
  but predates the 6.20 live-model fields shows only HQ. Control no longer
  renders “Unreported” Live Preview and Live Commit rows on server 6.19.0.
- Verified against `@gotcos/glasses-server` 6.20.1.

## 0.3.3 (build 24)

- **Adaptive transcription status.** Control now shows the effective model and
  readiness for all three server 6.20.0 transcription lanes: Small.en live
  preview, Large-v3-Turbo live commit, and Large-v3 HQ polish. Preview fallback
  is labeled instead of being presented as healthy Small.en.
- **Accuracy setup.** Guided Setup provisions the adaptive local models and
  warns when the transcription profile has no real names or specialist terms.
  Existing servers that do not publish the 6.20.0 health contract keep the new
  rows hidden rather than receiving guessed labels.
- Verified against `@gotcos/glasses-server` 6.20.0.

## 0.3.2 (build 23)

- **Agent CLI row.** One quick-glance line for all three backends COS routes
  to: `Claude ✓ · Codex ✓ · Cursor ✓`. Previously only Cursor had a row, so a
  signed-out Claude or Codex CLI was invisible until a query failed on the
  glasses. Ready state comes from the server's own per-binary probe
  (`features.claude` / `features.codex`); a server too old to publish it shows
  `?` rather than a confident cross. When all three are ready the caption
  shows their versions; when one is not it names the exact login command
  instead. CLI version strings are parsed for a real version token, because
  the Cursor probe reports "About Cursor CLI" rather than a number.
- Cursor keeps its own detailed row: the helper probes it locally and can
  distinguish sign-in-required from not-installed, which health cannot.

## 0.3.1 (build 22)

- **Unsaved captures row.** Server 6.19.0 quarantines meeting audio whose save
  never landed instead of deleting it, and reports it on health as
  `unsaved_captures`. Control now surfaces that count in the status card with a
  recovery hint (open COS on the phone to let a deferred save land, or drive
  `/api/meeting/orphans/:id/recover`). The row hides at zero and on older
  servers, where the key is simply absent. Display only — Control never drives
  recovery itself.
- The retained-batch state ("Idle · 1 retained batch") flows through the
  existing Meeting sync label automatically; no change was needed for it.

## 0.3.0 (build 21)

- **Meeting sync status.** The status card now shows **Meeting sync** — Idle, or
  HQ polish progress with a percent when the server publishes it (glasses-server
  6.18.4+). On older servers Control falls back to scanning
  `~/.cos-glasses/data/pending-batch`, so a long post-meeting Whisper polish no
  longer looks like a mysterious "degraded" hang while Update waits to drain.
  Active sync captions that Update / Restart stay blocked until polish finishes.

## 0.2.9 (build 20)

- **A failed install no longer strands in-place mode.** `install()` deleted the
  in-place ownership marker before four throw sites (pending transaction,
  unadoptable ownership, npm unreachable, staging failure) and never restored
  it, so a transient npm outage permanently turned `inPlaceActive()` off — and
  with it the per-minute in-place recovery watchdog — while otherwise appearing
  to fail safely. The marker is now captured up front, dropped only at the point
  of no return, and written back if the switch rolls back.
- **Doctor and Copy Report name the Control build.** The report carried no app
  version at all, so a support report could not identify which build produced
  it — worse given that 0.2.7 shipped as two different binaries. The app passes
  its identity the same way it already does for the update check, because the
  stable helper copy has no sibling `Info.plist` to read.
- **Restored a version-touchpoint assertion.** Making the footer dynamic in
  0.2.8 removed the only test that could catch a wrong `Info.plist`. The suite
  now pins `Info.plist` to the CHANGELOG heading rather than to a UI string.

## 0.2.8 (build 19)

- Footer shows the **live** managed server version from status (e.g. 6.16.9),
  not a compile-time "verified 6.16.x" pin that lagged behind Update Server.
- Controller version in the footer comes from `Info.plist` (`currentVersion`).
- Verified baseline for this cut: `@gotcos/glasses-server` **6.16.9** (message
  era + per-exchange model stamps). Install/Update still resolve npm `latest`.

## 0.2.7 (build 18)

- Clarify folder pickers: **Work Folder** (agent workspace) vs **Meetings
  Library** (COS `operations/` for G2 Review Meetings). Own tool row so labels
  no longer truncate to ambiguous "Choose…" / "Meeting…".

## 0.2.6 (build 17)

- Add **Meetings Folder** so each install can point G2 Review Meetings at its
  own COS `operations/` tree (`COS_OPERATIONS_DIR`). Status shows the active
  meetings library; unset keeps standalone local recordings.
- Allowlist `COS_OPERATIONS_DIR` / `COS_MEETINGS_ROOT` on the managed
  LaunchAgent. Server fallback remains `COS_SCRIPTS_DIR/..` when set.
- Verified baseline server: `@gotcos/glasses-server` **6.16.2** (Update Server
  still resolves npm `latest`).

## 0.2.5 (build 16)

- Target the verified public `@gotcos/glasses-server` **6.16.1** release, which
  keeps truthful HQ transcription and adds managed Cursor Agent slots
  (Composer 2.5 / Grok 4.5) plus Silero VAD weights in the npm tarball.
- Install / Adopt / Update Server resolve npm `@gotcos/glasses-server@latest`,
  so the same UI path picks up 6.16.2+ without a Control rebuild. The footer
  still shows the verified baseline (6.16.1).
- From a running recognized legacy LaunchAgent, offer **Install managed
  server** (stop when idle, then adopt/install latest) alongside Manage in
  place. Repair commits an already-healthy candidate instead of rolling back
  when an interrupted update left the new generation live.
- Preserve the existing companion-owned HQ-default/Fast-mode preference; this
  release does not introduce a conflicting Control-side preference.
- Keep public packaging fail-closed for Developer ID builds: notarization is
  required when `COS_SIGN_IDENTITY` is set. Until notarization is enrolled,
  public site ZIPs may continue the existing ad-hoc ship path used by 0.2.3.

## 0.2.4 (build 15)

- Target server 6.15.5 and require an installed local Whisper runtime to report
  ready before a managed candidate is accepted. Repair Whisper now releases the
  maintenance gate before its final readiness check, so a failed optional audio
  repair never strands the otherwise healthy server offline.
- Show Whisper preflight/loading/failure state instead of a generic unavailable
  label and include the bounded startup error in diagnostics.
- Report the actual maintenance work classes and countdown while draining,
  replacing the indefinite-looking “Draining active work” message.
- Bound candidate verification, provider queries, and Kokoro playback to one
  monotonic operation deadline with explicit proof-phase progress.
- Add boundary coverage for migrated pairing tokens and prove both stale PID
  text and a SIGKILLed lock-holder process cannot block a later helper.
- Gate persistent Whisper readiness on whisper-server/model prerequisites, not
  batch-only whisper-cli, and show the bounded startup error in the main status
  card, Doctor, and Copy Report.
- Public packaging now fails closed without Developer ID signing and
  notarization, then validates the extracted ZIP with codesign, stapler, and
  Gatekeeper. Ad-hoc output requires an explicit local-QA override.

## 0.2.3 (build 14)

- Fix Choose Folder for adopted self-managed LaunchAgents. The selected
  workspace is written to both neutral and legacy provider keys, safely
  reloaded through the maintenance gate, and rolled back if activation fails.
- Apply managed workspace changes immediately through a full plist reload;
  status no longer reports a folder that launchd has not loaded.
- Keep server `WorkingDirectory` and `COS_GLASSES_APP_DIR` on the verified
  server package while Claude, Codex, and Cursor use the selected workspace.
- Tighten rewritten LaunchAgent plists to mode 0600, require exact adopted
  ownership, and preserve pending recovery state. Older adopted servers never
  auto-restart; an explicit, confirmation-gated Restart performs a full
  bootout/bootstrap so launchd actually loads the new environment.
- Preserve custom Cursor paths and target public server 6.15.3.

## 0.2.2 (build 13)

- Require a real, authenticated provider turn before a 6.15.2+ managed
  install, update, restart, repair, or rollback is reported as verified.
- When Kokoro reports ready, prepare speech and fetch the short-lived playback
  URL without an API header, matching the native phone audio path.
- Preserve the managed COS work folder, MCP selectors/config, compatible
  Kokoro Python overrides, and provider binary paths across runtime changes.
- Accept migrated pairing tokens with at least 16 characters and explain the
  generated 64-character format for shorter invalid values.
- Keep lifecycle locking kernel-owned and clear normal-operation PID metadata
  on unlock; a dead helper cannot leave a held lock.
- Target public server 6.15.2.

## 0.2.1 (build 12)

- Preserve discovered Claude, Codex, and Cursor executable directories in the
  canonical managed LaunchAgent PATH, including user-local CLI installs.
- Replace HTTP-200-only update, restart, and in-place gates with provider
  capability verification. A missing provider bridge now fails the candidate
  switch and restores the previous runtime instead of reporting false-green.
- Target `@gotcos/glasses-server` 6.15.1 for the Kokoro Python compatibility
  fix.

## 0.2.0 (build 11)

- Add the check-only in-app update banner and signed appcast parser.
