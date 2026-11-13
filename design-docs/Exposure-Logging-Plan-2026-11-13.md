# Exposure logging plan (stage 1a) — 2026-11-13

Status: plan for Dor to approve. Nothing is implemented. No build, tests or simulator.
Parent: `design-docs/Personal-Recommender-Proposal-2026-11-13.md`, stage 1, split in two.
This is part 1a: record what was shown. Part 1b (rotation) changes behavior and comes after.

## Goal

Know which looks the app actually showed, so that repetition can be measured now and
penalized later. Part 1a changes no recommendation. The same looks appear as today.

Done means: after a week of normal use, the quality report prints how often the same
item, top+bottom pair and core look were shown within 3, 7 and 14 days.

## What the code does today (checked in source)

- Feedback is stored as `RecommendationEvent` (`Models/RecommendationEvent.swift`). It is
  written only when the user reacts, so there is no record of looks shown and ignored.
- Its deduplication key is `v2|plan|kind|garments`. Look time is missing, so the same
  garments with the same reaction on day and evening of one plan collide.
- Looks are produced in `OutfitPlannerView.swift` through `rankLooks` / `suggestOutfit`
  (around lines 4072, 4081, 5430, 5485, 5530, 5809) and saved by `persistDayPlan`.
- `DayPlan` stores slot assignments but not whether a look was generated or hand-made.
- The widget gets a prepared snapshot (`WidgetSnapshotStore`). Preparing it is not a display.

## Design

### 1. One record per look actually seen

`LookExposure`, a small `Codable`, `Sendable` value:

| Field | Purpose |
|---|---|
| `id`, `firstShownAt` | Identity and time |
| `profileID`, `dayPlanID`, `plannedDay`, `lookTime` | Which look slot it filled |
| `slots: [String: UUID]` | Exact slot assignments |
| `lookKey` | Stable key of the core pieces (one-piece or top+bottom, shoes, outer), for repeat counts |
| `origin` | `generated`, `refreshed`, `slotSwap`, `manual`, `restored` |
| `surface` | `planner` or `calendar` (widget is not recorded in 1a) |
| `temperatureC`, `wasRaining`, `desiredFormality` | Compact context, no calendar titles or locations |
| `modelVersion` | So later versions can be compared |

One record per profile + planned day + look time + `lookKey` + surface. Showing the same
look again that day writes nothing. A different look for the same day is a new record.

### 2. When a look counts as shown

The day card is on screen, the app is active, and it stays visible for about 1.5 seconds.
Background ranking, hidden alternatives, shopping previews and widget timeline preparation
never count. Hand-made looks are recorded too, with `origin = manual`: they matter for
rotation, but are excluded from any acceptance rate.

### 3. Storage: a local file, not SwiftData (recommended)

An `ExposureLog` actor keeps the records in a JSON file in Application Support, loaded once,
written off the main actor with a debounce and on background.

- A field added to a CloudKit-synced model cannot be removed later. This record is new and
  will change, so it should not enter the synced schema yet.
- No `context.save()`, so no CloudKit push per display (see the save-debouncing rule).
- Cost: history does not follow the user to another device or a reinstall. For a 14-day
  rotation window that is acceptable. It can be promoted to a synced model once stable.

Retention: keep 180 days, drop older records on load. Expected size is a few hundred records.

### 4. Link feedback to the exposure

Add one optional field to `RecommendationEvent`: `exposureID: UUID?`. This is the only
synced-schema change. New events get key `v3|plan|lookTime|kind|garments`. For day looks the
old `v2` key is also checked, so existing feedback is not recorded twice.

### 5. Summaries as pure functions

`ExposureSummary.build(records, now)` returns item, pair and look counts for 3/7/14 days.
Part 1b will read the same summary for its rotation penalty. Unit tests cover `lookKey`
(slot order, one-piece vs separates, accessories ignored), de-duplication, retention and counts.

### 6. Export, deletion, report

- `AccountDataService.makeExportArchive`: add `lookExposures`, bump `schemaVersion` to 3.
- `AccountDataService.deleteStoredData`: delete the file and reset the actor.
- `scripts/recommendation_quality_report.py`: print the repeat table when exposures exist.

## Delivery: two small PRs

1. **Log and tests.** `LookExposure`, `ExposureLog`, `ExposureSummary`, unit tests, export and
   deletion. Nothing calls it yet, so the app behaves exactly as before.
2. **Wire-up.** Planner and calendar visibility hook, origin tagging at the six generation
   call sites, `exposureID` + `v3` key on feedback, report script.

## To confirm while implementing

- Where day-card visibility is known. `OutfitPlannerView.swift` around line 2167 already
  gates on "expanded and scene active"; the hook should reuse it rather than add a timer.
- How each of the six generation call sites maps to an `origin`.
- Whether the calendar day editor shows suggested looks or only saved ones.

## Decisions for Dor

1. Storage: local file (recommended) or a synced SwiftData model.
2. Fix the day/evening feedback key collision in PR 2 (recommended) or leave it.
3. Dwell time before a look counts: 1.5 seconds (recommended) or immediately.

## Owner checks after each PR

- PR 1: build, run `ExposureSummaryTests` and `ExposureLogTests`, export data and see an
  empty `lookExposures` list, delete account data and confirm the file is gone.
- PR 2: open the planner, scroll through days, refresh one look, swap one piece; export and
  confirm one record per distinct look seen, none for days never scrolled to.
