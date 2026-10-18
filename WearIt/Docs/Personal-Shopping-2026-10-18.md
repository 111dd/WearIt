# Personal shopping — 2026-10-18

Status: implemented locally; owner device review and retailer-data review pending. No build, tests, simulator, app launch, commit or push performed by the agents.

## Problems found

- Gender tabs admitted unlabelled products to both feeds; the profile has no explicit product-cut preference.
- The initial shortlist ignored brand preference, offers and negative taste before expensive scoring.
- Accessories returned zero matching looks, and the UI omitted their category filter.
- Weather was fixed at 22°C and no rain; planned outfits were unused.
- Numeric model bias, an offer and exploration could lift products without concrete personal relevance.
- Shopify used the lowest variant price and highest comparison price, potentially inventing a discount.
- Unknown size availability could be mistaken for sold-out stock; unmapped size scales were not distinguished.
- Same-count catalog updates and wardrobe edits did not rebuild recommendations.

## Resulting behavior

- One personal adult-product feed, without a gender selector or inferred gender. Children's and clear nonwearable products are excluded. Unknown adult department labels confer no positive preference.
- Choice-weighted wardrobe colors, brands, type, fit, pattern and style are combined with save/dismiss/purchase attribute signals. Visits are weak signals. Reactions generalize to similar items; recently purchased near-duplicates lose priority even before being photographed into the wardrobe.
- Every recommendation passes a personal-evidence gate and must have a concrete compatible complete outfit with owned clothes, or complete a saved upcoming outfit. Strong matching evidence permits unfamiliar types; a sale alone cannot qualify one.
- Scoring examines at most 70 products deeply, reserving shortlist room for accessories and relevant offers. Owned partner pools are bounded to four per core category. Repeated category sizes and affinities are computed once.
- Current forecast and persisted day/evening plan weather replace the constant weather assumption. Upcoming matching reads slot assignments first, uses only the next seven days, and never changes plans or wear status. An item appropriate for an upcoming plan can qualify even when unsuitable at home today. Owned preview bottoms/shoes/layers are checked too.
- Accessories can complete owned outfits. Cards show the actual owned pieces alongside the shop item. At most one optional companion purchase is attached when the two-product look improves on both complete single-purchase alternatives and the companion addresses a gap or adds an unowned accessory type.
- The optional next-season switch admits personally relevant, verified offers of at least 30% on weather-inappropriate seasonal pieces, with broad Israel season heuristics. These are labeled separately, capped at two in the full feed and one in the Stats preview, and have no immediate wear-frequency claim.
- Known incompatible sizes and explicitly sold-out stock are excluded. Missing/partially mapped stock remains uncertain; known positive size evidence is shown explicitly. There is no category-wide inferred accessory size.
- Sale badges require an explicit original/current price pair verified by the new crawler, positive amounts and a product fetch within seven days. Old cached unverified discounts remain hidden until refetched. Prices may still differ by size/color; no price guarantee, coupon, delivery promise or expiry is invented.
- Refreshes use catalog revisions and consumed content, not just counts. Rebuilds are debounced. Saved snapshots remain accessible when the catalog is empty or the wardrobe is small.

## Source changes

- `Logic/PurchaseScorer.swift`: relevance/usefulness gates, ranking, weather/plans, outfit previews and bounded companion search.
- `Logic/ShopFeedback.swift`: weak visits, attribute learning, recent-purchase redundancy and backward-compatible optional snapshots. Existing feature positions are preserved; additions are appended. Empty archived feature arrays never train the numeric model.
- `Services/ShopCatalogService.swift`: raw evidence fields, validated discounts/stock/links, mapping and refresh lifecycle.
- `Services/ProductFieldMapper.swift`: jewelry and tie aliases in Hebrew/English; word-bounded jewelry rings.
- `Views/ShopPicksView.swift`: personal filters, seasonal opt-in, complete preview/actions, current-profile data scope and content invalidation.
- Both `Localizable.strings`: localized reasons, seasonal labels and qualified wear estimates.
- `scripts/catalog/build_catalog.py`: same-offer/variant pricing, color-specific variant evidence, tri-state stock and explicit discount verification.

## Owner review

- Review the personal feed with real wardrobe data: favored/disliked colors and brands; unfamiliar but strongly compatible types; no random products when evidence is weak.
- Confirm accessories with no prior category history can appear through a real compatible outfit. Confirm children's/nonwearable products are absent.
- Confirm day/evening plans show correct dates and pieces, including remote saved weather; incompatible-at-home products still match a suitable upcoming plan. Confirm worn/rejected looks and past plans are excluded and no plan is modified.
- Compare sale/current/original prices, selected color, stock and product links against actual retailer pages. Review `il/report.json` after the next real crawl. Legacy unverified products may have no discount badge until refreshed.
- Check known missing sizes, unknown availability, one-size accessories and unsupported shoe scales. No unrecognized size should be called sold out.
- Inspect a two-purchase preview, separate shop actions, save/dismiss/bought behavior, and hidden/bought companions after rebuilding.
- Toggle next-season opportunities; only meaningful verified offers should enter that separate subset, with no current-weather promise.
- Edit a garment's colors/brand/type without changing count, refresh a same-count catalog, change a plan/forecast, and react to a recommendation; ranking should refresh.
- Inspect English/Hebrew, RTL, large Dynamic Type and saved items offline. Measure scrolling/rebuild latency on a populated wardrobe; no timing evidence was collected here.

## Practical limits

The rank is a heuristic with local online preference learning, not a calibrated probability of buying or wearing. Actual conversion/long-term wear improvement has not been measured. Matching quality is limited by real retailer metadata and available catalog inventory; it does not discover shops outside the catalog. It does not infer fit/cut from department labels, perform visual similarity for shopping, predict shipping or create price alerts. Upcoming context comes from saved planner looks, not new calendar permissions or a separate calendar fetch. Broad next-season temperatures are heuristics, not destination forecasts. Feedback retains the existing one-user-per-device UserDefaults scope and does not sync through iCloud. Closed-loop learning from purchased-item wear, richer brand-specific fit and broader store coverage remain follow-ups.

## Follow-up — general Shopping area and explicit preferences

The first change removed department tabs without supplying a replacement department preference. Because colors and styles overlap across retailer departments, women's apparel could still rank for a user who did not want it. The profile did not contain a department choice. Separately, catalog cards used the first image even when later images showed the garment alone.

- Added a fifth Shopping tab, before Add. The default is the personal feed. Explicit general browsing offers search, department/color/brand/style filters, category/deals/saved and pagination without a minimum wardrobe or a claim of personal suitability. Temporary filters never write saved preferences.
- Optional `UserProfile.shoppingPreferencesRaw` stores department, colors, brands, styles and item-only photo preference. It is exported and merged when the keeper lacks an answer; default decoding supports absent fields. A shared draft/Save editor opens from Shopping, Profile and Settings, with failed-save restoration. Sizes remain in the existing My sizes screen.
- A saved explicit department is a hard eligibility gate, not a ranking hint. Automatic can reuse a valid previous men/women choice or sufficiently consistent, independent purchases and exact catalog-linked wardrobe sources. Names, profile photos, colors, sizes and generic styles never choose a department. One purchase alone is insufficient. If unresolved, show unisex/unknown-accessory candidates and a choose-preferences prompt; do not silently mix clothing departments. All departments remains a deliberate option.
- Retailer audience is classified once during catalog mapping. Conflicting evidence stays unknown. Unknown clothing cannot bypass a narrow department; unknown accessories remain useful across departments. This is department metadata, not body-fit or a person's gender.
- Explicit saved colors/brands/styles supplement learned taste. Retailer style phrases go through ProductFieldMapper, including Hebrew and boho/minimalist/vintage, so manual style filters are not limited to type defaults.
- Item-only photography defaults on. A serial actor checks at most four original public preview URLs per visible product, streaming at most 5 MB per response with timeouts, downsampling to 480 px and running Vision person/face plus studio-frame checks off-main. Queue, waiters and cache are bounded; cancelled tile requests release their waiters. No wardrobe images are uploaded and no image gender is inferred. No accepted image means a neutral category symbol and the existing shop link; the user can allow modeled shop photos in preferences.

Additional owner review: inspect five-tab navigation/RTL, missing and legacy preferences, explicit men/women/all gates, unresolved automatic, independent source evidence, manual browsing with an empty wardrobe, temporary filter cancellation, saved preference sync/export/merge, all nine localized style choices, product-only fallback and photo loading/cancellation while scrolling. The person/frame detector is a heuristic and can miss partial bodies or reject legitimate product photos; it does not guarantee garment isolation. No source changes have been published and no build/tests/simulator, network/image acceptance or timing measurements were run for this follow-up.

## Follow-up — visible purchase action and bottom variety

- Fixed the owner-reported compiler error: `dsField` does not exist; the search row now uses the existing `dsFieldStyle` modifier.
- Full product cards and optional companion rows expose a visible “I bought it” action (Hebrew: “רכשתי”), using the existing persisted purchase/learning flow. Actions adapt to narrow layouts with a vertical fallback. Bought/dismissed products and any dependent bundle preview are removed until the debounced rebuild produces a complete replacement.
- Shopping previews retain the best eligible combination for each owned bottom within 0.04 of the best look score, then prefer the least-used suitable bottom across the displayed feed. Date-specific upcoming previews keep their actual saved assignments. The candidate pool, weather gates and compatibility thresholds remain bounded and unchanged.
- `AIRecommender.rankLooks` also prefers underused bottoms among eligible alternatives within 0.06 of the current best, retaining the two-piece difference rule and explicit bottom locks. The first/best recommendation is unchanged; this rotates alternatives rather than rewriting saved or worn plans. When only one suitable bottom qualifies, repetition remains possible.

Source inspection only: no build, tests, simulator or publication. Owner checks remain pending for the compile fix, purchase actions in personal/manual/saved/companion cards, and variety with several weather-appropriate bottoms versus a locked/only-compatible bottom.
