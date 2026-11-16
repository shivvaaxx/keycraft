import SwiftUI

@main
struct KeycraftApp: App {
    @State private var store = DeviceStore()
    #if PAID_BUILD
    @State private var licence = LicenceState()
    #endif

    var body: some Scene {
        WindowGroup("Keycraft") {
            #if PAID_BUILD
            Group {
                if licence.license == nil { ActivationView() } else { ContentView() }
            }
            .environment(licence)
            .environment(store)
            .frame(minWidth: 900, minHeight: 560)
            .task { store.start() }
            .task { await DebugHooks.apply(store) }
            .modifier(DebugOpenWindow())
            #else
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .task { store.start() }
                .task { await DebugHooks.apply(store) }
                .modifier(DebugOpenWindow())
            #endif
        }
        .defaultSize(width: 1180, height: 720)
        .commands { AppCommands(store: store) }

        Window("Keyboard Library", id: "library") {
            LibraryWindowView().environment(store)
        }
        .defaultSize(width: 560, height: 640)

        Window("QMK Code", id: "qmk") {
            QMKCodeView().environment(store)
        }
        .defaultSize(width: 820, height: 640)

        Settings {
            #if PAID_BUILD
            SettingsView().environment(store).environment(licence)
            #else
            SettingsView().environment(store)
            #endif
        }
    }
}
