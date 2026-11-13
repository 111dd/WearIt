# Adaptive outfit cards — 2026-10-24

Dor chose the “היום במרכז” direction and asked for a photo area that follows the actual outfit: dresses without a pants placeholder, multiple accessories and no gender-based layout assumptions. This completes the interrupted local source work. Existing shopping, photo and recommendation changes are preserved.

## Source changes

- Planner photo tiles contain assigned garments only. They use one to three balanced columns, centered short rows and larger minimum widths for accessibility text. “Add to look” is a separate 44pt action rather than an empty photo tile. Accessories/shoes/layers precede structural changes when adding to an existing one-piece look. The compact worn summary uses the same visible item order.
- Dress and jumpsuit are explicit item types under the existing stored `.top` category. New outfit identity uses `.onePiece` instead of `.top` + `.bottom`. Category cases/order and the learned feature positions are unchanged. Product text and the existing image-classifier mapping share the new EN/HE vocabulary; Add/Edit expose the new types.
- Six stable accessory keys retain the original `.accessory` key plus `.accessory2` through `.accessory6`. Manual selection can add six distinct accessories without replacing an earlier accessory. This is a bounded manual capacity, not unlimited accessory storage. Automatic ranking keeps its conservative existing single-accessory behavior.
- Ranking explores separate top/bottom/shoe and one-piece/shoe branches, retaining existing availability, weather, taste and target rules. Candidate combinations remain bounded. Partial candidate lists remain supported because the planner merges multiple protected slots outside the ranker; complete shopping previews retain their own completeness gates. Fallback composition and shopping previews use the same structural alternatives. The separate gym packing top/bottom list excludes one-piece items.
- Manual assignment, replacements, suggestions, swaps, calendar editing and wardrobe placement guard conflicting locks before clearing clothes. Explicit structure changes remove unlocked conflicts. Calendar/trip/legacy array allocation keeps distinct accessory keys. Opening saved slot maps does not normalize historical assignments or change wear history; a legacy dress under `.top` is presented as a one-piece and canonicalized only by an explicit edit.
- Day-to-evening links follow compatible uncommitted changes. A missing day source or incompatible/committed evening leaves the existing evening assignment independent. Fill-missing generation skips worn/planned looks. Day refresh does not restore old pants into a newly generated dress look.
- Widget ordering recognizes all accessory keys and prioritizes the one-piece as the main garment. Alternative cache identity includes locks. Queued choices are checked after merging current locks, rejecting newly incompatible or duplicate placements while retaining unchanged historical mappings.
- All new labels are available in English and Hebrew. No new stored model, migration, gender inference or remote service was introduced.

## Owner device review

These scenarios are pending; no build, tests, simulator or app launch was performed by the agent.

| Scenario | Expected behavior |
| --- | --- |
| One, two, three, four and many assigned items | Photos resize/wrap with balanced rows, with no unused clothing photo placeholders. Check Hebrew/English, narrow widths and accessibility text. |
| Dress/jumpsuit + shoes, then add bag/watch/jewelry | No pants placeholder; each accessory stays visible and saved separately, up to six accessories. Add defaults to complements. |
| Change separates to a dress and back | Unlocked conflicting core pieces are removed. A conflicting locked piece blocks the change before anything disappears. |
| Several locked accessories; regenerate other pieces | Keep each protected item under its original key; no duplicate garment in two accessory slots. |
| Save/reopen via planner and calendar; edit a suitcase | Same one-piece/accessory assignments persist; reading a saved suitcase does not rebuild it. |
| Reclassify an existing top as a dress | Present the saved item without a pants placeholder; explicit replacement/drag uses one-piece placement; opening alone does not rewrite the saved slot map. |
| Worn today, Undo, reopen/collapse, add evening | Previous compact-day and evening-footer behavior remains independent; work choices hide for a worn day. |
| Linked evening + change day clothes | Compatible uncommitted links follow. Planned/worn or structurally incompatible evening retains its previous items independently. |
| Widget alternative queued before a new lock | Keep the current lock and reject a now-conflicting option; one-piece is the widget's leading item. |
| Learned recommendation behavior | Exercise the prior thermal-direction, real-swap and small-wardrobe cases in Planner-UX-Recommendations-2026-10-22.md. No improvement in measured speed or recommendation quality is claimed. |

Changes are local and uncommitted. Source review does not establish compilation, on-device appearance or freedom from runtime bugs. The owner runs Xcode under AGENTS.md; publication remains a separate explicit request.
