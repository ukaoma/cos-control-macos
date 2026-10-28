# Settings hub: the reviewed design

Miles, 2026-10-27 23:40 CDT, after reviewing the /design canvas:
"I like the A treatment with B siderail. Can you please build a hybrid. It helps because we have incredibly
long settings pages. We should also review the copy/messaging to ensure it's as concise and clear as possible."

The boards in this folder are the spec. Build to them, not to a re-interpretation.

- `A-meetings-dark.dc.html` and `A-system-light.dc.html`: the **A treatment**. Settings takes the left sidebar
  while it is open: a "‹ Today" back control, the serif "Settings" title, a search field ("Search 253 settings",
  ⌘F), then ten categories, each with an icon, its name and a one-line live status. The content column has
  the category title (serif, large), a one-line description, then groups as cards. Each card has a title and
  rows: label (semibold) plus one-line description on the left, the control on the right. Rarely used rows sit in
  an "Advanced" disclosure at the bottom of their card, with a count.
- `B-one-page-rail.dc.html`: take only the **"On this page" rail** from B (right side). In the hybrid it lists the
  GROUPS of the current category (for Meetings: Recording, Meeting assistant, Live cues, Library and sync,
  Fireflies import). The group in view has the ink colour, semibold weight and an accent left rule; the rest
  have the sub colour and a hairline rule. Clicking a group scrolls to it. It exists because some categories
  are very long.

Not in this build: the B one-page layout itself, and the Ask COS assistant UI (Miles has not picked A or B
for it; the engine in `Sources/SetupAssistant.swift` stays unwired).

Parity source: `docs/settings-hub/SETTINGS_INVENTORY.md` (253 rows, one place each, labels and descriptions).
Copy source: `docs/settings-hub/COPY_DECK.md` (written by the copy pass; it supersedes the inventory's wording
where they differ).
