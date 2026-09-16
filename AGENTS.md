# WearIt — agent brief

iOS wardrobe app (SwiftUI + SwiftData + CloudKit). Hebrew/English localized.

Read `docs/LEARNINGS.md` before changing code. After meaningful work, append a short entry there so the next agent inherits what you learned.

## Hard constraints

- **Never run a build or the simulator.** The user runs Xcode. Do not use `xcodebuild`, `simctl`, or launch the app.
- **Never commit unless asked.** Never push unless asked.
- **Never commit secrets.** `Config/Secrets.xcconfig` is gitignored. Edit `Config/Secrets.example.xcconfig` only.
- Prefer the smallest change that matches existing patterns. No drive-by refactors.

## Architecture facts

- Outfit identity lives on `DayPlan` **slots** (`slotAssignments` / `eveningSlotAssignments`), not only flat garment ID arrays. Calendar and planner must write the same way.
- Wear status is unified via `DayPlan.applyDayLookWearStatus` / `resolvedDayLookWearStatus`.
- Images go through `ImageStore` (disk + downsample + cache). Do not decode full-res images on the main thread or apply live SwiftUI `.blur` to wallpapers.
- Startup: `BootstrapView` + `DataMigrationService`. Critical work is gated by UserDefaults versions; deferred backfills use predicates, not full-table scans.
- API keys come from build settings (`$(BARCODE_LOOKUP_API_KEY)`), never hardcoded.

## When you finish a task

Append to `docs/LEARNINGS.md` (newest first):

```
## YYYY-MM-DD — one-line title
- **Did:** what changed
- **Why:** the actual problem
- **Watch:** pitfall the next agent will hit
```

Update this file only when a standing rule changes, not for every feature.
