# Keycraft

Free, open-source (GPL-3.0) native macOS app that configures keyboards live over USB. This first slice
speaks the VIA protocol (QMK) and includes a built-in Demo Keyboard, so it works with no hardware.
Keyboards are detected automatically (hot-plug): no pairing, no permission picker, no browser.

## Build
```
swift build && swift test          # core library + tests
xcodegen generate
xcodebuild -project Keycraft.xcodeproj -scheme Keycraft -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Keycraft.app
```
Debug hooks (environment): `KEYCRAFT_DEMO_ONLY=1` skips hardware detection and opens the Demo Keyboard;
`KEYCRAFT_BACKUP_DIR=<path>` redirects backups.

## License and credits
GPL-3.0 (see LICENSE). Protocol details come from QMK Firmware (`via.c`, `via.h`, `keycodes.h`) and the
VIA app client (`keyboard-api.ts`). The bundled keyboard definitions in
`Sources/KeycraftCore/Resources/KeyboardDatabase/` are from the-via/keyboards (GPL-3.0, compatible with this app's license).

## Turning on VIA in your keyboard's firmware
Keycraft edits keys live through VIA, a feature of QMK firmware. If a keyboard shows "Live Editing Isn't
Available", its firmware was built without VIA. Look for a VIA-enabled firmware for your model on the
maker's site or on usevia.app, flash it, and reconnect the keyboard.
