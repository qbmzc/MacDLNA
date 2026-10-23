# Repository Guidelines

## Project Structure & Module Organization

MacDLNA is a dependency-free Swift Package executable for macOS 13+, built with Swift tools 5.9. All source files live in `Sources/MacDLNA/`:

- `MacDLNAApp.swift`: SwiftUI menu-bar interface and service coordination.
- `AudioEngine.swift` and `LyricService.swift`: playback, media metadata, and lyrics.
- `SSDPService.swift` and `UPnPHTTPServer.swift`: discovery and HTTP/SOAP control.
- `UPnPXMLTemplates.swift` and `NetworkUtils.swift`: protocol descriptions and network helpers.

`Package.swift` defines the executable. `build_app.sh` generates the application bundle and its configuration. `.build/` and `MacDLNA.app/` are generated outputs; do not edit or commit them. No dedicated test or asset directories currently exist.

## Build, Test, and Development Commands

Install Xcode Command Line Tools and use a Mac running macOS 13 or later.

- `swift build`: compile a debug executable.
- `swift run MacDLNA`: run locally from the terminal.
- `swift build -c release`: compile an optimized executable.
- `./build_app.sh`: rebuild `MacDLNA.app`, generate its plist, and apply an ad-hoc signature. This replaces the existing bundle.
- `open MacDLNA.app`: launch the packaged menu-bar application.

## Coding Style & Naming Conventions

Match the existing Swift style: four-space indentation, opening braces on the declaration line, `UpperCamelCase` types, and `lowerCamelCase` properties and functions. Name files after their primary type. Use `// MARK: -` to group responsibilities. Keep protocol handling separate from views, preserve existing queue boundaries, and dispatch UI-observed changes to the main thread. No formatter or linter is configured.

## Testing Guidelines

There is no test target or coverage threshold yet. Run `swift build` for every code change. For behavior changes, verify discovery from a controller on the same LAN, casting, play/pause, seeking, volume, metadata, and affected lyric behavior. Record the macOS version, controller app, and results. If adding automated tests, register an XCTest target in `Package.swift`, place `*Tests.swift` in `Tests/MacDLNATests/`, and run `swift test`.

## Commit & Pull Request Guidelines

No Git history was available when this guide was created. Use concise imperative commit messages, optionally scoped, such as `fix(ssdp): handle repeated discovery requests`. Keep commits focused. Pull requests should describe behavior changes, validation commands, manual casting results, and linked issues where applicable. Include screenshots for interface changes.

## Security & Configuration

SSDP uses UDP port 1900; HTTP defaults to port 8585. Test on a trusted LAN and avoid exposing the receiver to the public internet. Change bundle permissions in `build_app.sh`, not generated `Info.plist`. Do not commit credentials or private streaming URLs.
