# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-09-12

### Fixed

- Cached parsed field results and batched incoming UI updates to keep the receive view responsive under sustained traffic.
- Kept the verification module action bar available while its content scrolls, and added a session-only reset for its floating position.
- Added a verified Windows release script with checks for analysis, tests, fresh artifacts, launch responsiveness, build identity, and SHA256 output.
- Synchronized release documentation with the in-app floating verification module.

## [0.3.1] - 2026-09-12

### Fixed

- Replaced the delayed independent integrity calculator window with an in-app
  draggable verification panel.
- Minimizing the verification panel now preserves its input, algorithm, and
  result until HCOM closes.
- Renamed the calculator surface and right-side module to “校验模块”.

## [0.3.0] - 2026-09-12

### Added

- Protocol frame definition, JSON import/export, receive framing, and structured field parsing.
- Independent Windows integrity calculator with common checksum, CRC, and digest algorithms.
- Custom CRC parameters and complete-frame output that can be returned to the main send input.

### Changed

- Version metadata now distinguishes App `0.3.0`, Core `0.2.0`, and IPC protocol `v1`.

## [0.2.0] - 2026-09-12

### Added

- Windows UART/COM workbench, connection workflow, send queue, receive framing, and logging.

[Unreleased]: https://github.com/Tylenoler/HCOM/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/Tylenoler/HCOM/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Tylenoler/HCOM/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Tylenoler/HCOM/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Tylenoler/HCOM/releases/tag/v0.2.0
