# Catalog crawler publication — 2026-10-21

Dor explicitly authorized publishing the corrected crawler and manually running it.

- PR: https://github.com/111dd/WearIt/pull/37 — merged.
- Main merge: `681d027b57170727539181cad725f108a108d3a7`.
- Scope: `scripts/catalog/build_catalog.py` and focused progress/next-step/learnings entries based on remote main. Existing dirty application changes were not published or altered.
- Manual run: https://github.com/111dd/WearIt/actions/runs/39650673399, dispatched on main with both stores at 21:12:48 Israel time.
- Confirmed through GitHub: `workflow_dispatch`, branch main and exact merged head above. The run and Publish to catalog-data step completed successfully at 22:54 Israel time.
- Published catalog: generated `2026-10-21T19:54:27+00:00`, 3,643 raw products and 954 verified price reductions of at least 5% (Terminal X 593, Castro 361). These are raw counts before app eligibility filters; 192 offers are labeled men. Terminal X refreshed 1,096 products (104 failed requests); Castro refreshed 1,071 products (zero failed requests, 129 non-product pages). No missing-image lists were reported.

The GitHub connector created the branch/commit/PR and merged it. Its tools did not expose workflow dispatch, so the existing signed-in Chrome GitHub UI was used to run Shop catalog. No credentials were copied or changed. The local checkout remains on its existing main revision with all work preserved.

The report and catalog price pairs were inspected after completion. Next: owner refreshes the catalog in the app and checks offers under the actual department/category/stock gates. The app can refresh catalog data without a new app release; local app UI/ranking/filter changes require their own publication and owner device review.

No app build, test suite or simulator was run.
