# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-09-21

### Added

- Apache-2.0 license (`LICENSE`).
- Continuous integration now builds the Windows release package (`flutter build windows`) instead of stopping after analysis and tests.

### Changed

- Repository links, the in-app About entry and the product documents follow the repository rename to `HPCom`.

### Fixed

- Template-length framing keeps a declared zero-payload frame (`AA 55 00 57 0D`) in one piece instead of releasing it as orphan bytes; the minimum-length guard no longer double-counts the fixed header, length, checksum and trailer fields.
- The custom baud rate prompt is no longer 28 px shorter than its content, which clipped the helper text and raised a `RenderFlex` overflow.
- The widget suite seeds an in-memory `SharedPreferences` store, so `flutter test` no longer stalls on an unanswered platform read until the 10-minute test timeout.
- The Windows build no longer requires Rust in `D:\HCOM-Rust`: CMake resolves Cargo from `-DHCOM_CARGO_EXECUTABLE`, the `.tooling/cargo-executable.txt` pointer that CI writes, the `HCOM_CARGO_EXECUTABLE` environment variable, `CARGO_HOME`, `%USERPROFILE%\.cargo\bin` or `PATH`, so CI can build the release package.

## [1.0.0] - 2026-09-20

### Changed

- Renamed the Windows application and executable to HPCom.
- Updated the product logo, Windows icon, taskbar icon, and theme-aware in-app mark.
- Published the first public Windows x64 release package and bilingual usage guide.

## [0.4.0] - 2026-09-13

### Added

- Added a dedicated virtual-COM relay mode: HCOM owns the physical COM port, forwards data between it and a named virtual COM endpoint, and records both directions in the unified stream.
- Added the HCOM-owned KMDF virtual-COM control protocol for creating named virtual port pairs from the workbench; formal releases will bundle only the Microsoft-signed HCOM driver package.
- Added IPC v2 commands and events for relay creation/state plus a Core-owned periodic scheduling worker.

### Changed

- Periodic sending now runs on an independent Rust thread and uses a shared serialized write path, rather than being timed by the Core event loop.
- Relay mode rejects HCOM manual and periodic writes so the external program remains the only virtual-port writer.

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

[Unreleased]: https://github.com/Tylenoler/HPCom/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/Tylenoler/HPCom/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Tylenoler/HPCom/compare/v0.4.0...v1.0.0
[0.4.0]: https://github.com/Tylenoler/HPCom/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/Tylenoler/HPCom/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Tylenoler/HPCom/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Tylenoler/HPCom/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Tylenoler/HPCom/releases/tag/v0.2.0
