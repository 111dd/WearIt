#!/usr/bin/env python3
"""Summarize observed WearIt feedback and wear diversity from a local export.

Read-only, standard library only. No network, archive extraction, photos, or model replay.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import date, datetime, time, timedelta, timezone
import json
from pathlib import Path
import sys
import uuid
import zipfile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


MAX_JSON_BYTES = 64 * 1024 * 1024
THERMAL = ("justRight", "tooWarm", "tooCold")
TASTE = ("loved", "notMyStyle")
CORE_CATEGORIES = ("top", "bottom", "shoes")
WEAR_SOURCES = {"planner", "plannerEvening", "manual", "calendar", "migration"}


class ReportError(Exception):
    pass


def uuid_value(value):
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return None


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc) if parsed.tzinfo else None
    except (ValueError, OverflowError):
        return None


def calendar_date(value):
    try:
        parsed = date.fromisoformat(value)
        return parsed if parsed.isoformat() == value else None
    except (TypeError, ValueError):
        return None


def reject_nonfinite(_value):
    raise ReportError("The JSON contains a non-finite number and cannot be summarized safely.")


def load_export(path):
    try:
        if path.suffix.lower() == ".zip" or zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                matches = [
                    info for info in archive.infolist()
                    if not info.is_dir() and info.filename.rsplit("/", 1)[-1] == "wearit-data.json"
                ]
                if len(matches) != 1:
                    raise ReportError("The ZIP must contain exactly one wearit-data.json file.")
                if matches[0].file_size > MAX_JSON_BYTES:
                    raise ReportError("The export JSON exceeds the 64 MiB reading limit.")
                with archive.open(matches[0]) as member:
                    raw = member.read(MAX_JSON_BYTES + 1)
        else:
            if path.stat().st_size > MAX_JSON_BYTES:
                raise ReportError("The export JSON exceeds the 64 MiB reading limit.")
            with path.open("rb") as source:
                raw = source.read(MAX_JSON_BYTES + 1)
        if len(raw) > MAX_JSON_BYTES:
            raise ReportError("The export JSON exceeds the 64 MiB reading limit.")
        payload = json.loads(raw.decode("utf-8-sig"), parse_constant=reject_nonfinite)
    except ReportError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError, zipfile.BadZipFile,
            RuntimeError, NotImplementedError, RecursionError):
        raise ReportError("Could not read a valid local WearIt JSON or ZIP export.") from None
    if not isinstance(payload, dict) or payload.get("app") != "WearIt":
        raise ReportError("The JSON is not a WearIt account export.")
    return payload


def export_rows(payload, name, coverage):
    if name not in payload or not isinstance(payload[name], list):
        coverage[f"{name}: unavailable or unsupported array"] += 1
        return None
    result = []
    for row in payload[name]:
        if isinstance(row, dict):
            result.append(row)
        else:
            coverage[f"{name}: malformed rows skipped"] += 1
    return result


def look_identity(event):
    """A fallback date token identifies a UTC-keyed legacy group, never a local plan date."""
    look_time = event.get("lookTime")
    if look_time not in ("day", "evening"):
        return None
    plan_id = uuid_value(event.get("dayPlanID"))
    if plan_id:
        return ("plan", plan_id, look_time)
    key = event.get("deduplicationKey")
    if not isinstance(key, str):
        return None
    parts = key.split("|", 3)
    if len(parts) != 4 or parts[0] != "v2" or parts[2] != event.get("kind"):
        return None
    plan_token = uuid_value(parts[1])
    if plan_token:
        return ("plan", plan_token, look_time)
    day_token = calendar_date(parts[1])
    if day_token:
        return ("legacy-day", day_token.isoformat(), look_time)
    return None


def scope_for(raw_owner, selected_profile, include_legacy):
    if raw_owner is None:
        return (not selected_profile or include_legacy, "legacy")
    owner = uuid_value(raw_owner)
    if not owner:
        return (False, "invalid")
    return (not selected_profile or owner == selected_profile, owner)


def window_for(moment, windows):
    for name, start, end in windows:
        if start <= moment < end:
            return name
    return None


def feedback_summary(rows, windows, data_as_of, selected_profile, include_legacy, coverage):
    if rows is None:
        return None
    latest = {name: {"thermal": {}, "taste": {}} for name, _, _ in windows}
    for event in rows:
        kind = event.get("kind")
        family = "thermal" if kind in THERMAL else "taste" if kind in TASTE else None
        if family is None:
            continue
        accepted, owner = scope_for(event.get("profileID"), selected_profile, include_legacy)
        if owner == "legacy":
            coverage[f"feedback: unscoped legacy rows {'included' if accepted else 'excluded'}"] += 1
        if not accepted:
            if owner != "legacy":
                coverage["feedback: rows with invalid profile skipped" if owner == "invalid"
                         else "feedback: other-profile rows excluded"] += 1
            continue
        created_at = timestamp(event.get("createdAt"))
        if created_at is None:
            coverage["feedback: rows missing an aware response timestamp skipped"] += 1
            continue
        if created_at > data_as_of:
            coverage["feedback: future or post-export response rows skipped"] += 1
            continue
        window = window_for(created_at, windows)
        if window is None:
            continue
        identity = look_identity(event)
        if identity is None:
            coverage["feedback: rows without a valid plan/look identity skipped"] += 1
            continue
        selected_ids = event.get("selectedGarmentIDs")
        if not isinstance(selected_ids, list) or not selected_ids or any(uuid_value(value) is None for value in selected_ids):
            coverage["feedback: rows without valid evaluated garment IDs skipped"] += 1
            continue
        event_id = uuid_value(event.get("id"))
        if event_id is None:
            coverage["feedback: rows without a valid event ID skipped"] += 1
            continue
        if identity[0] == "legacy-day":
            coverage["feedback: rows grouped by legacy UTC day key"] += 1
        group = (owner,) + identity
        rank = (created_at, event_id, kind)
        prior = latest[window][family].get(group)
        if prior is None or rank > prior[0]:
            latest[window][family][group] = (rank, kind, owner == "legacy")
    return latest


def garment_index(rows, coverage):
    if rows is None:
        return None
    result = {}
    for garment in rows:
        garment_id = uuid_value(garment.get("id"))
        if garment_id is None:
            coverage["garments: rows without a valid ID skipped"] += 1
            continue
        if garment_id in result:
            # Conflicting identity/ownership must not be resolved by input order.
            if result[garment_id] != (garment.get("category"), garment.get("ownerID")):
                result[garment_id] = (None, "invalid")
                coverage["garments: conflicting duplicate IDs excluded from scoped/category counts"] += 1
            continue
        result[garment_id] = (garment.get("category"), garment.get("ownerID"))
    return result


def wear_summary(rows, garments, windows, data_as_of, zone, selected_profile, include_legacy, coverage):
    if rows is None or (selected_profile and garments is None):
        return None
    result = {
        name: {"days": set(), "garment_days": set(),
               "core": {category: set() for category in CORE_CATEGORIES},
               "core_days": {category: set() for category in CORE_CATEGORIES},
               "unclassified": set()}
        for name, _, _ in windows
    }
    for event in rows:
        source = event.get("source")
        if source == "calendarBlock":
            coverage["wear: calendar-block rows excluded"] += 1
            continue
        if not isinstance(source, str) or source not in WEAR_SOURCES:
            coverage["wear: rows with missing/unsupported source skipped"] += 1
            continue
        moment = timestamp(event.get("date"))
        if moment is None:
            coverage["wear: rows missing an aware wear timestamp skipped"] += 1
            continue
        if moment > data_as_of:
            coverage["wear: future or post-export rows skipped"] += 1
            continue
        window = window_for(moment, windows)
        if window is None:
            continue
        raw_ids = event.get("garmentIDs")
        if not isinstance(raw_ids, list):
            coverage["wear: rows missing garment IDs skipped"] += 1
            continue
        ids = {value for raw in raw_ids if (value := uuid_value(raw)) is not None}
        coverage["wear: invalid garment-ID references skipped"] += sum(uuid_value(raw) is None for raw in raw_ids)
        day = moment.astimezone(zone).date()
        included = False
        for garment_id in ids:
            known = garments is not None and garment_id in garments
            category, raw_owner = garments[garment_id] if known else (None, None)
            if not known:
                coverage["wear: references to absent garment metadata"] += 1
                if selected_profile:
                    coverage["wear: unknown-owner references excluded from profile scope"] += 1
                    continue
            accepted, owner = scope_for(raw_owner, selected_profile, include_legacy)
            if owner == "legacy":
                coverage[f"wear: unscoped garment references {'included' if accepted else 'excluded'}"] += 1
            if not accepted:
                if owner != "legacy":
                    coverage["wear: other/invalid-owner garment references excluded"] += 1
                continue
            included = True
            result[window]["days"].add(day)
            result[window]["garment_days"].add((day, garment_id))
            if category in CORE_CATEGORIES:
                result[window]["core"][category].add(garment_id)
                result[window]["core_days"][category].add((day, garment_id))
            elif category not in ("outer", "accessory"):
                coverage["wear: included references with unknown category"] += 1
                result[window]["unclassified"].add((day, garment_id))
        if source == "migration" and included:
            coverage["wear: included migration rows (historical provenance)"] += 1
    return result


def print_feedback(families):
    for family, kinds, labels in (
        ("thermal", THERMAL, ("just right", "too warm", "too cold")),
        ("taste", TASTE, ("loved", "not my style")),
    ):
        values = list(families[family].values())
        denominator = len(values)
        if not denominator:
            print(f"  {family.title()}: no explicit responding looks in this window; no outcome estimate.")
            continue
        counts = Counter(value[1] for value in values)
        parts = ", ".join(f"{label} {counts[kind]}/{denominator}" for kind, label in zip(kinds, labels))
        print(f"  {family.title()}: {denominator} responding looks; {parts}.")
        legacy = sum(value[2] for value in values)
        if legacy:
            print(f"    Includes {legacy} unscoped legacy look(s), not attributable to a profile.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path, help="Local WearIt export ZIP or wearit-data.json")
    parser.add_argument("--cutover", required=True, help="First day after the change, YYYY-MM-DD")
    parser.add_argument("--days", type=int, default=14, help="Days in each equal window (default: 14)")
    parser.add_argument("--timezone", help="IANA time zone; otherwise use the export timeZoneIdentifier")
    parser.add_argument("--profile-id", help="Profile UUID; otherwise use the exported profile ID if available")
    parser.add_argument("--include-legacy", action="store_true", help="Include and flag unscoped legacy rows in profile scope")
    args = parser.parse_args()
    cutover = calendar_date(args.cutover)
    if cutover is None or not 1 <= args.days <= 3660:
        raise ReportError("Use --cutover YYYY-MM-DD and --days between 1 and 3660.")
    payload = load_export(args.export)
    zone_name = args.timezone or payload.get("timeZoneIdentifier")
    if not isinstance(zone_name, str) or not zone_name:
        raise ReportError("This export has no time zone. Supply --timezone, for example Asia/Jerusalem.")
    try:
        zone = ZoneInfo(zone_name)
    except (ZoneInfoNotFoundError, ValueError):
        raise ReportError("The time zone is unavailable. Supply an installed IANA --timezone name.") from None
    profile = payload.get("profile")
    raw_profile = args.profile_id or (profile.get("id") if isinstance(profile, dict) else None)
    selected_profile = uuid_value(raw_profile)
    if raw_profile is not None and selected_profile is None:
        raise ReportError("The selected/exported profile ID is invalid.")
    try:
        boundaries = [cutover - timedelta(days=args.days), cutover, cutover + timedelta(days=args.days)]
        moments = [datetime.combine(value, time.min, tzinfo=zone).astimezone(timezone.utc) for value in boundaries]
    except (OverflowError, ValueError):
        raise ReportError("The requested calendar window is out of range.") from None
    windows = [("Before", moments[0], moments[1]), ("After", moments[1], moments[2])]
    exported_at = timestamp(payload.get("exportedAt"))
    now = datetime.now(timezone.utc)
    data_as_of = min(exported_at, now) if exported_at else now
    coverage = Counter()
    events = export_rows(payload, "recommendationEvents", coverage)
    garment_rows = export_rows(payload, "garments", coverage)
    wears = export_rows(payload, "wearHistory", coverage)
    feedback = feedback_summary(events, windows, data_as_of, selected_profile, args.include_legacy, coverage)
    garments = garment_index(garment_rows, coverage)
    wear = wear_summary(wears, garments, windows, data_as_of, zone, selected_profile, args.include_legacy, coverage)

    print("WearIt observed feedback and wear diversity")
    print(f"Time zone: {zone.key}. Equal calendar windows: {args.days} days each.")
    print("Scope: selected profile." if selected_profile else "Scope: all exported profiles; no selected profile ID was available.")
    print("Feedback dates are response-received dates, not the dates the looks were worn.")
    print("Latest explicit thermal and taste response per validated look is counted separately in each window.")
    print("A look may appear in both windows if its responses span the cutover.")
    full_comparison = exported_at is not None and data_as_of >= moments[2]
    for index, (name, _start, end) in enumerate(windows):
        complete = exported_at is not None and data_as_of >= end
        status = "complete by export time" if complete else "PARTIAL / completeness unverified"
        print(f"\n{name}: [{boundaries[index].isoformat()}, {boundaries[index + 1].isoformat()}) — {status}")
        if feedback is None:
            print("  Feedback unavailable: this export does not contain a supported recommendationEvents array.")
        else:
            print_feedback(feedback[name])
        if wear is None:
            print("  Wear diversity unavailable: wear history or profile ownership metadata is missing.")
        else:
            summary = wear[name]
            if not summary["days"]:
                print("  Wear diversity: no eligible wear-days in this window; no diversity estimate.")
            else:
                print(f"  Observed wear: {len(summary['days'])} distinct days; {len(summary['garment_days'])} distinct garment-days.")
                if garments is None:
                    print("  Core-item diversity unavailable: garment category metadata is missing.")
                else:
                    print("  Known core diversity: " + "; ".join(
                        f"{category}: {len(summary['core'][category])} different items / {len(summary['core_days'][category])} garment-days"
                        for category in CORE_CATEGORIES
                    ) + ".")
                    if summary["unclassified"]:
                        print(f"    Categories unavailable for {len(summary['unclassified'])} garment-days; core totals are incomplete.")
    print("\nCoverage and limits")
    if not full_comparison:
        print("  The full after-window is not established by this export. Counts are descriptive; no before/after comparison is available.")
    if exported_at is None:
        print("  Export timestamp missing/invalid; window completeness cannot be established.")
    elif exported_at > now:
        print("  Export timestamp is in the future; future records and completeness are capped at the current time.")
    for label, count in sorted(coverage.items()):
        if count:
            print(f"  {label}: {count}.")
    print("  Coverage counts describe input rows/references and may extend beyond the observation windows.")
    print("  Missing arrays mean unavailable evidence, not zero outcomes. Included rows can still have incomplete history.")
    print("  A garment worn twice in one day counts as one garment-day. Core diversity uses known categories only.")
    print("  This is not recommendation accuracy, acceptance, or evidence that the change caused better outcomes.")
    print("  No exposure denominator or historical model replay exists here; weather, plans, wardrobe changes and response habits can differ.")


if __name__ == "__main__":
    try:
        main()
    except ReportError as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(2)
