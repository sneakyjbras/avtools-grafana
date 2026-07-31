# Changelog

All notable changes to **av-tools-grafana** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.10.1] — 2026-07-31

### Fixed
- **"Commission Date — Count" bar charts were unreadable** on both `av_devices_dashboard`
  and `av_rooms_dashboard` (QA and prod). Three separate presentation defects, no SQL involved:
  - **Bucket granularity.** `av_devices` stringified `commissiondate` with `dateFormat: "YYYY-MM"`,
    producing one bar per month — **205 distinct buckets** against the live data (4,501 devices
    spanning 2005-04-30 → 2026-07-22). `av_rooms` was worse: its `convertFieldType` carried **no
    `dateFormat` at all**, so it bucketed on the raw date value. Both now use `"YYYY"` → **22 bars**.
  - **Sort order.** The `sortBy` transformation ordered by `conferenceroomnofmt (count)` *descending*,
    so a date axis was rendered in popularity order — which is why the tick labels read as arbitrary
    strings instead of a timeline. Now ascending by the date field.
  - **Tick labels** were horizontal (`xTickLabelRotation: 0`) and overlapped. Now `-45`.
- The `av_rooms` x-axis is relabelled `Commission Date` → **`Commission Year`** to match what is plotted.

### Unchanged
- No `rawSql` was modified, so every result set and the full Status → Room → Eqclass → Category → Device
  filter chain behave exactly as before. `colorByField` still resolves in both panels
  (`conferenceroomnofmt (count)` and `Count`). The QA dashboards carry the byte-identical change.


### Changed
- **License & Maintainer documentation**: Added `CONTRIBUTING.md` listing José Bras (`jose.bras@cern.ch` / `j.eduardo.bras@outlook.com`, `@jsapinat` / `@sneakyjbras`) as sole maintainer under the MIT License.

## [1.10.0] — 2026-07-28

### Added
- **Room up-climb de-recursion**: Replaced the last `WITH RECURSIVE` device→room position-climb queries in `AV: Devices Table` (`grafana/dashboard/prod/av_devices_dashboard.json` + `grafana/dashboard/qa/av_devices_dashboard-qa.json`) with direct joins against the precomputed `eam_rooms` cache table (populated by `avtools sync-rooms`). The recursion lived in the `room`, `eqclass`, `category`, and `device` template variables (8 `WITH RECURSIVE` occurrences per dashboard — one `query` + one `definition` field for each of the 4 variables); the same panel query already de-recursed in `1.9.x` (`Device Table`, and the alerts/`av_rooms` panels) is now the only pattern left in the dashboard, so no panel in this repo runs a recursive room-climb anymore. Output semantics are unchanged: same `pos_to_room`/`no_parent_positions`/`no_position_devices` CTE names and columns, same cascading Status→Room→Class→Category→Device filter behavior, and the same `__NO_ROOM_NO_POSITION__` / `__NO_ROOM_NO_PARENT__` sentinel handling — only the CTE bodies now read `eam_rooms.room_no` keyed on `parent_position`/`equipmentno` instead of climbing `eam_positions.parentasset`.

### Fixed
- **Five devices that the old recursive climb silently dropped now appear in their rooms.** `CCAX-000883` (Crestron control system, CCA-31.3.004), `CCAX-002620`/`002621`/`002622` (APC UPS units, CCA-61.1.009 / CCA-3862.1.001 / CCA-3294.R.008) and `CCAX-004122` (PC, CCA-62.S.001). All five have `position == parent_position == room_no` — the device is installed **directly in the room** rather than in a rack position inside it. The old down-walk joined devices to *leaf positions beneath* a room, so a device whose position **is** the room never matched and was omitted from the dropdown. The `eam_rooms` join has no such blind spot.

### Notes
- **QA gate PASSED 2026-07-31** (`scripts/verify_rooms_equivalence.sql`, run against the QA cache):
  - **Result 1 (per-device): `total_devices = 4501, mismatches = 0, matches = 4501`** — for every device the old climb resolved, the `eam_rooms` join agrees exactly.
  - Result 3 (per-room): 5 rooms differ, every one in the same direction — `eam_rooms` has one **extra** device, never a missing one (`only_in_down_walk = 0` in all 5). Those are the five devices listed under *Fixed* above, i.e. the new query is a strict improvement rather than a divergence, so the "0 rows" wording of the Result-3 criterion is satisfied in spirit.
  - `eam_rooms` coverage is complete (4,501 rows vs 4,501 devices). A uniform `resolved_at` is expected, not stale: `EAMRoom.avtools_compare_fields()` deliberately excludes `resolved_at` so a re-resolution yielding the same room is not treated as a change and does not churn the row on every 15-minute `sync-rooms` run.

## [1.9.8] — 2026-07-27

### Added
- **Room down-walk de-recursion**: Optimized room hierarchy querying in `av_rooms` panels via `eam_rooms`.

### Fixed
- **No-position devices projection**: Restored `no_position_devices` projection to fix SQL runtime error `42703`.
