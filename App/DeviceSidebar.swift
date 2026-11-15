import KeycraftCore
import SwiftUI

struct DeviceSidebar: View {
    @Environment(DeviceStore.self) private var store
    @AppStorage("showDemoKeyboard") private var showDemo = true

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedID) {
            Section("Connected") {
                if store.sessions.isEmpty {
                    Text("No keyboards connected").foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { session in
                    SidebarRow(name: session.displayName, status: session.statusText).tag(session.id)
                }
            }
            if showDemo {
                Section("Demo") {
                    SidebarRow(name: store.demo.displayName, status: store.demo.statusText).tag(store.demo.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }
}

private struct SidebarRow: View {
    let name: String
    let status: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "keyboard")
        }
        .accessibilityElement(children: .combine)
    }
}
