# WearIt concurrency and performance audit — 2026-10-21

Scope: code review of launch, planner/advice/widget generation, shopping, wardrobe image loading, photo processing and image sync. Requested outcome: faster interactions and better use of Apple processors without reducing features or recommendation quality. No application code changed during this audit. No build, tests, simulator, app launch or profiling run was performed.

The earlier paused-device crash supplied direct evidence of stack exhaustion during Swift generic metadata decoding of the day card. Its source fix is saved but has not been confirmed in a rebuilt app. That crash is not a CPU benchmark. All performance rankings below are hypotheses grounded in call paths, not measured percentages or a guarantee of faster execution.

## Conclusion

The largest visible opportunity is to move planner computation off the UI actor and stop optional advice/widget work from extending UI updates. The app already has useful off-main work; the main deficiency is inconsistent isolation, duplicated derived work and independent queues competing without an overall resource policy.

Moving work off-main improves responsiveness even when total calculation time stays the same. Parallel calculation can reduce elapsed time only for independent, sufficiently large work. An actor serializes its synchronous work; it is not a multicore accelerator by itself. `Task` and `async` do not alone establish a background boundary. Apple explains these distinctions in [Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/).

Do not bind tasks to specific performance/efficiency cores or create a thread per garment. Express urgency and dependencies; the operating system schedules the available resources using QoS. Raising everything to high priority competes with interaction and does not create CPU capacity. See [Addressing CPU bottlenecks](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks) and [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/).

## Findings, in recommended order

### P1 — Planner scoring remains synchronous on the UI actor

Evidence: [scheduleGenerateAllOutfits](../Views/OutfitPlannerView.swift) around line 5065 creates an inherited-context Task. `generateAllOutfits` calls synchronous `generateDayOutfit` / `generateEveningOutfitIfNeeded`, yielding only between days. `generateDayOutfit` calls `AIRecommender.suggestOutfit` before updating/saving the board. [rankLooks](../Logic/AIRecommender.swift) around line 911 builds the core candidate combinations, computes look features and sorts results. With six candidates in each core slot, the core pass can score 216 combinations, plus item scoring and optional layers. This bound alone does not establish that it is slow.

Recommendation: extract the existing scoring rules into a pure engine using immutable Sendable snapshots of garment features, preference weights, wear/availability and weather/calendar context. Copy inputs on their owning actor; return IDs and scores. Keep SwiftData models, `ModelContext`, training and saved-plan mutations on their owning actor. Start with one background calculation, then measure whether two bounded partitions improve elapsed time.

Preserve the current candidate counts, optional layers, locked garments, repeated-item toggle, replacements, contextual shorts comfort and learned taste. Day-to-day exclusions depend on previous choices: keep day/evening selection and commitment in order. Parallelize scoring within a fixed request, not blindly all days. Merge partitions in original order before applying existing tie handling and diversity selection.

Important: `ensureState` fetches/inserts/migrates/saves models, and the recommender caches model objects. Do not call the existing context-taking API from `Task.detached` or share its models across workers. Shopping's snapshot boundary is a useful pattern, not permission to share its worker-local transient models either.

Effort/risk: larger bounded change; highest functional risk if computation and persistence are not separated. First measure `day-recommendation` and new snapshot/score/apply intervals.

### P1 — Advice and widget alternatives add synchronous work to render/save paths

Evidence: `dayColumn` calls `changeSuggestions`; a cache miss calls `OutfitChangeAdvisor.suggestions` synchronously (around lines 848 and 2354). `persistDayPlan` calls `saveWidgetSnapshot`; that computes `widgetAlternatives`, calling `rankLooks`, before the snapshot service dispatches thumbnail work to its background actor (around lines 5478–5549). [WidgetSnapshotCoordinator](../Services/WidgetSnapshotStore.swift) already prepares thumbnails off-main, so it is the earlier alternatives step that needs attention.

Recommendation: compute optional advice asynchronously from a revisioned snapshot, outside body evaluation. Save/publish the current widget look and wear status first; add alternatives from a background result only when the same plan is still current. Coalesce duplicate requests before scoring, not only before WidgetKit reload.

Preservation requirements: an old advice/result must never overwrite a new selection, resurrect dismissed advice, or change a worn/confirmed plan. While alternatives are pending, retain valid previous alternatives for the same inputs; discard them when their inputs become invalid. Keep widget commands authoritative.

Correctness prerequisite: the current alternatives cache key includes date, assigned IDs, forecast and wardrobe signature, but not explicit lock flags, all cross-day selections or learned-weight revision. Expand invalidation before making the cache more persistent. Faster reuse of stale suggestions would be a regression.

Effort/risk: medium; share the pure scorer from P1 rather than implementing a second recommendation engine.

### P1 — Local thumbnails need shared in-flight work and cancellation

Evidence: [WardrobeTileView](../Views/WardrobeView.swift) around line 905 and [DSGarmentThumbnail](../UI/DesignSystem.swift) around line 444 each launch a detached decode and await its value. The later cancellation check prevents assigning stale UI, but does not cancel the detached job. [ImageStore](../Services/ImageStore.swift) has useful byte-budgeted caches (64 MiB + 32 MiB), yet cache misses from simultaneous consumers can duplicate decoding. No shared admission bound is present in these callers.

Recommendation: a shared local preview coordinator keyed by source/version, pixel size and trim mode, coalescing waiters. Remove queued work when no consumer remains; propagate cancellation to active work and check it between stages. A synchronous decode may still finish before cancellation takes effect. Start by measuring a limit of two decodes, with a third only if profiling justifies it. Return cached previews immediately and prioritize visible content.

Preserve full-resolution originals, cutout alpha, photo roles, manual cover selection and cache invalidation. The same file at a different display size is a distinct result. This proposal changes scheduling, not saved image quality. A global serial queue for all images would create a new bottleneck.

Effort/risk: medium; likely relevant to rapid scrolling, memory peaks and battery. Benefit must be measured under cold-cache scroll, not only warm-cache reopen.

### P2 — Shopping's heavy pass is off-main, but preparation is not

Evidence: [ShopPicksEngine.picks](../Views/ShopPicksView.swift) lines 16–80 computes wear summaries, taste, wardrobe gaps, department resolution, weather history and snapshots on MainActor before invoking [ShopRankingWorker.rank](../Services/ShopRankingWorker.swift). The comprehensive signature (around line 215) traverses garments, history, forecasts and feedback; it is also used for view task IDs and again inside preparation. The screen queries complete wear/recommendation history. The ranking actor caches only after those inputs have been prepared.

Recommendation: first reuse derived summaries by explicit data revision, and move pure derivation to value-based workers. Share compatible results between Stats and Shopping. Retain full historical learning through incremental aggregates; do not silently truncate history to make the screen faster. Revision changes must cover CloudKit imports, deletes, edits, profile switching and preference corrections, not only array counts.

Only after measurement, partition expensive independent product scoring into a small task group. Keep candidate selection, global diversity, accessory attachment and final merge coordinated. Maintain stable ordering, all current eligibility/size/weather rules and the 70-clothing/10-accessory budget. The serial actor currently provides useful protection against overlapping runs and shared mutable transient models; removing it indiscriminately is unsafe.

Effort/risk: medium for preparation caching, larger for parallel scorer extraction. Add separate timings for snapshot preparation, cheap matching, deep ranking and publication.

### P2 — Background image/network jobs lack a common workload budget

Evidence: [ShopProductPhotoService](../Services/ShopProductPhotoService.swift) already coalesces requests, bounds the queue and runs at most three shared jobs with cancellation and progressive images. [CloudKitImageSyncService](../Services/CloudKitImageSyncService.swift) deduplicates each record but can launch detached jobs for many different records without an app-wide transfer limit. [GarmentVisualSimilarity.warmUp](../Services/GarmentVisualSimilarity.swift) computes up to 40 new fingerprints per launch in the background. These paths can overlap local decoding, photo editing and purchasing.

Recommendation: separate network admission from expensive CPU/Vision admission. Give visible-image decode and explicit user edits priority over optional studio-photo refinement/fingerprint warm-up. Reduce optional concurrency during serious thermal pressure or Low Power Mode and resume later. Do not cancel required purchase persistence or lose pending sync. A first experimental policy is two heavy CPU image jobs total, with one optional Vision refinement allowed; these are starting measurements, not universal optimal limits. Network jobs can have a different bound because most of their lifetime is waiting.

For image sync retain per-garment ordering and the latest-cover coalescing already present. Preserve retries, cancellation/delete semantics and asset cleanup. Never drop queued user data to satisfy a concurrency cap.

Effort/risk: medium. Do not increase shopping's three jobs just to match a processor's advertised core count.

### P2 — Remove repeated computations before multiplying workers

Evidence: [AIRecommender.similarityBonus](../Logic/AIRecommender.swift) around line 436 scans peer garments for each eligible new item, builds color/style sets and can compute Vision feature-print distances. Different ranking calls repeat this work. [WardrobeView.rebuildVisibleGarments](../Views/WardrobeView.swift) around line 122 builds wear maps, filters/sorts and resolves a question synchronously; debounce already reduces how often this happens.

Recommendation: cache immutable per-garment feature vectors/sets and expensive pair similarities, and precompute query-specific bonuses once. Include image/feature-print revision, taste/love and relevant candidate-pool membership in keys; do not reuse a best-peer bonus from a different pool. Invalidate on edit, import and deletion. Move wardrobe filter/sort over value snapshots only if measured cost warrants it; preserve localized sorting and all filters.

Effort/risk: medium. Do not remove visual similarity, personalization or diversity as an optimization. Small vector dot products are not an automatic reason to adopt Accelerate or Metal; batch size and conversion overhead must justify that extra implementation.

### P3 — Launch and independent destination weather requests

Evidence: [AppBootstrapper.loadContainer](../Services/AppBootstrapper.swift) constructs the store synchronously on MainActor despite being async. [BootstrapCoordinator](../BootstrapView.swift) correctly gates the initial screen and defers other work, but deferred closures are explicitly MainActor; deferred does not mean background. Some thumbnail work is already detached. The planner's `refreshEventPlaceForecasts` around line 4555 deduplicates locations within a pass but awaits distinct locations serially.

Recommendation: measure store opening, migration, auth and deferred maintenance separately before touching startup ordering. Move only pure maintenance calculations to snapshots initially. Do not detach the live context or mount the planner before critical migrations. For weather, collect distinct location value requests and fetch a small number concurrently, then apply one revision-checked result. That improves network waiting, not CPU-core utilization. Preserve destination date matching, calendar interpretation and real-weather failure handling; no fabricated home/destination weather on failure.

Effort/risk: medium to high for store startup; modest for independent weather requests. Lower priority unless traces show it dominates.

## Apple hardware: what to use and what to retain

- Scheduling: user-initiated scoring/visible content should have appropriate urgency; maintenance and optional analysis should be lower priority. Avoid semaphores or blocking waits on Swift's cooperative pool. A bounded task group needs genuinely concurrent worker functions; calling one synchronous actor method from every child still serializes the work. Project settings currently use Swift 5 mode with Approachable Concurrency enabled; inspect actual compiler isolation before adopting newer `@concurrent` syntax. Do not bundle a language-mode migration into this change.
- Photos: [LookPhotoProcessor](../ImageProcessing/LookPhotoProcessor.swift) already reuses a CIContext and separates Vision analysis from rendering. Retain this. Core Image handles hardware selection, and its context can be reused across threads while mutable filters must not be shared concurrently; see [CIContext](https://developer.apple.com/documentation/coreimage/cicontext). Avoid repeated CPU↔GPU image conversions rather than introducing custom shaders without evidence.
- Vision: supported devices vary by request/stage and hardware. [VNRequest.supportedComputeStageDevices](https://developer.apple.com/documentation/vision/vnrequest/supportedcomputestagedevices) exposes that support. There is no evidence here that every existing request uses the Neural Engine, and no reason to promise that forcing it would help. Keep on-device processing and existing quality until measured alternatives match results.
- Existing strengths: background catalog mapping, serial shopping snapshots, progressive bounded shop photos, image cache byte limits, media persistence actor, background widget thumbnail generation, planner save debounce and existing signposts. Improve their missing boundaries rather than replace all of them.

## Feature-preservation contract

Every result request carries profile identity and input revisions. Before committing, verify current selected/locked slots, plan date, wear/confirmation status, weather/calendar inputs and preference revisions. Discard obsolete computation without discarding user actions. Keep feedback updates and saves ordered and exactly once, including purchase/Undo and widget commands.

The parallel version must score the same eligible items with the same rules as the serial baseline. Return only value results and stable IDs; preserve reduction/tie ordering. Compare both paths on identical snapshots before removing the serial fallback. Respect dependencies between day/evening and cross-day repetition. UI updates stay on MainActor; live SwiftData objects stay on their context's executor. Avoid `@unchecked Sendable` as a workaround for crossing that boundary.

## Measurement and delivery sequence

1. Establish a device baseline once Dor runs the rebuilt app. Use the same Release/Profile configuration, dataset, OS, thermal state and interactions for before/after. Debug crash evidence is insufficient for a speed claim. Record cold/warm launch, first useful screen, replace-look latency, day/evening generation, rapid wardrobe scroll, first useful shopping image, add-photo persistence and widget update latency.
2. Extend [existing signposts](../Helpers/WearItPerformance.swift) to advice, widget alternatives, snapshot preparation, ranking, decode/refinement and queue wait. Record P50/P95 duration, main-thread long slices, frame hitches, peak memory, CPU time, energy/thermal behavior, duplicate work and stale-result drops. Test offline/slow network, rapid filter/profile changes and Low Power Mode separately. Use synthetic small/medium/large wardrobes for scale; do not log personal photos, names or receipt data.
3. First implementation packet: pure planner scorer off-main plus stale-result protection; then move advice/widget computation onto it. Confirm parity of locked/worn/uniform/trip/repetition/learning behavior.
4. Second packet: shared local preview pipeline, cancellation and resource admission. Confirm image fidelity, no missing covers and bounded memory during scroll/import.
5. Third packet: derived-input caching and measured bounded scoring parallelism (compare one versus two workers before trying more). Retain serial execution for small inputs or devices where overhead wins.

Acceptance: improved measured responsiveness without altered eligible results or lost feature behavior, and no material regression in peak memory, energy or persistence correctness. No numerical speedup is claimed until these measurements exist. This audit recommends the implementation sequence; it does not implement it.
