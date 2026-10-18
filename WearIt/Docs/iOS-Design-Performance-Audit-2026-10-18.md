# WearIt — design, interaction and performance audit

Date: 2026-10-18. Code baseline: `d010b6f` plus the current working tree. Audience: Dor and implementation agents. Initial scope: recommendations and delivery plan. Subsequent implementation is recorded below; device validation remains pending.

## Executive decision

Make the daily outfit the first thing people reach; make every interaction respond before optional processing; reserve Liquid Glass for controls and navigation. Preserve WearIt's personal wardrobe photography, teal accent, bilingual UI and learned recommendations.

The strongest immediate opportunities are synchronous image persistence in Add, ranking work in interactive paths, cache invalidation that watches counts rather than meaningful edits, and too many competing prompts before the first outfit. These are specific findings in today's source, not a proposal to rewrite the app.

**Evidence boundary:** this is a code and official-documentation audit. No app launch, build, tests, screenshots, Instruments trace or accessibility session was performed. Code paths below are observed; latency, dropped frames, battery cost and final visual quality are unmeasured. Design proposals need owner review on a real device. Do not present estimated benefits as measured improvements.

## Platform accuracy: iOS 27

The deployment target remains iOS 18.5. Existing iOS 26 Liquid Glass adoption is real and already gated. This report does not recommend raising the minimum target.

The official [SwiftUI What's New page](https://developer.apple.com/swiftui/whats-new/) retrieved during this audit describes Xcode 27 but explicitly calls its changes the **2027 releases**. That conflicts with this audit's October 2026 date. Treat the listed 27 capabilities as research candidates, not proof that an API is available in the owner's SDK today. Before implementation, inspect that SDK's declarations, exact availability and official release notes. A runtime availability check alone does not let an older SDK compile an unknown symbol.

Useful candidates from that page: toolbar overflow/priority controls; broader reordering and swipe containers; improved remote-image caching. Prefer established APIs for immediate work. Document APIs have little relevance to the core wardrobe workflow. Do not replace proven gestures or local image storage simply to adopt a new API.

Apple's [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and [custom glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) support using native components and grouping related custom glass effects. Use these to guide the surface review below; more glass is not a product goal.

## Existing strengths to preserve

- `UI/GlassKit.swift:44–95`: wallpaper is downsampled and blurred once off-main, with no live SwiftUI wallpaper blur. Keep this.
- `UI/DesignSystem.swift:414–451`, `Views/WardrobeView.swift:843+`: thumbnail cache lookup, background image loading and task cancellation checks already exist. Do not report all image loading as synchronous.
- `Services/ImageStore.swift:21–33`: decoded-image caches have cost limits. Improve specific missing paths before introducing another image library.
- `BootstrapView.swift:55–125`: the app gate mounts after critical bootstrap; deferred work and signposts exist.
- `Services/WidgetSnapshotStore.swift:89–152`: draft capture is on the main actor; thumbnail/snapshot processing is already dispatched to a coordinator. The remaining ranking concern is **before** that dispatch.
- `UI/OutfitLookRow.swift:99–114, 375+`: accessibility actions and horizontal UIKit gesture arbitration already exist. Calendar notes already retain their original day. Avoid reopening those previously solved problems.
- Wardrobe already precomputes its wear map once per rebuild and uses a lazy grid. Stats already bounds history fetch counts. Planner cards already use signatures and equality checks. Extend these carefully.

## Priorities and ownership

Effort is relative implementation size, not a delivery promise. P1 = first tranche; P2 = after baseline or design review; P3 = optional exploration. No release-blocking P0 is established without runtime evidence.

| ID | Priority | Work | Evidence | Effort | Dependency |
|---|---|---|---|---|---|
| A01 | P1 | Background image persistence in Add | Synchronous encode/write calls | M | None |
| A02 | P1 | Bind calendar photo import to its originating day | Date captured after suspension | S | None |
| A03 | P1 | Separate widget alternative ranking from confirm/save | Direct ranking before draft dispatch | M | A04 for complete cache key |
| A04 | P1 | Invalidate derived results on meaningful input changes | Count-only observers; incomplete memo key | M | None |
| A05 | P1 | Put today's outfit before optional prompts | Multiple independent cards before days | S–M | Dor approves hierarchy |
| A06 | P2 | Distinguish content surfaces from glass controls | Shared surface helper applies glass to cards | M | Dor approves one screen |
| A07 | P2 | Keep shopping responsive and reuse ranking | Synchronous main-actor ranking | M–L | A04 |
| A08 | P2 | Remove cold LookPost file repair from UI paths | Main-actor disk writes in resolver | M | None |
| A09 | P2 | Accessibility and adaptive layout pass | Fixed control dimensions; custom surfaces | M | A06 shared tokens |
| A10 | P2 | Make replacement cancellable and identity-safe | Fixed-delay callback with no lifetime token | S–M | None |
| A11 | P2 | Navigation and background loading polish | Globally hidden bar fills; wallpaper task | S–M | A06 |
| A12 | P3 | Evaluate new platform APIs with SDK evidence | Official page has date mismatch | S per spike | Owner's SDK details |

## Implementation status

- 2026-10-18 — Dor reports the implemented changes work and requested publication. This is owner-reported functional confirmation, not a recorded Instruments measurement or confirmation of every scenario below.

- 2026-10-18 — A01 implemented locally at Dor's request. `Services/GarmentImagePersistence.swift` serializes encoding, file writes, thumbnail creation and request-owned cleanup outside the main actor. Add uses cancellable tasks/generation guards, preparation/save progress, retry on media failure and retained cards after partial batch failures. SwiftData creation/save remains on the UI actor; uncommitted media is discarded when leaving and rebuilt on return. No build, tests, simulator or runtime capture was run. Device validation and performance measurement are pending; the audit baseline/line references below describe the pre-change code.
- 2026-10-18 — A02 implemented locally: calendar photo import captures the destination day before loading and passes it explicitly to post creation. An empty processing result no longer reports success. No runtime validation performed.
- 2026-10-18 — Garment gallery expanded at Dor's request: primary selection, per-photo angles tailored to category/type, stable path-based viewer, background photo preparation, original-source preservation and export of photo roles. Additional photo files retain their existing local-only behavior; this does not add gallery asset sync.
- 2026-10-18 — A05 implemented locally at Dor's request: Today first, a single optional suggestion slot, full upcoming day cards, compact header/spacing and responsive outfit photography. Planner content cards pilot a calm opaque-when-needed surface; this is only the planner portion of A06. No build, tests, simulator or visual/runtime validation performed for this new layout.
- 2026-10-18 — A06 shared content surfaces and wardrobe photography implemented locally at Dor's request: square garment frames, alpha-padding trim, richer wardrobe cards with quick actions/search/density, native subject selection in Add/Edit, and opt-in photo discovery/import. This extends the planner surface pilot to Add/Edit, wardrobe, profile, calendar cards and DSCard consumers including Stats. Global theme ownership, every legacy card, and widget photography are not included. No build/tests/simulator or visual/runtime validation performed.
- Next: owner visual acceptance of A05/A06 and photo tools on device; gallery asset sync, broader theme behavior and actual performance measurements remain separate.

### A06 / garment photography handoff (2026-10-18)

- **Observed path → behavior:** garment tiles previously cropped with fill, placed text over photos and used varied aspect ratios. Shared `GarmentPhotoCanvas` now fits whole garments in square tile frames. `ImageStore.loadGarmentPreview` downsamples/caches by paths and size and trims only transparent padding off-main. Large previews prefer the main file over the 420 px stored thumb. Opaque backgrounds are retained until explicit selection; white-on-white clothing is not heuristically cropped.
- **Surfaces:** `DSContentSurface` gives content a quiet background/border, becoming opaque for Reduce Transparency/Increase Contrast. DSCard, the planner surface adapter, Add/Edit, wardrobe, profile and calendar content use it; buttons, menus, navigation and save bars retain their interaction materials. This does not change root color-scheme ownership or every legacy component.
- **Wardrobe:** default two-column cards, optional compact three-column density, adaptive iPad sizing and one column at accessibility text sizes. Search includes name/brand/type/notes and ignores the implicit current-season scope while searching, preserving explicit filters. Cards show two-line titles, metadata, color swatches, photo counts and visible quick actions. Photo update notifications rebuild derived wardrobe data. No results has a reset action.
- **Native selection:** `GarmentSubjectPicker` bridges UIImageView to VisionKit `ImageAnalysisInteraction`, with tap/long-press subject selection and a confirmation button. Existing `GarmentCutoutService` offers alternate object/body-band candidates when native selection groups a person with their clothes. This is best-effort segmentation, not an editable pixel mask. Manual crop remains available. Explicit Add selection invalidates pending AI generations and is not sent back through automatic recutting. Apple references: [subject lifting](https://developer.apple.com/videos/play/wwdc2023/10176/) and [ImageAnalyzer](https://developer.apple.com/documentation/visionkit/imageanalyzer). Installed SDK declarations were read: `.imageSubject` belongs to interaction types, not `ImageAnalyzer.AnalysisTypes`; local `.text` analysis initializes the analysis while the interaction only exposes subject lifting. Working inputs are upright and bounded to 2400 px off-main; a supplied Add original is retained for saving.
- **Photo discovery:** `GarmentPhotoSearchView` first filters the existing Israeli shop catalog by category, then prioritizes type/brand/color; `GarmentPhotoDiscovery` compares local Vision feature prints with at most 12 downloaded public previews, displays up to six, and stops starting candidates after an 18-second window. An in-flight request has its own timeout. It never uploads wardrobe photos or feature prints. Metadata/fallback ranking is used if no print is available. Results are similar candidates, not exact-product identification or a guarantee of higher resolution.
- **Web/import boundary:** this is not whole-web reverse image search. A browser image search uses brand/type/color text, and the user can import photos from a public product-page link through the existing metadata reader. Manual link import cancels catalog discovery. Product galleries are limited to eight attempted URLs/six previews; full-resolution retrieval starts only after choosing a photo, downsampling to 2048 px, with original-URL fallback if an enlarged CDN URL fails. HTTP/image MIME/file-size checks precede decoding. Network/catalog/blocked-site failures show localized fallback guidance.
- **Data invariants:** nothing replaces a saved image automatically. A compare screen offers primary replacement or add-to-gallery; replacing primary retains the previous cover. Persistence uses the existing media worker and photo-only rollback. Optional `sourceURL` in photo metadata records public shop provenance, survives promotion/removal/recrop, is available from the gallery menu and is exported. No new model/table or bulk migration. Original/additional assets remain local-only; main-image CloudKit sync remains the existing path. Low-resolution/opaque photo advice is computed locally when opening the editor.
- **Validation actually performed:** source inspection, installed-SDK declaration lookup and official Apple documentation research. No build, test suite, simulator, app launch, screenshots, benchmark or external photo import was run. All final visual quality and network behavior remain unverified on a device.
- **Owner device review:** (1) Hebrew/English, dark/light backdrops, large text and both grid densities; inspect long tops, wide shoes and accessories without clipping. (2) Select a separate object, long-press a subject, choose a worn top/bottom, cancel, reopen, and confirm original/previous-cover retention. (3) Add an item, pick a different subject, and ensure later AI work cannot replace it. (4) Try a low-resolution photo, catalog results, an empty/offline catalog, a product URL, a blocked image and cancellation during loading. (5) Add versus replace, role/primary changes, source link/export and main-image/widget refresh. (6) Check planner wrapping, calendar/profile/Stats content contrast after the shared surface change. Record actual responsiveness before claiming performance gains.

### Gallery handoff (2026-10-18)

- `Garment.photoMetadataRaw` is optional JSON: per-file role, original source and thumbnail paths. This is an additive model property, not a new model/table. Unknown future role values fall back in the UI without losing source paths.
- `Models/GarmentPhoto.swift` resolves legacy path-based images without a bulk migration. Legacy inline photo data is converted by the media worker only when its editor opens, before gallery mutations become available.
- The main image remains `imagePath`; role (front/back/etc.) is independent. Replacing or promoting a main photo preserves the old one and its crop source. Removing the main photo promotes an available replacement before committing the removal.
- Photo-field snapshots are restored on save failure. New/unreferenced files are cleaned by the worker after failure/success respectively; shared source references within the item are retained. Photo creation, thumbnail creation and decoding stay outside the main actor.
- Main changes evict the garment thumbnail cache and refresh the widget snapshot. CloudKit uploads keep the newest pending main path while an older one is uploading, and update the existing asset using [CloudKit's changed-key save policy](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy). Original/additional image assets still have the existing local-only behavior; metadata synchronizing does not synchronize those files.
- Account export retains the existing photo list and adds `primaryPhoto` / `photoDetails` with role and main status tied to exported filenames.
- Pending owner checks: import a calendar photo on A and switch to B while loading; set a shoe sole/back view; promote a gallery photo and recrop it; switch back to the old cover; remove current/secondary photos; cancel during image preparation; reopen the item; check a garment with legacy inline photo data, a missing local secondary file and an export. Check Hebrew/English and large text. No build, test run, simulator, device capture or CloudKit roundtrip was performed by the agent.

### Planner layout handoff (A05)

- `plannerContent` orders today → optional suggestion → upcoming days. Both upcoming cards retain the existing editing, drag/drop, locking and wear actions. No collapsed-day state was introduced.
- One eligible suggestion is displayed; its menu exposes the other eligible choices. Work/calendar/gap questions precede optional rediscovery/daily Style Swipe; Style Swipe onboarding remains eligible. Existing snooze/dismiss keys are reused. A question inside today's card temporarily takes precedence over the optional slot. Rediscovery cannot alter a worn/planned/uniform-only day.
- `UI/PlannerComponents.swift` scopes paper surfaces, suggestion/action styling and the responsive tile layout to the planner. It uses the existing `DSGarmentTile` background-loading pipeline. An empty evening row is a compact Add action, not a full-size placeholder photo.
- Tile layout fills width, balances overflow rows and preserves slot identities. Rely on [SwiftUI's automatic RTL coordinate mirroring](https://developer.apple.com/documentation/swiftui/layoutsubviews/layoutdirection); do not reverse the columns again. `DayCardSignature.welcomeLine` includes newly displayed greeting/location inputs.
- Pending owner checks: small/large phone, 1–5 garments plus Add, day/evening and uniform-only days, English/Hebrew and large accessibility text, busy photo backdrop, Reduce Transparency/Increase Contrast, optional question answer/skip, suggestion selection/dismissal, worn/locked item behavior and drag between days. No launch/build/tests/profiling/simulator was run.

## Agent work packets

### A01 — Add: move image encoding and disk persistence out of interaction handlers

**Evidence:** `Views/AddGarmentView.swift:1002+` (`saveBatch`), `1943+` (`confirmCroppedImage`) and `2081+` (`persistDisplayImage`). Crop confirmation calls persistence before changing the flow state. Persistence encodes original JPEG, display PNG/JPEG, writes files and generates a thumbnail synchronously. Batch repeats this work for each item. `Services/ImageStore.swift:16` explicitly documents that its synchronous I/O belongs on a background executor.

**Impact hypothesis:** a large camera photo or batch can delay the next screen, button feedback and scrolling. No duration has been measured.

**Implementation:** create a focused media-persistence worker accepting immutable image/file inputs and returning paths. Run encoding, writes and thumbnail production there. Keep SwiftData insertion and UI publication on the owning actor. Reuse the existing generation token so an older crop result cannot replace a newer one. Make navigation responsive immediately, with a localized processing state and save availability tied to successful persistence. Preserve transparency in cutouts; do not indiscriminately convert PNGs to JPEG.

**Done:** repeated crop changes keep only the latest result; leaving the screen prevents late UI publication; partial batch failure is recoverable; failed files do not create broken garments; superseded temporary outputs are cleaned up without deleting referenced images. Owner checks a large photo and multi-item batch. Trace should show encoding and file work outside the main thread. Never pass a live `Garment` or `ModelContext` to a detached worker.

### A02 — Calendar: preserve the photo import's destination date

**Evidence:** `Views/CalendarLookView.swift:611–636`. `handlePhotosPicker` awaits transferable loading, then `save(images:)` reads `selectedDay`. If selection changes during the earlier awaits, the saved post can receive the new day.

**Implementation:** capture the destination date when the picker result is accepted, before the first suspension, and pass it explicitly through processing and `LookPostStore.create`. Keep a task/generation identity for replacement and dismissal. Review memory use: the current import retains an array of original UIImages before processing; process bounded batches or one image at a time if measurements justify it.

**Done:** start import for day A, move to B while loading, and the post still belongs to A. Import failure leaves no misleading success state. The existing note-draft fix remains intact. A focused date-propagation regression test can be added later if Dor requests tests; do not launch a suite by default.

### A03 — Planner: do not compute widget alternatives before a confirm completes

**Evidence:** `Views/OutfitPlannerView.swift:5328–5414`: plan persistence saves, invokes `saveWidgetSnapshot`, which invokes `widgetAlternatives`, which calls `rankLooks` on a memo miss. `WidgetSnapshotService` moves later snapshot processing off-main, but that does not move this earlier ranking. The fast `worn` guard helps day looks; other statuses and evening interactions can still enter this path.

**Implementation:** keep the existing immediate save and widget command ordering. Publish the authoritative current look promptly. Schedule optional alternative computation with coalescing, generation IDs and cancellation on superseding inputs. Reuse the coordinator's ordering; do not allow a slow older alternative result to overwrite a newer confirmed look. Begin with deferred/chunked main-actor work if model APIs require it; a background ranking rewrite requires value snapshots and a pure scorer first.

**Done:** rapid replace → lock → confirm preserves the final slots and wear status in app and widget; stale alternatives never unlock or replace a protected garment. No redundant ranking on repeated identical snapshot requests. Measure current-look publication separately from alternatives becoming ready.

### A04 — Derived state: update on edits, not only changes in collection size

**Evidence:** count observers at `Views/OutfitPlannerView.swift:271–280`, `Views/StatsView.swift:63–69`, `Views/ShopPicksView.swift:177–179,487–488`. A favorite, blocked flag, thermal correction, profile size or forecast change can leave collection counts unchanged. `widgetAlternatives` key at `5376–5381` omits locks and other recommendation context; `availableGarmentsSignature` at `6214+` contains IDs, worn and unavailable flags only. The memo has no explicit invalidation elsewhere in the inspected file beyond its capacity clear.

**Implementation:** inventory the inputs to each derived result. Add narrowly scoped revisions or compact value signatures driven by existing mutation paths, including CloudKit-originated changes. For widget alternatives include locked slot assignments, repeat policy/cross-day exclusions, occasion and preference/model revisions, relevant garment edits and forecast inputs. Do not build a full historical hash in every view body. Coalesce one logical edit into one rebuild. Do not use `.id(UUID())` as a refresh mechanism.

**Done:** change one item's blocked/category/thermal/favorite state without inserting a row; change usual size; update forecast values with the same day count; lock an unchanged outfit. Affected results refresh once and unrelated screens retain scroll position. Preserve stable identities and update `DayCardSignature` when a card input changes. This is a stale-result risk established by the shown invalidation paths; confirm all existing notifications before adding another event bus.

### A05 — Planner hierarchy: reach the outfit before optional engagement

**Evidence:** `Views/OutfitPlannerView.swift:358–442` renders unworn nudge, gap card, calendar/work prompt and Style Swipe before the day cards. Several can coexist. `RootView.swift:64+` can add a sign-in inset above the whole tab.

**Design proposal:** opening order is compact date/weather/event context → today's outfit → worn/not-worn action when relevant → optional evening → tomorrow. Put optional prompts after the first outfit, with at most one expanded prompt at a time. Prioritize a question that changes today's recommendation over shopping or Style Swipe. An empty wardrobe keeps its useful add-item entry instead of an empty outfit shell. Preserve access to all existing actions in context menus or their existing destinations.

**Done:** on the smallest supported iPhone at default text size, the first outfit is reachable with less scrolling than the current baseline; at accessibility sizes content remains readable without forcing everything into one screen. No permission is requested simply by moving a card. Worn, confirmed and uniform-only days retain their existing semantics. Dor reviews the one-screen before/after before expanding the change.

### A06 — Visual system: calm content, glass for the action layer

**Evidence:** `UI/GlassKit.swift:124–182` sends generic surfaces to native glass; `UI/DesignSystem.swift:165–204` applies it to cards and fields. Wardrobe, Calendar and Add use these surfaces repeatedly, sometimes with shadows. Related controls already use `LiquidGlassGroup` in places; the primitive is present.

**Design proposal:** introduce separate semantic styles for (1) content cards, (2) control groups, (3) selected/primary actions. Outfit and garment photography get a quiet, backdrop-aware surface with restrained borders; toolbar, segmented controls and floating actions can use native glass. Reuse existing DS spacing/radius/teal values. Do not flatten all photos or remove user wallpapers.

**Implementation:** pilot the planner day card and one action group. Use `GlassEffectContainer` only for nearby related glass siblings, not as a global wrapper around an entire scroll screen. Avoid glass nested inside glass by default. Add explicit high-contrast and Reduce Transparency treatment for custom surfaces, retaining system behavior for native components. Maintain iOS 18.5 fallback materials.

**Done:** compare light gradient, dark backdrop and busy photo; text and garment edges remain legible, controls have a clear hierarchy, no unintended merging of distant glass shapes. Owner reviews screenshots and scrolling on device. Reduced composition cost is a hypothesis until GPU/render traces show it.

### A07 — Shopping and Stats: coalesce ranking, keep results visible

**Evidence:** `Logic/PurchaseScorer.swift:18,61–115+` is main-actor isolated with a cheap pass followed by a bounded pool of 70 deep candidates. `Views/ShopPicksView.swift:301+,521+` runs ranking synchronously for full picks and the Stats preview; refresh completion and product-count observation can both request work.

**Implementation:** retain the 70-candidate cap and ranking semantics. Add task ownership, cancellation between batches and one revision-keyed ranking result that the top-three preview can reuse. Keep old picks visible with a subtle updating state while refreshing. Yielding between chunks can improve responsiveness but does not reduce total CPU; instrument it. Only move pure value computations off-main after snapshotting all required data, including learned state. Never detach `PurchaseScorer.rank` while it accepts live SwiftData models/context.

**Done:** one catalog revision produces one ranking per relevant input key; switching gender rapidly publishes only the last selection. Saving/hiding/buying updates results consistently. Compare order and reasons for fixed inputs before/after. No claim that a top-three limit avoids the deep ranking pass without inspecting its implementation.

### A08 — LookPost photo restoration: separate path lookup from file repair

**Evidence:** `Services/LookPostStore.swift:18+` creates local files synchronously; `localPhotoPath(for:)` at `48+` may write synced bytes back to disk on the main actor. `Views/LookPosts/LookPostViews.swift:116+` resolves this path before background downsampling. `Views/CalendarLookView.swift:649+` also calls the resolver while filtering posts. These are cold-device restoration paths, not proof every thumbnail causes a disk write.

**Implementation:** provide a cheap read-only path lookup and a separate async repair/preparation operation. Capture photo bytes and destination safely on the owner actor, write on a media worker, publish any model path update back on the owner actor. Deduplicate simultaneous repair for the same post. Keep one authoritative post photo and preserve the cache semantics.

**Done:** a newly synced post with missing local cache loads without file writes during body evaluation; no duplicate repair for simultaneous profile/calendar requests. Deleting a post during repair cannot resurrect it or publish a stale image. Keep deletion-after-navigation semantics.

### A09 — Accessibility is part of the smooth design

**Evidence:** `UI/OutfitLookRow.swift:280–320` contains 28×44 close controls and a fixed 40-point capture CTA with one-line scaling. `UI/GlassKit.swift` has no explicit Reduce Transparency branch for its custom fallback stack. Existing Reduce Motion handling, scaled metrics and accessibility actions should be retained.

**Implementation:** aim for comfortable 44×44-point hit areas where layout permits, with spacing that prevents overlap. Use minimum heights and adaptive wrapping rather than shrinking essential Hebrew text. At large text sizes stack dense action rows and filters vertically where needed. Use semantic leading/trailing and SF Symbols direction behavior. Review combined accessibility elements so individual actions remain reachable. Selection/status must use shape/text/traits as well as color.

**Done:** owner checks English/Hebrew, VoiceOver, largest accessibility sizes, Bold Text, Increase Contrast, Reduce Transparency and Reduce Motion. Verify event/date order and action names in Hebrew. Do not call every sub-44 control an automatic HIG violation: context and actual hit areas matter. See [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### A10 — Replacement: safe lifecycle and continuous feedback

**Evidence:** `UI/OutfitLookRow.swift:393–411` animates out, then executes `onReplace` in `DispatchQueue.main.asyncAfter` after 0.16 seconds. There is no cancellation handle or item-generation guard in this function. The callback's relevance after navigation/rebinding must be verified.

**Implementation:** model the phases locally (idle, outgoing, applying, incoming), with one cancellable task and captured look identity. Permit one replacement at a time. Compute the replacement before the moment it must appear when practical; never show an empty card while waiting. Keep the UIKit horizontal recognizer and VoiceOver equivalent. Preserve Reduce Motion's immediate path. Use one haptic per meaningful commit.

**Done:** quick double gestures, navigation away during the delay and an external widget update cannot replace a different day's look or leave an offset card. Animation timing is a design choice, not a performance measurement. Follow [Apple motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion).

### A11 — Navigation and wallpaper polish

**Evidence:** `UI/AppBackdropPreference.swift:245+` hides navigation/tab background fills globally. `RootView.swift:71+` can synchronously load a custom image for a one-time luminance backfill. `UI/GlassKit.swift:65–79` awaits detached wallpaper work without a cancellation check before assigning the result.

**Implementation:** compare native bar behavior against the current custom treatment on one screen before changing the shared helper. Retain navigation stacks, back buttons and the existing root/pushed navbar distinction. Move any luminance backfill loading off-main. Add cancellation/generation checks to wallpaper publication and coalesce rapid blur changes if a trace demonstrates repeated expensive preparation.

**Done:** a busy wallpaper never compromises bar labels; interactive back and scroll-edge transitions stay coherent; a slow old wallpaper task cannot replace the newest selection. Do not apply scroll minimization to the tab bar by default: navigation discoverability needs review first.

### A12 — Platform adoption spike, after core improvements

Inspect the installed SDK before writing code. Consider native overflow prioritization for crowded toolbars; remote `AsyncImage` caching for shop images; and native swipe/reorder APIs only if their available semantics match the planner's slot locks, linked evening items, nested scrolling and RTL. Keep local `ImageStore` for wardrobe files. Availability is per symbol; retain the current deployment target and fallback behavior. Deliver a small proposal listing exact declarations, availability and the interaction it improves. Do not implement all candidates together.

## Validation and measurement handoff

These are proposed checks for Dor to run or authorize later, not checks executed in this audit. Agents must obey AGENTS.md: no builds, simulator or default test runs. Use the existing `Helpers/WearItPerformance.swift` signpost subsystem and existing Bootstrap/Widget instrumentation before creating new infrastructure. Log interval IDs and counts, never clothing names, photos, locations or event titles.

Use a physical device, the same OS/build configuration, the same wardrobe and the same thermal conditions before/after. Separate cold cache, warm cache, offline and CloudKit photo restoration. Include a typical wardrobe and a larger owner-approved dataset; do not seed fake data into the real synced store. Record device, item/history counts and cache state with each trace.

| Scenario | Capture | Baseline | Success criterion |
|---|---|---|---|
| Open planner and scroll all three days | SwiftUI + Time Profiler + animation hitches | Not measured | First outfit appears sooner or unchanged; fewer long updates; same content |
| Crop → details; batch save | Main-thread intervals, responsiveness, memory | Not measured | Encoding/write work leaves main; touch feedback appears before optional processing |
| Replace → lock → confirm → widget | Input-to-state latency; ranking count; snapshot events | Not measured | Correct latest state; optional ranking outside immediate confirm path |
| Shopping refresh and gender switching | Ranking duration/count; selection-to-first-result | Not measured | No stale publication; reduced duplicate ranking; scrolling remains responsive |
| Profile cold photo restoration | File repair time, image decode, peak memory | Not measured | Repair off-main and deduplicated; images stay associated with the right post |
| Calendar import while switching dates | Post date and visible status | Not measured | Original date preserved for every imported photo |

Proposed engineering targets, to calibrate after baseline: visible touch feedback within 100 ms at p95; no individual app-induced main-thread stall above 100 ms in these flows; aim for frame work within the active display budget (about 16.7 ms at 60 Hz, 8.3 ms at 120 Hz, with headroom for the system). These are internal goals, not Apple guarantees or measured WearIt numbers. Do not force 120 Hz or mask expensive work with longer animations. For scrolling compare hitch duration/count, not average FPS alone. For energy compare the same-duration interaction recording; shorter elapsed work is not automatically lower energy.

Use the [SwiftUI Instruments cause-and-effect graph](https://developer.apple.com/videos/play/wwdc2025/306/) to find which state actually invalidates the heavy subtree before splitting broad queries. Read [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) for capture interpretation. No trace-backed diagnosis is available yet.

## Delivery sequence and agent contract

1. Dor selects the first packet. Recommended start: A02 (small correctness fix), then A01 (likely visible responsiveness gain). Add narrowly scoped signposts only as needed for those changes.
2. A04 then A03, so the alternative pipeline has a correct input identity before it becomes asynchronous.
3. Dor reviews A05's hierarchy and A06's surface pilot together; implement the approved single screen, then extend shared tokens. A09 accompanies those changes.
4. A07/A08 address remaining computation and cold-media paths. A10/A11 polish lifecycle and transitions after correctness is stable.
5. A12 remains an independent SDK-verified exploration.

One branch and one PR per focused change when publishing is requested. No commit/push/merge for this audit. No parallel agents were launched. Separate fixes sharing a file should be sequenced to avoid conflicts; shared DS/GlassKit changes can affect every screen.

Each implementation handoff must state: packet ID; observed code path; changed behavior; data invariants preserved; validation actually performed versus pending owner checks; before/after evidence if supplied; remaining limits. Re-read current code and relevant LEARNINGS before editing: line references here are navigation aids and will move.

Do not introduce a new package, full app architecture migration, broad @Observable conversion, universal `.equatable()`, forced view identity resets or a planner file split as a prerequisite. Preserve CloudKit-safe models, CurrentUser, LookPostStore ownership, debounced saves, slot-based look identity, day/evening wear semantics, locks and deterministic AI fallbacks. Localize new UI in both languages. This audit is a menu of concrete improvements; it does not authorize all implementation work.

## Relationship to earlier reviews

`docs/LEARNINGS.md` records the October 7 design fixes and references `audits/design-review.md`, but that older report was not found in this checkout. The battery/CloudKit report exists at `WearIt/Docs/BatteryCloudKitAuditReport.md`. This audit uses the current code and does not assume previously fixed issues are still open. Existing local modification to `WearIt.xcodeproj/project.pbxproj` was left untouched.
