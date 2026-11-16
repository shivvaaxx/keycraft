import KeycraftCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail column for one keyboard: state or canvas, the layer switcher, backups and the key inspector.
struct KeyboardDetailView: View {
    @Bindable var session: KeyboardSession
    @Environment(DeviceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        content
            .navigationTitle(session.displayName)
            .navigationSubtitle(subtitle)
            .toolbar {
                if session.isReady {
                    ToolbarItem(placement: .principal) {
                        Picker("Layer", selection: $session.layer) {
                            ForEach(0..<session.layerCount, id: \.self) { Text(Keycode.layerName($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .help(session.layer == 0 ? "Keys you get without holding a layer key"
                              : "Active while a key assigned to \(Keycode.layerName(session.layer)) is held or toggled")
                    }
                    if session.macros != nil {
                        ToolbarItem {
                            Button("Macros", systemImage: "record.circle") { store.showMacros = true }
                                .help("Record key presses that one key plays back")
                        }
                    }
                    ToolbarItem {
                        Button("Backups", systemImage: "clock.arrow.circlepath") { store.showBackups = true }
                            .help("Back up or restore this keyboard's keymap")
                    }
                    ToolbarItem {
                        Button("Key Details", systemImage: "sidebar.trailing") { store.showInspector.toggle() }
                            .help("Show key details")
                    }
                }
            }
            .task { await session.loadIfNeeded() }
            .sheet(isPresented: $store.showBackups) { BackupsView(session: session) }
            .sheet(isPresented: $store.showMacros) { MacrosView(session: session) }
            .sheet(isPresented: $store.showSharing) {
                if store.sharingAvailable { SharingSheet(session: session, account: store.account, anonymous: store.anonymous) }
            }
            .fileImporter(isPresented: $store.showImporter, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { Task { await session.importDefinition(url) } }
            }
    }

    private var subtitle: String {
        if session.isDemo, let name = session.definition?.name { return name }
        if let maker = session.maker, !maker.isEmpty { return maker }
        return session.info.vidPid
    }

    @ViewBuilder private var content: some View {
        if session.isReady, let definition = session.definition, session.keymap.indices.contains(session.layer) {
            KeyboardCanvasView(session: session, definition: definition)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if session.offerShare, store.canShare(session) { ShareBanner(session: session) }
                }
                .inspector(isPresented: Bindable(store).showInspector) {
                    KeyInspectorView(session: session, definition: definition)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        } else {
            KeyboardStateView(session: session)
        }
    }
}
