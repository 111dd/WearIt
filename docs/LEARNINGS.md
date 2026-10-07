# Learnings

Newest first. Written by agents, for agents. Keep each entry short.

## 2026-10-06 — Readable glass and a backdrop-aware accent
- **Did:** Untinted glass uses the planner card veil (`DS.Glass.cardTint`). AccentColor is a deep teal in light and a light teal in dark. Labels on a solid accent fill use `DS.Accent.onFill`. Washed `.tertiary` captions on cards are `.secondary`.
- **Why:** The accent asset was empty, so system teal sat on light wallpapers (soft sky and the card glass) and failed contrast. The app already flips `preferredColorScheme` from the backdrop.
- **Watch:** Do not sample the wallpaper under each label; it costs scroll frames. A new accent fill needs `DS.Accent.onFill` for its glyph, not hardcoded white. Pass an explicit `tint` only when a card should not use the shared veil.

## 2026-10-06 — Love is learned; user sizes live on UserProfile
- **Did:** removed the love slider (add + edit); `LoveScoreLearner` runs once per launch (swaps −2/+1, capped; weekly −1 for items unworn 60+ days, floor 30, favorites exempt). Added `UserProfile` size/measurement fields, `MySizesView`, a Size row in the add screen's detected card pre-filled via `MySizesView.usualSize`.
- **Why:** dor wants the app to learn how much an item is loved, and to know the user's sizes for future in-stock matching.
- **Watch:** wear confirmations already add +1 live (`WearHistoryService` `loveScoreDelta`), so the learner must not count wears again. Tops and outerwear share one usual size. A label scan may replace a guessed (✨) size but never one the user picked.

## 2026-10-05 — Substring keywords: "sweatshirts" contains "tshirts"
- **Did:** `mapItemType` scores the product title alone first; added "sweatshirt"/"סווטשירט" to sweater.
- **Why:** a G-Star sweater (path `sweatshirts-hoodies`) became a T-shirt; ties go to the first type in the list.
- **Watch:** add a longer keyword for any word that contains another type's keyword. The add screen's ✨ marks compare against `autoValues`; call `markAutoFilled` right after any automatic write, per field.

## 2026-10-05 — Product links: the variant in the URL is the item the user has
- **Did:** Shopify / Zara adapters, `ProductGroup` variant selection, all photos + `ProductImagePicker`, `WebPageRenderer` fallback, description → fit/sleeve/pattern/material.
- **Why:** links filled the first color and the first size on the page (usually XS), took the model photo, and failed on text like "Check out… https://…" or `&amp;` in pasted links.
- **Watch:** the cloud container can't reach shop sites (proxy blocks them), so adapters were written from the shops' known JSON shapes and must stay defensive. `WebPageRenderer` is slow (up to 15 s); it runs only when the plain fetch yields nothing.

## 2026-10-05 — Add-garment category detection had never worked
- **Did:** `GarmentCutoutService` + `GarmentVisionClassifier` + `AutoFillService.refine` (Foundation Models image input) replace `ClothingAIPipeline`, whose classifier and segmentation models were stubs that threw.
- **Why:** only colors and the cutout were auto-filled; `GarmentImageUnderstandingService` existed but was never called.
- **Watch:** instant guesses are tracked in `aiSuggested*` state; refinement and cutout switches only replace values still equal to those (or empty). Every late AI result checks `aiGeneration`. Selfie bands are rough horizontal strips cut from the person mask, so they need the body pose (shoulders + hips); fewer than two bands means "not a selfie".

## 2026-10-05 — Item situations: answer first, then wear, then the item
- **Did:** `GarmentOccasionProfile` + `GarmentOccasion` (maps from `CalendarOccasionKind`), "Right for" chips on the item, a wardrobe question for items worn 3+ times for a situation they don't seem to fit.
- **Why:** occasion fit was only formality plus two hand-set tags (gym, work).
- **Watch:** `Garment.setOccasionAnswer` is the only writer: it keeps `.work` / `.gym` occasion tags in sync, which `isWorkwear`, `isActivewear` and `GymKit` read. Work and workout looks are scored by the rule terms; `situationFit` only adds the user's answers there and the derived fit for formal / evening / outdoor.

## 2026-10-05 — Planner questions: ask only when the answer changes the look
- **Did:** `ComfortPreferences` (day answers + samples in UserDefaults, learned thresholds, `isBorderline`), `LayerQuestionCard` / `EventQuestionCard` in the day card, `SleeveQuestionCard` in the wardrobe, `RecoContext.layerChoice` / `shortSleeveFromC`.
- **Why:** the jacket and sleeve call on 17–23° days was a guess, and unreadable events silently counted as nothing.
- **Watch:** the day answer must reach both `RecoContext.outerLayerPolicy` and the planner's `shouldShowSlot(.outer)`, or the outer slot hides while the score wants a jacket. One question a day (`planner.questionDay`); the card is part of `DayCardSignature`.

## 2026-10-05 — Occasion memory learns per-occasion looks from wear history
- **Did:** `WearEvent.occasionRaw` + `OccasionMemory.tagUntagged` (reads the calendar for past wear days) + `OccasionStyleProfile` used by `AIRecommender.occasionFit` and the planner's formality target.
- **Why:** wear events never recorded what they were worn for, so "your work look" could not be learned.
- **Watch:** nil `occasionRaw` = not looked up yet, "none" = plain day. Without calendar access plain days stay nil on purpose so connecting the calendar later tags them. A corrected event title calls `forgetRecentTags` so past looks are re-read. A uniform work day maps to `.none` for the habit; a free dress code still learns `.work`.

## 2026-10-05 — Calendar events: words, not substrings; day and evening apart
- **Did:** replaced the substring keyword classifier with `Logic/CalendarEventUnderstanding` and split
  `DayCalendarContext` into day / evening occasions, sport reminders and work dress code.
- **Why:** a 266-event audit scored the old classifier 40%: any unmatched event after 16:00 became
  "evening out", "run" matched brunch, "ברית" matched עברית, and a morning gym made the whole day sporty.
  Hebrew holiday eves used Nisan=1 numbering; Foundation's Hebrew calendar is Tishrei=1 … Elul=13.
- **Watch:** add vocabulary as words or phrases with weights, and add a test case in
  `WearItTests/CalendarEventUnderstandingTests`. The audit corpus and a Python port live in the project's
  `plans/` folder (`calendar_classifier_test.py`, `calendar_engine_port.py`).

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
