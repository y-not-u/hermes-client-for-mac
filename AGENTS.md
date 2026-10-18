# Repository Guidelines

## Project Structure & Module Organization

Hermes for Mac is a native SwiftUI client for macOS 14+; the Hermes service runs separately. `HermesMac/Views/` contains UI components, `Stores/` holds observable application and conversation state, `Models/` defines protocol and parsing types, and `Services/` handles networking, authentication, notifications, and AppKit/WebKit integration. Assets live in `Assets.xcassets`; the bundled desktop viewer lives in `Resources/BotScreen/`. `Tools/CredentialHelper/` contains the credential helper. XCTest suites are in `Tests/HermesMacTests/`, automation in `script/`, and setup, protocol, and validation notes in `docs/`.

## Build, Test, and Development Commands

Use full Xcode with the macOS SDK selected through `xcode-select`, plus Python 3.

- `./script/setup_local_signing.sh`: create the local signing certificate once; retain the certificate and private key across builds.
- `./script/build_and_run.sh --build`: build the Debug app into `DerivedData/Build/Products/Debug/HermesMac.app`.
- `./script/build_and_run.sh`: build and launch; the script closes only the running HermesMacDev process, leaving Release running.
- `./script/build_and_run.sh --debug`: build and start LLDB. Use `--logs` or `--telemetry` to inspect runtime logs.
- `./script/test.sh`: start the aiohttp mock server and run SwiftPM tests; the first run installs the Python dependency in a temporary virtual environment.
- `python3 script/generate_project.py`: regenerate the Xcode project after adding Swift files.

## Coding Style & Naming Conventions

Match surrounding Swift code: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` properties and functions. Name files after their principal type, such as `BotScreenStore.swift`. Keep UI in views and transport logic in services; preserve `@MainActor` isolation for UI-facing state. No formatter or linter configuration is checked in. Preserve bundled noVNC/pako sources and licenses; integration changes belong in the viewer wrapper files.

## Testing Guidelines

Use XCTest classes named `*Tests` and descriptive methods beginning with `test`. Add regression coverage for changed state transitions, protocol handling, parsing, and viewer behavior. Run `./script/test.sh --filter StateTests` for focused checks and the full suite before submitting. No numeric coverage threshold is configured. Record relevant manual UI and live-service verification using `docs/VALIDATION.md` and `docs/BOT_SCREEN.md`.

## Commit & Pull Request Guidelines

Follow the history's Conventional Commits pattern: `feat(botscreen): ...` or `fix(chat): ...`. Keep changes focused. PRs should explain the problem and resulting behavior, link related issues, list validation performed, and include screenshots for visible UI changes. Update protocol or setup documentation when behavior changes. Never commit tokens, credentials, signing keys, or generated build artifacts.
