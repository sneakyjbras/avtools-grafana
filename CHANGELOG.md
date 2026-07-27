# Changelog

All notable changes to **av-tools-grafana** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **License & Maintainer documentation**: Added `CONTRIBUTING.md` listing José Bras (`jose.bras@cern.ch` / `j.eduardo.bras@outlook.com`, `@jsapinat` / `@sneakyjbras`) as sole maintainer under the MIT License.

## [1.9.8] — 2026-07-27

### Added
- **Room down-walk de-recursion**: Optimized room hierarchy querying in `av_rooms` panels via `eam_rooms`.

### Fixed
- **No-position devices projection**: Restored `no_position_devices` projection to fix SQL runtime error `42703`.
