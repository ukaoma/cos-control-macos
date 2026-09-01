# Pet card anatomy, measured

Every number below is either read directly out of `Sources/SessionPet.swift` /
`Sources/Models.swift`, or produced by executing the row layout in a headless
`NSHostingView` with the app's own bundled `DMSans.ttf` and `JetBrainsMono.ttf`
registered. Nothing here is estimated from a screenshot.

Measurement harness (scratch, not committed):
`rowprobe2.swift` rebuilds `missionRow` and the `completionsList` row verbatim at
Medium / Small / Large, mounts each in an `NSHostingView` at a fixed root width,
runs a layout pass, and reads every subview's `GeometryReader` size back through
a `PreferenceKey`. Font advances come from `NSAttributedString.size()` against
the same TTFs the app registers in `COSType.registerBundledFonts()`.

---

## 1. The size ramp is a single multiplier

`PetSize` (`Models.swift:3117`)

| preset | `pixels` | `scale` | `length(b)` | `typeSize(b)` |
|---|---|---|---|---|
| Small  | 48  | 0.75 | `round(b * 0.75)` | `max(8, round(b * 0.75))` |
| Medium | 64  | 1.00 | `round(b)`        | `max(8, round(b))` |
| Large  | 80  | 1.25 | `round(b * 1.25)` | `max(8, round(b * 1.25))` |

`typeSize` has an `8` floor (`Models.swift:3138`). Consequence, and it is the
single most important fact about Small: **at Small every type size in the row
collapses onto the same 8pt.**

```
Small: typeSize(11) = max(8, 8)  = 8     <- title
       typeSize(10) = max(8, 8)  = 8     <- "Finished", idle title
       typeSize(9)  = max(8, 7)  = 8     <- ticker, every SF Symbol
       typeSize(8)  = max(8, 6)  = 8     <- age, workspace, all mono caps
```

Small has exactly one type size. Any hierarchy that is expressed by *size*
disappears there; only weight and color survive. Lengths keep scaling, so the
54pt provider block becomes 41pt while the 11pt title becomes 8pt. The chrome
shrinks 25%, the content shrinks 27%, and the ratio between them does not
improve.

## 2. The card's width is set by the sprite, not by the text

`SessionPetPresenter.syncPanel()` (`SessionPet.swift:118`) and
`SessionPetRoot.body` (`SessionPet.swift:323`):

```swift
let width = max(model.petSize.length(260),          // panel
                viewportSize.width + model.petSize.length(36))

.frame(width: max(size.length(248),                 // root view
                  viewportSize.width + size.length(36)))
```

Two different floors, 260 and 248, so when the sprite is small the root sits
centered in the panel with 6pt of clear on each side.

`viewportSize` is the **max render width over every live pose**
(`Models.swift:3831`, `liveCases` at `3474`) so it does not move with session
count. By design, "a poll must never re-center the pet." With the shipped
`DefaultPet` art and the default 300% character dial
(`PetCharacterScale.defaultPercent = 300`, `Models.swift:3228`):

| pose | frames | frame px | aspect | clamp | render W @ Medium/300% |
|---|---|---|---|---|---|
| idle (renderScale 1.3) | 8 | 83 x 256 | 0.324 | 0.60 | 150 |
| patrol (cinematic) | 8 | 104 x 256 | 0.406 | 0.75 | 144 |
| done | 8 | 99 x 256 | 0.387 | 0.60 | 115 |
| trio (cinematic) | 13 | 286 x 256 | 1.117 | -- | 215 |
| duel (cinematic) | 17 | 304 x 256 | 1.188 | -- | 228 |
| swarm (cinematic) | 26 | 311 x 256 | 1.215 | -- | 233 |

Envelope ~233pt, so `root = max(248, 233 + 36) = 269pt`, `panel = 269pt`.
A different character pack or a lower dial drops it to the **248pt floor**.

**Every text budget in the card is a function of that one number.** The list
plate is `root - 20` (root `.padding(10)`), and the row is `plate - 20 - 10`
(list `.padding(.horizontal, 10)` plus the scroll inset
`.padding(.trailing, 10)`). Measured, at Medium: `row = root - 50`.

## 3. Where the ~10 characters come from (finished list)

`completionsList`, `SessionPet.swift:735-812`. Structure, verbatim:

```
HStack(spacing: 0) {
  Button { HStack(alignment: .top, spacing: length(8)) {
      providerMark(...)                       // .frame(width: length(54))
      VStack(spacing: length(2)) {
        Text(row.name).body(typeSize(11)).lineLimit(1)
        Text("Finished").body(typeSize(10))   // :758, literal, every row
      }
      Spacer(minLength: 0)
  }.padding(.vertical, length(7)) }
  completionAction("arrow.up.forward.app")    // Image(9pt bold) + padding(4)
  completionAction("text.alignleft")
  completionAction("xmark")
}
```

Executed layout, Medium, at the two root widths that actually occur:

| root | plate | row | label | mark | **title** | spacer | 3 buttons | row H |
|---|---|---|---|---|---|---|---|---|
| 248 (floor) | 228 | 198 | 141 | 54 | **68** | 3 | 19+20+18 = 57 | 43 |
| 269 (shipped art) | 249 | 219 | 162 | 54 | **89** | 3 | 57 | 43 |
| 560 (hypothetical) | 540 | 510 | 453 | 54 | **187** | 196 | 57 | 43 |

SF Symbol widths at `pointSize 9, weight .bold`, measured:
`arrow.up.forward.app` 11.0, `text.alignleft` 12.0, `xmark` 10.0. Each carries
`.padding(length(4))` on all sides, so the three controls cost **57pt**, or
**29% of the 198pt row**.

DM Sans advance at 11pt, measured against the bundled `DMSans.ttf`:
**6.291 pt/char** average. Fitted with a tail ellipsis:

| budget | characters + ellipsis |
|---|---|
| 68pt | **10** |
| 72pt | 10 |
| 87pt | 13 |
| 100pt | 16 |
| 187pt | 30 (whole 34-char string fits at ~34) |

**68pt is exactly the 10 characters in Miles's screenshot.**

So the truncation source, in order of cost, is:

| consumer | pt | share of the 198pt row |
|---|---|---|
| three always-on icon buttons | 57 | 29% |
| `providerMark` fixed block (`:699`) | 54 | 27% |
| HStack spacing (2 x 8) | 16 | 8% |
| list padding already deducted upstream (30) | -- | -- |
| **left for the title** | **68** | **34%** |

Note on the "~560pt" figure in the brief: the arithmetic above says a 560pt root
gives the title 187pt, which renders the full 34-character sample string with no
ellipsis at all. A 10-character truncation is only reachable at root 248-252.
The likely reconciliation is that 560 was read off a Retina screenshot in
**pixels** (560 px / 2 = 280 pt), which lands in the 248-269pt band. Either way
the conclusion is the same and does not depend on which is right: the finished
list is running at or near its width floor.

## 4. The mission row is worse, not better

`missionRow`, `SessionPet.swift:574-641`. Executed layout, Medium:

| root | row | label | mark | **title** | spacer | meta stack | ticker | dismiss | row H |
|---|---|---|---|---|---|---|---|---|---|
| 248 | 198 | 178 | 54 | **41** | 4 | 44 | 157 | 20 | 61 |
| 269 | 219 | 199 | 54 | **47** | 8 | 55 | 173 | 20 | 61 |
| 560 | 510 | 490 | 54 | **195** | 140 | 66 | 206 | 20 | 56 |

**41pt.** At 11pt DM Sans that is 6 characters per line; `lineLimit(2)` makes it
about 12 characters of title for a running session. The 2026-08-31 fix that
moved the ticker onto its own full-width line worked. 157pt is real, the one healthy
measurement in the row. It did nothing for the title, because
the title is competing with two fixed blocks:

- `providerMark` at `.frame(width: size.length(54))` (`:699`). An icon plus the
  word CLAUDE / CODEX / CURSOR in mono caps. The word is redundant with the icon
  and with the per-provider tint (`providerTint`, `:868`).
- the trailing meta `VStack`, `compactAgeLabel` over `workspace`, the workspace
  capped at `.frame(maxWidth: size.length(66))` (`:603`). Measured 44-66pt.

Those two total **98-120pt of a 178pt label**. Identity chrome outranks content
roughly 3:1.

The meta stack also sets the row's first-line height: it measures 23pt tall
against the title's 14pt, which is why a one-line-title mission row is still
56pt (`root 560` above) rather than 47pt.

## 5. Vertical budget and rows visible

Both lists switch to a fixed-height `ScrollView` past 3 rows. `maxHeight` is
banned here and the reason is in the source: it "collapses under
`sizeThatFits`" (`:740-745`), which shipped once as an empty white capsule.

| list | trigger | frame height (`SessionPet.swift`) | Medium | Small | Large |
|---|---|---|---|---|---|
| `sessionList` | `sessions.count > 3` | `size.length(240)` (`:538`) | 240 | 180 | 300 |
| `completionsList` | `petCompletions.count > 3` | `size.length(160)` (`:799`) | 160 | 120 | 200 |

Measured row heights, and what fits:

| row | Small | Medium | Large | rows in the Medium frame |
|---|---|---|---|---|
| mission (2-line title) | 49 | 61 | 78 | 240 / 62 = **3** |
| completion | 32 | 43 | 56 | 160 / 44 = **3** (+ 28pt of a 4th) |
| section header | ~17 | ~21 | ~26 | costs one third of a row each |

`petSectionHeader` (`:555`) adds `.padding(.top, 7) + .padding(.bottom, 3)`
around an 8pt mono line, so a live list showing all three sections spends ~63pt
of the 240pt frame, a full row, on labels.

## 6. Content the model already has and the card throws away

`PetCompletion` (`Models.swift:924`) stores:

```swift
let id, sessionId, name, provider, workspace: String
let finishedAt: Date
var seen: Bool
```

`completionsList` renders `provider` and `name`. It renders **neither
`workspace` nor `finishedAt`**, and in their place prints the string literal
`"Finished"` (`:758`) on every row. Two forked Claude sessions therefore render
as the same three tokens; `ClaudeSession.ambiguousTitles` (`Models.swift:580`)
exists precisely because forks share a title, and measured 8 duplicate-title
groups across 69 rows on 2026-08-18.

There is no outcome field anywhere in `PetCompletion`. But
`ClaudeSession.discussionSummary` (`Models.swift:535`, parsed from the helper's
`discussion_summary` at `:764`) is already on the session, is already rendered
on running rows through `petLiveLine` (`:690`), and is already in scope inside
`PetCompletionDetector.diff`. The detector builds each `PetCompletion` from
`prior`, the last running snapshot, and simply does not carry the field across
(`Models.swift:1105-1120`).

## 7. Type and color, as shipped

`COSType` (`COSBrand.swift`) registers three bundled faces at process scope:
`Fraunces` (display), `DM Sans` (body), `JetBrains Mono` (mono).

Measured average advance per character:

| face | size | pt/char |
|---|---|---|
| DM Sans | 11 | 6.291 |
| DM Sans | 10 | 5.719 |
| DM Sans | 8 | 4.575 |
| JetBrains Mono bold | 9 | 5.400 |
| JetBrains Mono bold | 8 | 4.800 |

JetBrains Mono measures exactly `0.6 * size`, which confirms
`PetTicker.advanceRatio = 0.6` (`Models.swift:3372`).

`DMSans.ttf` ships a single face. Under CoreText descriptor weighting,
`.regular`, `.medium` and `.semibold` all measure the **same advance width**, so
`COSType.body(_, weight: .semibold)` buys color weight, never a different
character budget. A direction cannot buy room by changing weight.

Palette, real values (`Views.swift:48-89`, `COSMotion.swift:201`):

| token | light | dark | hex used in the artboards |
|---|---|---|---|
| `ink` | 0.12, 0.09, 0.07 | same | `#1F1712` |
| `panel` | cream 0.96, 0.94, 0.90 | espresso 0.09, 0.07, 0.05 | `#F5F0E6` / `#17120D` |
| `card` | white | 0.15, 0.115, 0.085 | `#FFFFFF` / `#261D16` |
| `line` | 0.45, 0.34, 0.16 @ 0.20 | 0.79, 0.66, 0.43 @ 0.16 | `rgba(201,168,110,0.16)` |
| `cream` | 0.96, 0.94, 0.90 | same | `#F5F0E6` |
| `gold` | 0.79, 0.66, 0.43 | same | `#C9A86E` |
| `amber` | 0.79, 0.50, 0.27 | same | `#C98045` |
| `green` | 0.20, 0.58, 0.34 | same | `#339457` |
| `plateInk` | 0.17, 0.13, 0.09 | gold | `#2B2117` / `#C9A86E` |

Provider tints, `SessionPet.swift:868`:

| provider | value | hex |
|---|---|---|
| claude (default) | 0.78, 0.45, 0.22 | `#C77338` |
| codex | 0.10, 0.55, 0.48 | `#1A8C7A` |
| cursor | 0.42, 0.38, 0.86 | `#6B61DB` |

## 8. Constraints any direction inherits

1. **Blur backing on every surface.** Lists take
   `.regularMaterial` in a `RoundedRectangle(cornerRadius: length(12))` plus a
   1pt `COSPalette.line` stroke (`:802-811`); the ledger takes `.thinMaterial`
   in a `Capsule` (`:394`). The stroke is load-bearing: it is what keeps an edge
   when Reduce Transparency flattens the blur.
2. **Hover changes no layout.** `ledgerSlot` (`:342`) is a `ZStack` at a fixed
   `.frame(height: size.length(42))` and the bar cross-fades to the pills inside
   it. `Tests/pet-layout-source-contract.py` asserts `.frame(height:` is present
   and `maxHeight` is absent in that slot.
3. **Fixed `.frame(height:)` on scrolling lists.** `maxHeight` collapses under
   `sizeThatFits`. Asserted for `completionsList` in the same contract file.
4. **No bare `Shape` as an HStack child.** The mission row's state rail is an
   `.overlay(alignment: .leading)` (`:637`) with the comment recording that as
   an HStack child it "greedily absorbed ~800px of blank card."
5. **Nested `Button` never receives the click on macOS.** Both the dismiss
   control and the three completion actions are declared as *siblings* of the
   row button inside `HStack(spacing: 0)` (`:574`, `:773`). Any direction that
   moves a control inside the row's label kills it.
6. **Two `model.petExpanded.toggle()` sites, exactly.** RUNNING pill and the
   sprite double-click. Asserted by count.
7. **`missionRow` and `idleRow` must each contain
   `model.openSessionInPlatform(session)` and `.help("Open in platform")`** in
   their own slice (`Tests/run.sh:2121`). A shared helper that lets one
   occurrence cover both rows fails the contract.
