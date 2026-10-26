# Sessions → Usage

Implementation baseline: Control 0.5.344 (build 398, ce9b71c), server 6.91.1. This feature is local to Control and its bundled helper; it requires no new server endpoint, account credentials, or subscription.

The native Sessions page has a Usage tab with calendar-date windows, custom inclusive dates, All history or month, provider and model filters; provider/model lines or stacked bars; daily/monthly buckets; provider/model/day breakdowns; a disjoint token mix; and API-equivalent value. It uses the current COS typography and palette, including dark mode. Tracking starts when Control runs, backfills in bounded slices, then refreshes every five minutes. Users can pause tracking while retaining history or refresh manually.

## Coverage and storage

- Claude Code: the current user's `~/.claude/projects/**/*.jsonl`, including subagents. Assistant message IDs deduplicate streaming fragments and copied fork history; the largest complete observation wins.
- Codex: `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/**/*.jsonl`. Cumulative counter differences produce events. Initial/resumed/reset records use last-turn usage rather than charging inherited totals. Missing baselines are reported. Provider comes from session metadata; model comes from turn context. Identical timestamp/model/provider/counter observations deduplicate copied history.
- Cursor, browser-only chats, remote Macs and calls without usable token records are not covered. Missing evidence is not displayed as zero usage. Unknown model prices remain unavailable; token counts still contribute.
- One ledger per macOS user: `~/Library/Application Support/COS Control/usage/session-usage-v1.sqlite`. It stores counts, dates, provider/model names, hashed event identities and file checkpoints, not prompts, responses, credentials or full log lines. No usage is uploaded. File mode is 0600 and directory mode is 0700.
- History remains after source logs are deleted or moved. Logs deleted before first collection cannot be backfilled. The ledger pins its reporting time zone on creation, preventing travel from moving existing monthly totals.
- Imports run in the helper, never in text-entry/render callbacks. Passes are bounded to 64 MiB and a 12-second scheduling deadline; each file reads at most 8 MiB. Transactions couple inserted events and checkpoints. The deadline is checked between files. Fair rotation prevents a busy session from starving older history. Partial final lines wait for a file change; a budget-cut row resumes on the next pass without requiring a source write. Oversized rows are skipped incrementally through their newline so later usage remains reachable, and surface coverage gaps along with malformed records.

## Accounting and costs

Input, output, cache-read and cache-write are disjoint. Codex cached input is subtracted from its inclusive input count; reasoning is already included in output. Large totals often reflect repeated cached context processing, not an equally large volume of newly written text.

Costs are **standard API-equivalent value, not actual subscription spend**. A versioned October 25, 2026 rate snapshot is applied to all history. The UI explicitly excludes discounts, speed tiers, tools and taxes. The catalog uses exact documented model IDs and dated aliases; it does not guess prices for unknown families. Anthropic cache writes distinguish five-minute versus one-hour retention when supplied. Codex records with unresolved cache-write or long-context pricing remain unpriced.

Sources: [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing), [OpenAI pricing](https://developers.openai.com/api/docs/pricing). Future price snapshots require explicit migration/revaluation policy; existing ledger values retain the snapshot used when imported.

## Files and verification

- `Sources/SessionUsageCore.swift`: normalized records and rate catalog.
- `HelperSources/SessionUsageCollector.swift`: incremental SQLite collection.
- `Sources/SessionUsageView.swift`: store, filters, charts and coverage UI.
- `HelperSources/main.swift`: `session-usage` and `session-usage --read-only` helper commands.
- `Sources/ControllerModel.swift`, `Sources/ActivityWindow.swift`: lifecycle and Sessions integration.
- `Tests/run-session-usage.sh`: parsing, deduplication, cumulative counters, cache pricing, month boundaries, retained history, partial writes, archive/model changes and unknown-price fixtures.
- `Tests/SessionUsageRender.swift`: offscreen light/dark renders at 800 and 1200 points. Never activates or orders in a window.
- `Tests/SessionUsageCanary.swift`: bounded real-log import with the database restricted to `/tmp`; prints aggregates only. It does not modify source sessions.

Release integration: merged Control 0.5.345 dictation parity QA fixes (4570a8d). Public release version and final QA/signing receipts are recorded separately. Server 6.92.0 is the matching published server. Transcription/cue flags remain unchanged.

## Validation on October 25, 2026

- Swift 6 strict-concurrency full app module compiled with the native render harness (final app receipt `compile.BulW2O`, harness `compile.Krn3AC`). Existing warnings in ControllerModel/SessionPet are unrelated to this feature.
- Usage fixture suite passed, including active/archive deduplication, model changes and incomplete-tail scheduling (`compile.2R7Ljp`).
- Compiled helper command imported an isolated fixture; `--read-only` did not ingest subsequently appended usage.
- Bounded read-only real-log canary read nine local files into a scratch database, with no malformed/unreadable records in that slice. Backfill was intentionally incomplete; its totals are not a complete account/month audit.
- Offscreen 800/1200-point light/dark native renders passed and were visually inspected. The preview uses invented fixture totals, not billing data.
- Desktop safety, shell syntax, integration source assertions and whitespace checks passed. No test activated an app or interrupted the user's desktop.

This is feature validation, not a signed release/install approval. The complete release suite and signed packaging gates remain part of integration into the next Control release.

## 0.5.349 refinements

Token share compares the selected local token records; it is not a provider subscription allowance or percentage of a plan used. Within provider compares each model to all models from its provider in the selected period, even when a single model is filtered. Exclude cache reads changes the token bars, ranking and both share columns; it retains input, output and cache writes and never changes estimated API value.

Last 7 days includes today and the six preceding reporting-zone dates. Last weekend is the most recently completed Saturday/Sunday pair. Hover a daily/monthly bar for its breakdown; click to keep the full breakdown below the chart, or use the keyboard-accessible Inspect period selector and Previous/Next controls. Monthly history spans all recorded months with current provider/model filters; the model table keeps the selected period. Colors stay stable as filters change.

See docs/usage-refinement-349.md for the audit, design rationale and QA scope. No source logs, ledger records or provider pricing were altered by these presentation changes.

## Next-release Usage refinements (October 26, 2026)

- Default to Last 30 days. Last 7/30/90 days include today and the preceding 6/29/89 calendar dates in the ledger reporting timezone. These are calendar-date windows, not rolling elapsed-hour windows. Custom dates include both endpoints; a reversed date range returns no records with an inline correction. Hidden times in date pickers do not invalidate a same-day range. Last weekend and explicit month/history selections remain available.
- Daily and monthly charts now use the same selected date/provider/model rows as every summary and table. Monthly buckets can be partial at selection boundaries. All history plus Monthly reproduces the full historical view.
- Providers are the default chart series, with line markers for observed dates. Model series and stacked bars remain available. Models preserve the existing top-six-plus-other grouping. Lines connect observed dates; missing dates are not filled or claimed as zero use. Unknown-priced provider/model periods are omitted from the API-value plot. Partial points include only priced records, with unknown cost called out in the plot note, hover and detail.
- Provider totals reconcile tokens, selected-token share, deduplicated usage-record counts and API value. Model shares retain their existing period-wide provider denominator. The daily breakdown totals tokens, records and API value for every observed day under the current filters. Hover/keyboard period details add provider totals/shares, pricing-coverage record counts, models and all token categories.
- Token mix exposes uncached input, output, cache read and cache write with shares of the displayed token denominator. Exclude cache reads removes only reads from this mix, charts, table tokens and shares. The top All recorded tokens summary intentionally remains inclusive; API values always retain every priced category. Cache counts are not described as monetary savings.
- Subscription limits and coverage explicitly state that balances/reset times, environments and distinct session counts are unavailable. Usage records are observations after ledger deduplication, not messages or sessions. The daily ledger cannot supply an accurate rolling 24-hour filter. No schema, collector source roots, privacy boundaries or pricing rates changed.

Validation for this change is recorded in `docs/usage-refinement-20261026.md`. The superseded 0.5.349 note above describes that release's historical monthly scope.
