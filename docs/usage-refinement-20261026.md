# Usage refinement contract — October 26, 2026

Base: shipped Control 0.5.349 build 403, `03b10362a5fb542ff62445f357eecbd1380772b6`. This work changes Usage presentation and pure presentation math only. It does not change the collector schema, source logs, pricing, server, flags, version or installed app.

## Data contract

The current ledger retains day, provider, model, disjoint token counts, deduplicated usage observations and priced/unpriced API estimates. Every date filter uses the pinned ledger timezone. Calendar 7/30/90-day selections include today. Custom selection includes both endpoint dates, ignores picker times within the same day and rejects reversed dates. Monthly charts aggregate the selected rows; boundary months may be partial.

Usage records are not sessions or messages. No timestamp-granular rolling 24-hour count, environment filter, plan utilization, reset time, cache savings or unknown-price estimate is inferred from absent data. Supported-log coverage stays local to this Mac.

Provider lines are the default; users can select model series or stacked bars. Points represent observed dates without zero-filling. Unpriced periods are omitted from API-value marks and partial values retain explicit unknown-cost labeling. Hover, click and the keyboard period selector expose provider/model/token and pricing-coverage detail.

Provider totals, model selection shares, daily totals and token mix all use the current date/provider/model selection. Within-provider model shares intentionally retain the full provider's models in that date selection. Cache-read exclusion changes chart tokens, ranking, mix and shares; it retains cache writes. The All recorded tokens summary remains inclusive and every API estimate includes all priced categories.

## Design

Keep COS's cream/espresso/gold palette and existing type/control system. Place scope and metric distinctions before the chart, then provider totals, token categories, model ranking and an expandable daily list. Preserve offscreen-only renders and keyboard-accessible chart inspection. The expanded limits/coverage note identifies which requested dimensions the ledger cannot answer.

## Verification

- Focused Swift 6 strict-concurrency fixture suite: passed with the bounded compiler, receipt `/Users/ukaoma/cos-release-candidates/usage-refinements-20261026/native/compile.LYhz8T` (3.779 s execution; 190,480,384 bytes peak owned RSS; zero swap growth).
- Fourteen new behavioral assertions cover 30/90-day calendar boundaries, fall DST, leap February, inclusive custom endpoints, reversed/missing custom dates, same-day hidden picker times, provider/day aggregation, partial/unknown pricing and token-mix reconciliation. Existing parsing, copied-history deduplication, retained history, partial append, oversized rows, model switches, cache accounting and timezone fixtures remain green.
- Full 54-source app kit and native offscreen harness passed Swift 6 strict-concurrency / macOS 14 qualification. App receipt `native/compile.aQGtQq`: 256.346 s, 937,541,632 bytes peak owned RSS, 14,313,553,920 bytes minimum available memory, zero swap growth. Harness receipt `native/compile.FdWJb6`: 1.553 s. Existing ControllerModel and SessionPet warnings are unrelated.
- Render evidence: `/Users/ukaoma/cos-release-candidates/usage-refinements-20261026/renders` contains 22 fixture PNGs: 30-day/default, 90-day, custom with inspected day and All history with inspected month at 800/1200 points, light/dark; compact detail and actual hover overlays for both lines and bars. Reviewed wide light default, narrow dark custom/inspector, narrow light monthly history and actual light line hover. Controls, provider/token/model rows and detail text fit; narrow API summary wraps without clipping.
- No CUA, focus/input automation, app activation, installation or restart was used. The render harness retains prohibited activation policy and offscreen windows. No new interactive pointer-event automation or native cost-mode screenshot was run; cost coverage and unknown pricing are asserted in the focused suite, with existing chart access paths retained.
- Whitespace checks: passed before native qualification.

The root integration session owns final regression, release versioning, signing, publishing and installation. These checks alone do not qualify a public release.
