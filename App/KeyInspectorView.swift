import KeycraftCore
import SwiftUI

/// The inspector for the selected key: what it does now, and a searchable list of everything it can do instead.
struct KeyInspectorView: View {
    @Bindable var session: KeyboardSession
    let definition: VIADefinition
    @Environment(DeviceStore.self) private var store
    @State private var query = ""
    @State private var showSaved = false
    @FocusState private var searchFocused: Bool

    private var position: Int? {
        guard let i = session.selectedKey, definition.keys.indices.contains(i) else { return nil }
        let key = definition.keys[i]
        return key.row * definition.cols + key.col
    }

    var body: some View {
        Group {
            if let position {
                VStack(alignment: .leading, spacing: 0) {
                    header(position: position)
                    Divider()
                    search
                    keyList(currentCode: session.keymap[session.layer][position])
                }
            } else {
                ContentUnavailableView("No Key Selected", systemImage: "cursorarrow.click",
                                       description: Text("Click a key on the keyboard to see what it does and change it."))
            }
        }
        .task(id: session.saveCount) {
            guard session.saveCount > 0 else { return }
            showSaved = true
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { showSaved = false }
        }
        .onChange(of: session.pickerFocusRequest) { searchFocused = true }
    }

    // MARK: Current assignment

    private func header(position: Int) -> some View {
        let info = Keycode.info(session.keymap[session.layer][position], protocolVersion: session.protocolVersion,
                                custom: definition.customKeycodes)
        let key = definition.keys[session.selectedKey ?? 0]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Key").font(.caption).foregroundStyle(.secondary)
            Text(info.name).font(.title2.bold()).lineLimit(2)
            Text(info.description).font(.callout).foregroundStyle(.secondary)
            Text("Row \(key.row), column \(key.col) · \(Keycode.layerName(session.layer))")
                .font(.caption).foregroundStyle(.secondary)
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if let error = session.writeError {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.callout).foregroundStyle(.red)
                if let code = session.retryCode {
                    Button("Try Again") { Task { await store.assign(code, on: session) } }
                        .help("Send the change to the keyboard again")
                }
            }
        } else if showSaved {
            Label("Saved to keyboard", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        }
    }

    // MARK: Change To

    private var search: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Change To").font(.headline)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .help("Find a key by name, for example Volume or Command")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var groups: [KeycodeGroup] {
        let all = Keycode.catalogue(layerCount: session.layerCount, protocolVersion: session.protocolVersion,
                                    custom: definition.customKeycodes)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { group in
            let hits = group.keycodes.filter { [$0.name, $0.label, $0.description].contains { $0.lowercased().contains(q) } }
            return hits.isEmpty ? nil : KeycodeGroup(title: group.title, footer: group.footer, keycodes: hits)
        }
    }

    private func keyList(currentCode: UInt16) -> some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.keycodes) { key in
                        KeycodeRow(info: key, isCurrent: key.code == currentCode) {
                            Task { await store.assign(key.code, on: session) }
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if !group.footer.isEmpty { Text(group.footer).font(.caption) }
                }
            }
        }
        .listStyle(.inset)
        .disabled(session.isBusy)
    }
}

private struct KeycodeRow: View {
    let info: KeycodeInfo
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name)
                    Text(info.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if isCurrent { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(info.description)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
