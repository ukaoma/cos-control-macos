# Usage refinement, Control 0.5.349

## Evidence and scope

An all-provider monthly token share is not account allowance consumption. Repeated cache reads can dominate the denominator. A read-only audit found no imported Codex count mismatch; the misleading comparison was raw token share versus subscription usage. Provider quotas cannot be reconstructed from token counts, and missing account-wide evidence must not be shown as zero or estimated as a percentage. The private audit receipts remain local; this document contains no account usage totals.

No collector/schema/rate changes are justified by this audit. Reuse the existing local helper, SQLite ledger, timezone, incremental refresh, exact model IDs and pricing snapshot. The UI must distinguish all recorded tokens, tokens excluding cache reads, estimated API value and subscription allowance.

## Design plan

Keep COS's existing identity. Palette: cream #F5F0E6, espresso #17120D, gold #C9A86E, readable bronze #89662D, subtle text #66635E, white #FFFFFF; use adaptive COSPalette tokens. Charts retain distinct model colors across filtering, with text labels carrying identity. Use existing COSType heading/body families; proportional text and tabular digits for comparisons. No new font or ornamental card grid.

Left-aligned layout:

    [Period] [Provider] [Model]                         [Refresh]
    Recorded tokens     Fresh input / output     Cache reads     API value
    Token share is not subscription allowance. [clear explanation]
    Daily / Monthly history       All tokens / Without cache reads / API value
    | stacked chart, hover guide + period breakdown floating beside pointer |
    Inspect period [date]                  [previous] [next]
    Model + provider     Tokens     Token share     Within provider     API value
    Coverage + local tracking controls

Refine the current screen, not its theme: compact B/M/K totals; explicit share denominators; Last 7 days and Last weekend to compare the timeframe the user describes; a chart tooltip with period, model split, disjoint token categories and unknown-price status; keyboard-accessible period inspection. The tooltip is the single prominent interaction. Preserve reduced motion and avoid automatic animation.

## Review against brief

Rejected a new dashboard skin and a quota-style gauge: neither answers the accounting question, and the gauge would invent billing semantics. The strongest change is a verifiable explanation of the denominator with an alternate cache-free view. All percentages use actual imported counts. Tooltip estimates remain labeled API-equivalent and retain unknown pricing.

## QA scope

Test weekend/month/timezone boundaries, disjoint counts, share denominators across provider/model filters, cache-free totals, period/model aggregation, unknown-price tooltips, deterministic ordering, readable billion totals, and empty selections. Offscreen native render checks at 800/1200pt in both appearances, including the tooltip. No desktop keyboard automation. Combined release remains held for revised ambient art and full release QA.

## Focused validation

- Read-only audit compared available local Codex usage observations to the existing ledger. No imported count mismatches. Newer observations may lag the five-minute importer, and oversized rows remain explicit coverage gaps. This does not prove account-wide coverage.
- Accounting fixtures passed: existing import/dedup/reset/retention cases plus completed-weekend/7-day/timezone boundaries, batch filtering, cache-free counts, synthetic provider-share arithmetic, small nonzero percentages, provider separation, model ranking and unknown-price labeling.
- First offscreen native renders passed at 800/1200 points in light/dark, for month and history. The final pass also exercises the real chart's floating overlay without sending an input event. Pointer state lives only in the chart; relative-period boundaries are calculated once per selection rather than per record.
- Desktop-safety and release-note mutation checks passed. No app activation, keyboard automation, source-log edits, ledger migration or server settings changes.
- Full combined release QA/signing is held until the revised ambient art passes the user's visual review. Focused results are not a public-release completion receipt.

Final app module compile and all 12 offscreen render cases passed (eight full views, two detail cards, two actual chart overlays). The final tooltip layer-order adjustment also passed a focused Swift 6 typecheck against that exact app module. The complete signed release remains a separate gate.
