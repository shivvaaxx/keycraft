import SwiftUI

@main
struct KeycraftApp: App {
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup("Keycraft") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .task { store.start() }
                .task { await DebugHooks.apply(store) }
                .modifier(DebugOpenWindow())
        }
        .defaultSize(width: 1180, height: 720)
        .commands { AppCommands(store: store) }

        Window("Keyboard Library", id: "library") {
            LibraryWindowView().environment(store)
        }
        .defaultSize(width: 560, height: 640)

        Settings {
            SettingsView().environment(store)
        }
    }
}
