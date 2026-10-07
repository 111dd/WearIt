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
- **Local agents (working directly on Dor's Mac files): never commit or push unless asked.**
  Cloud agents working on their own branch may commit and push that branch freely; merging into
  `main` still waits for Dor ("תעלה לגיט").
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
- Git flow: one branch + one PR per change. When Dor says "תעלה לגיט", commit, push, open the PR
  and merge it into `main`; Dor then only pulls `main` in Xcode. Don't ask Dor to switch branches.
  Undo a merged change with a revert PR (never rewrite `main`). Old branches that are 0 commits ahead
  of `main` are safe to delete (the session proxy can't delete branches; Dor uses GitHub's trash icon).

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
   `DayJournalCard` (the day's events plus the look, if one was planned), `DayLookEditorSheet`.
   A flight, or two-plus days at a far pin, opens `TripPackingView` (looks per day, underwear/socks
   counts, swimwear or a coat from the destination forecast). Manual trips live in UserDefaults.
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
  Xcode Cloud creates the file in `ci_scripts/ci_post_clone.sh` (key from a `BARCODE_LOOKUP_API_KEY`
  secret environment variable in the workflow, else empty).
  API keys come from build settings (`$(BARCODE_LOOKUP_API_KEY)`), never hardcoded.
- Calendar: `CalendarEventUnderstanding.classify` (pure, tested) → `CalendarContextService.build`
  → `DayCalendarContext` with separate day / evening occasions. Use `occasion(isEvening:workDressCode:)`
  and `formalityBump(isEvening:workDressCode:)`, never the headline `occasionKind`, for a look.
  A tagged place ≥ 40 km from home (`EventLocationDressing`) replaces that look's forecast
  (`EventLocationForecastService`: WeatherKit, else Open-Meteo — never mock).
- Weather: WeatherKit (`ForecastService`) plus Open-Meteo (`WeatherService`),
  shared state in `WeatherCenter`.
- Images are files under `Documents/WearItImages` (`ImageStore`: disk + downsample +
  cache), synced separately by `CloudKitImageSyncService`. `Garment.imageData` is legacy.
- Privacy policy: in-app `PrivacyPolicyView` from `privacy_*` strings; the public copy is `docs/privacy-policy.html`
  (GitHub Pages from `main` /docs, `https://111dd.github.io/WearIt/privacy-policy.html`). After editing a `privacy_*`
  string run `python3 scripts/make_privacy_page.py`.
- No CI, no third-party packages (Mantis cropper has a stub fallback).

## Architecture facts

- **One "me" per iCloud account**: always get the profile through `CurrentUser` (exact Apple ID match, else the
  main profile: signed-in first, then oldest). Signing in adopts it (`CurrentUser.adopt`), signing out keeps it,
  and `CurrentUser.mergeDuplicateProfiles` folds duplicates at launch. Never create a `UserProfile` elsewhere.
- "Delete all my data" (`AccountDataService.deleteStoredData`) must delete and reset the gate in one main-actor turn;
  a new `@Model` type has to be added there and to the export.
- No sample wardrobe is seeded. New installs see `OnboardingView` (gate in `AppGateView`); launch work that would
  prompt for permissions waits for `OnboardingState.isCompleted`.
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
  Cloud Compute. It takes a file URL, never a live SwiftData object. `AutoFillService.refine`
  writes the cutout to a temp JPEG for it and maps the answer to the app's enums.

## Code map

| Folder | What lives there |
|---|---|
| `Models/` | SwiftData `@Model`s: `Garment`, `DayPlan` (+ `DayPlanService`), `WearEvent`, `RecommendationEvent`, `UserProfile`, `TasteProfile`, `NotificationPreferences`, `Brand`, `Outfit`, `DailyLook`. Taxonomy enums in `GarmentTypes.swift`; per-type defaults in `ItemTypeDefaults.swift`. |
| `Logic/` | Recommendation: `AIRecommender` (online logistic model + heuristics, `RecoState` weights per profile, `FeatureSpace`), `TemperatureComfort` + `GarmentThermalProfile`, `TasteAffinity`, `CombinationAffinity`, `OutfitComposer`, `OutfitChangeAdvisor`, `WardrobeGapAnalyzer`, `LoveScoreLearner`. Away-from-home: `EventLocationDressing`, `TripFinder`, `TripPackingBuilder`. `Recommender.swift` (root) is the rule-based fallback. |
| `Services/` | Weather, calendar context (incl. Hebrew/Jewish holiday rules), notifications, CloudKit monitor/image sync, migrations, widget snapshot, auth (Sign in with Apple + keychain), product enrichment (`BarcodeLookupService`, `ProductPageMetadataService`, `DigimarcProductIDService`, `LabelScanService`, `ProductFieldMapper`, `GarmentEnrichmentService`), `LookExplanationService` (FoundationModels). |
| `Services/imgML`, `ImageProcessing/` | Add-garment AI: `GarmentCutoutService` (instance cutout with choices, selfie top/bottom/shoes bands, quality hints), `GarmentVisionClassifier` (built-in `VNClassifyImageRequest`), `ColorExtractor`, `AutoFillService` (instant `suggest` + Foundation Models `refine`). `ImageCutout` is the Simulator/no-subject fallback. `Models/DeepLabV3.mlmodel` + `DeepLabSegmenter` are unused. |
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
- **Product links**: shop-specific sources go in `Services/ShopProductAdapters` (Zara also registered in
  `ProductURLResolverRegistry`) and build the result with `ProductPageMetadataService.makeProduct`; they return
  nil / fall back to the generic reader instead of failing. Never fill size from a product page.
- **Uniform work days**: only when `UserProfile.workDressCode == .uniform` and the day has a timed work event.
  `WorkDayAttirePreferences` (UserDefaults, per day, last answer inherited) holds "work clothes only" / "own clothes".
  Work clothes only + nothing before work = no day look (`isUniformOnlyDay`; cleared once per day, never a worn or
  committed one unless the user taps the choice). A plan before work dresses the day look; a non-workout plan
  after work turns on the evening look, labeled "After work".
- **Love is learned, never asked**: there is no love control in the UI. `Garment.loveScore` moves only through
  signals: confirmed wear (+1 live via `WearHistoryService` `loveScoreDelta`), look feedback, Style Swipe, and
  `LoveScoreLearner` (swaps, neglect decay; deferred bootstrap). Don't count wears twice.
- **User sizes**: usual sizes (`topSizeRaw` for tops + outerwear, `bottomSizeRaw`, `shoeSizeRaw`) and body
  measurements in cm live on `UserProfile`, edited on "My sizes" (`Views/MySizesView`). Read a usual size via
  `MySizesView.usualSize(for:profile:garments:)` (falls back to the size most of the user's items carry). The add
  screen pre-fills it marked ✨; a scanned label may replace a guessed size, never one the user picked.
  Goal: later match in-stock items in the user's size.
- **RecoState features**: append new features at the end of `FeatureSpace` so old
  weights migrate by zero-padding, and bump `RecoState.version`.
- Widget types (`TodaySnapshot`, `WidgetCommand`) are duplicated in
  `WearItWidget/WidgetShared.swift` and `Services/Widget*`; keep both in sync.
- `OutfitPlannerView.swift` is ~4.7k lines; use its `// MARK:` sections to navigate.
- **Away from home**: a map pin (`EKEvent.structuredLocation.geoLocation`) ≥ 40 km from home
  changes a look's forecast; for a trip or all-day event a typed location also counts once
  `TypedEventPlaceResolver` has geocoded it (cached in UserDefaults, nearby matches preferred).
  Tapping such an event in the calendar journal opens `EventPlacePickerSheet` (live `PlaceSearchField`,
  MapKit suggestions); a user pick counts for any event with that typed text, timed ones too.
  "Home" is the last device fix, saved across launches (`DeviceCoordinate.saved`). A failed remote fetch must not fall through to mock weather, and a
  confirmed or worn look is not replanned. A flight, or two-plus days at one far pin, is a trip
  (`TripFinder`). Suitcase checks and counts live in UserDefaults (`tripPacking.list.<id>`);
  hand-made trips are `tripPacking.manualTrips`. Do not rebuild a saved suitcase on open.
  All-day EventKit end dates are exclusive (the morning after the last day).

## Progress log

Newest first. One line per meaningful change: date, tool, what.

- 2026-10-07 · Claude Code · Xcode Cloud / TestFlight: the app's Info.plist was tracked as lowercase `info.plist` while the project and its synchronized-group exception say `Info.plist` (fresh clones then copy it into the bundle as a resource); renamed. `ITSAppUsesNonExemptEncryption = NO` so TestFlight builds skip the export-compliance question.
- 2026-10-07 · Claude Code · Real profile + users step 3: `UserProfile.username` (`UsernameRules`, local until sharing has a server) and `birthday`; "Edit profile" sheet (`Views/EditProfileView`: name, @username, bio, private email/phone/birthday); username in the intro. Settings > Your data: privacy policy (`Views/PrivacyPolicyView`, published from `docs/privacy-policy.html` via GitHub Pages, built by `scripts/make_privacy_page.py`), export to zip (`Services/AccountDataService`), delete all my data (store rows, iCloud photos, local files, defaults, sign-in). `PrivacyInfo.xcprivacy` for app + widget; sign-in screen localized and no longer claims sign-in is what syncs.
- 2026-10-07 · Claude Code · Users step 1+2 (`plans/users-analysis.md`): one stable profile (sign-in adopts the current profile instead of starting an empty one, sign-out keeps it, duplicate profiles merged at launch); no sample items seeded; first-run intro (`Views/OnboardingView`: welcome, name / work clothes / runs cold, permissions with reasons, optional Sign in with Apple); "restoring from iCloud" empty state; "Show the intro again" in Settings; removed dead `WelcomeView` and `SeedData`.
- 2026-10-07 · Claude Code · Jackets actually show up: a "light layer" is any outer up to warmth 3 that isn't a coat/parka/puffer (`TemperatureComfort.isLightLayer`, used by `.lightOnly`, the style layer and the `lightLayer` gap); style-layer days are 18–27°. A short-sleeve day look with no layer gets a "cool evening/morning (17°) · take your jacket?" row (`layerTip`); yes/no answers learn the user's own cool-hours threshold (`ComfortPreferences.coolHourJacketBelowC`).
- 2026-10-07 · Claude Code · Wardrobe analysis + variety: a light jacket over short sleeves on mild dry days (about every other day, `AIRecommender.offersStyleLayer`); new gaps `lightLayer` and `thinRotation` (tops 7 / bottoms 4 / shoes 3, `WardrobeGapAnalyzer.coverage` shown in Stats); the planner shows one "add to your wardrobe" card when the board repeats a thin category or the weather needs a missing layer. Swap suggestions name the item type and show the suggested piece; Hebrew top slot is "חולצה".
- 2026-10-07 · Claude Code · Uniform work days: the work row asks "work clothes only / my own clothes" (per day, last answer carries over, `Logic/WorkDayAttire`). Work clothes only clears the day look (and its wears, so stats skip it), offers an "after work" look, and reads plans before/after the shift (`WorkDaySchedule`). Hebrew "תחתון" is now "מכנסיים"; wardrobe questions show the item's photo.
- 2026-10-07 · Claude Code · Interactive place search (`UI/PlaceSearchField`, suggestions open while typing): used for a hand-made trip's destination and for an event's typed location from the calendar journal.
- 2026-10-07 · Claude Code · Away-from-home polish: a trip or all-day event with a typed place ("Eilat", no map pin) now counts after a one-time cached lookup; the last device location is saved so pins work right after launch.
- 2026-10-06 · Cursor · Calendar journal shows the day's events. A detected or hand-made trip opens a suitcase: a look per day, editable underwear/socks counts, swimwear when the destination is warm and a coat when it's cold.
- 2026-10-06 · Cursor · A calendar event with a tagged place ~40 km from home dresses that look for the forecast there (day pin → day look, evening pin → evening look, all-day trip covers both).
- 2026-10-06 · Cursor · Shared the planner's readable glass veil with every untinted card, and made the accent a deep teal on light backdrops / light teal on dark photos (`DS.Accent.onFill` for glyphs on a fill).
- 2026-10-06 · Claude Code · Love is learned, sizes are the user's: the love slider is gone from add/edit
  (`Logic/LoveScoreLearner` in deferred bootstrap adds swap signals and slow neglect decay on top of the live
  wear/feedback/swipe nudges). "My sizes" (`Views/MySizesView`, from the profile) stores usual top/bottom/shoe
  sizes and body measurements on `UserProfile`; the add screen's detected card has a Size row pre-filled
  from it (or from the user's own items). Sizes now include W24/W26 and EU 35–38.
- 2026-10-05 · Claude Code · Lighter add screen: "Check what we found" card (one row per field, ✨ while a value is
  still the auto-filled one via `autoValues`, tap opens only that editor, sleeve as an inline menu); weather comfort
  and season moved under "More details"; links no longer open the full form. Cutouts rendered from a 2048 px copy
  (Vision still on 1536), shop photos fetched at full size (`ProductImagePicker.highResolution`), a link photo of a
  model shows only the linked category's part. Item type prefers the product title ("sweatshirts" path read as
  t-shirt). `ci_scripts/ci_post_clone.sh` creates `Secrets.xcconfig` on Xcode Cloud.
- 2026-10-05 · Claude Code · Up to 3 photos per item on add: a link keeps two more shop photos
  (`ProductImagePicker.rankedImages`, duplicate photos skipped), a scanned care label is kept, and "More photos"
  adds from the library; saved to `Garment.additionalImagePaths` (shown in the item's gallery; not CloudKit-synced).

- 2026-10-05 · Claude Code · Smarter product links (`plans/add-garment-smarter.md` step A): link found inside any
  shared text, `&amp;` and tracking params cleaned; Shopify `/products/<handle>.js` and Zara `?ajax=true` adapters
  (`Services/ShopProductAdapters`) pick the linked color/variant; JSON-LD `ProductGroup` variants; all product
  photos collected and `ProductImagePicker` chooses the item-alone shot; fit/sleeve/pattern/material (incl.
  Hebrew) read from title + description; page size no longer auto-filled; hidden `WebPageRenderer` (WKWebView)
  when a page is blocked or built in JS; `PasteButton` instead of reading the clipboard.

- 2026-10-05 · Claude Code · Garment understanding + smart cutout (plan: project `plans/ai-everywhere.md`
  steps 1–2). Add-garment now classifies with Apple's built-in Vision classifier instantly and refines
  with Foundation Models on the image (iOS 27: category, type, colors, pattern, sleeve, fit). Cutout picks
  items (drops clutter, "which item?" chooser), splits mirror selfies into top/bottom/shoes by body pose,
  frames every cutout with even padding, and hints a retake (cut off / too small / too dark). Removed the
  never-shipped `AI/` placeholder pipeline and `GarmentMLClassifier`.

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
and recommend from that. Wardrobe gaps and the trip packing list have shipped; smarter stats is next.

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
- Split `OutfitPlannerView.swift` into smaller files (variety, persistence, drag & drop).
- Remove the unused `DeepLabV3.mlmodel` / `DeepLabSegmenter`, `VisionAutoCropper`, `ImagePostprocess`.
- AI plan steps 3–6 (`plans/ai-everywhere.md`): background AI queue + nightly backfill, best-photo
  pick + duplicates, look photo → wardrobe items, "ask the wardrobe".
- Remove legacy `OutfitView` / `ContentView` if confirmed unused.
- Sizes: use body measurements for brand size advice and in-stock matching (needs a product/stock source).
- Show the learned love on the item (read-only) or use it in Stats ("items you love but rarely wear").

## When you finish a task

Append to `docs/LEARNINGS.md` (newest first):

```
## YYYY-MM-DD — one-line title
- **Did:** what changed
- **Why:** the actual problem
- **Watch:** pitfall the next agent will hit
```

Update the standing sections of this file only when a rule or fact changes, not for every feature.
