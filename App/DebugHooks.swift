import AppKit
import SwiftUI

/// Debug-only launch switches for screenshots and manual checks (Debug builds only):
/// `KEYCRAFT_APPEARANCE=dark|light`, `KEYCRAFT_SELECT_KEY=<index>`, `KEYCRAFT_LAYER=<n>`, `KEYCRAFT_HOVER=<hex keycode>` (key inspector).
enum DebugHooks {
    @MainActor static func apply(_ store: DeviceStore) async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        switch env["KEYCRAFT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if env["KEYCRAFT_OPEN"] == "qmk" { store.selectDemo() }   // so the opened file has a keyboard to be drawn on
        if env["KEYCRAFT_OPEN"] == "macros" {    // the Macros sheet on the Demo Keyboard
            store.selectDemo()
            for _ in 0..<50 where store.demo.macros == nil { try? await Task.sleep(for: .milliseconds(100)) }
            store.showMacros = true
        }
        if env["KEYCRAFT_OPEN"] == "sharing" {   // the Sharing sheet on the Demo Keyboard (it can't really be shared)
            store.selectDemo()
            try? await Task.sleep(for: .seconds(1))
            store.showSharing = true
        }
        guard env["KEYCRAFT_SELECT_KEY"] != nil || env["KEYCRAFT_LAYER"] != nil else { return }
        for _ in 0..<100 {   // wait for the selected keyboard to finish reading
            if let session = store.selected, session.isReady {
                session.selectedKey = env["KEYCRAFT_SELECT_KEY"].flatMap(Int.init)
                session.layer = env["KEYCRAFT_LAYER"].flatMap(Int.init) ?? session.layer
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #endif
    }
}

/// Debug builds only: `KEYCRAFT_OPEN=library|settings|sharing|macros|qmk` opens that window or sheet at launch (for screenshots).
struct DebugOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["KEYCRAFT_OPEN"] {
            case "library": openWindow(id: "library")
            case "qmk": openWindow(id: "qmk")   // with KEYCRAFT_QMK_FILE=<path> to open a keymap.c
            case "settings": openSettings()
            default: break
            }
            #endif
        }
    }
}
