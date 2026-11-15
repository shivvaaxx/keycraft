import KeycraftCore
import SwiftUI

/// Menu bar: every command is reachable here. File, Keyboard and Help are Keycraft's own; the library opens from Window.
struct AppCommands: Commands {
    let store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    private var session: KeyboardSession? { store.selected }
    private var ready: Bool { session?.isReady == true }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Load Layout File…") { store.showImporter = true }
                .keyboardShortcut("o")
                .disabled(session == nil)
            Divider()
            Button("Open QMK Code…") { openWindow(id: "qmk") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Export as QMK Code…") { if let session { QMKExport.save(session) } }
                .disabled(!ready)
            if store.account != nil {
                Button("Share Keyboard Layout…") { store.showSharing = true }
                    .disabled(session.map { !store.canShare($0) } ?? true)
            }
        }
        CommandGroup(after: .toolbar) {
            Button(store.showInspector ? "Hide Key Details" : "Show Key Details") { store.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!ready)
        }
        CommandMenu("Keyboard") {
            Button("Reload from Keyboard") { if let session { Task { await session.load() } } }
                .keyboardShortcut("r")
                .disabled(session == nil)
            Button("Back Up Now") { if let session { Task { _ = await store.backUpNow(session) } } }
                .keyboardShortcut("b")
                .disabled(!ready)
            Button("Backups…") { store.showBackups = true }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!ready)
            Divider()
            Button("Next Layer") { step(1) }
                .keyboardShortcut("]")
                .disabled(!ready)
            Button("Previous Layer") { step(-1) }
                .keyboardShortcut("[")
                .disabled(!ready)
        }
        CommandGroup(before: .windowList) {
            Button("Keyboard Library") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            if store.libraries.canUpdate {
                Button("Check for Keyboard Updates") {
                    openWindow(id: "library")   // the result is shown there
                    Task { await store.libraries.checkForUpdates() }
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Keycraft Help") { Help.openReadme() }
            Divider()
            // Keycraft is free; these open the donation pages in the browser.
            Button("Support Keycraft on Ko-fi…") { NSWorkspace.shared.open(KeycraftConfig.koFiURL) }
            Button("Sponsor Keycraft on GitHub…") { NSWorkspace.shared.open(KeycraftConfig.githubSponsorsURL) }
        }
    }

    private func step(_ delta: Int) {
        guard let session, session.layerCount > 0 else { return }
        session.layer = min(max(session.layer + delta, 0), session.layerCount - 1)
    }
}
