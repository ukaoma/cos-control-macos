# Four directions for the pet card

Every number in this file traces to `ANATOMY.md`, which measures the shipped row
by executing it, not by reading it. The one number worth carrying in your head:
at the card's 248pt root the finished row leaves the title **68pt**, which is
**10 characters** of DM Sans at 11pt. That is the complaint, exactly.

The four sample rows are identical across all four artboards: two finished
Claude rows whose titles diverge at character 15, one running Codex row with a
56-character live line, one waiting Cursor row. D is interactive: its rows
respond to a real pointer, so hover it rather than reading it.

---

## The problem is three problems

1. **Width starvation.** The 198pt row spends 57pt on three always-on icon
   buttons and 54pt on a provider wordmark that repeats what the icon and the
   tint already say. Add 16pt of HStack spacing and the title gets 34% of the
   row. On the mission row the trailing age-over-workspace stack takes another
   44 to 66pt and the title drops to **41pt**.
2. **Content vacancy.** Every finished row prints the literal string
   `"Finished"` (`SessionPet.swift:758`). `PetCompletion` stores `workspace` and
   `finishedAt` and the view renders neither. Two forked Claude sessions
   therefore render as the same three tokens, which is precisely the case
   `ClaudeSession.ambiguousTitles` exists to detect.
3. **Vertical scarcity.** Both lists scroll in fixed frames, 160pt finished and
   240pt live. Any direction that grows the row pays in rows visible.

No direction can fix (1) alone. Widening the title without giving the row an
actual outcome to say still yields three identical rows, just legibly identical.

---

## Direction A. Outcome line

**Thesis.** Give the answer its own full width line and stop spending the title
line on chrome.

| | before | after |
|---|---|---|
| finished title box | 68pt / 10 chars | **121pt / 19 chars** |
| finished outcome line | none | **165pt / 30 chars** |
| readable per finished row | 10 chars | **49 chars** |
| finished row height | 43pt | 48pt |
| finished rows in the 160pt frame | 3 | **3** (48 x 3 + 2 dividers = 146) |
| mission title box | 41pt / ~12 chars | **121pt x 2 lines / ~38 chars** |
| mission row height | 61pt | 61pt |
| card width | unchanged | unchanged |

**What it costs.** The workspace leaves the mission row. It has nowhere to go
inside 165pt without starving the ticker, and the source already records that
110pt was too narrow for the ticker to show one whole word. It survives as the
row's `.help()` tooltip and, under C or B, on the row itself. Two of the three
per-row icon buttons move into an overflow menu behind a single 22pt slot; the
slot cross-fades between the overflow dot and a one-click clear, which is a
color change inside a fixed frame, not a size change.

**Small.** Every `typeSize` collapses onto the 8pt floor, so the title and its
outcome line stop being separated by scale and are left with weight, tint and
the mono face. The budgets themselves hold: title 86pt is 18 characters,
outcome 120pt is 25, so 43 characters against the shipped Small row's 9. The
next thing to go is the age label, which should drop off line one below a 200pt
root and let the title run to the slot.

**What it needs from the model that does not exist.**
One field. `PetCompletion` gains `summary: String`;
`PetCompletionDetector.diff` already holds `prior`, the last running snapshot,
so the value is `prior.discussionSummary` and the change is one line. The hand
written `init(from:)` decodes it with `decodeIfPresent ?? ""` so persisted rows
from before the change still load. When it is empty the row falls back to the
relative age, never to the word "Finished".

**Implementation sketch.**
- `completionsList` (`SessionPet.swift:735`): keep the
  `Group { if count > 3 { ScrollView { … }.frame(height: size.length(160)) } else { … } }`
  shape byte for byte. `Tests/pet-layout-source-contract.py` asserts `ScrollView`
  and `.frame(height:` are present and `maxHeight` is absent in that slice.
- Replace the three sibling `completionAction(...)` calls with one
  `completionOverflow(row)` wrapped in `.frame(width: size.length(22))`. It stays
  a **sibling** of the row `Button` inside the `HStack(spacing: 0)`; nesting it
  in the label kills the click on macOS.
- `providerMark` (`:680`) gains a `wordmark: Bool = true` parameter. Finished and
  mission rows pass `false` and it renders the glyph alone at
  `.frame(width: size.typeSize(14))`. `idleRow` can keep the wordmark or lose it;
  it is the only place the label earns its width.
- `missionRow` (`:574`): delete the trailing meta `VStack`, move
  `session.compactAgeLabel()` into the title `HStack` after the `Spacer`. Leave
  the rail as an `.overlay(alignment: .leading)` (`:637`) and leave
  `TickerLine` alone; it simply inherits the wider line.
- Reuse `TickerLine` for the finished row's outcome so an over-long outcome
  scrolls instead of clipping, exactly as the live line does.
- `missionRow` and `idleRow` must each still contain
  `model.openSessionInPlatform(session)` and `.help("Open in platform")` in their
  own slice (`Tests/run.sh:2121`).

---

## Direction B. Outcome first, identity second

**Thesis.** Stop letting the sprite decide how wide the reading surface is, then
invert the row so the first and heaviest line is what the session did.

| | before | after |
|---|---|---|
| root width | `max(248, viewport + 36)` | `max(392, viewport + 36)` |
| primary line | none | **274pt / 39 chars at 12pt semibold** |
| secondary line (glyph, title, workspace) | title 68pt | **293pt / ~56 chars at 9pt dim** |
| readable per finished row | 10 chars | **95 chars** |
| finished row height | 43pt | 44pt |
| finished rows in the 160pt frame | 3 | 3 |
| mission row height | 61pt | **44pt** |
| mission rows in the 240pt frame | 3 | **5** |
| ticker window | 157pt | **274pt** |

**What it costs.** Width. The plate goes from 228 to 372pt over a sprite whose
live-pose envelope measures about 233pt, so the card reads as a nameplate the
figure stands under rather than a label beside it. That is a taste call and it
is Miles's to make; nothing measurable breaks.

Mission rows get shorter, which is worth saying plainly: the shipped 61pt row is
61pt only because the age-over-workspace stack measures 23pt against the title's
14pt and sets line one's height. Delete the stack and the row is 44pt.

**Small.** The text is fine. `size.length(392)` gives a 294pt root, the outcome
box holds 176pt, and 38 characters still read at the 8pt floor; the plate to
figure ratio is unchanged at 1.7x because both sides scale together. What
degrades is the hierarchy itself: B rests entirely on 12pt primary over 9pt
secondary, and the `typeSize` floor collapses both onto 8pt, leaving weight and
tint. Second, Small stops meaning small, since a 294pt plate is wider than the
shipped Medium card's 248pt root. Mitigation: hold the content floor at Medium
and Large only and let Small fall back to `max(248, viewport + 36)`.

**What it needs from the model that does not exist.**
The same one field as A. Running and waiting rows need nothing:
`ClaudeSession.petLiveLine` (`Models.swift:690`) already returns the live summary
or what the session waits on, and B only promotes it from line two to line one.

**Implementation sketch.**
- Add `PetCard.minRootWidth(_ size: PetSize) -> CGFloat` next to `PetPanelFrame`,
  returning `size.length(392)` (or `size.length(248)` at `.small` if the
  mitigation is taken). Use it in **both** width sites or the root will render
  centered inside a wider panel: `SessionPetPresenter.syncPanel()`'s
  `let width = max(...)` (`SessionPet.swift:118`) and `SessionPetRoot.body`'s
  `.frame(width: max(...))` (`:323`). The 260 / 248 mismatch that exists today is
  the bug this pairing prevents.
- One shared `outcomeRow(_:tint:primary:secondary:)` feeds `missionRow`,
  `idleRow` and the completion row, so the three cannot drift. It must be a
  factory called separately at each site, not a slice shared between them, or the
  `Tests/run.sh:2121` slice assertion fails.
- `.frame(height: size.length(240))` and `size.length(160)` stay literal.

---

## Direction C. One row answers, the rest identify

**Thesis.** Most rows only need to be told apart, so shrink them to a single
24pt line and spend everything saved on exactly one focused row.

| | before | after |
|---|---|---|
| dense row height | 43pt | **24pt** |
| dense title box | 68pt / 10 chars | **139pt / 24 chars** |
| focused row height | n/a | 72pt |
| focused title / outcome | n/a | **137pt / 181pt at mono 9pt** |
| finished rows in the 160pt frame | 3 | **4** (72 + 24 x 3 + 4 dividers = 148) |
| mission row height when unfocused | 61pt | 24pt |
| live rows in the 240pt frame | 3 | **7** |
| card width | unchanged | unchanged |

At 139pt the two forks read `COS-glasses server relea…` and
`COS-glasses session arch…`. **The reported bug is fixed with no width change,
no height change, and no new model field.** The outcome is the upgrade on top.

**What it costs.** Only one row carries its outcome at a time, and a second
running session loses its ticker until you click it. Today every running row
shows its live line in a 157pt window. The mitigation is that the live list's
focused row is `ClaudeSession.petPreferredFocus` (`Models.swift:672`), which
already follows the working session, so the row you care about is focused
without a click.

**Small.** The most tolerant of the three, because its hierarchy is height and
background rather than type size and neither is squeezed by the 8pt floor. What
degrades first is the action bar: three mono-caps pills measure about 92pt
against a 136pt line, so CLEAR wraps or clips. Drop to two pills plus an
overflow below a 200pt root. The workspace is the flexible item on that bar and
truncates before the pills do, which is the right thing to lose.

**What it needs from the model that does not exist.**
The same `summary` field, plus one published id:
`@Published var petFocusedCompletionID: String?` on `ControllerModel`, defaulting
to the newest row whose `seen` is false. `PetCompletion.seen`
(`Models.swift:930`) already exists and already means exactly this. The live list
needs no new state at all: `model.petFocusID` and `petPreferredFocus` are both
already there and already wired.

**Implementation sketch.**
- Split each list body into `focusedRow(...)` and `denseRow(...)`, interleaved
  with the existing `Divider()` and `petSectionHeader` calls. The fixed
  `.frame(height: size.length(160))` / `size.length(240)` and the `> 3` scroll
  trigger stay exactly as written.
- Focus is set by a click, never by hover, so `showPills` / `revealActive` and
  the `ledgerSlot` cross-fade are untouched and the fixed-height ledger contract
  still holds.
- The focused row's three action pills are siblings of the row button, same rule
  as today's `completionAction` trio.
- Do **not** add a `petExpanded.toggle()` site. The contract asserts the count is
  exactly two, the RUNNING pill and the sprite double-click. Focus is its own
  flag.

---

## Direction D. Outcome first, actions on demand

**Thesis.** Take B's row, then make the trailing 57pt do two jobs instead of
none: at rest it says when and where, under the pointer it becomes the three
paths off the row, and the primary line starts scrolling. Nothing changes size.

| | before | after |
|---|---|---|
| root width | `max(248, viewport + 36)` | `max(392, viewport + 36)` |
| row width | 198pt | **352pt** |
| primary line, the outcome | none | **281pt / 40 chars at 12pt semibold** |
| secondary line, glyph and title | title 68pt / 10 chars | **276pt / 53 chars at 9pt dim** |
| trailing slot, at rest | three lit icons, 57pt | **age over workspace, 57pt** |
| trailing slot, on hover | the same three icons | **the same three actions, 57pt** |
| layout change on hover | n/a | **none, 0pt** |
| readable per finished row | 10 chars | **91 chars** |
| finished row height | 43pt | 44pt |
| finished rows in the 160pt frame | 3 | 3 |
| mission row height | 61pt | **44pt** |
| live rows in the 240pt frame | 3 | **5**, or 4 with both section headers |
| ticker window | 157pt | **281pt** |
| lines in motion at rest | one per running row | **zero** |
| lines in motion on hover | n/a | **exactly one, the hovered row** |

Two of those numbers need their source named.

**The 57pt slot.** `arrow.up.forward.app`, `text.alignleft` and `xmark` measure
11.0, 12.0 and 10.0pt at `pointSize 9, weight .bold`, each with
`.padding(length(4))`, so the three controls are 19 + 20 + 18 = **57pt**
(ANATOMY §3). D reserves exactly that, in both states, and cross-fades the two
occupants inside it, the way `ledgerSlot` (`SessionPet.swift:342`) already
cross-fades the bar into the pills. A slot that only *appeared* on hover would
reflow the row; a slot reserved and left empty at rest would waste the same 57pt
the card wastes today. The at-rest occupant has to earn it, which is why it is
the age **and** the workspace, not the age alone: the age is 14pt of text in a
57pt box, and 43pt of dead air is the trap restated.

**That meta stack is free here, and it was not free before.** On the shipped
mission row it measures 23pt against a 14pt title, which is the whole reason a
one-line-title mission row is 61pt rather than 47 (ANATOMY §4). D's body is
already two lines at 30pt, so a 23pt trailing column cannot set anything. The
stack was never the problem; its neighbours were. Moving it there also hands
line two its entire 276pt, where B had to cap the title at 172pt to fit the
workspace beside it.

**Where the extra 10pt came from.** `completionsList` insets its content
`.padding(.trailing, size.length(10))` for the overlay scroll indicator
(`SessionPet.swift:800`) and insets nothing on the leading edge. Measured on the
artboard, the rail's ink starts 11px inside the card and every trailing item
stopped 21px inside it. That 10pt asymmetry is the dead space; hiding the
indicator instead returns it, and because it sits at the row's trailing edge the
whole 10pt lands on the reading lines. Miles then looked at the render and
said the trailing items still were not against the container, and he was right:
the plate carries 10px of its own padding plus a 1px border, so the X ink sat
11px inside the card, exactly where the left rail sits. Symmetric padding reads
as balance on text and as dead space on a corner control. The slot now breaks
the plate's padding with a negative right margin, so its trailing edge IS the
plate's inner edge and the 10px it stops reserving goes to the body as well:
window 263 to **281pt**, title 258 to **276pt**. The slot's 57pt frame is
unchanged, so hover still moves nothing. Separately, the trailing
symbol carries 4pt of its own padding, which is hit target rather than layout, so
the action row overhangs by that 4pt and the glyph's INK lands on the same edge
the age and the workspace already sit on. The slot's 57pt frame does not move.
**This fix is independent of which direction wins.** A and C should take it too.

**The ticker.** The primary line sits still and ellipsised at rest and scrolls
only while its own row is hovered, on `PetTicker`'s shipped parameters:
`advanceRatio 0.6`, `gap 30`, `speed 26`, `startHold 1.4`
(`Models.swift:3372`). It never scrolls when the text fits, which is why the
second finished row is 33 characters, 226pt in a 281pt window, and never moves.

**Hover-gate the running rows too.** Today every running row scrolls on its own
in a 157pt window. At D's proportions the 240pt frame holds five rows, so
"every running row" can mean five lines moving at once over arbitrary wallpaper,
on a card whose job is to be glanced at. Gating gives an exact invariant: **at
rest nothing in the card moves, and under the pointer exactly one line does**,
because the pointer can only be on one row. The 1.4s start hold covers the other
half of the objection: a pointer crossing four stacked rows on its way somewhere
else never holds one long enough to start it, so the sweep produces no motion at
all. One carve-out is arguable, letting `petPreferredFocus`
(`Models.swift:672`) keep an automatic ticker so the session you are actually
working in scrolls untouched. It costs the card its single law and it is not
worth that.

**What it costs.**

1. **B's width, unchanged.** A 372pt plate over a roughly 233pt figure. Every
   argument against B's proportion applies to D exactly as written.
2. **Per-row hover on a nonactivating panel.** `.onHover` will not fire here:
   SwiftUI's tracking area arms only while the app is active, which is why the
   root already carries a bespoke `HoverSensor` (`SessionPet.swift:327`). D
   needs one per row. Five AppKit tracking areas inside a scrolling list, with
   enter and exit ordering between adjacent rows and rows moving under a
   stationary cursor while it scrolls. This is D's one genuinely new mechanism
   and the thing most likely to be fiddly on the real panel rather than in a
   mock.
3. **The three actions become pointer-only.** Today they are visible at a
   glance. The row's own click is unchanged, so only the two secondary paths and
   clear go behind hover, but a control reachable only by pointer is an
   accessibility regression. D should ship with a right-click context menu
   carrying the same three items, not add one afterwards.
4. **At-rest motion goes to zero.** The ticker was the live list's one sign of
   life. `LedgerBreathing` still breathes so the card is not dead, but this
   changes what the pet is. Taste call, and Miles's to make.
5. **The workspace's truncation cap drops 66pt to 57pt**, so a long repository
   name loses about two characters. `cos-control-macos` truncates.
6. **The finished list loses its scroll indicator.** The partial fourth row
   becomes the only affordance saying the list scrolls.

**Small.** The slot degrades, and only the slot. Its two occupants scale
differently: the symbols are `typeSize(9)`, which floors at 8, so they shrink
11% while their 4pt padding shrinks 25%, and the slot lands at **47pt** rather
than 43. The workspace truncates there where the shipped row truncated at 66.
Mitigation below root 300pt: return the workspace to line two after the title
and leave the slot the age, which is B's arrangement and costs D its
"the slot earns its keep" argument at Small only.

The type holds up better than B's section claims for B. `typeSize(12)` at Small
is `max(8, round(12 * 0.75)) = max(8, 9) = 9`, **not 8**. ANATOMY §1's table
stops at 11pt, which is why B's Small section reads as if a 12-over-9 hierarchy
collapses flat. It does not: D keeps 9 over 8, plus weight and tint. Budgets at
Small: root 294, row 262, slot 47, ticker window **204pt** (39 characters at
9pt), title **200pt** (43 characters at the 8pt advance of 4.575). Against the
shipped Small row's 9. B's plate-to-figure mitigation applies unchanged: hold
the 392 floor at Medium and Large only.

**What it needs from the model that does not exist.**
The same one field as A, B and C, and nothing else. `PetCompletion` gains
`summary: String`, set from `prior.discussionSummary` in
`PetCompletionDetector.diff` (`Models.swift:1105-1120`), decoded with
`decodeIfPresent ?? ""` so persisted rows still load. Running and waiting rows
need nothing; `petLiveLine` (`Models.swift:690`) already returns the live
summary or what the session waits on. Hover is view state, never model state: a
`@State private var hoveredRowID: String?` on the list view, never a
`@Published` on `ControllerModel`, or a pointer move invalidates every other
observer of the panel.

**Implementation sketch.**
- `PetCard.minRootWidth(_ size: PetSize)`, used at **both** width sites:
  `SessionPetPresenter.syncPanel()` (`SessionPet.swift:118`) and
  `SessionPetRoot.body` (`:323`). Same requirement as B; the 260 / 248 mismatch
  that exists today is the bug this pairing prevents.
- `completionsList` (`:735`): keep the
  `Group { if count > 3 { ScrollView { … }.frame(height: size.length(160)) } else { … } }`
  shape byte for byte. `Tests/pet-layout-source-contract.py` asserts `ScrollView`
  and `.frame(height:` are present and `maxHeight` is absent in that slice.
  Replace `content.padding(.trailing, size.length(10))` with
  `.scrollIndicators(.hidden)`; that inset is the 10pt of trailing dead space.
- New `trailingSlot(age:workspace:hovered:actions:)`, modelled directly on
  `ledgerSlot` (`:342`): a `ZStack` at a fixed `.frame(width: size.length(57))`,
  meta column at `.opacity(hovered ? 0 : 1)`, action row at
  `.opacity(hovered ? 1 : 0).allowsHitTesting(hovered)`, and
  `.animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: hovered)`,
  the ledger's own duration, so the two cross-fades read as one gesture. Give
  the action row `.padding(.trailing, -size.length(4))` for the optical overhang.
- The three `completionAction(...)` calls (`:703`) move inside that `ZStack`,
  and the **slot** becomes the sibling of the row `Button` in
  `HStack(spacing: 0)` (`:773`). A `Button` nested in another `Button`'s label
  never receives the click on macOS. Live rows take the same trio, so
  `dismissControl` (`:717`) folds into it and the two row types stop having
  different trailing geometry.
- Per-row hover: a `HoverSensor` in each row's `.background { }` writing to
  `hoveredRowID`. `HoverSensorView.hitTest` returns nil, so it cannot swallow
  the row's click.
- `TickerLine` (`:884`) gains `active: Bool` and adds it to the `.task(id:)`
  key. Leaving hover cancels the task, whose first line already sets
  `rolling = false`, so the offset resets to the start with no new animation code.
- `TickerLine` also gains a `font:`. `PetTicker.width`'s ASCII fast path is
  `count * fontSize * 0.6`, calibrated to JetBrains Mono; DM Sans measures
  0.572 em (6.291pt at 11pt, ANATOMY §7), so the fast path over-estimates by
  about 5% and would call a line that fits "scrolling". Route the non-mono
  primary line through the existing `PetTicker.measuredWidth`.
- `missionRow` (`:574`): delete the trailing meta `VStack` (`:596-606`) and
  rebuild it as the slot's at-rest occupant. Leave the rail as
  `.overlay(alignment: .leading)` (`:637`). `missionRow` and `idleRow` must each
  still contain `model.openSessionInPlatform(session)` and
  `.help("Open in platform")` in their own slice (`Tests/run.sh:2121`); the row
  `Button`'s action is unchanged, so that holds.
- Do **not** add a `model.petExpanded.toggle()` site. The contract asserts the
  count is exactly two.
- Worth adding to the contract, mirroring `ledgerSlot`'s existing assertions:
  the trailing slot contains `.frame(width:` and not `maxWidth`, and
  `TickerLine`'s scroll is gated on the active flag.

---

## Recommendation

**The width question comes first, and it decides everything else.**

D is not a fourth option competing with C on the same axis. D is B's row with a
hover layer, so it inherits B's one real cost unchanged: a 372pt plate over a
roughly 233pt figure. If that proportion is acceptable, **D strictly dominates
B**: same geometry, the wasted 57pt now saying when and where, three actions
instead of one overflow dot, a flush trailing edge, and a card with nothing
moving on it at rest. There is no reason left to prefer B. If the proportion is
not acceptable, D is unavailable and the choice is C.

**If the plate can grow: ship D.** It is the best card of the four. Every row
carries its outcome rather than one row at a time, any row can be read in full
without a click, and it is the only direction that makes the at-rest card
quieter instead of busier.

**If the plate cannot grow: ship C, then A's outcome line into C's focused row.**

C first, because it is the only direction that fixes the reported bug with zero
new model state, zero width change and zero vertical cost, and it is the only
one that makes the list *shorter* while making it more readable. A 24pt dense
row at a 139pt title already separates the two forked sessions that read
identically today. That is a change that can ship this week and be judged on the
desktop rather than in a mock.

Then add the `summary` field and let C's focused row print it. That is the same
one-line change all three directions need, and in C it lands on the one row that
has room for a 33-character mono line without touching any other geometry.

**What D costs that C does not, stated plainly.** Two things, and neither is
small. First, per-row hover on a nonactivating panel: five AppKit tracking areas
in a scrolling list where SwiftUI's `.onHover` does not fire at all, with
enter and exit ordering between adjacent rows and rows moving under a stationary
cursor. C's focus is a click, so it touches none of that. Second, D's three
actions are reachable only with a pointer, which C's labelled pills are not.
And D is worthless without the `summary` field, while C fixes the reported bug
with no new model state at all. That is the difference between shipping this
week and shipping after a model change.

**What C costs that D does not.** Only one row answers at a time, and a second
running session loses its ticker until you click it. In D every row carries its
outcome and any row can be read in full. C's three action pills are on the
focused row only; D's are on every row.

Against B: B produces the best single row of the original three, and its
mission-row result is genuinely strong, 61pt down to 44pt and three visible rows
up to five. But D is B plus a hover layer at no additional width, so B is now
dominated. Take B only if the per-row hover machinery in D turns out to be
unworkable on the real panel, in which case B is D with three permanently lit
icons instead of a cross-fading slot.

Against A: A is the safest and the least interesting. It keeps every geometry
constant and roughly quintuples the readable text, but it needs the new model
field to be worth anything at all. Without `summary`, A ships a 165pt line that
says "Finished" in a bigger box. A is the right answer only if the outcome field
turns out to be harder than one line in `PetCompletionDetector.diff`.

**Two things to do regardless of which one wins.** First, the card's width is
currently a side effect of the character dial and the installed sprite art;
give the plate its own floor so the reading surface stops moving when someone
changes character packs. Second, take D's trailing-edge fix: `completionsList`
insets 10pt on the right for a scroll indicator and nothing on the left, which
parks every trailing item inside the card's own margin. A and C get the same
10pt back for free.
