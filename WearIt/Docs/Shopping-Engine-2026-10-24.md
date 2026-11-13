# Shopping discovery engine: proposal and cost comparison — 2026-10-24

Status: Dor authorized starting the local foundation after reviewing this proposal. See [the implemented first packet](Shopping-Engine-Foundation-2026-10-24.md). The server/provider alternatives below remain a proposal; no service signup, paid request, deployment, crawl, build, tests, simulator, app launch, commit or push was performed. Official pricing/documentation was checked on 2026-10-24.

## Recommended direction

Use an evidence-aware shopping profile on the phone to select useful brands, product types and sources. A shared public-product index can return a bounded candidate set; the existing local ranker evaluates actual outfits, sizes, weather and wardrobe gaps. Add broader web discovery only when indexed sources lack suitable products. This preserves the useful existing recommendation engine and separates source discovery from personal outfit ranking.

Start with the reusable local profile/performance foundation. If Dor chooses a server, build a small indexed-catalog pilot first. Measure its coverage and cost before enabling a paid web-search provider. A more capable search system does not require a paid language-model call for each recommendation.

## What is already implemented

| Capability | Current source evidence |
| --- | --- |
| Wardrobe brand/color/style/fit/material taste and choice signals | `Logic/TasteAffinity.swift:165`; durable snapshot in `Models/TasteProfile.swift:4` |
| Save/open/dismiss/bought learning with different strengths and recency decay | `Logic/ShopFeedback.swift:100–168` |
| Personal department/size/weather/complete-outfit eligibility and shortlist scoring | `Logic/PurchaseScorer.swift:99–233` |
| Background deep ranking using value snapshots | `Services/ShopRankingWorker.swift:3–55` |
| Bounded shared photo loading, progressive previews and cancellation | `Services/ShopProductPhotoService.swift:45–165` |
| Persistent personal selection of up to 20 occupied slots | `Logic/ShopPersonalSelection.swift:4–57` |

Discovery currently collects the same two configured stores for everyone: Terminal X and Castro (`../scripts/catalog/stores.json`). The nightly collector publishes one country JSON (`../.github/workflows/catalog.yml`). The phone downloads the full catalog; mapping is off-main, with ETag/cache support (`Services/ShopCatalogService.swift:123–230`). Learned taste currently changes ranking after retrieval; it does not select internet sources or generate personal search queries.

The documented 2026-10-21 publication result is historical, not a live count of today's products or stock. `plans/shopping-israel.md`, referenced by older comments, was not present in this checkout.

## Three options and their differences

| Option | Work on shared infrastructure | Work on the phone | Reach and tradeoff |
| --- | --- | --- | --- |
| A. Improve the existing setup | Existing nightly collector; publish coverage manifest and optionally store/department shards | Learn profile, select shards, retrieve and rerank locally | No new service required. More stores need adapters. The phone still handles more catalog data and retrieval; this is curated catalog discovery. |
| B. Small catalog/search service | Existing collector feeds an indexed public catalog; service selects sources/products and prepares reusable public metadata | Send a compact shopping request, then validate/rerank the returned candidates against the wardrobe | Smaller payloads and less repeated catalog work on the phone. Requires operating an endpoint and database. Coverage still depends on connected sources. |
| C. Catalog service plus web discovery | Option B plus bounded provider queries for uncovered brands/styles/products, then product-page validation | Same private final ranking as B | Broader discovery and more variable cost/latency. Search snippets do not establish live stock, exact-size price or delivery. |

The existing setup already uses remote collection on GitHub. “No new server” means keeping that setup, rather than collecting the internet on the phone. New manifests/shards must be additive: retain the existing version-1 country catalog for installed clients, and switch retrieval only in a compatible app version. Moving work to a service can improve responsiveness by reducing bytes and repeated work; the actual benefit needs owner-run device measurements.

## Operating costs, in USD

These are infrastructure/provider examples, not development or maintenance quotes. They exclude taxes, paid retailer feeds, optional image processing/storage, domain registration and future model usage. No exchange-rate conversion is assumed.

| Component | Current official pricing / planning implication |
| --- | --- |
| Option A | No new provider fee by design; existing GitHub usage/limits still apply. Extra source adapters have implementation and maintenance cost. |
| Small endpoint | Cloudflare Workers has a limited Free tier. Its Paid plan starts at **$5/month**, including 10 million requests and 30 million CPU milliseconds/month. This is a practical pilot example, not a selected hosting vendor or a complete production quote. |
| Public product database | D1 has Free/Paid allocations. On Workers Paid, the first 5 GB, 25 billion rows read/month and 50 million rows written/month are included; overages are separate. A modest indexed catalog may fit, but estimate actual database/index size and refresh writes before promising the base price. |
| Optional web search | Brave Search lists **$5 per 1,000 requests**, with $5 recurring monthly Search credits. One app refresh can cause zero, one or several provider requests; it is not priced per app user. |

Example arithmetic, before provider credits and other usage: a $5 endpoint plus 1,000 provider requests/month is **$10/month**; plus 10,000 provider requests/month is **$55/month**. These illustrate scale, not a forecast of WearIt's bill. With an indexed-catalog-only pilot there is no web-search line item. A small experiment may fit free allocations, subject to their limits.

Set explicit provider-request and spend budgets; stop optional discovery at the budget and continue with indexed/cached eligible products. Shared catalog retrieval should supply normal refreshes. Avoid turning every screen opening, keystroke or user action into multiple paid web searches.

Important provider selection constraint: Brave's public pricing FAQ says storing results requires storage rights; its help page states retention is prohibited unless separately arranged. Confirm the exact plan/contract before persisting or sharing any provider-returned data, including URLs/snippets. No default right to cache search results is assumed. Prefer merchant feeds or independently collected public product data where permitted; obtain any required search-storage rights before designing persistent discovery around a provider. Search access itself grants no rights to retailer content.

Official references:

- [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Cloudflare D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)
- [Brave Search plans](https://api-dashboard.search.brave.com/app/plans)
- [Brave API pricing and storage-rights FAQ](https://brave.com/search/api/)
- [Brave retention/help guidance](https://api-dashboard.search.brave.com/documentation/resources/help-feedback)

## How smarter personalization should work

1. **Local evidence-aware shopping profile.** Reuse existing taste/feedback signals and add category-specific brand/type/style affinities, evidence counts, provenance, confidence and freshness. Explicit preference wins over a weak guess. Keep sizes and department as shopping facts. Budget is optional and user-correctable; ownership alone does not prove willingness to pay a particular price.
2. **Source coverage registry.** Separate brand identity from retailer identity. Record canonical names/aliases, observed brands/types/departments, target-market/delivery evidence, data freshness, adapter method and metadata quality. Use observed catalog coverage rather than invented stereotypes about a store's style.
3. **Bounded source/query planning.** Prioritize sources with matching brands/types and reliable market evidence. Generate structured queries from a real wardrobe need, then broaden to compatible unfamiliar brands when confidence or coverage is low. Keep an exploration allowance; do not exclude all unknown brands. General search supports domain/country/language targeting, but country ranking is not proof of shipping eligibility.
4. **Product evidence and deduplication.** Retain source URL, timestamps, explicit/inferred attributes, product group/variant identity, original size scale and size-specific offers where available. Use confirmed identifiers for cross-store matches; similar titles alone do not establish the same SKU. Unknown availability stays unknown.
5. **Local outfit reranking.** Reuse `PurchaseScorer` and its existing complete-look/size/weather/department gates. Begin with a proposed 100–300 retrieved candidates, then retain the existing deep budget of 70 clothing candidates plus up to 10 accessories. Evaluate retrieval coverage against the existing full-catalog path before reducing the data used in production. Held and saved IDs need direct lookup even when absent from a new retrieval batch.

Example, using fictional preferences rather than Dor's actual data: repeated positive evidence for clean casual tops from brand A creates a request for that type/fit/style. The router selects stores with observed brand A or compatible product coverage, retrieves suitable candidates, and the phone checks whether each candidate makes useful outfits with owned pieces. A user can like one brand for shoes and another for outerwear.

Confidence matters: `TasteAffinity.swift:142–145` peak-normalizes affinity, so one weakly represented brand can score 1.0. Catalog styles may come solely from type defaults (`ShopCatalogService.swift:265–268`). Neither fact establishes strong routing evidence. One “Not for me” response also does not identify whether price, fit, color or brand caused rejection. Sparse closets need clearly labeled preference-based discovery rather than a claim that a full outfit has been evaluated.

Optional semantic text/image representations can later enrich public products once per product/version. They should complement exact brand/type constraints and known retailer facts. Private wardrobe photos need not be uploaded, and a language model should not invent URLs, prices, stock or store-brand relationships.

Useful standards/capabilities checked:

- [Google product data specification](https://support.google.com/merchants/answer/7052112?hl=en) documents separate size/system, product-group/variant, availability and shipping attributes. It is a schema reference, not a public search feed that WearIt can automatically access.
- [Brave Web Search reference](https://api-dashboard.search.brave.com/api-reference/web/search/get) documents query, country/language targeting and source reranking controls. Suitability for Israeli apparel coverage remains unmeasured.

## First implementation packet to choose

The reusable foundation is useful for either A or B:

- Define one shared shopping snapshot/coordinator for Shopping and Stats, cache/coalesce before expensive derivation, and move pure preparation behind immutable values. Keep live SwiftData objects and writes on their owning actor.
- Agree on one history contract first: Shopping currently supplies 400 wear events, Stats 200; both supply up to 300 recommendation events. Do not silently shorten evidence or assume the two requests are equivalent (`Views/ShopPicksView.swift:416–421`; `Views/StatsView.swift:19–33`).
- Replace repeated whole-input signature work with correctly invalidated semantic revisions, covering edits/deletes/imports, profile switches, feedback/model changes, plans, weather, date/availability/offer expiry and same-count catalog updates. Cache I/O can also leave MainActor.
- Reuse cheap product metrics for browse and personal shortlist selection while preserving their distinct eligibility/relevance rules. The current worker computes browse matches and then recomputes overlapping product evidence for ranking (`ShopRankingWorker.swift:50–52`).
- Build a versioned local search profile and public source-coverage manifest; use them to explain candidate/source choices. Do not add more model entities or paid AI dependencies without need.
- Add preparation/ranking/apply/first-photo timings and cache/duplicate-work counters. Measure with the owner after an owner build. Apple's [SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) supports moving expensive work outside view evaluation and caching it.

If B is selected, follow with a minimal product-index endpoint using the existing collector. Expand a few sources based on missing brand/type coverage and data quality. Choose and benchmark a provider only when C is selected; no API subscription or hosting deployment is approved by this proposal.

## Behavior, privacy and acceptance

- Existing 20 personal slots remain stable: dismissal releases a slot; purchase/unavailability/unsuitability hides an occupied item without silently substituting another. Newly discovered products fill eligible empty slots. A different “fresh discoveries” behavior is a separate product choice.
- Preserve independent For You/Explore filters, draft Apply/Cancel, saved products, seasonal opt-in, verified offer freshness, unknown-size handling, one-piece outfits/accessory compatibility and purchase/Undo. Feedback must still train once.
- Keep profile, wardrobe photos/IDs, wear-event records, private calendar data and complete planned outfits local/private iCloud. A future remote request should contain only necessary shopping constraints; even brand/style preferences are personal data. Avoid storing request bodies or attaching a stable user identity by default. A service inevitably receives network metadata.
- The current privacy copy says WearIt has no server. Before enabling B/C, revise EN/HE privacy strings, regenerate the public page with the existing script, and document the new request data, providers, retention and controls. Keep paid provider keys server-side.
- Compare identical-snapshot eligible IDs, scores/ties, preview completeness and reasons for the performance foundation. For retrieval changes, measure relevant candidate coverage and novelty separately; do not claim exact parity for a deliberately smaller candidate pool.
- Owner-run performance measures: cold/warm first useful content, preparation/ranking P50/P95, main-thread work, catalog bytes, memory, first useful image and rapid mode/profile switching. Quality measures: useful/irrelevant product feedback, source/brand coverage and duplicate/stock/price errors. Opens are weak evidence, not measured recommendation accuracy.

Current decision: Dor approved beginning the shared local foundation, now implemented in source. A new indexed-catalog service and paid web discovery remain separate choices; no provider, operating spend or new remote personal-data boundary has been configured.
