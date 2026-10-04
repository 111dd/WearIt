# WearIt: shared notes for AI assistants

This file is the single source of truth shared by every AI tool working on WearIt
(Claude Code, Cursor, Codex, Copilot, etc.). Read it before starting. When you finish
a piece of work, add a line to the **Progress log** and update **Next steps**.
`CLAUDE.md` and `.cursor/rules/` just point here, so edit this file, not those.

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
- Weather: WeatherKit (`ForecastService`) plus Open-Meteo (`WeatherService`),
  shared state in `WeatherCenter`.
- Images are files under `Documents/WearItImages` (`ImageStore`), synced separately
  by `CloudKitImageSyncService`. `Garment.imageData` is legacy.
- No CI, no third-party packages (Mantis cropper has a stub fallback).

## Code map

| Folder | What lives there |
|---|---|
| `Models/` | SwiftData `@Model`s: `Garment`, `DayPlan` (+ `DayPlanService`), `WearEvent`, `RecommendationEvent`, `UserProfile`, `TasteProfile`, `NotificationPreferences`, `Brand`, `Outfit`, `DailyLook`. Taxonomy enums in `GarmentTypes.swift`; per-type defaults in `ItemTypeDefaults.swift`. |
| `Logic/` | Recommendation: `AIRecommender` (online logistic model + heuristics, `RecoState` weights per profile, `FeatureSpace`), `TemperatureComfort` + `GarmentThermalProfile`, `TasteAffinity`, `CombinationAffinity`, `OutfitComposer`, `OutfitChangeAdvisor`. `Recommender.swift` (root) is the rule-based fallback. |
| `Services/` | Weather, calendar context (incl. Hebrew/Jewish holiday rules), notifications, CloudKit monitor/image sync, migrations, widget snapshot, auth (Sign in with Apple + keychain), product enrichment (`BarcodeLookupService`, `ProductPageMetadataService`, `DigimarcProductIDService`, `LabelScanService`, `ProductFieldMapper`, `GarmentEnrichmentService`), `LookExplanationService` (FoundationModels). |
| `Services/imgML`, `ImageProcessing/`, `AI/` | Vision-based classification, color extraction, background cutout. `AI/ClassificationService` and `AI/SegmentationService` are placeholders for `.mlmodel` files that were never added. |
| `UI/` | Design system (`DesignSystem.swift` = `DS` tokens, `GlassKit.swift` liquid-glass), backdrop presets, shared components. |
| `Views/` | Screens. `OutfitView.swift` is legacy (not in the tab bar). `ContentView.swift` is an old list view. |
| `WearItTests/` | Swift Testing (`@Test`) unit tests. |

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

- 2026-10-04 · Claude Code · Wardrobe gaps: `Logic/WardrobeGapAnalyzer` (rain/cold/heat/formal/
  workhorse/missing-core rules with evidence + taste-shaped suggestion), shown in Stats via
  `Views/Components/WardrobeGapsSection` (search link, 60-day dismiss). Planner "suggest better"
  swaps now log a `.replaced` RecommendationEvent (implicit signal, saved with the debounced persist).
- 2026-10-04 · Claude Code · Created this AGENTS.md (app map, conventions, backlog).
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
- Packing list for a trip: dates + destination forecast → planned looks.
- Split `OutfitPlannerView.swift` into smaller files (variety, persistence, drag & drop).
- Replace or remove the `.mlmodel` placeholders in `AI/`.
- Remove legacy `OutfitView` / `ContentView` if confirmed unused.
