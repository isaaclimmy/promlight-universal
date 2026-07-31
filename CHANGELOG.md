# Changelog

## 0.2.1 — 2026-07-31

- Restored the original PromLight application icon in Finder and release packages.
- Added build and packaging checks that reject bundles with a missing or invalid icon.

## 0.2.0 — 2026-07-31

- Added PromLight battery percentage to the English local console and `/api/status`.
- Added the `PromLight battery` command and battery output to `--selftest`.
- Read the Bluetooth accessory level already maintained by macOS, with a 60-second cache and a `pmset` compatibility fallback.
- Matched battery records to the connected PromLight by accessory identifier when available.

## 0.1.0 — 2026-07-31

- Clean-room native macOS implementation for PromLight HID hardware.
- Universal `arm64` and `x86_64` application bundle.
- Direct IOKit HID transport with no Rosetta, Python, or Homebrew dependency.
- English local control and setup console.
- Compatible local AI hook listener and native hook client.
- Hook installers for Claude, Codex, Cursor, Copilot, Qoder, CodeBuddy, and Antigravity.
- User LaunchAgent support, command-line diagnostics, and reproducible release packaging.
