# Keycraft — Slice 2: keyboard library, sharing, and the Apple-style redesign

Goal (Shiva): "design the app as if Apple built it — simple, but anyone using it knows what each
button or setting is for." Plus: a big built-in keyboard database, and a way for users to send new
keyboards back to the shared database.

HIG pages used (in `~/.claude/skills/apple-design/references/hig/`): `alerts.md`, `sidebars.md`,
`settings.md`, `toolbars.md`, `writing.md`, `feedback.md`, `loading.md`, `offering-help.md`,
`accessibility.md`, `designing-for-macos.md`. Citations below are `file › headline`.

Out of scope: KeyMapper port (event-tap remapping, Key Test, lighting), Vial, vendor drivers,
flashing, git operations on this repo.

---

## Part A — Keyboard Library (database)

### A1. Bundled database (done by Claude, you only load it)
`Sources/KeycraftCore/Resources/KeyboardDatabase/via-keyboards.zlib` = raw-deflate JSON built by
`Scripts/build-keyboard-db.py` from github.com/the-via/keyboards (GPL-3.0):
`{"version":1,"source":"…","builtAt":"ISO8601","keyboards":[ <VIA definition> + "maker" + "definitionFormat" ]}`
2,032 keyboards, one per vendorId:productId. Decompress with `(data as NSData).decompressed(using: .zlib)`.
Remove the two old fixture JSONs from `Resources/Definitions/` (keep copies under `Tests/…/Fixtures/`
for tests). The Demo Keyboard keeps using the GH60 Satan definition (look it up in the database by
4335:0002).

### A2. `KeyboardLibrary` (KeycraftCore, new file `Library/KeyboardLibrary.swift`)
- Loads, in order of priority for the same vid:pid: (1) user-imported definitions in
  `~/Library/Application Support/Keycraft/Definitions/*.json`, (2) downloaded library
  `~/Library/Application Support/Keycraft/Library/via-keyboards.zlib` if its `builtAt` is newer than
  the bundled one, (3) bundled.
- API: `definition(vendorID:productID:) -> VIADefinition?`, `entries: [LibraryEntry]`
  (name, maker, vid, pid, source: .bundled/.downloaded/.imported), `builtAt`, `count`.
- Decode lazily: keep raw JSON per entry, decode `VIADefinition` on lookup (fast launch —
  `loading.md › Show something as soon as possible`). Load off the main thread.
- Every definition in the bundled database must parse with `VIADefinition` (test: iterate all 2,032,
  assert ≥ 99% parse and print failures; fix the parser for any common pattern you find, e.g.
  rotation keys, `"d": true` decals, string matrix positions with whitespace).

### A3. Library updates
- `LibraryUpdater`: GETs `<base>/manifest.json` → `{"builtAt":"…","sha256":"…","url":"…/via-keyboards.zlib","count":N}`;
  if newer than the active library, downloads, verifies SHA-256 (CryptoKit), writes atomically to
  the Library dir. HTTPS only. Timeout 15 s. Never blocks UI. Errors surface in the Library window
  only, never as an alert (`alerts.md › Use alerts sparingly`).
- `<base>` comes from `KeycraftConfig.swift` (single file of constants):
  `libraryBaseURL: URL?`, `databaseRepo: (owner: String, name: String)?`, `githubClientID: String?`.
  All nil for now → updater and sharing report "not set up in this build" and the UI hides the
  controls that need them. Tests use URLProtocol stubs.
- Setting: "Check for keyboard updates automatically" (default on), checks at most once per day.

## Part B — Sharing a keyboard to the database ("git push" a new keyboard)

Model: the database is a public GitHub repo. A user never pushes to it directly; the app pushes the
new definition to **the user's fork** and opens a **pull request**; maintainers review and merge; CI
rebuilds `via-keyboards.zlib` + `manifest.json`; every app picks it up via A3. (Review protects
everyone's keyboards: an unreviewed bad definition reaches every user.)

`GitHubSharing` (KeycraftCore, `Sharing/GitHubSharing.swift`), REST v3 via URLSession, no third-party deps:
1. Sign in: OAuth **device flow** (`POST https://github.com/login/device/code` with client_id,
   scope `public_repo`; show `user_code`, open `verification_uri`; poll
   `https://github.com/login/oauth/access_token` respecting `interval`/`slow_down`/`expired_token`).
   Store token in Keychain (`kSecClassGenericPassword`, service `app.keycraft.github`). Sign out deletes it.
2. Share: `GET /user` → login; `POST /repos/{owner}/{repo}/forks` (idempotent; poll until the fork
   answers `GET /repos/{login}/{repo}`); get default branch SHA of upstream; create branch
   `add-<maker>-<slug>-<vidpid>` on the fork (`POST /repos/{login}/{repo}/git/refs`); `PUT
   /repos/{login}/{repo}/contents/keyboards/<maker>/<slug>.json` (base64 content, message
   `Add <name> (<VID:PID>)`); `POST /repos/{owner}/{repo}/pulls` (head `<login>:<branch>`, base
   default branch, body: name, VID:PID, matrix, "Submitted from Keycraft <version>"). Return PR URL.
   If a PR for that branch already exists (422), return the existing PR URL.
3. Validate before sharing: definition parses, vid/pid present, matrix fits all keys, name non-empty,
   size < 1 MB. Never include anything except the definition JSON (no serials, no backups).
Tests: full flow against a URLProtocol stub, including slow_down and the 422 path.

UI for sharing: see B-screens below.

## Part C — Redesign (Apple-style)

Principles: familiar system components for every control; the keyboard itself is the one visual
signature; every control explains itself through its label, a help tag, or a section footer.

### C1. Window and navigation
- `NavigationSplitView` with sidebar + detail; detail hosts an `.inspector` for the selected key.
- Sidebar (`sidebars.md › show no more than two levels`, `› Consider using familiar symbols`):
  - Section **Connected**: one row per keyboard: SF Symbol `keyboard`, name, secondary line = status
    in words: "Ready", "Reading keymap…", "Not supported", "Layout needed".
  - Section **Demo**: "Demo Keyboard" (setting can hide it).
  - Nothing critical at the bottom (`sidebars.md › Avoid putting critical information or actions at the bottom`).
  - Collapse duplicate interfaces of one physical keyboard into one row (same vid/pid/serial or
    same locationID prefix).
- Window title = keyboard name, subtitle = maker (`toolbars.md › Don't title windows with your app name`).

### C2. Toolbar (detail)
- Layer control: segmented `Picker`, labels **"Base", "Layer 1", "Layer 2", "Layer 3"** (0-based
  layer 0 = Base). Help tag: "Keys you get without holding a layer key" for Base; "Active while a
  key assigned to Layer N is held or toggled" for others.
- Backups: symbol `clock.arrow.circlepath`, label "Backups", help "Back up or restore this keyboard's keymap".
- Inspector toggle: `sidebar.trailing`, help "Show key details".
- No other toolbar items (`toolbars.md › Choose items deliberately to avoid overcrowding`). Every
  item has a text label available (`toolbars.md › Make sure the meaning of each control is clear`).

### C3. Keyboard canvas (the signature)
- Keycaps sized to fit the available width (unit = min(available / layoutWidth, 64), floor 30 pt);
  centred; re-layout on resize. Physical-feeling caps: rounded rect, subtle top highlight and
  bottom shadow using semantic colours only (light + dark). Accent ring when selected.
- Cap text: primary label (e.g. "A", "⌘", "Hold L1") — never truncated mid-word; shrink to a
  minimum 10 pt (`accessibility.md`, macOS min 10 pt) then wrap to 2 lines.
- Transparent keys show the effective key from the layer below, dimmed, with a small "▽" glyph;
  help "Uses the key from the layer below".
- Keys changed this session show a small accent dot (top-right) until next launch.
- Keyboard navigation: arrow keys move selection between caps (nearest neighbour by geometry),
  Return/Space opens the inspector's picker, Escape deselects. VoiceOver label
  "<label>, row R, column C, <layer name>"; hint "Double-tap to change".
- Layer switch crossfades labels (0.15 s); none with Reduce Motion.

### C4. Inspector — "Key"
Top: large current assignment (name + one-line plain-English description). Then "Change To" with a
search field and grouped list (sections with footers that explain the group):
- **Letters & Numbers**, **Symbols**, **Editing** (Return, Delete, Tab, Escape, Space…),
  **Navigation** (arrows, Home, End, Page Up/Down), **Function Keys**, **Modifiers** (Mac names:
  Control, Option, Command, Shift — left/right), **Media & System** (volume, brightness, play,
  next… — QMK `KC_AUDIO_*`, `KC_MEDIA_*`, `KC_BRIGHTNESS_*`, consumer usages ≥ 0xA5 per keycodes.h),
  **Keypad**, **Layers**, **Special**.
- Layers group shows, per layer N < layerCount, three rows with descriptions:
  "Hold for Layer N — Layer N is active only while you hold this key" (MO),
  "Switch to Layer N — Stays on Layer N until you switch again" (TO),
  "Toggle Layer N — Press once to turn Layer N on, again to turn it off" (TG).
- Special: "None — Key does nothing", "Transparent — Uses the key from the layer below".
- Every keycode in the catalogue carries `name` + `description` (≤ 75 chars,
  `offering-help.md › Be brief`); descriptions appear as row subtitles and help tags.
- Selecting a code writes it (after the backup gate). Success → inline "Saved to keyboard" with a
  checkmark under the title for 2 s (`feedback.md › integrate status feedback into your interface`);
  no alert. Failure → inline red text with what happened and "Try Again".
- Unknown codes show "Custom code 0x7C16 — Set by the keyboard's firmware".

### C5. Backup warning
System `.alert` (not a custom sheet). Title: **"Some things can't be backed up"**. Message: one line
per missing important item "• Firmware: this keyboard can't send its firmware to a Mac" /
"• Macros: the keyboard didn't respond in time", then "If something goes wrong, these can't be
restored." Buttons: **Cancel** (`.cancel`, default, Return) and **Change Anyway**
(`.destructive`). Let the system place them (`alerts.md › Place buttons where people expect`).
Suppression: `.dialogSuppressionToggle("Don't warn again for this keyboard", isSuppressed:)` shown
ONLY when every missing item is `.notSupported` (permanent, e.g. firmware); persisted per vid:pid.
Failures (timeouts, errors) always warn. (Keeps Shiva's rule — warn and ask, never refuse — while
following `alerts.md › Use alerts sparingly`.)

### C6. Backups sheet
Title "Backups — <keyboard>". Explanatory line: "Keycraft backs up your keyboard automatically before
its first change each time you connect it." List rows: date (relative + absolute), contents
("Keymap, Macros"), and a caution badge if it was made with missing items. Buttons: "Back Up Now",
"Restore Keymap" (enabled for a row with a keymap; confirm via alert "Restore keymap from <date>?
This replaces the keymap on <keyboard>." Cancel / Restore), "Show in Finder". Done closes.

### C7. States (`writing.md › Provide clear next steps on any blank screens`) — use `ContentUnavailableView`
- No keyboard: "Connect a Keyboard" / "Plug your keyboard into this Mac with a USB cable. Keycraft
  finds it automatically." / [Try the Demo Keyboard].
- Reading: ProgressView "Reading keymap from <name>…" shown immediately.
- Not supported (no VIA reply on the first command, i.e. timeout on get_protocol_version):
  "Live Editing Isn't Available" / "<name> didn't respond. Its firmware may not have VIA turned
  on." / [Try Again] [Learn More] (Learn More opens the README section on VIA firmware).
- Layout needed (VIA works, no definition): "Layout Needed" / "Keycraft knows 2,032 keyboards but
  not this one (<VID:PID>). Load its VIA layout file, then share it so others get it too." /
  [Load Layout File…].
- After a user imports a layout for a keyboard not in the library: a non-modal banner above the
  canvas: "Share this layout with the Keycraft library?" [Share…] [Not Now].

### C8. Sharing sheet
Shows what will be shared: name, maker (editable text fields with validation), VID:PID, key count,
a small layout preview, and the sentence "Only the layout file is shared — nothing about your
keymap or this Mac." Steps in one sheet: if signed out → "Sign In with GitHub" (device code shown
large with a Copy button and "Open GitHub" button; status "Waiting for you to approve on GitHub…");
then [Share] → progress "Creating pull request…" → "Shared. Maintainers will review it." with a
link "View Pull Request". If sharing isn't configured in this build, the Share entry points are hidden.

### C9. Keyboard Library window (Window ▸ Keyboard Library, ⇧⌘L)
Searchable list grouped by maker; row: name, VID:PID, source badge (Built in / Updated / Added by
you). Header: "2,032 keyboards · Updated <date>" and [Check for Updates] (hidden if not configured).
Footer explains: "If your keyboard isn't listed, load its VIA layout file from the keyboard's page."

### C10. Settings (⌘,) — minimal (`settings.md › Minimize the number of settings you offer`)
`Settings` scene, panes with fixed toolbar (`settings.md › noncustomizable toolbar`):
- **General**: "Show Demo Keyboard in sidebar" (mini switch); "Check for keyboard updates
  automatically" (mini switch, footer "Keycraft checks once a day for newly added keyboards.").
- **Backups**: location path + [Show in Finder]; footer explaining automatic backups.
- **Sharing** (only if configured): "GitHub account: <login>" + [Sign Out] or [Sign In…]; footer
  "Used only to send keyboard layouts to the shared library."
`.formStyle(.grouped)`; mini switches (`toggles.md` via skill notes).

### C11. Menu bar (`designing-for-macos.md`: every command reachable from the menu bar)
- File: Load Layout File… (⌘O), Share Keyboard Layout… (only if configured).
- Keyboard (new menu): Reload from Keyboard (⌘R), Back Up Now (⌘B), Backups… (⇧⌘B),
  Next Layer (⌘]), Previous Layer (⌘[).
- Window: Keyboard Library (⇧⌘L).
- Help: Keycraft Help opens README.

### C12. Writing
Title-style capitalisation for buttons, menus, section headers (`writing.md › Adopt capitalization
rules … consistently`). Name things by what people control: "Layer", "Key", "Backup", "Layout
File" — never "definition", "matrix", "keycode", "VIA protocol" in primary UI (they may appear in
secondary detail like VID:PID). Errors say what happened and what to do, no apologies.

## Part D — small fixes carried over
1. `IOHIDTransport.close()` idempotent (guard with a flag inside the bridge lock; cancel once).
2. Not-supported state as C7 (first-command timeout ⇒ "not supported", not a generic error).

## Done check
- `swift build`, `swift test` green (new tests: library load + ≥99% parse, updater checksum
  accept/reject, sharing flow stub incl. 422 + slow_down, keycode catalogue has name+description for
  every entry, suppression only offered for all-notSupported).
- `xcodegen generate && xcodebuild … build` succeeds with zero Swift warnings.
- Launch with `KEYCRAFT_DEMO_ONLY=1`; screenshots of: empty state, demo keyboard with inspector open
  on Layers group, Library window, Settings General. Report paths.
- Report deviations and anything unverified. No git commands.

---

## Amendments (override anything above)

E1. **Custom keycodes.** VIA definitions may carry `customKeycodes: [{name, title, shortName}]`
(e.g. every Keychron board: Mission Control, Launchpad, Siri…). Entry *i* maps to keycode
`QK_KB + i` where `QK_KB = 0x7E00`, `QK_KB_MAX = 0x7E3F` (keycodes.h lines 91–92). Show `shortName`
on the cap, `name` as the inspector name and `title` as the description, and list them in a
"This Keyboard" group at the top of the picker. Only codes outside every known range fall back to
"Custom code 0x…".

E2. **Interface choice.** Do not filter on report size. the-via/app filters only by usage page/usage
and then "attempts connection" (`src/utils/hid-keyboards.ts` getRecognisedDevices → canConnect).
Keycraft: for each matching 0xFF60/0x61 interface, send `get_protocol_version` (read-only) with a
short timeout; use the first interface whose reply echoes 0x01. Physical keyboard = interfaces with
the same vid/pid/serial and the same USB locationID; show it once. If none echoes, that keyboard is
"Not supported" (C7) — still listed once. Remove the 32-byte filter from `HIDDeviceMonitor`. The
transport must handle 64-byte reports: request is padded to the interface's MaxOutputReportSize;
reply parsing uses only the first 32 bytes.

E3. **Rendering any keyboard.** `MockVIADevice` gains `init(definition:)` so it can emulate any
library entry (layer 0 filled with the definition's default labels where they look like keycodes,
otherwise KC_A…). Rotated keys (`r`, `rx`, `ry`): implement KLE rotation for real (rotate key
rect about (rx, ry) by r degrees; KLE resets x to rx and y to ry on a new rotation cluster). The
canvas draws rotated caps with `.rotationEffect` and computes bounds from rotated corners.

E4. **Counts in copy** come from `KeyboardLibrary.count`, never hard-coded.

E5. **Sharing (Part B) and the updater (A3)** are built in a later step, once Shiva names the GitHub
repo and registers the OAuth app. Keep `KeycraftConfig.swift` with nil values now; don't build B yet.

E6. **Backup alert (C5) wording/suppression** waits for Shiva's answer; until then keep slice-1
behaviour and title "Unable to back up", but switch it to a system `.alert` with Cancel as the
default (Return) button.

Reference files (read-only): REF = upstream sources from qmk/qmk_firmware and the-via/app
(`keycodes.h`, `via.h`, `via.c`, `keyboard-api.ts`, `hid-keyboards.ts`).

E7. **Decisions from Shiva (2026-11-15), override C5/E5/E6:**
- Backup alert: keep the title **"Unable to back up"** (Shiva's words). System `.alert`, Cancel default.
  Add `.dialogSuppressionToggle("Don't warn again for this keyboard")` offered ONLY when every missing
  important item is `.notSupported` (permanent); persisted per vid:pid; failures always warn.
  "Saved firmware file counts as a backup" is deferred to the flashing slice.
- Database repo: a public repo on Shiva's **personal** GitHub account (collaborators later; can transfer to an org later). Base URL lives in one config constant. Sharing = OAuth **device
  flow** sign-in in-app (Shiva registers the OAuth App and supplies the Client ID), fork + PR as in Part B.

E8. **Database repo is live (2026-11-15):** https://github.com/shivvaaxx/keycraft-keyboards
- `KeycraftConfig.libraryBaseURL` = `https://github.com/shivvaaxx/keycraft-keyboards/releases/download/db-latest`
  (manifest at `<base>/manifest.json`; its `url` field is the absolute zlib URL; `count` included).
- `databaseRepo` = (owner: "shivvaaxx", name: "keycraft-keyboards"); new layouts go to
  `keyboards/<maker>/<slug>.json`; CI (`scripts/build.py --check`) validates PRs; max file 1 MB.
- `githubClientID = "Ov23li0k38TEcp6DAb59"` (OAuth App registered 2026-11-15, device flow on, no secret; public value, safe to commit).
