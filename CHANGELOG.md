# Changelog

All notable changes to **av-tools-grafana** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **License & Maintainer documentation**: Added `CONTRIBUTING.md` listing José Bras (`jose.bras@cern.ch` / `j.eduardo.bras@outlook.com`, `@jsapinat` / `@sneakyjbras`) as sole maintainer under the MIT License.

## [1.10.0] — 2026-07-28

### Added
- **Room up-climb de-recursion**: Replaced the last `WITH RECURSIVE` device→room position-climb queries in `AV: Devices Table` (`grafana/dashboard/prod/av_devices_dashboard.json` + `grafana/dashboard/qa/av_devices_dashboard-qa.json`) with direct joins against the precomputed `eam_rooms` cache table (populated by `avtools sync-rooms`). The recursion lived in the `room`, `eqclass`, `category`, and `device` template variables (8 `WITH RECURSIVE` occurrences per dashboard — one `query` + one `definition` field for each of the 4 variables); the same panel query already de-recursed in `1.9.x` (`Device Table`, and the alerts/`av_rooms` panels) is now the only pattern left in the dashboard, so no panel in this repo runs a recursive room-climb anymore. Output semantics are unchanged: same `pos_to_room`/`no_parent_positions`/`no_position_devices` CTE names and columns, same cascading Status→Room→Class→Category→Device filter behavior, and the same `__NO_ROOM_NO_POSITION__` / `__NO_ROOM_NO_PARENT__` sentinel handling — only the CTE bodies now read `eam_rooms.room_no` keyed on `parent_position`/`equipmentno` instead of climbing `eam_positions.parentasset`.

### Notes
- QA gate: `psql "$DATABASE_URL" -f scripts/verify_rooms_equivalence.sql` must report `mismatches = 0` (Result 1) before this is promoted — the script is the canonical proof that `eam_rooms.room_no` is equivalent to the old recursive climb.

## [1.9.8] — 2026-07-27

### Added
- **Room down-walk de-recursion**: Optimized room hierarchy querying in `av_rooms` panels via `eam_rooms`.

### Fixed
- **No-position devices projection**: Restored `no_position_devices` projection to fix SQL runtime error `42703`.
