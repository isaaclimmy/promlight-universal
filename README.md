# PromLight Universal

PromLight Universal is a clean-room, source-maintainable macOS controller for
PromLight Bluetooth status lights. The application and every runtime component
are built for both Apple silicon and Intel Macs.

It does not require Rosetta, Python, Homebrew, hidapi, or the original Intel
application.

## Included

- Native IOKit HID transport for PromLight VID `07D7`, PID `6B01`.
- LED colors, on/off/blink actions, exclusive mode, count, frequency, and fade.
- Persistent brightness, blink frequency, fade, and BLE advertising settings.
- AI hook daemon on the loopback-only address `127.0.0.1:47800`.
- Accessible, self-contained English console on `127.0.0.1:7800`.
- Battery percentage from macOS's Bluetooth accessory power source, available
  in the console, local status API, diagnostics, and CLI.
- Global, project, or exportable hook setup for Claude, Codex, Cursor, Copilot,
  Qoder, CodeBuddy, and Antigravity.
- Project, agent, alias, and default-device routing.
- User-level login startup through a LaunchAgent.
- Reproducible Universal app and release ZIP scripts.

## Build

Requirements: macOS 13 or later and a current Xcode command-line toolchain.

```bash
Scripts/build-universal.sh
```

The verified app is written to `dist/PromLight.app`. The script independently
builds `arm64` and `x86_64`, combines them with `lipo`, creates a Universal
dSYM, applies an ad-hoc hardened-runtime signature, and verifies both slices.

Create the friend-ready ZIP, checksum, and English install guide with:

```bash
Scripts/package-release.sh
```

## Run and configure

Double-click `PromLight.app` to start the service and open the English local
console. From Terminal, the executable is inside the app bundle:

```bash
'/Applications/PromLight.app/Contents/MacOS/PromLight' devices
'/Applications/PromLight.app/Contents/MacOS/PromLight' battery
'/Applications/PromLight.app/Contents/MacOS/PromLight' test
'/Applications/PromLight.app/Contents/MacOS/PromLight' setup codex
'/Applications/PromLight.app/Contents/MacOS/PromLight' setup all
'/Applications/PromLight.app/Contents/MacOS/PromLight' autostart enable
```

User configuration is stored in:

```text
~/Library/Application Support/PromLight Universal/
```

All listener sockets bind only to `127.0.0.1`. Ports can be changed in
`config.json` without exposing the service to other computers.

## Distribution security

The local build is ad-hoc signed. A normal zero-warning gift or public release
must be signed with an Apple Developer ID Application certificate, submitted to
Apple's notarization service, and stapled before the final ZIP is created. The
generated `INSTALL.txt` explains the expected Gatekeeper flow for the current
non-notarized preview.

## Project status

Version 0.2.1 reproduces the device control, AI hook, routing, setup, local web
console, battery status, diagnostics, and startup behavior needed for daily use. Software
updates are distributed as complete app releases; this build does not reuse the
original vendor's update channel.

PromLight Universal is an independent compatibility project and is not an
official Ghostyu Electronics release.
