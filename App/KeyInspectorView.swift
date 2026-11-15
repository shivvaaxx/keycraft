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
                    holdPicker(code: session.keymap[session.layer][position])
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
            if Keycode.needsExplanation(info.code) {
                Text(info.description).font(.callout).foregroundStyle(.secondary)
            }
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
        } else {
            // Always laid out, only faded: the list below must not jump when the confirmation comes and goes.
            Label("Saved to keyboard", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
                .opacity(showSaved ? 1 : 0)
                .accessibilityHidden(!showSaved)
        }
    }

    // MARK: When held (mod-tap / layer-tap)

    /// Tap/hold needs v2 keycodes and a basic tap key; mod-tap and layer-tap only carry an 8-bit key.
    private func tapPart(_ code: UInt16) -> (tap: UInt16, hold: Keycode.Hold?)? {
        guard session.protocolVersion >= VIAProtocol.keycodesV2 else { return nil }
        if let split = Keycode.tapHold(code, protocolVersion: session.protocolVersion) { return (split.tap, split.hold) }
        return (0x04...0xFF).contains(code) ? (code, nil) : nil
    }

    @ViewBuilder private func holdPicker(code: UInt16) -> some View {
        if let (tap, hold) = tapPart(code) {
            let binding = Binding<Keycode.Hold?>(
                get: { hold },
                set: { new in Task { await store.assign(new.map { Keycode.tapHold(tap: tap, hold: $0) } ?? tap, on: session) } })
            HStack {
                Picker("When Held", selection: binding) {
                    Text("Nothing").tag(Keycode.Hold?.none)
                    Section("Modifier") {
                        ForEach([(Keycode.Modifier.control, "Control"), (Keycode.Modifier.option, "Option"),
                                 (Keycode.Modifier.shift, "Shift"), (Keycode.Modifier.command, "Command"),
                                 (Keycode.Modifier.hyper, "Hyper (⌃⌥⇧⌘)"), (Keycode.Modifier.meh, "Meh (⌃⌥⇧)")], id: \.0) { m, name in
                            Text(name).tag(Keycode.Hold?.some(.modifiers(m)))
                        }
                    }
                    // Layer-tap encodes layers 0-15.
                    if session.layerCount > 1 {
                        Section("Layer") {
                            ForEach(1..<min(session.layerCount, 16), id: \.self) { n in
                                Text(Keycode.layerName(n)).tag(Keycode.Hold?.some(.layer(n)))
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(session.isBusy)
                .help("Make this key do something else while you hold it down")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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

    private var catalogue: [KeycodeGroup] {
        Keycode.catalogue(layerCount: session.layerCount, protocolVersion: session.protocolVersion, custom: definition.customKeycodes)
    }

    private var groups: [KeycodeGroup] {
        let all = catalogue
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { group in
            let hits = group.keycodes.filter { [$0.name, $0.label, $0.description].contains { $0.lowercased().contains(q) } }
            return hits.isEmpty ? nil : KeycodeGroup(title: group.title, footer: group.footer, keycodes: hits, isPlain: group.isPlain)
        }
    }

    private func keyList(currentCode: UInt16) -> some View {
        // On a tap/hold key the list picks the tap half, keeping the hold.
        let split = tapPart(currentCode)
        let current = split?.tap ?? currentCode
        func choose(_ code: UInt16) {
            let new = if let hold = split?.hold, (0x04...0xFF).contains(code) { Keycode.tapHold(tap: code, hold: hold) } else { code }
            Task { await store.assign(new, on: session) }
        }
        return List {
            ForEach(groups) { group in
                Section {
                    if group.isPlain {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                            ForEach(group.keycodes) { key in
                                KeycodeChip(info: key, isCurrent: key.code == current) { choose(key.code) }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(group.keycodes) { key in
                            KeycodeRow(info: key, isCurrent: key.code == current) { choose(key.code) }
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
                    if Keycode.needsExplanation(info.code) {
                        Text(info.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
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

/// A self-explanatory key (letter, number, F-key) as a small keycap: the label is all it needs.
private struct KeycodeChip: View {
    let info: KeycodeInfo
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            Text(info.label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .background(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)), in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: isCurrent ? 0 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(info.name)
        .accessibilityLabel(info.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
