import KeycraftCore
import SwiftUI

struct ContentView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        NavigationSplitView {
            DeviceSidebar()
        } detail: {
            if let session = store.selected {
                KeyboardDetailView(session: session).id(ObjectIdentifier(session))
            } else {
                EmptyStateView()
            }
        }
        .backupAlert(isActive: !store.showBackups)
    }
}
