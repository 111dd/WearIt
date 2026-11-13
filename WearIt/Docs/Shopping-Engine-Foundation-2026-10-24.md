# Shopping engine local foundation — 2026-10-24

Status: implemented locally after Dor approved starting the first packet from [the proposal](Shopping-Engine-2026-10-24.md). Source review only. No build, tests, simulator, app launch, benchmark, crawl, new service signup/deployment, commit or publication was performed.

Owner build follow-up: Dor reported two type-check timeouts in `ShopSearchProfile.swift`. Split ownership support arithmetic, evidence/confidence aggregation, style accumulation and retailer priority construction into explicitly typed steps/helpers. Weights, confidence rules, product identity, ordering/tie rules and eligibility remain unchanged. The agent did not compile; confirmation in the next owner build is pending.

## User-visible behavior

- Existing eligible products gain a small ordering bonus from brand/style/type evidence specific to their category. A shoe-brand preference no longer supplies this new bonus to unrelated clothing categories.
- Ownership alone is weak evidence. Repeated wear, actual outfit choices, saved/bought products and explicit shopping preferences supply stronger support. A single owned item cannot establish high confidence. Unknown reasons for a dismissal supply only a weak negative and cannot ban a retailer or brand through this profile.
- Brand/style explanations require sufficient evidence from the new profile. Type-default style tags stay weak, so a generic casual type does not establish a strong personal style match on its own.
- Shopping and its Stats preview now observe the same 400 wear / 300 recommendation events. Stats' other calculations retain their existing 200-wear-event input.
- The current Terminal X/Castro catalog remains the active product source. Source coverage ranking exists as a local helper for the next retrieval packet; it does not trigger searches, contact new stores or run an unused full-catalog pass during ranking.

The existing personal selection remains stable: occupied slots stay occupied across refreshes, save/open and relaunch; dismissal frees a slot. Purchased/unavailable/unsuitable products hide without automatic substitution. Newly ranked products fill eligible empty slots. This packet deliberately does not reset existing selections to force different recommendations onto the screen.

## Reduced repeated work

`ShopRankingCoordinator` coalesces matching requests before snapshot preparation. Shopping and Stats can share an in-flight calculation or a completed value result. It keeps at most two completed results with a 60-second lookup lifetime. Each caller has its own waiter; cancelling one screen does not cancel a calculation still needed by another, while the last cancelled waiter cancels abandoned work.

Live SwiftData objects are read only on MainActor and copied into value snapshots. `ShopRankingWorker` reconstructs uninserted actor-local models and computes the existing wear summary, choice signals, taste and wardrobe gaps in the worker, then builds the new search profile and ranks. Saved model objects and `ModelContext` never cross the boundary. Snapshotting, current department/size resolution, feedback summaries and comfort preparation still have a MainActor component.

Cheap per-product affinities/reaction values are now computed once for Explore estimates and personal shortlist selection through `PurchaseScorer.rankAndMatch`. The existing deep budget remains 70 clothing candidates plus up to 10 accessories; held IDs, useful-offer reserve, full outfit/weather/size/department gates and old feature positions remain intact.

Catalog cache directory lookup, reads and atomic writes now run on utility workers alongside the existing detached decoding/mapping. MainActor still owns product publication, loading/error state, revisions and ETag sequencing.

## Invalidation and cancellation

- Preserve the comprehensive content signature rather than substituting array counts. Sort signature inputs canonically so query ordering alone does not prevent reuse.
- Newly include consumed `shopProductID`, wear source, feedback revision, calendar/time zone and locale. Existing signature fields cover wardrobe edits, preferences, plans, weather, recommendation feedback and same-count catalog revisions.
- Key ranking additionally by current profile/preferences, held product IDs, copied look-model weights/interactions and a minute epoch. Cache expiry is separate from semantic result validation; crossing a minute during a calculation cannot strand an empty Stats preview.
- Both surfaces discard cancelled/stale results and reschedule a non-cancelled request when its semantic inputs change during the await.
- Insufficient inputs return empty only to that caller; they do not globally cancel another screen's work.
- Account deletion resets shared in-memory ranking work/results and shopping feedback in the same synchronous main-actor deletion turn. Otherwise an already-created feedback singleton would retain old signals after its UserDefaults domain was removed.

The 60-second time bound is checked on a request. It is not a timer, live inventory tracking or a promise of a scheduled foreground refresh. No additional polling was introduced.

## Evidence and limits

`ShopSearchProfile` is an ephemeral versioned value, not a new SwiftData entity or synchronized behavioral history. It records independent-item evidence, confidence and positive/negative mass for brands/styles/types by category. A purchased product appearing both in the wardrobe and shopping feedback counts as one identity. Explicit shopping preferences are separate strong evidence.

Legacy brand/type form provenance is not reliably persisted by Add. Their owned metadata therefore receives a conservative 0.65 reliability instead of pretending to distinguish manual from inferred fields. Persisted style enrichment and exact legacy type-default sets are discounted. This does not introduce brand aliases, brand-specific body fit, a learned spending budget or visual product embeddings.

The old eligibility metrics and online-learning feature positions remain unchanged; the new confidence profile adds up to 0.10 to candidate/final ordering. This preserves the existing pre-ranking gates, while intentionally allowing the bounded shortlist/order to change. Exact before/after recommendation parity is not claimed. Full garment snapshots now also retain favorites, wear history, owner/size/layer/occasion fields that the earlier ranking-only snapshot omitted, so local look scoring receives the consumed wardrobe facts.

Signposts now separate `snapshot`, `preparation` and `ranking`, with `result-cache-hit`, `shared-ranking` and `ranking-cache-hit` events. They contain no garment names, paths, photos or private request data. Source structure establishes fewer duplicated calculations and background execution; no numerical speed or recommendation-quality improvement has been measured.

Remaining preparation work includes MainActor signatures/observation and the smaller context/feedback snapshots. Replacing full signature traversals needs reliable store/change revisions; this packet keeps correctness rather than inventing incomplete invalidation. No additional CPU workers or photo concurrency were added.

## Source changes

| File | Responsibility |
| --- | --- |
| `Logic/ShopSearchProfile.swift` | Category-specific evidence and optional local source coverage helper |
| `Services/ShopRankingCoordinator.swift` | Shared cache, in-flight work and waiter cancellation |
| `Services/ShopRankingWorker.swift` | Value snapshots, background derivation, profile and ranking |
| `Logic/PurchaseScorer.swift` | Shared cheap evaluation, ordering bonus and evidence-based reasons |
| `Views/ShopPicksView.swift`, `Views/StatsView.swift` | Canonical shopping history, shared requests and stale-result guards |
| `Services/ShopCatalogService.swift` | Background disk cache I/O |
| `Helpers/WearItPerformance.swift` | Shopping signposter |
| `Logic/ShopFeedback.swift`, `Services/AccountDataService.swift` | In-memory reset on account deletion |

No new user-facing strings were added. Existing localized reason strings remain the presentation path. Pre-existing planner, garment, shopping-filter, photo and crawler edits were retained.

## Owner device review

After an owner build, compare the same wardrobe and shopping preferences before/after:

1. Open Shopping, then Stats, then return; compare held product IDs, reasons and cache-hit/shared-ranking intervals. Review an initially empty selection and a pre-existing occupied selection separately.
2. Check explicit preferred brands, sparse one-brand closets, repeated actual wear, category-specific brands and default/inferred styles. Check save/open/dismiss/buy and purchase Undo; no duplicate independent evidence for a purchased wardrobe item.
3. Change a garment brand/type without changing count, refresh same-count catalog metadata, change profile/preferences/plan/weather, and navigate away during ranking. Confirm no stale result or empty-preview dead end.
4. Retain independent For You/Explore category/type/saved/deal filters, unsupported/unknown sizes, verified offers, seasonal opt-in, complete dress/jumpsuit looks, accessories and locked/saved planned looks.
5. Exercise account deletion/onboarding to confirm previous feedback and cached picks do not reappear.
6. Measure cold/warm first useful shopping content, snapshot/preparation/ranking duration, UI-thread work, scrolling, first photo, memory and energy. Use the existing actor ranker as the concurrency baseline; more tasks are not evidence of better performance.

Next separate decision: select additional sources based on actual missing brand/type coverage and choose whether to add a small indexed public-catalog service. Hosting, paid web discovery and new remote personal request data remain unconfigured.
