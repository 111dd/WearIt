# Learnings

Newest first. Written by agents, for agents. Keep each entry short.

## 2026-10-18 — Publish the complete local change set
- **Did:** Dor authorized committing, pushing and merging all current shopping, planner and wardrobe/photo changes through one PR.
- **Why:** bring main up to date so Dor can pull it in Xcode.
- **Watch:** publication does not imply device validation; no build, tests or simulator were run. Keep existing owner-review follow-ups.

## 2026-10-18 — Purchase actions and bottom variety in suggested looks
- **Did:** visible purchased buttons on full shopping/companion cards, existing feedback persistence/learning reused; dependent bundle previews removed until rerank after purchase/dismiss. Fixed search modifier dsField → existing dsFieldStyle. Shopping previews rotate per-bottom compatible alternatives within 0.04 of the best; rankLooks rotates unlocked bottoms among eligible alternatives within 0.06. No builds/tests/simulator/publication.
- **Why:** purchase action existed only in a long-press menu; independently picking the best combination kept reusing the same pants, and two-piece outfit diversity alone could change only top/shoes. Owner screenshot reported nonexistent dsField.
- **Watch:** never rotate the actual saved upcoming look or a locked bottom. Keep weather/availability and compatibility gates; one eligible bottom may repeat. Candidate pool remains four per category / 70 deep products, per-bottom preview options bounded by existing combinations. Do not drop a bought/dismissed core companion from a preview and leave an incomplete outfit visible; remove that dependent preview until rebuilt. Purchase does not invent/insert a wardrobe Garment. Use real DesignSystem modifier names; nothing here was compiled by agents.

## 2026-10-18 — Shopping defaults require explicit product-department evidence
- **Did:** dedicated Shopping tab, personal default + independent manual catalog browsing; optional JSON profile shopping preferences with draft Save, export/merge and legacy choice preservation. Department is a hard eligibility gate; colors/brands/styles supplement taste. Bounded cached serial public-photo worker checks visible product previews for person-free/studio images; neutral fallback when uncertain. EN/HE labels and explicit style phrase mapping. No build/tests/simulator/network acceptance/publication.
- **Why:** removing gender tabs alone let women's products score on shared colors/styles; UserProfile had no shopping-department preference. Catalog cards also blindly took the first (often modeled) image.
- **Watch:** never infer a user's gender/department from name/avatar/colors/sizes. Use explicit saved choice, prior men/women choice, or sufficiently consistent independent retailer-linked sources/purchases; one purchase is insufficient. Unresolved Automatic shows a choose-preferences prompt plus neutral candidates, not mixed clothing. Seed a legacy explicit choice into the settings draft so an unrelated Save cannot erase it; saving Automatic explicitly wins afterward. General browsing bypasses personal/minimum-wardrobe gates but keeps adult/department/stock validation; filter edits do not write profile or train. Product-only photos are heuristic, not guaranteed garment isolation; do not fall back to a known modeled shot when enabled. Cache by URLs/fetch/photo mode, bound downloads/queue/cache, cancel stale waiters; no wardrobe uploads or image-gender inference. Preferences are additive optional JSON, feedback remains existing device-local state. Handoff: WearIt/Docs/Personal-Shopping-2026-10-18.md.

## 2026-10-18 — Dismissible daily-look change advice
- **Did:** separate 44-point close button alongside Apply; date/look-scoped local dismissal in `PlannerChangeSuggestionVisibility`, hidden for worn looks, with stale Apply guards. No build/tests/simulator or publication. Other agent work and localizations preserved.
- **Why:** cached better-piece suggestions remained visible after confirming worn and had no dismissal action.
- **Watch:** visibility must be checked before returning advisor memo results. Include the visible `OutfitChangeSuggestion?` in `DayCardSignature`; otherwise `.equatable()` can keep the old card after dismissal. Read worn through `lookWearStatus` (legacy day fallback included), not WearEvent presence. Closing is presentation state in AppStorage, not dislike/recommendation feedback or a CloudKit save. Keys use actual date/look, not board indices; retain bounded recent dismissals. Undoing worn can reveal advice again unless manually dismissed.

## 2026-10-18 — Personal shopping, reliable offers and complete looks
- **Did:** replaced gender menus with personal useful/deals/upcoming/everyday/accessory/optional next-season picks; choice-weighted colors/brands/style/type/fit/pattern plus reaction attributes, weak visits and recent-purchase redundancy. Concrete owned-wardrobe previews, optional second purchase, saved/offline actions, content-based debounced rebuilds. Crawler now pairs same-variant prices/color/stock and preserves unknown availability; app requires verified recent offers. No builds/tests/simulator/publication; owner review pending (`WearIt/Docs/Personal-Shopping-2026-10-18.md`).
- **Why:** unlabelled products appeared in both gender tabs, accessories always had zero looks, weather was fixed at 22°C, planned looks were unused and Shopify could combine different variants into a false discount.
- **Watch:** keep structural personal/usefulness gates outside learned bias/discounts. Deep scoring remains bounded to 70 products; optional bundles must beat two complete single-purchase looks. Saved upcoming slots and persisted destination weather are read-only; never replan or mutate wears for shopping. Product fetchedAt, not catalog generatedAt, controls offer freshness. Old originalPrice values are unverified until refetched by the updated crawler; never use AggregateOffer.highPrice as a discount. Unknown/unsupported sizes and color scope cannot imply sold-out or exact-size availability; accessories have no category-wide usual size. Feature positions stay append-only, new state snapshots optional for v1 decoding. No gender inference, calibrated purchase probability, shipping/expiry promise, or performance evidence. Seasonal IL temperatures are heuristics. Feedback keeps existing one-user/device defaults scope.

## 2026-10-18 — A06: shared photography, native selection and photo discovery
- **Did:** shared quiet content surfaces, square whole-garment frames and cached off-main transparent-padding trim; wardrobe search/density/quick actions, Add/Edit native subject selection with existing garment candidates, opt-in catalog visual neighbors and product-link photo import. Optional photo source URL survives promotion/recrop and exports. No build/tests/simulator, visual evidence or live network imports; owner review pending.
- **Why:** fill-cropping and inconsistent frames hid clothing, while heavy content glass and title overlays competed with photos. Users need explicit control over which object and which photo represents an item.
- **Watch:** trim alpha only, never guess an opaque white background away. Use path+size cache keys, no UUID-only preview cache. Subject selection uses UIImageView + VisionKit imageSubject interaction; installed SDK has no imageSubject analysis type, so local text analysis initializes it. Native subjects may group a whole person; existing body-band choices are approximate, crop remains the fallback. Explicit Add selection invalidates AI generation and skips recutting. Discovery compares local feature prints with at most 12 public catalog previews; it never uploads wardrobe images and is not whole-web reverse search/exact-product identification. Manual link import cancels discovery. Always show compare/confirm; retain the old cover, keep public source metadata, use existing media rollback. Extra/original assets remain local-only. Full device/network acceptance matrix is in the audit handoff.

## 2026-10-18 — A05: Today-first planner and a single suggestion slot
- **Did:** Today first, optional suggestion after it, upcoming full interactive cards; a small menu switches between eligible suggestions. `PlannerComponents` scopes quiet content surfaces and responsive photo layout to the planner. New labels in both languages. No build/tests/simulator or visual/runtime checks for this layout.
- **Why:** several independent prompt cards and 32-point gaps pushed the actual outfit down; fixed 50/72-point tiles wasted space or overflowed narrow rows.
- **Watch:** keep existing slot identities, gesture/drop handlers and wear semantics. Suggestions reuse existing dismiss/snooze keys; rediscovery is blocked for worn/planned/uniform-only days; today's inline question takes priority. Empty evening rows use a compact Add action. Photo rows use `DSGarmentTile(showTitle: false)` and native Layout with balanced wrapping, no geometry state; SwiftUI automatically mirrors layout coordinates for RTL, so do not manually reverse columns. `DayCardSignature` includes the new greeting/location string. Surface contrast/transparency is local to planner cards; the shared theme/root color-scheme behavior is unchanged. Owner visual review and detailed checks remain pending in the audit handoff.


## 2026-10-18 — Calendar destination date and item photo roles
- **Did:** A02 captures `selectedDay` before the calendar's first photo-load await. Item editor gallery now includes main + additional photos with stable path identity, primary selection and per-photo roles tailored to garment category/type. Optional JSON `Garment.photoMetadataRaw` stores role/source/thumb paths; AccountDataService exports primary and roles. No agent build/tests/simulator. Dor later reported the changes work; a detailed validation matrix and timings were not supplied.
- **Why:** photo imports could land on a later selected day; item photos previously had no primary-selection or view semantics.
- **Watch:** role and primary are independent. Before promoting/replacing main, remember its original/thumb metadata and retain it in additional paths; recrop must use the promoted photo's own source. Media preparation uses `GarmentImagePersistence`, model changes/save stay on UI actor, failed photo transactions restore only photo fields. Cleanup subtracts still-referenced paths and runs after save. Main changes evict cached garment thumb and refresh widget. CloudKit main upload coalesces the newest pending path and uses changedKeys to replace an existing asset. Extra/original image files remain local-only; synced metadata does not fetch those assets. Legacy inline data is prepared on editor open, not a full-store migration. Owner checks and details: audit's Gallery handoff section.


## 2026-10-18 — A01: Add media persistence outside the main actor
- **Did:** `GarmentImagePersistence` serial actor encodes/writes main, original, thumbnail and extra photos; Add uses task cancellation and generation guards, localized progress/retry, draft-only cleanup and batch staging before SwiftData insertion. Failed batch cards remain reviewable, with pending analysis resumed. No build, tests, simulator or runtime measurements.
- **Why:** synchronous image encoding and writes ran before details transitions and inside Save, especially costly for large photos/batches.
- **Watch:** the media worker accepts images/paths only, never live SwiftData objects. All three main-image files must succeed; cancellation/failure deletes only files created by that request. Files transfer to model ownership only after context save, so reset cannot delete committed media. Leaving cancels tasks and discards uncommitted files, recreated from the retained draft on return. Keep generation checks after awaits; the UI save stays synchronous after media preparation. Device checks remain pending.


## 2026-10-18 — Code-based design and performance audit
- **Did:** `WearIt/Docs/iOS-Design-Performance-Audit-2026-10-18.md`: 12 scoped packets with current code references, ordering, acceptance criteria and device-measurement handoff. No application code changed or runtime verification performed.
- **Why:** prioritize real interaction bottlenecks and clearer visual hierarchy before optional platform adoption.
- **Watch:** Add persists image encodings synchronously before details; calendar photo import captures selected day after loading; widget alternative ranking happens before the existing async snapshot coordinator. Count-only rebuilds and the widget memo key need input coverage review. Preserve existing thumbnail workers, deferred bootstrap, gesture fixes and save debouncing. Apple's retrieved SwiftUI overview labels Xcode 27 changes as 2027 releases: verify installed SDK declarations before adopting them.


## 2026-10-17 — Planner body type-check limit, sheets need a painted backdrop
- **Did:** split `OutfitPlannerView.body` into `plannerStack` → `plannerWithSheets` → `body` (sheet switch in `plannerSheet(_:)`); `LookCaptureView` uses `withLocalAppBackdropPainted()`.
- **Why:** two PRs each added modifiers to one chain → "unable to type-check in reasonable time"; `withLocalAppBackdrop()` clears the hosting background, so a sheet showed the screen behind it.
- **Watch:** add planner modifiers to the shortest piece, never back into one chain. Sheets / full-screen covers use the Painted variant. Copy an existing call for custom inits (`DSGarmentThumbnail(garment, size:)` has no `garment:` label); nothing here compiles before Dor builds.

## 2026-10-17 — Shop picks ranked on the device
- **Did:** `ShopCatalogService`, `PurchaseScorer`, `ShopFeedback`, `Views/ShopPicksView` (+ Stats section, planner gap link).
- **Why:** suggest purchases the user will actually wear, using the wardrobe without sending it anywhere.
- **Watch:** catalog fields are raw; map only through `ShopCatalogService.map` (→ `makeProduct`). Products become transient `Garment`s for scoring: never insert them. Only ~70 products get the look-building pass after a cheap taste pass, keep it that way (it runs on the main actor). `ShopPreferenceModel` features are append-only.

## 2026-10-17 — Shop catalog crawler
- **Did:** `scripts/catalog/build_catalog.py` + `.github/workflows/catalog.yml` publish `il/catalog.json` on the `catalog-data` branch.
- **Why:** personalized purchase suggestions need a product source; no server yet, so GitHub Actions + a data branch.
- **Watch:** Claude's cloud container can't reach the shop sites (proxy 403), so tune `stores.json` from `il/report.json` after a real run. "sitemap" contains "item": match product sitemaps on the file name without it. Keep mapping to the taxonomy in the app, not in the crawler.

## 2026-10-17 — Interactive widget (↻, tabs, ✓/✕, reactions)
- **Did:** the planner precomputes two alternative day looks for today and tomorrow (memoized by look + forecast) into the snapshot; widget intents for next look, tab, not worn and reaction. `chooseLook` / `notWorn` / `confirmWorn` are applied to `DayPlan` in `consumeIfNeeded` in tap order (so "worn" after ↻ records the picked garments); reactions are handed to the planner (`.widgetFeedbackPending`) so `submitFeedback` / `submitTemperatureFeedback` do the learning. Any outside change posts `.dayPlanChangedOutside` and the planner re-applies that day's plan.
- **Why:** dor asked for a more interactive widget.
- **Watch:** the widget's own UI state lives in `widgetUIStateV1` (not the snapshot) because the app rewrites the snapshot; the shown look is matched by garment IDs, so after the app applies a pick it lines up with option 0 again.

## 2026-10-17 — Look photos are LookPosts
- **Did:** added `LookPost` + `LookPostStore` + `LookPhotoProcessor`; profile grid, "Snap the look", calendar day photos all read/write posts.
- **Why:** `DailyLook.photoPaths` were local files only (never reached other devices) and had no room for caption, visibility or tags needed for the social phase.
- **Watch:** read a post's photo through `LookPostStore.localPhotoPath(for:)` (rewrites the file from synced `photoData` on a new device). Delete a post only after its detail view has popped. `garmentIDs` is private; only `publicTaggedGarmentIDs` may ever leave the device.

## 2026-10-17 — Widget step 1: date-aware, queued "I wore it", new layouts
- **Did:** `WidgetSnapshot` v2 (`widgetSnapshotV2`) holds today's and tomorrow's day + evening looks; the widget picks by entry date (entries at 18:00 and midnight). Widget taps append to a command queue that `WidgetCommandService.consumeIfNeeded` applies on every app activation via `markWorn` (`LookWearStatus`, one `recordWorn`, posts `.lookMarkedWornOutside` so the planner board doesn't save the old status back). Thumbs are `Thumbs/{uuid}-{mtime}.png`, unreferenced ones deleted. Planner's `unconfirmDay` now clears `dayLookWearStatus` too.
- **Why:** after midnight the widget showed yesterday's look and its button marked yesterday; one command key meant a second tap overwrote the first; the planner's in-memory status overwrote widget confirms; thumbs never refreshed after a photo change; garments went one-color on tinted Home Screens.
- **Watch:** the widget can't write SwiftData, so a widget "worn" lands in the store only when the app runs; the snapshot save merges still-queued commands so it never flips back. The date key uses a Gregorian POSIX formatter on both sides (device calendar may be Hebrew). The app manifest now declares FileTimestamp C617.1 (thumb version from the photo's modification date).

## 2026-10-07 — Design review phase 1: bugs and speed
- **Did:** "Clear day" now persists; `WearEventStore` fetches one day by `#Predicate` instead of the whole table; wardrobe builds the wear map and its daily question once per rebuild; calendar day/period swipes use `HorizontalSwipeGesture` (which now ignores touches inside nested horizontal scroll views); journal notes save to the day they were typed on and commit on disappear; pushed screens use `compactNavBar()` so their back button never hides; sign-in banner is a `safeAreaInset`; leftover English strings localized. Full review: project `audits/design-review.md`.
- **Why:** the planner fetched every `WearEvent` three times per redraw, cleared looks came back on the next hydrate, and the card `.id(selectedDay)` dropped a note being typed when the user swiped.
- **Watch:** `hidesBarsOnSwipe` lives on the shared navigation controller: use `minimalCollapsingNavBar()` only on a tab's root screen and `compactNavBar()` on anything pushed or shown in a sheet. A card keyed by `.id(...)` is destroyed on change, so any draft it holds must carry its own key when saved.

## 2026-10-07 — Xcode Cloud export: "Could not find Info.plist for exported archive"
- **Did:** renamed `WearIt/info.plist` to `WearIt/Info.plist` (git case-only rename) and added `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`.
- **Why:** git tracked the file in lowercase, but `INFOPLIST_FILE` and the synchronized-group membership exception use `Info.plist`. A fresh clone (Xcode Cloud) can treat the lowercase file as a resource and copy it over the generated Info.plist, so export finds no app version (inferred, not reproduced).
- **Watch:** macOS hides case-only mismatches (`core.ignorecase`); check `git ls-files` names against the project file, not the Mac's Finder.

## 2026-10-07 — Real profile, export and delete-all
- **Did:** username/birthday on `UserProfile`, `EditProfileView` (saves on Save, not per keystroke), `AccountDataService` export (JSON + photos zipped with `NSFileCoordinator .forUploading`) and delete-all, privacy policy in app + `docs/privacy-policy.html` (GitHub Pages, regenerate with `scripts/make_privacy_page.py`), `PrivacyInfo.xcprivacy` (UserDefaults CA92.1 + app group 1C8F.1).
- **Why:** dor wants a real profile; App Store needs in-app deletion, a privacy policy and a privacy manifest.
- **Watch:** delete row by row (batch deletes aren't mirrored to CloudKit) and clear `AIRecommender`'s state cache. Usernames are not unique until a server exists. If you add a file-timestamp or disk-space API, add its reason to both manifests.

## 2026-10-07 — Profile split on sign-in, sample items on new devices
- **Did:** `CurrentUser` resolves "me" without ever returning nil when a profile exists; `adopt` on sign-in; `mergeDuplicateProfiles` in critical bootstrap (moves ownerID, RecommendationEvent.profileID, the RecoState with more signals, TasteProfile). Seed removed; `OnboardingView` added.
- **Why:** skip-then-sign-in created an empty profile, so sizes, work dress code and learned weights vanished while the wardrobe stayed; seeding into an empty store on a new device pushed fake items into the real iCloud wardrobe.
- **Watch:** the keeper order (`isPreferred`) must stay data-only so every device merges into the same profile. Old users have `didCompleteOnboarding` set already; don't rename the key.

## 2026-10-07 — Jackets were filtered out by a warmth ≤ 2 rule
- **Did:** one `TemperatureComfort.isLightLayer` (outer, warmth ≤ 3, not coat/parka/puffer) for `.lightOnly`, the style layer and the light-layer gap; style-layer range 18..<27; planner jacket tip for cool mornings/evenings on short-sleeve day looks, learning from yes/no.
- **Why:** most jackets are rated 3, so `.lightOnly` penalized them and the style layer never had candidates; the day's weighted temperature also sat above the old 20..<25 range on 19–29° days.
- **Watch:** the tip's samples (`comfortCoolHourSamples`) are separate from the day-question samples on purpose: one is the coolest hour, the other the day's weighted temperature. Don't mix them.

## 2026-10-07 — Style layer and wardrobe depth
- **Did:** `rankLooks` adds a light outer (warmth ≤ 2) over a short-sleeve top on dry 20–25° days when `offersStyleLayer` says so (stable per day + top, skipped for "short, no jacket" / "long"). `WardrobeGapAnalyzer` got `lightLayer`, `thinRotation` (only with `Input.checksRotation`) and `coverage`. Planner nudge: `computeWardrobeGapNudge`, snoozed 14 days per gap id.
- **Why:** dor wanted varied looks (jacket + tee) and the app to say what's missing instead of repeating clothes, as groundwork for "what to buy".
- **Watch:** the style layer bypasses the suppress-policy score penalty on purpose; don't "fix" it by letting the look score decide, or it never appears. Existing gap tests assume rotation checks are off by default.

## 2026-10-07 — Work clothes only days
- **Did:** the uniform work row became a choice (`WorkDayAttire`), with before/after-work plans from `WorkDaySchedule` (needs `CalendarDayEvent.end`). Uniform-only days skip `generateDayOutfit` and drop the planned look once (`WorkDayAttirePreferences.markApplied`).
- **Why:** dor wears a uniform: the day look was noise and polluted wear stats, and the real need is a look for after work.
- **Watch:** the row's state lives in UserDefaults, so it is in `DayCardSignature.reminderLine` (the card is `.equatable()`). A manual look added on a uniform-only day must survive the next generation pass (that's what the applied flag is for).

## 2026-10-07 — Place search with live suggestions
- **Did:** `PlaceSearchField` (MKLocalSearchCompleter + MKLocalSearch) in the manual trip sheet and in `EventPlacePickerSheet`, opened from an event row with a typed location and no map pin. A pick is saved in `TypedEventPlaceResolver` as `userPicked` and posts `.calendarUnderstandingChanged`.
- **Why:** dor wanted to choose the place from a list instead of trusting a one-shot guess.
- **Watch:** a user pick is never overwritten by a geocode guess, and counts for timed events too (guesses don't). `await` can't sit on the right of `??` (autoclosure).

## 2026-10-07 — Typed trip places and a saved home fix
- **Did:** `TypedEventPlaceResolver` geocodes a typed event location (trips and all-day events only), cached for good in UserDefaults; the planner and calendar resolve the queue and re-read the calendar when something new is found. `DeviceCoordinate` is saved so `homeCoordinate` exists at launch.
- **Why:** a vacation typed as "Eilat" without a map pin was ignored, and pins did nothing until the first location fix.
- **Watch:** never geocode a timed meeting's typed location ("office" could land anywhere). Lookups are biased to 100 km around home so vague names stay local. Network errors are retried, "no result" waits a week.

## 2026-10-06 — Calendar journal plus a suitcase
- **Did:** The calendar day lists its events. `TripFinder` turns a flight, or two-plus days at a far pin, into a trip. `TripPackingView` suggests a look per day and a checklist (counts for underwear/socks/swim, closet coats when it's cold). Manual trips are saved in UserDefaults.
- **Why:** The calendar was only a worn-look journal, and a vacation had nowhere to become a packing list.
- **Watch:** All-day EventKit end dates are exclusive (the morning after the last day). A single far meeting is not a trip; a one-day flight is. Don't regenerate a saved suitcase on every open — checks and counts live under `tripPacking.list.<id>`. WeatherKit covers about 10 days; longer trips use Open-Meteo, and dates past the forecast get no swim/coat guess.

## 2026-10-06 — Dress for a calendar pin's weather
- **Did:** `EventLocationDressing` picks a tagged place only when it is ≥ 40 km from the device fix. `EventLocationForecastService` loads that forecast (WeatherKit, else Open-Meteo). A timed event scores the hours around it; an all-day trip uses the whole day.
- **Why:** a trip or a meeting in another city was still dressed for home.
- **Watch:** only `EKEvent.structuredLocation.geoLocation` counts — a typed "London" with no map pin is ignored. Same-city pins stay on the home forecast. A failed fetch must not fall through to mock temperatures. Confirmed or worn looks are not replanned.

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
