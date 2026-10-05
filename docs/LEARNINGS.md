# Learnings

Newest first. Written by agents, for agents. Keep each entry short.

## 2026-10-05 — Full-screen covers must not use the app backdrop
- **Did:** Style Swipe dropped `withLocalAppBackdrop()` and paints its own opaque background.
- **Why:** `ClearHostingBackground` clears every superview and controller up the chain, so a
  `fullScreenCover` became see-through and the screen behind it showed (and felt tappable).
- **Watch:** for covers use an opaque `.background` + `.presentationBackground`. Constants on a
  `@MainActor` type read from nonisolated code need `nonisolated static let`.

## 2026-10-05 — Recommender judges whole looks and learns from choices

- **Did:** `suggestOutfit` now calls `rankLooks`: top 6 per core slot, every combination scored as a look (piece scores + `LookDNA.priorScore` + learned `RecoState.lookWeights` + pair affinity), then outer/accessory. Swaps/picks call `learnPreference` (pairwise) and `learnLookPreference`; locks and auto-replace are soft signals saved with the planner persist (`save: false`). Style Swipe trains the same models.
- **Why:** Pieces were picked greedily one by one, so colors and proportions never mattered, and the strongest signal (what the user swapped in) was logged but never learned.
- **Watch:** `LookDNA.vector` order is the meaning of `lookWeights`; only append to it (and to `StyleInsights` index math). Learning calls inside the planner must pass `save: false`; Style Swipe saves once per deck. Visual prints live in Application Support, never in a `@Model`.

## 2026-10-05 — Text on glass was hard to read

- **Did:** Removed glass-on-glass inside the planner day card (forecast chip, ⋯ circle, gesture hint). Weather and the calendar event are plain subtitle lines. The card glass gets `tint: Color(.systemBackground).opacity(0.35)`.
- **Why:** Small glass shapes on top of the card's glass, with `.secondary`/`.tertiary` text, washed out on the light backdrop presets. Liquid Glass only flips small standalone controls between light and dark, not content inside a big card.
- **Watch:** Inside cards prefer plain text with `.primary`/`.secondary`; keep glass for the card itself and for standalone controls. Avoid `.tertiary` on glass.

## 2026-10-05 — Swipe in a ScrollView and double-tap delay

- **Did:** Swipe-to-replace is a `UIGestureRecognizerRepresentable` pan (`HorizontalSwipeGesture`) that fails as soon as movement is more vertical than horizontal. Removed the tile double-tap.
- **Why:** A SwiftUI `DragGesture` on planner content (inside the vertical ScrollView, around tiles with `onDrag`/`contextMenu`) did not fire reliably on iOS 18. A double-tap next to a single tap makes every single tap wait; dor found that delay annoying.
- **Watch:** Don't add `onTapGesture(count: 2)` on planner tiles. New sideways gestures in scroll content should reuse `HorizontalSwipeGesture`.

## 2026-10-05 — Look card is gesture-first

- **Did:** `OutfitLookRow` shows only the action that fits the moment (wear prompt today/past, nothing on future days, corner status mark after), a post-wear reaction strip, swipe-to-replace (`DragGesture` via `simultaneousGesture`, horizontal-only), and the planner tile now double-taps to love and single-taps to open `quickSwapStrip`.
- **Why:** The owner found the four-button glass bar heavy; feedback before wearing a look is noise.
- **Watch:** `DayCardContainer` is `.equatable()` — any new planner `@State` that changes a card (quick swap, hint) must be added to `DayCardSignature` or the card will not redraw. Tile `onTapGesture(count: 2)` must stay before the single tap. Every gesture needs a matching `accessibilityAction`.

## 2026-10-05 — "Why this look?" was empty in Hebrew

- **Did:** Added `LookReasonBuilder` (deterministic reasons from forecast, calendar occasion, favorites, wear history, `CombinationAffinity`, taste colors). The planner card's insight line and expanded details use it; the FoundationModels summary is shown on top only when it exists.
- **Why:** `LookExplanationAvailability.isSupported` requires the device language to be in `SystemLanguageModel.supportedLanguages`. Hebrew is not supported, and devices without Apple Intelligence also return false, so the explanation silently never appeared and the row only repeated weather guidance.
- **Watch:** Never make a user-facing feature depend only on FoundationModels; always ship a deterministic fallback. New `Reason` cases need text in `reasonText`, an icon in `reasonIcon`, and en + he strings.

## 2026-09-16 — Skip full-table startup migrations

- **Did:** `DataMigrationService` now gates critical garment/brand work with UserDefaults (`criticalGarmentMigrationVersion`, `brandDuplicateMergeDone`). Pending garments are fetched by `migrationVersion` (`nil` / `0` / `1`) instead of `FetchDescriptor<Garment>()`. Thumbnail backfill uses `#Predicate { thumbnailPath == nil && imagePath != nil }`, generates thumbs off-main, and yields every 8 items. `BrandStore.mergeDuplicateBrands` loads garments only when duplicates exist.
- **Why:** Every launch was scanning the whole wardrobe (and dirtying brand `normalizedKey`) before the first UI frame.
- **Watch:** Bump `currentCriticalGarmentMigrationVersion` when `Garment.migrateIfNeeded()` writes a new version. SwiftData `#Predicate` cannot portably express `optionalInt < 2`. Do not reintroduce an unfiltered garment fetch on the critical path.

## 2026-09-15 — Calendar is a day journal, not a history dump

- **Did:** Replaced month-grid + summary + photos + history with `CalendarDateStrip` (week/month), `DayJournalCard`, and `DayLookEditorSheet`. Planner deep link via `Notification.Name.openPlannerDay`.
- **Why:** The old page stacked too many sections; calendar edits also diverged from planner storage.
- **Watch:** Write looks with `DayPlan.setSlotAssignments`, not only `selectedGarmentIDs`. Wear status goes through `applyDayLookWearStatus`. Reflection UI must `ViewThatFits` on small screens.

## 2026-09-15 — Replace-look ping-ponged two shirts

- **Did:** Session `replacementRotation` cycles candidates. Shoes / outer / accessory have `cooldownDays == 0` and a soft cross-day penalty instead of a hard exclude.
- **Why:** “Forgotten clothes” existed but replace only flipped between two tops; day-after-day shoes/coats are normal.
- **Watch:** Hard-excluding flexible categories will recreate the loop. Keep rotation per slot/day.

## 2026-09-15 — Secrets and App Store version mismatch

- **Did:** Barcode API key moved to `Config/Secrets.xcconfig` (`$(BARCODE_LOOKUP_API_KEY)` in Info.plist). Widget `MARKETING_VERSION` aligned to `1.0.1`. Added `.gitignore` for DerivedData / xcuserdata / secrets.
- **Why:** Hardcoded key in the repo; widget vs app version would fail App Store submit.
- **Watch:** Never commit `Config/Secrets.xcconfig`. Never put a real key in `BarcodeLookupService`.

## 2026-09-15 — Do not run build or simulator

- **Did:** Standing rule. User builds and runs in Xcode.
- **Why:** Agent `xcodebuild` with `CODE_SIGNING_ALLOWED=NO` stripped CloudKit entitlements (`SIGABRT`). `simctl launch` also killed LLDB (“Xcode has killed the LLDB RPC server”).
- **Watch:** Do not “just quickly compile to verify.” If you need confidence, reason about the change; the user will build.

## Still open (perf, not done)

- `Garment.imageData` (legacy blob) is still on the model — every garment fetch can pull it.
- `WearEventStore.events(on:)` / `findEvent` fetch all wear events then filter in memory; planner `isConfirmed` calls this from card signatures.
- Planner/wardrobe `@Query` often has no predicate/`fetchLimit`.
- Linear `allGarments.first { $0.id == id }` in planner — prefer `garmentsByID`.
- Do not measure by launching Instruments yourself; leave that to the user.
