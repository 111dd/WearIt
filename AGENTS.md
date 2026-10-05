# WearIt: shared notes for AI assistants

This file is the single source of truth shared by every AI tool working on WearIt
(Claude Code, Cursor, Codex, Copilot, etc.). Read it first, then skim the newest entries
in `docs/LEARNINGS.md` that touch the files you are about to change. When you finish
a piece of work, add a line to the **Progress log**, update **Next steps**, and append a
short entry to `docs/LEARNINGS.md` (format at the bottom of this file).
`CLAUDE.md` and `.cursor/rules/` just point here, so edit this file, not those.

## Hard constraints

- **Never run a build or the simulator.** The owner runs Xcode. Do not use `xcodebuild`,
  `simctl`, or launch the app.
- **Never commit unless asked.** Never push unless asked.
- **Never commit secrets.** `Config/Secrets.xcconfig` is gitignored. Edit
  `Config/Secrets.example.xcconfig` only.
- Prefer the smallest change that matches existing patterns. No drive-by refactors.

## Owner preferences

- The owner is Dor (GitHub `111dd`). Conversations are often in Hebrew; code,
  comments and commit messages are in English.
- The app works and is used daily. Do **not** run the test suite or "verify" things
  by default; build/test only when the owner asks.
- Develop together with the owner: propose, then implement what they choose.
- Keep changes focused. Big refactors only when asked.

## What the app is

WearIt is an iOS app (SwiftUI + SwiftData, synced through CloudKit) that plans what to
wear. The user photographs their wardrobe, and the app suggests daily outfits based on
the weather forecast, calendar events, wear history and learned taste, and lets them
plan a week ahead, log what they actually wore, and give feedback that trains the
recommender. UI languages: English and Hebrew (RTL).

Tabs (`WearIt/RootView.swift`):
1. **Outfits** (`OutfitPlannerView`): multi-day planner, day + optional evening look,
   slots, locking, drag and drop, replace/confirm/not worn, AI look explanations.
   Profile and Stats open from its toolbar; Settings opens from Profile.
2. **Calendar** (`CalendarLookView` + `UI/Calendar/*`): date strip (week/month),
   `DayJournalCard`, `DayLookEditorSheet`. Shares DayPlan data with the planner.
3. **Wardrobe** (`WardrobeView`): grid with filters, edit item (`EditGarmentView`).
4. **Add** (`AddGarmentView`): photo → crop/cutout → details; barcode / QR / product
   URL / clothing-label scan to auto-fill fields.

Also: a home-screen widget (`WearItWidget/`) showing today's outfit with a "confirm
worn" App Intent, App Shortcuts (`WearItAppIntents.swift`), local notifications.

## Tech facts

- Deployment target iOS 18.5, Swift 5 mode. FoundationModels (on-device LLM) code
  is gated with `#if canImport(FoundationModels)` + `@available(iOS 26, *)`.
- Bundle id `com.dordavid.WearIt`; CloudKit container `iCloud.com.dordavid.WearIt`;
  app group `group.com.dordavid.WearIt` (widget snapshot + commands via shared defaults).
- Store: `Application Support/WearIt.store`, schema listed in
  `Services/AppBootstrapper.swift`. Launch: `WearItApp` → `AppBootstrapper` (container)
  → `BootstrapView` (seed, migrations, weather, deferred work) → `RootView`.
- Secrets: `Config/Secrets.xcconfig` (git-ignored, copy from `Secrets.example.xcconfig`).
  Only `BARCODE_LOOKUP_API_KEY` today; the app degrades gracefully without it.
  API keys come from build settings (`$(BARCODE_LOOKUP_API_KEY)`), never hardcoded.
- Calendar: `CalendarEventUnderstanding.classify` (pure, tested) → `CalendarContextService.build`
  → `DayCalendarContext` with separate day / evening occasions. Use `occasion(isEvening:workDressCode:)`
  and `formalityBump(isEvening:workDressCode:)`, never the headline `occasionKind`, for a look.
- Weather: WeatherKit (`ForecastService`) plus Open-Meteo (`WeatherService`),
  shared state in `WeatherCenter`.
- Images are files under `Documents/WearItImages` (`ImageStore`: disk + downsample +
  cache), synced separately by `CloudKitImageSyncService`. `Garment.imageData` is legacy.
- No CI, no third-party packages (Mantis cropper has a stub fallback).

## Architecture facts

- Outfit identity lives on `DayPlan` **slots** (`slotAssignments` / `eveningSlotAssignments`),
  not only flat garment ID arrays. Calendar and planner must write the same way.
- Wear status is unified via `DayPlan.applyDayLookWearStatus` / `resolvedDayLookWearStatus`.
- Do not decode full-res images on the main thread or apply live SwiftUI `.blur` to wallpapers.
- Startup: `BootstrapView` + `DataMigrationService`. Do not mount `AppGateView` until
  `loadState == .ready`. Critical work is gated by UserDefaults versions; deferred backfills
  use predicates, not full-table scans.
- Planner repeats are a user toggle (`planner.allowRepeatedItems`, default on). Evening wear
  is a separate `WearEvent` source: `.plannerEvening`.
- `WearHistoryService.timesWorn` is distinct wear-days. A failed event fetch must not insert
  a duplicate.
- On-device image understanding (`GarmentImageUnderstandingService`) is iOS 27+ vision, no
  Cloud Compute. It takes a file URL, never a live SwiftData object.

## Code map

| Folder | What lives there |
|---|---|
| `Models/` | SwiftData `@Model`s: `Garment`, `DayPlan` (+ `DayPlanService`), `WearEvent`, `RecommendationEvent`, `UserProfile`, `TasteProfile`, `NotificationPreferences`, `Brand`, `Outfit`, `DailyLook`. Taxonomy enums in `GarmentTypes.swift`; per-type defaults in `ItemTypeDefaults.swift`. |
| `Logic/` | Recommendation: `AIRecommender` (online logistic model + heuristics, `RecoState` weights per profile, `FeatureSpace`), `TemperatureComfort` + `GarmentThermalProfile`, `TasteAffinity`, `CombinationAffinity`, `OutfitComposer`, `OutfitChangeAdvisor`, `WardrobeGapAnalyzer`. `Recommender.swift` (root) is the rule-based fallback. |
| `Services/` | Weather, calendar context (incl. Hebrew/Jewish holiday rules), notifications, CloudKit monitor/image sync, migrations, widget snapshot, auth (Sign in with Apple + keychain), product enrichment (`BarcodeLookupService`, `ProductPageMetadataService`, `DigimarcProductIDService`, `LabelScanService`, `ProductFieldMapper`, `GarmentEnrichmentService`), `LookExplanationService` (FoundationModels). |
| `Services/imgML`, `ImageProcessing/`, `AI/` | Vision-based classification, color extraction, background cutout. `AI/ClassificationService` and `AI/SegmentationService` are placeholders for `.mlmodel` files that were never added. |
| `UI/` | Design system (`DesignSystem.swift` = `DS` tokens, `GlassKit.swift` liquid-glass), backdrop presets, shared components. |
| `Views/` | Screens. `OutfitView.swift` is legacy (not in the tab bar). `ContentView.swift` is an old list view. |
| `WearItTests/` | Swift Testing (`@Test`) unit tests. |
| `docs/` | `LEARNINGS.md`: newest-first pitfalls and lessons written by agents, for agents. |

## Conventions and gotchas

- **CloudKit-safe models**: every new `@Model` property must be optional or have a
  default; no `@Attribute(.unique)`; no non-optional relationships. Additive changes
  need no migration step (see the note at the top of `DataMigrationService`).
- **Save debouncing**: each `context.save()` triggers a CloudKit push. The planner
  debounces `persistDayPlan` (pass `immediate: true` for confirm actions) and flushes on
  background. Don't add save-per-keystroke code. See `Docs/BatteryCloudKitAuditReport.md`.
- **Localization**: every user-facing string goes through `String(localized:)` /
  `LocalizedStringKey` with keys added to **both** `en.lproj` and `he.lproj`
  `Localizable.strings`. Check RTL for anything with direction (swipes, arrows).
- **Wear status**: read and write it through `LookWearStatus` on `DayPlan`, not raw
  `wasWornConfirmed`. Calendar and planner share slot assignments via `setSlotAssignments`.
- **Thermal**: warmth/breathability are derived (`GarmentThermalProfile`); user
  corrections live in `thermalWarmthOverride` / `thermalBreathabilityOverride`.
- **Enrichment provenance**: fields auto-filled by AI/defaults are tracked in
  `Garment.aiEnrichedFieldsRaw`; a manual edit removes the key.
- **Product text → taxonomy** always goes through `ProductFieldMapper`.
- **RecoState features**: append new features at the end of `FeatureSpace` so old
  weights migrate by zero-padding, and bump `RecoState.version`.
- Widget types (`TodaySnapshot`, `WidgetCommand`) are duplicated in
  `WearItWidget/WidgetShared.swift` and `Services/Widget*`; keep both in sync.
- `OutfitPlannerView.swift` is ~4.7k lines; use its `// MARK:` sections to navigate.

## Progress log

Newest first. One line per meaningful change: date, tool, what.

- 2026-10-05 · Claude Code · "Right for" per item: `Logic/GarmentOccasionProfile` scores everyday / work /
  evening out / formal / workouts / outdoors / home from the item (formality, type, style, tags) and from
  calendar-tagged wear; user answers in `Garment.occasionFitsRaw` / `occasionNotFitsRaw` (work and
  workouts sync the `.work` / `.gym` tags). Chips replace the two toggles in `EditGarmentView`; the
  wardrobe asks "you often wear X for work, mark it?"; `AIRecommender.situationFit` uses it.

- 2026-10-05 · Claude Code · Ask when in doubt: one planner question a day inside the day card, either
  "short + jacket / long / short?" on in-between days (`Logic/ComfortPreferences`, learns the user's
  short-sleeve and jacket temperatures and asks less) or "what is this event?" for unreadable events
  (answers become `CalendarEventCorrections`). `Garment.sleeveLengthRaw` + `sleeveLength` (derived from
  type, asked once in the wardrobe for shirts/blouses, editable on the item).

- 2026-10-05 · Claude Code · Occasion memory: confirmed looks are tagged with their calendar occasion
  (`WearEvent.occasionRaw`, filled after the fact by `Services/OccasionMemory`, incl. 180 days of
  history), `Logic/OccasionStyleProfile` learns the user's own look per occasion; from 3 looks it
  nudges item scores and the formality target and fades the occasion rules; "Your usual style for…" reason.

- 2026-10-05 · Claude Code · Calendar understanding: word-based Hebrew/English event engine
  (`Logic/CalendarEventUnderstanding`, prefixes/construct forms, weighted keywords, user corrections
  from the planner's event line), day vs evening split in `DayCalendarContext`, a workout after other
  plans is a "pack gym clothes" reminder with a `GymKit` instead of a sporty day, work days follow
  `UserProfile.workDressCode` (asked once by a planner card, editable in Settings), connect-calendar
  card, re-plan on EventKit changes, Hebrew holiday-eve month numbers fixed, gym/work toggles on items.

- 2026-10-05 · Claude Code · Style Swipe polish: opaque full-screen layer of its own (no app
  backdrop, nothing behind takes taps), bigger "worn" flat-lay card on a light studio surface with
  a palette/silhouette footer and color swatches, deck mixes the model's looks with random closet
  combinations and picks for palette/silhouette variety. Deck-size constants are `nonisolated`.

- 2026-10-05 · Claude Code · Smarter recommendations (plans in the project's `plans/` folder):
  pairwise learning from swaps/picks/calendar corrections, locks as soft positives, choice-based
  taste, weekday/weekend formality features (RecoState v5); Look DNA (`Logic/LookDNA`,
  `ColorHarmony`) and whole-look ranking (`AIRecommender.rankLooks`, used by `suggestOutfit`);
  Style Swipe (`Views/StyleSwipe`, planner entry card + profile row, `StyleInsights`); "More like
  this" / "Something different" in the day ⋯ menu; "Your formulas" on the profile; on-device
  visual similarity (`Services/GarmentVisualSimilarity`, Vision feature prints, local cache).

- 2026-10-05 · Claude Code · Day card header: forecast (and rain %) plus the dress-relevant
  calendar event are plain subtitle lines under the day title instead of a glass chip; ⋯ is a plain
  glyph; the card glass gets a light `systemBackground` tint so text stays readable on any backdrop.
- 2026-10-05 · Claude Code · Look card gestures fixed: swipe-to-replace now uses a UIKit pan
  (`UI/HorizontalSwipeGesture`) that fails on vertical movement; tile double-tap removed so a tap
  opens quick swaps instantly; "Love" moved to the day ⋯ menu (plus the reaction strip / status mark).
- 2026-10-05 · Claude Code · Flowing look card (`UI/OutfitLookRow`): today/past shows one
  "Did you wear it?" ✓/✕ line, future shows no buttons ("I'll wear this" moved to the day ⋯ menu),
  a corner status mark holds undo + fine-tune, a one-time 😍🥶🥵👎 strip after "worn". Gestures:
  swipe a look to replace, double-tap a tile to love, tap a tile for an inline quick-swap strip
  (locked/linked tiles still open the item sheet). One-time gesture hint on the first look.
- 2026-10-05 · Claude Code · "Why this look?" works everywhere: `Logic/LookReasonBuilder` gives
  concrete localized reasons (rain-ready, evening layer, occasion, favorite, rotation, proven pair,
  favorite color, temp range). Collapsed card line shows the top reason; details list them under
  the AI summary. Builds on the Liquid Glass control bar from the look-card branch.
- 2026-10-05 · Claude Code · Merged the `claude/project-thread-k0ji4x` branch (wardrobe gaps,
  this file) into `main`; folded the earlier short agent brief (hard constraints, architecture
  facts, `docs/LEARNINGS.md` workflow) into this file.
- 2026-10-04 · Claude Code · Wardrobe gaps: `Logic/WardrobeGapAnalyzer` (rain/cold/heat/formal/
  workhorse/missing-core rules with evidence + taste-shaped suggestion), shown in Stats via
  `Views/Components/WardrobeGapsSection` (search link, 60-day dismiss). Planner "suggest better"
  swaps now log a `.replaced` RecommendationEvent (implicit signal, saved with the debounced persist).
- 2026-10-04 · Claude Code · Created this AGENTS.md (app map, conventions, backlog).
- 2026-09-16 · Claude Code · Faster launch: `DataMigrationService` gates critical work by
  UserDefaults versions and uses predicates for deferred backfills; planner speedups.
- 2026-09-15 · Cursor · Garment enrichment (barcode/QR/URL/label), thermal comfort,
  planner variety + confirm/not-worn/replace, AI look explanations, Settings split from
  Profile; calendar tab redesigned around a single day card; secrets moved to xcconfig.
- 2026-07-10 · Taste affinity, calendar context, UI polish across wardrobe and outfits.
- 2026-07-09 · App shortcuts and recommendation feedback.
- 2026-02 · CloudKit sync, notification scheduling and categories.
- 2025-12 · On-device ML (classification, color extraction, cutout).
- 2025-09-05 · Initial commit.

## Next steps (backlog)

Ideas, not commitments. The owner picks what to do next.

Agreed direction (2026-10-04): understand the user better with low-effort, on-device signals,
and recommend from that. Order: wardrobe gaps → smarter stats → trip packing list.

- User understanding: feed implicit signals (`.replaced`, not-worn looks, dismissed outfits,
  feedback kinds) into `TasteAffinityBuilder` as soft negatives; today taste uses only
  love/wear/favorite on garments.
- Smarter micro-questions: extend `MicroQuestionCard` beyond brand, max one per day, picking
  the question with the most information (e.g. "you often say too cold, do you run cold?",
  "never worn, still love it?").
- On-device AI (FoundationModels, iOS 26, already used by `LookExplanationService`): weekly
  cached "style portrait" and natural-language gap explanations. No server, no per-tap calls.
- Smarter stats: optional purchase price → cost per wear; owned vs actually worn per
  category/style; items to donate; too-cold/too-warm trends; most swapped-out items.
- Trip packing list: dates + destination forecast → planned looks.
- Split `OutfitPlannerView.swift` into smaller files (variety, persistence, drag & drop).
- Replace or remove the `.mlmodel` placeholders in `AI/`.
- Remove legacy `OutfitView` / `ContentView` if confirmed unused.

## When you finish a task

Append to `docs/LEARNINGS.md` (newest first):

```
## YYYY-MM-DD — one-line title
- **Did:** what changed
- **Why:** the actual problem
- **Watch:** pitfall the next agent will hit
```

Update the standing sections of this file only when a rule or fact changes, not for every feature.
