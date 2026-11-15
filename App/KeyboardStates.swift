import KeycraftCore
import SwiftUI

/// Nothing is selected: tell people what to do next.
struct EmptyStateView: View {
    @Environment(DeviceStore.self) private var store
    @AppStorage("showDemoKeyboard") private var showDemo = true

    var body: some View {
        ContentUnavailableView {
            Label("Connect a Keyboard", systemImage: "keyboard")
        } description: {
            Text("Plug your keyboard into this Mac with a USB cable. Keycraft finds it automatically.")
        } actions: {
            if showDemo {
                Button("Try the Demo Keyboard") { store.selectDemo() }
                    .help("Explore Keycraft with a built-in keyboard, no hardware needed")
            }
        }
    }
}

/// Every state of a selected keyboard except `.ready` (the canvas), each with a clear next step.
struct KeyboardStateView: View {
    let session: KeyboardSession
    @Environment(DeviceStore.self) private var store

    var body: some View {
        switch session.phase {
        case .loading:
            ProgressView("Reading keymap from \(session.displayName)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notSupported:
            ContentUnavailableView {
                Label("Live Editing Isn't Available", systemImage: "keyboard.badge.ellipsis")
            } description: {
                Text("\(session.displayName) didn't respond. Its firmware may not have VIA turned on.")
            } actions: {
                Button("Try Again") { Task { await session.load() } }
                    .help("Ask the keyboard again")
                Button("Learn More") { Help.openReadme() }
                    .help("How to turn on live editing in your keyboard's firmware")
            }
        case .noDefinition:
            ContentUnavailableView {
                Label("Layout Needed", systemImage: "square.dashed")
            } description: {
                Text("Keycraft knows \(count) keyboards but not this one (\(session.info.vidPid)). Load its VIA layout file to start editing.")
            } actions: {
                Button("Load Layout File…") { store.showImporter = true }
                    .help("Choose the layout file (.json) for this keyboard")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Read the Keyboard", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(message) Check the USB cable, then try again.")
            } actions: {
                Button("Try Again") { Task { await session.load() } }
                    .help("Read the keymap from the keyboard again")
            }
        case .ready:
            EmptyView()
        }
    }

    private var count: String { (store.libraries.library?.count ?? 0).formatted() }
}

enum Help {
    /// The README ships inside the app; "Keycraft Help" and "Learn More" open it.
    static func openReadme() {
        if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) }
    }
}
