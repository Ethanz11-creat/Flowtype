# FlowType §12 — JSON → SQLite (GRDB) Migration · Design Spec

> Status: approved-pending. Supersedes PRD §12 where they differ. Scope = full §12 this cycle (core migration + `storeTranscriptText` + export + temp-wav-delete). Out of scope: `editedCharCount`/一次成稿率, cloud sync.

## 1. Goal
Move FlowType's dictation data from two capped JSON files to one local SQLite database (GRDB), with the **session table as the single source of truth** and all statistics **derived** from it through the existing, already-tested pure `StatsEngine`. Remove the arbitrary 500-session / 365-day caps, eliminate the dual-write, and make data robust + privacy-respecting for a production GitHub release.

## 2. Current state (what we migrate from)
- `history.json` = `[DictationSession]` (id, createdAt, rawTranscript, finalText, polishMode, durationMs?, recordingMs?, appName?, appBundleID?, language?), **capped at 500** (`HistoryStore`).
- `daily_stats.json` = `[DailyStats]` daily aggregates (totalDurationMs, totalRecordingMs, totalWordCount, sessionCount, byApp, byLang, hourHistogram), **capped at 365 days** (`DailyStatsStore`).
- Aggregates are **derived from sessions** on every `HistoryStore.append` (dual-write). Both persist via the generic `PersistentStore<T>` (atomic JSON). macOS 15. No DB linked today.
- The pure `StatsEngine.summarize(_ all: [DailyStats], range:now:cal:)` + `denseHeatmap(...)` already do all aggregation (heatmap, 24h, streaks, speed, time-saved) over `[DailyStats]`, using `Calendar`-based local-midnight `dayOrdinal` (DST-safe). **This engine is preserved unchanged.**

## 3. Architecture
```
recording done ─► INSERT one `session` row  (the ONLY write path)
                       │
        ┌──────────────┴───────────────┐
        ▼                               ▼
  History page                   StatsRepository
  (reads `session`,        (session rows ── fold by local day ──► [DailyStats]
   uncapped)                ∪ daily_legacy rows)            │
                                                            ▼
                                              StatsEngine (UNCHANGED) ─► Overview
```
- **GRDB** (one SPM dependency), DB file `~/Library/Application Support/FlowType/flowtype.sqlite` in WAL mode.
- New thin **`StatsRepository`** turns the DB into `[DailyStats]` and feeds the existing `StatsEngine`. `StatsEngine`'s signature, logic, and self-tests do not change.
- `HistoryStore` / `DailyStatsStore` are replaced by DB-backed stores; the daily-aggregate JSON dual-write is gone.

## 4. Schema
### 4.1 `session` (forward source of truth; **no row cap**)
| column | type | notes |
|---|---|---|
| `id` | TEXT PK | UUID |
| `startedAt` | REAL | **Unix seconds** (matches SQLite `unixepoch`) |
| `recordingMs` | INTEGER | pure recording (松手即停) — **the speed/总时长 denominator** |
| `durationMs` | INTEGER | legacy end-to-end wall clock — storage only, **never** in speed |
| `charCount` | INTEGER | trimmed char count, computed at insert — **stored**, so nulling text never loses it |
| `language` | TEXT? | "zh"/"en"/"mixed" (CJK heuristic), computed at insert |
| `appName` | TEXT? | target app |
| `appBundleID` | TEXT? | target app bundle id |
| `polishMode` | TEXT | "raw"/"polish" |
| `sttBackend` | TEXT | **new** — "qwen" / "apple" / "legacy" (migrated old rows = "legacy") |
| `rawTranscript` | TEXT? | nullable — gated by `storeTranscriptText` / cleared by 清空历史 |
| `finalText` | TEXT? | nullable — same gating |

Index on `startedAt`. **All stat inputs (`startedAt`, `recordingMs`, `durationMs`, `charCount`, `language`, `appName`) are columns independent of the transcript text**, so erasing `rawTranscript`/`finalText` never affects statistics.

### 4.2 `daily_legacy` (frozen pre-migration snapshot; read-only)
Exact copy of `daily_stats.json` at migration time: `date TEXT PK, totalDurationMs INT, totalRecordingMs INT, totalWordCount INT, sessionCount INT, byApp TEXT(JSON), byLang TEXT(JSON), hourHistogram TEXT(JSON)`. Preserves old days' chars / active-days / streaks / per-app / 24h losslessly even though their individual sessions were truncated by the old 500-cap.

### 4.3 `meta`
Key/value: `migrationDate` (the local calendar day migration ran), `schemaVersion`.

## 5. Migration (one-time, idempotent, atomic, reversible)
On launch, if the DB file does not exist (or `meta.schemaVersion` absent):
1. Open DB, create tables in one transaction.
2. Read `history.json` → INSERT every session into `session` (old rows `sttBackend="legacy"`; `charCount` recomputed from `finalText`; `recordingMs`/`durationMs` carried; text columns kept).
3. Read `daily_stats.json` → INSERT every day into `daily_legacy` verbatim.
4. Write `meta.migrationDate = today` (local), `schemaVersion = 1`.
5. Commit. On success, **rename** `history.json` → `history.json.bak` and `daily_stats.json` → `daily_stats.json.bak` (do **not** delete — recovery safety).
6. Any failure → roll back the transaction, leave JSON untouched, log, retry on next launch (no half state).

### 5.1 Stat boundary rule (no double-count, no loss) — ratifies (a)
`StatsRepository` builds `[DailyStats]` as:
- **`date < migrationDate`** → take the row from `daily_legacy` (frozen historical truth).
- **`date >= migrationDate`** → aggregate from the `session` table (live).

`migrationDate` (today) and onward come **only** from `session`; `daily_legacy` strictly excludes today. Today's earlier-than-migration sessions are all present in `session` because `history.json`'s 500-cap only truncates **old** sessions — recent days (incl. today) are complete. Therefore the two sources never overlap → no day is counted twice and none is lost. Migrated old sessions still live in `session` for History browsing but do **not** feed stats for pre-migration days (those come from `daily_legacy`).

## 6. StatsRepository (DB → `[DailyStats]`)
- Loads the stat columns of `session` rows (not transcripts) and **folds them into `[DailyStats]` in Swift using the existing `Calendar` local-midnight `dayOrdinal`** — reusing the tested, DST/timezone-safe bucketing and keeping a single source of day-grouping truth. (Equivalent SQL would be `date(startedAt,'unixepoch','localtime')`; UTC default is forbidden — **Tech-1**.) Per-day it accumulates `totalRecordingMs`, `totalDurationMs`, `totalWordCount=ΣcharCount`, `sessionCount`, `byApp`, `byLang`, `hourHistogram[localHour]`.
- Merges with `daily_legacy` rows per §5.1, producing the same `[DailyStats]` shape `StatsEngine` already consumes.
- `StatsEngine` then computes speed/time-saved with `recordingMs` as the denominator (its existing `denomMs = recMs>0 ? recMs : durMs` logic) — **Tech-2**; `durationMs` never enters speed.
- Exposed through an `@MainActor ObservableObject` that **preserves today's `DailyStatsStore.shared.stats: [DailyStats]` read API** (now derived from the DB and recomputed on change; the old `recordSession` write method is removed). `OverviewPage`/`HeroSection`/`AchievementsSection` keep calling `StatsEngine.summarize(store.stats, …)` **unchanged**.

## 7. Session writes & History
- A finished dictation INSERTs exactly one `session` row (no dual-write). `sttBackend` recorded from which provider produced the final text (Qwen vs Apple fallback).
- A DB-backed session store **preserves the `HistoryStore.shared.sessions` read API** (internals now query the DB) and publishes recent sessions for the History page, now **uncapped** (paged/lazy load if large; default newest-first). The History view needs no changes.

## 8. Privacy & destructive actions — ratifies (c)
Two clearly separated actions:
- **「清空历史」(privacy, default-safe):** `UPDATE session SET rawTranscript=NULL, finalText=NULL` for all rows — erases *what was said* but **keeps every metadata row**, so active-days / streaks / 字数 / heatmap all survive. This is the same shape as `storeTranscriptText`, applied retroactively. History page shows such rows as "(文本已清除)" with their timestamp/app/charCount intact.
- **「重置统计」(destruction):** `DELETE FROM session; DELETE FROM daily_legacy;` behind a **strong double-confirm**. This is the only path that zeroes achievements/streaks/heatmap. Visually and textually distinct from 清空历史.
- **`storeTranscriptText` setting** (default **on**): when **off**, new sessions INSERT with `NULL` text from the start; all stat columns are still written, so statistics are unaffected. Toggling off affects future sessions; purging existing text is the explicit 清空历史 action.

## 9. Export
History page gains **导出**:
- **JSON** — full session records (all columns, including text when present).
- **CSV** — flat columns `startedAt,appName,language,charCount,recordingMs,sttBackend,finalText` with correct RFC-4180 escaping (quote fields containing comma/quote/newline; double internal quotes). Empty text when cleared/withheld.
Save via `NSSavePanel`. The existing clear behavior is replaced by the two §8 actions.

## 10. Temp-wav defer-delete (orthogonal correctness fix)
`AppleSpeechProvider`'s temporary `.wav` is deleted on **every** exit path — success, failure, and cancellation — via `defer`/guaranteed cleanup, so audio never persists on disk. Independent of the DB layer.

## 11. Error handling
- DB fails to open → log via `AppLogger`, fall back to an **empty read-only** in-memory state (UI shows empty stats), never crash.
- Migration failure → transaction rollback, JSON preserved, retried next launch.
- Write failures (INSERT) → logged, non-fatal; the dictation result is still injected (stats are best-effort, never block the user).

## 12. Testing (custom in-target self-test runner; GRDB in-memory DB)
1. **Migration idempotency** — running migration twice yields one consistent dataset; second run is a no-op.
2. **Boundary no-double-count** — sessions on/after `migrationDate` + `daily_legacy` before it produce per-day totals with no overlap; today counted once from sessions.
3. **StatsRepository ≡ StatsEngine equivalence** — synthetic sessions folded by `StatsRepository` produce a `[DailyStats]` that yields the same `StatsSummary`/heatmap as feeding a hand-built `[DailyStats]` to the unchanged `StatsEngine`.
4. **Local-day bucketing** — folding uses an injected `Calendar`/timezone; sessions near local midnight bucket to the correct local day (no UTC drift).
5. **Privacy-off / clear-history** — with `storeTranscriptText=off` (and after 清空历史) text columns are NULL but `charCount`/dates/streaks are unchanged vs the text-present case.
6. **Speed denominator** — speed/time-saved computed from `recordingMs`; a row with large `durationMs` but small `recordingMs` does not depress speed.
7. **CSV escaping** — fields with comma/quote/newline round-trip correctly.

## 13. Acceptance
1. Fresh install with existing JSON migrates losslessly; `*.json.bak` left behind; Overview numbers identical pre/post migration.
2. Heavy-user case (old aggregate-only days) keeps full heatmap/streak history via `daily_legacy`.
3. New dictations persist to the DB only; History uncapped; no `daily_stats.json` dual-write.
4. 清空历史 erases transcripts but preserves all stats/streaks; 重置统计 (double-confirmed) clears everything.
5. `storeTranscriptText=off` stores no transcript yet stats still accrue.
6. Export produces valid JSON and well-escaped CSV.
7. AppleSpeech temp `.wav` is gone after success/failure/cancel.
8. Heatmap/streaks align to local-timezone natural days; speed lands in a realistic range (recordingMs denominator).
9. All existing self-tests stay green; new DB self-tests pass.

## 14. Out of scope (YAGNI)
`editedCharCount`/一次成稿率 (deferred earlier); cloud / iCloud sync (future opt-in).
