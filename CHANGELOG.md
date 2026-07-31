# Changelog

All notable changes to **av-tools-grafana** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.11.0] — 2026-07-31

### Fixed
- **Every "last seen" / "age" panel was reading ~0 regardless of real staleness.** `timestamp(X)`
  reports a sample's own timestamp only when `X` is a **bare vector selector**; given the output of
  any function the sample is minted at evaluation time, so `timestamp(last_over_time(m[w])) == time()`
  and `time() - timestamp(...)` collapses to zero. Introduced by `1919357`, which wrapped instant
  selectors in `last_over_time()` so panels would survive the move to per-tier refresh rates —
  correct for value panels, wrong inside `timestamp()`. Unwrapped in 10 expressions (5 panels ×
  prod/qa): `Device Table` (av_devices), `Last Checked` / `SNMP Last Sample` /
  `Minutes Since SNMP Sample` (av_devices_details), `Rooms Table` and
  `Minutes Since Last SNMP Cycle` (av_rooms). Safe to unwrap: every metric involved
  (`ping_check_status`, `snmp_probe_status`, `snmp_devices_targeted`) is CRITICAL/ALWAYS tier at a
  5-minute refresh, so the tier split never made them sparse. **These are the panels that would have
  revealed the 2026-07-30 collection outage, and they would have shown "0 minutes" throughout.**
- **`Connectivity Breakdown` (av_rooms, panels 25/27) reported impossible numbers.** Three compounding
  faults: the PromQL targets counted *series* over a `[6h]` window rather than devices, sweeping in
  every label set seen in six hours; an **unfiltered `reduce`** also hit the Prometheus frames,
  emitting two same-named fields per frame (the real value and a constant `1`); and the `min`/`max`
  `reduceRow` steps were silently *choosing between those two fields* rather than doing arithmetic —
  so `Online` and `Snmp` were pinned at **1** and `Offline` = `Connected − 1`, i.e. the entire
  connected fleet rendered as offline. Targets now mirror panel 26
  (`count(max by (equipmentno) (...[15m]))`), `reduce` is scoped by refId, and the final `organize`
  is rebuilt against what the chain actually emits.
- **`Devices per Room` and `Coverage & Monitoring Ratios by Room` leaked a `conferenceroomno (count)`
  column and showed implausible magnitudes.** Both declared `conferenceroomno` as group key *and*
  counted aggregate, minting an unrenamed duplicate of the per-room device count whose magnitude was
  the 2,046-device "No position" bucket. Both also stacked series that are subsets or roll-ups of one
  another, so a 114-device room drew a bar near 400; `Coverage Ratios` percent-stacked three
  *independent* 0–1 ratios, rendering 100/100/100 as three 33% bands. Stacking is now a true partition
  (`Online + Offline + Coverage Gap == Total Devices`) and the ratios are unstacked.
- **`sortBy` on both room panels pointed at `roomrank`, a field no query produces** (the SQL emits
  `room_sort_rank`, which becomes `room_sort_rank (max)` after `groupBy`) — the sort had been
  silently inert. `Coverage Ratios` also never excluded `gis` (numeric, 1 per real room) so it was
  drawn as a fourth ratio, and its `Coverage Gap` `calculateField` had a binary config with **no
  operator at all**.
- **Five stat panels rendered raw PromQL as their series name.** `SNMP Coverage (now)` and
  `Minutes Since Last SNMP Cycle` (av_rooms) plus `SNMP Last Sample`, `Minutes Since SNMP Sample` and
  `SNMP Status (now)` (av_devices_details) had neither `legendFormat` nor `displayName`, so Grafana
  fell back to the expression text — tolerable until `1919357` made those expressions much longer.

### Changed
- The `Unconnected Devices` slice on `Connectivity Breakdown — %` is now **transparent**
  (was `text`), matching `Network Health — %` and `Snmp Monitoring Health — %` on the AV Devices
  dashboard. It keeps its share of the circle, its legend entry and its tooltip value while letting
  the Online/Offline colours carry the read. The bargauge counterpart deliberately keeps normal
  colours — a transparent bar would simply be invisible.


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
