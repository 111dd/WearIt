# Observing recommendation quality — 2026-10-22

Use a fresh **Settings → Your data → Export my data** archive after both observation windows have ended. The report reads only the exported JSON, writes nothing, makes no network requests and never extracts or reads photos. It prints aggregates, without names, notes, garment titles or UUIDs.

```sh
python3 Tools/recommendation_quality_report.py "/path/to/WearIt Export.zip" --cutover 2026-10-22 --days 14
```

`--cutover` is the first local day using the updated app on the device, not the day its source was edited. The date above is an example only; the agent has not built or deployed this change. The example's equal windows are October 8–21 and October 22–November 4, with November 5 excluded. A full comparison for that example requires an export made on or after November 5 in the selected time zone. An earlier export is clearly marked partial and is descriptive only.

The tool uses the export's `timeZoneIdentifier`; use `--timezone Asia/Jerusalem` to override it or read an older export without a time zone. `--profile-id <UUID>` overrides the exported active profile. With a selected profile, unscoped legacy rows are excluded and counted in coverage. Add `--include-legacy` only when deliberately including that uncertain history; included legacy responses remain flagged. Wear records have no profile ID, so ownership is resolved through known exported garments; unknown owners cannot be attributed to a profile. Without an available profile ID the report describes all exported profiles.

## What is counted

- **Thermal feedback:** the latest explicit `justRight`, `tooWarm` or `tooCold` response for each validated plan/look identity within each window. Each result displays a raw count over the number of responding looks. A wear confirmation alone is not a comfort response.
- **Taste feedback:** the latest explicit `loved` or `notMyStyle` response per plan/look within each window. Style Swipe, automatic replacements and merely wearing a look are not equivalent to these explicit answers.
- **Wear diversity:** distinct local wear-days, garment-days and different known tops, bottoms and shoes. Duplicate wears of the same garment on one day count once, including day/evening duplicates. Calendar blocks and future/post-export rows are excluded; included migration records are noted.

Feedback windows consistently use **when a response was received** (`createdAt`), not the look's planned date. The same look can therefore occur in both windows when its responses cross the cutover. A valid legacy `v2` day key may identify a group, but its UTC day token is never interpreted as the local date of a worn look. Feedback types are grouped separately, so a later taste answer cannot replace a thermal answer.

## Interpreting the report

These are observed outcomes among looks that received explicit feedback, not an acceptance rate or calibrated recommendation accuracy. The export has no complete recommendation-exposure denominator, historical candidate pools or historical model weights. More different clothes is not automatically a better result; comfort, suitability and user choice still matter.

Compare complete equal windows cautiously. Weather, calendar events, wardrobe changes, frequency of app use and willingness to answer can all change. The report does not establish that a code change caused an improvement. Keep raw counts and coverage beside any interpretation; small samples and missing ownership/category metadata limit conclusions.

Older exports without `recommendationEvents` report feedback as **unavailable**, while still reporting supported wear data. Invalid dates, identities, ownership and unsupported sources appear as aggregate coverage counts. A missing array is never presented as evidence of zero complaints.

The reader accepts a JSON file or a ZIP containing exactly one `wearit-data.json`, and limits JSON input to 64 MiB. The implementation requires Python 3.9+ and an installed IANA time-zone database. It has received source review only; the agent has not executed it or run tests, builds or the simulator. Owner-run checks remain pending.
