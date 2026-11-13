# Personal recommendations and rotation — 2026-11-13

Status: source audit and proposal for Dor to choose. No recommendation implementation changed; no build, tests, simulator, app launch, commit or publication. The working tree already contains extensive local changes, including the recommendation engine. Findings describe those current files, not a device build or an inspected personal database.

## Recommendation

Keep the existing on-device infrastructure, but separate four responsibilities: contextual comfort, personal style, item compatibility, and rotation. Introduce exposure history and diverse candidate retrieval first; then improve contextual learning; finally add bounded contextual-bandit exploration. A general-purpose language model should not be the decision engine. Richer image understanding is an optional later input, not a prerequisite for solving repetition.

## Findings from current source

| Finding | Evidence | Consequence |
|---|---|---|
| Repeats are allowed by default | `Views/OutfitPlannerView.swift`: `planner.allowRepeatedItems = true`; `Services/AvailabilityService.swift`: `cooldownDays` returns zero when enabled | Same-day day-look availability is still checked, but the normal minimum interval between wears disappears. Other board days receive a soft penalty rather than a hard ban. The device's actual saved setting is unknown. |
| Rotation is mostly request-local | `Logic/AIRecommender.swift`: `rankLooks`, local `pieceUses`, default `limit = 1`; `suggestOutfit` selects the first result | The first result has no diversity pressure from this local counter. Multiple alternatives can differ while tomorrow still returns familiar items. Planner cross-day penalties and manual replacement rotation do exist. |
| Candidate retrieval limits what compatibility can discover | `rankLooks`: top six independently scored candidates per core slot, before full-look scoring | A seventh-ranked piece that makes a better or fresher combination cannot win. Availability and explicit exclusions shrink this further. |
| Familiar choices reinforce several scores | `combinedScore`, `heuristicScore`, `lookScore`; `CombinationAffinityBuilder`; planner `confirmWorn`; `LoveScoreLearner` | Wearing can strengthen love, attribute preference, co-wear pairs and model weights. These signals are useful, but without exposure correction can reward what the app repeatedly offers. Unworn items also gradually lose love after 60 days, regardless of whether they were offered. |
| Recency has no guaranteed direction | `FeatureSpace.iRecency`; `combinedScore` | Recency is partly learned with an unconstrained coefficient. Heuristics fall from 80% to 20% after 20 counted interactions. There is no independent durable recent-exposure/whole-look rotation term in `lookScore`. |
| Trust is based on count rather than evidence quality | `combinedScore`, `lookScore`, `learningProgress`, `applyDirectionalFeedback` | Item and look models each move toward 80% learned weight after 20 signals. Even directional feedback increments the item interaction counter. The progress indicator measures volume, not predictive accuracy. |
| Exploration setting is not wired into selection | All `epsilon` occurrences in `Logic/AIRecommender.swift` are declarations/assignments; ranking sorts by score | Merely enabling `setExploration` would not implement exploration. A new selection policy is required. |
| Personalization already exists, but representations are limited | `features`, `LookDNA.vector`, `learnLookPreference`, `TasteAffinityBuilder` | There is real logistic/pairwise learning, not just fixed rules. Item features include color/brand affinities but omit direct style/type/fit/pattern/material interactions. Look features summarize palette/proportions/coherence without weather or occasion context. Similar aggregate looks can be indistinguishable. |
| Compatibility relies on summaries and exact pair IDs | `LookDNA`, `CombinationAffinityBuilder` | Learned co-wear does not transfer directly to unseen attribute pairs. Whole-look rejection subtracts from every pair, although one piece or the overall outfit could have caused the rejection. |
| Weather handling is already substantial | `TemperatureComfort.garmentScore`, `RecoContext`, `GarmentWeatherHistory`, planner `recoContext` | Hourly apparent temperatures, day/evening and destination forecasts, coverage, layers and directional comfort feedback already exist. Extend them rather than replace them with a temperature-only rule. |
| Comfort attribution is uncertain | `GarmentWeatherHistory.init` applies look feedback to each selected garment/type | A report that the outfit was too warm cannot prove that the shoes or every other individual piece caused it. Wear alone currently provides weaker positive comfort evidence; it should remain distinct from explicit comfort. |
| Recommendation exposures are not durably recorded | `RecommendationEvent`, planner `recordLearningEvent`; existing recommendation quality guide | `shownGarmentIDs` is populated during feedback, not a complete record of actual visible recommendations. There is no reliable denominator for acceptance, no original candidate/score snapshot and no selection propensity. |
| Day/evening feedback identity needs attention | `RecommendationEventStore.deduplicationKey` includes plan/kind/IDs, but omits look time | Identical garments and reaction on day and evening of the same plan can collide. Future logging must distinguish look identity and revisions. This audit does not claim that every evening feedback path is currently correct. |

These are mechanisms capable of causing the reported behavior. Exact contributions require an owner export and knowledge of the installed build. No personal counts or quality improvement are inferred from source alone.

## Proposed design

### 1. Keep preferences separate from eligibility and variety

Availability, explicit restrictions, slot structure, locked pieces and protected planned/worn looks remain authoritative. Repeats allowed should mean repetition is permitted when appropriate; it should not disable soft variety. Repeats disabled retains the existing stricter policy. Explicit manual reuse wins over automatic rotation.

After eligibility, rank complete outfits using separate components:

`quality = comfort + occasion fit + personal style + compatibility`

`selection = quality - recent item exposure - repeated pair/look exposure + bounded exploration`

These are conceptual components, not proposed equal numeric weights. Normalize and inspect their contributions before selecting coefficients. Keep a comfort/quality floor independent of learned taste and exploration. Do not use sigmoid output as a calibrated probability of wearing a look.

### 2. Retrieve a mixed, bounded candidate pool

For each applicable core slot, start with a six-candidate budget: four high-quality choices, one suitable underexposed choice, and one suitable novel pairing candidate. Deduplicate, respect locks and structure, and fill missing positions from eligible choices. Counts are initial tuning parameters, not validated optimums.

Only choose novelty candidates above a weather/occasion suitability floor. Underexposure is relative to eligible opportunities; a winter coat should not lose preference merely because summer passed without a wear. Use recent exposure and distinct wear-days separately, with stronger rotation for tops/bottoms and weaker rotation for shoes/outerwear/accessories.

Bound core combinations as today (up to 216 separates plus 36 one-piece combinations before lock restrictions). Rerank with recent item, pair and core-look overlap across approximately 7–14 days and the upcoming board. This window is a tuning starting point. Keep a familiar fallback when the eligible wardrobe is small; never promise an impossible daily unique outfit.

Manual replacement should remain neutral unless the user explicitly expresses preference. Record an exposure only when a look is actually shown; background ranking, hidden alternatives, snapshot generation and shopping previews do not count as exposures. Widget exposures must be tracked separately or treated as unknown rather than inferred from timeline preparation.

### 3. Improve three small learning components

| Component | Representation and learning | Sparse-data behavior |
|---|---|---|
| Personal style | Extend append-only item/look features with type, style, fit, pattern and selected interactions with occasion, look time and weather. Continue pairwise training when a user explicitly chooses B over A in the same context. | Regularized global-per-user preferences with cautious context residuals; do not create an independent model for every weather/occasion combination. |
| Comfort | Preserve physical/hourly scoring; learn a small personal comfort correction from explicit too-warm/too-cold/just-right responses. Evaluate the outfit's layering and coverage together. | Shrink toward the physical prior. Whole-look feedback updates whole-look comfort first; uncertain garment attribution has low weight. A wear confirmation is not explicit thermal approval. |
| Compatibility | Combine general palette/proportion rules, category-aware attribute-pair features and confidence-shrunk exact pair evidence. For example, learn relaxed top + straight bottom in an outing context and transfer cautiously to another garment with those attributes. | Unknown pairs are uncertain, not bad. One rejected outfit must not label all its garments and pairs as disliked. |

Confidence should depend on distinct comparable decisions, recency, explicit versus implicit evidence and prediction errors, rather than a raw 20-interaction threshold. Cap repeated same-look contributions, apply regularization/forgetting deliberately and prevent one confirmation entering training twice through app/widget/history. Do not reset or replay existing weights silently. Append feature indices and version state; retain the prior path for rollback.

Photo understanding can later improve missing attributes. Existing visual similarity is not learned fashion compatibility: two visually similar items are not necessarily complementary. A pretrained type-aware compatibility embedding is a separate project requiring weight/license checks, garment-photo domain validation, conversion/device-budget assessment and evaluation. Training a deep fashion model from one user's sparse wardrobe history is not the first implementation step.

### 4. Add bounded contextual exploration after logging exists

Use a small shared-feature linear contextual bandit (LinUCB is a candidate) over whole-look features, rather than a separate arm for every exact outfit. Maintain its uncertainty state separately from the existing pairwise taste head. Keep comfort and availability gates outside exploration; limit candidates to a near-best quality band. Use shared features so unseen combinations can borrow evidence from known types/styles.

Bandit feedback must be an attributable, deduplicated decision outcome. Explicit like/dislike and a chosen alternative are more informative than display, opening, or no answer. Missing feedback is missing, not rejection. Preserve thermal feedback as a separate objective instead of interpreting a hot outfit as a disliked style.

First ship deterministic rotation. Later introduce a small stochastic choice among eligible near-best alternatives, held stable for the date/look/input revision. Log the actual selection distribution and chosen probability; a UCB bonus or rank score is not a propensity. There is no need to implement a full bandit before measuring whether the first changes resolve repetition.

## Durable evidence to add

Proposed additive decision/exposure record: active profile, decision ID, planned local date, day/evening, exact slot assignments and look revision, surface, model/feature version, weather/occasion value snapshot, candidate budget/eligibility summary, chosen score contributions, actual display time and linked subsequent feedback. For stochastic selection, also store the eligible final distribution or reproducible policy inputs and chosen propensity. Distinguish recommendation display, explicit selection, planned confirmation, real wear, style feedback, comfort feedback and neutral replacement.

Store compact value/feature snapshots, not photos or calendar titles/locations. Bound retained history and aggregate older exposure counts. Any new CloudKit model must use optional/defaulted properties, be registered in the schema, exported and deleted with the account. Preserve debounced saves; never save an impression on every SwiftUI redraw. App/widget feedback keys must include profile, plan/day, look time, look revision and event identity. Correction/Undo behavior must be specified before online updates.

## Delivery sequence

1. **Rotation and observability:** implement contextual exposure summaries, mixed retrieval, recent item/pair/look reranking, and an internal score breakdown. Integrate planner generation, refresh/single-slot changes, evening, widget alternatives and fallback paths while keeping shopping scoring separate from daily-wear rotation. Shared `AIRecommender` changes must not accidentally rotate shopping previews or saved plans.
2. **Contextual personalization:** add richer style/pair features, explicit signal attribution, evidence-based trust and seasonal/opportunity-aware handling of neglected items. Preserve the current comfort prior and historical state.
3. **Exploration:** compare deterministic rotation with bounded contextual-bandit selection only after real exposure/outcome coverage is sufficient. Keep a versioned fallback and rollback switch.
4. **Optional visual model:** consider only if metadata/compatibility remains the measured bottleneck.

Perform heavy pure calculations on immutable snapshots off the main actor; apply results by stable IDs only after rechecking profile, date/look, locks, saved status and input revision. Live SwiftData objects stay on their context's executor. Use bounded candidate and cache budgets. No server or paid inference service is required by the first three stages; device latency, battery and memory still need measurement.

## Evaluation and owner validation

Record the existing baseline before changing behavior. With an owner-authorized fresh export, the existing `Tools/recommendation_quality_report.py` can describe historical wear variety and explicit feedback coverage, but cannot recover unseen exposures or prove a counterfactual policy improvement.

Once exposure logging exists, track:

- Core-look, top/bottom-pair and item repetition within 3/7/14 days, separating recommendations from actual wears and normalizing by eligible wardrobe size/opportunity.
- Eligible wardrobe coverage; distinguish underexposed suitable clothing from unsuitable seasonal clothing.
- Explicit selected/kept/confirmed/worn outcomes with separate denominators and unresolved outcomes, not a single invented acceptance rate.
- Explicit style and comfort responses with raw counts, coverage and uncertainty. Diversity is useful only while suitability and comfort remain acceptable.
- Candidate recall: how often a manually chosen available item was absent from retrieval.
- Owner-device p50/p95 ranking/preparation time, UI responsiveness and energy/memory observations.

Replay fixed value snapshots to inspect constraints and score changes; do not label replay over deterministic historical logs as unbiased offline bandit evaluation. Propensity-based estimates require recorded supported randomized exposure and adequate overlap. Compare prospective time windows carefully because weather, events and wardrobe changes confound the result.

Acceptance cases for a later authorized implementation: many equivalent tops; one viable bottom; repeat toggle on/off; a locked piece; dress/jumpsuit structure; same-day linked evening items; future planned/worn looks; unavailable clothes; new unexposed item; cold-to-hot hourly swings; explicit comfort correction; neutral replacement; repeated widget/app feedback; profile switch/CloudKit update during ranking. Build/test/device execution remains owner-controlled under project rules.

## Research basis

- Li et al., *A Contextual-Bandit Approach to Personalized News Article Recommendation*: contextual learning/exploration and the requirements for offline evaluation from randomized traffic. This establishes an algorithmic pattern, not evidence of a WearIt improvement. https://arxiv.org/abs/1003.0146
- Vasileva et al., *Learning Type-Aware Embeddings for Fashion Compatibility*: distinguishes item similarity from type-aware compatibility. It does not provide a validated drop-in iOS model for WearIt's photos. https://openaccess.thecvf.com/content_ECCV_2018/html/Mariya_Vasileva_Learning_Type-Aware_Embeddings_ECCV_2018_paper.html

## Decision

Recommended first implementation scope: stage 1 plus the minimum durable exposure schema needed to evaluate it. Stage 2 follows as a separate focused change; stage 3 depends on observed evidence. No implementation is authorized by this proposal alone.
