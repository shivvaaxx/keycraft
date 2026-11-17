import KeycraftCore
import SwiftUI

/// The inspector for the selected key: what it does now, and a searchable list of everything it can do instead.
struct KeyInspectorView: View {
    @Bindable var session: KeyboardSession
    let definition: VIADefinition
    @Environment(DeviceStore.self) private var store
    @State private var query = ""
    @State private var showSaved = false
    @State private var hoveredCode: UInt16?
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
        Keycode.catalogue(layerCount: session.layerCount, protocolVersion: session.protocolVersion, custom: definition.customKeycodes,
                          macros: (session.macros ?? []).map(Macros.summary))
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
                    ChipGrid(minimum: group.isPlain ? 40 : 56) {
                        ForEach(group.keycodes) { key in
                            KeycodeChip(info: key, isCurrent: key.code == current, action: { choose(key.code) }, onHover: { inside in
                                if inside { hoveredCode = key.code } else if hoveredCode == key.code { hoveredCode = nil }
                            })
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(group.title)
                } footer: {
                    if let info = group.keycodes.first(where: { $0.code == hoveredCode }) {
                        Text(info.description.isEmpty ? info.name : "\(info.name): \(info.description)").font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else if !group.footer.isEmpty {
                        Text(group.footer).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(session.isBusy)
        #if DEBUG
        // Screenshots: `KEYCRAFT_HOVER=<hex keycode>` shows that key's explanation as if the pointer were over it.
        .task { hoveredCode = ProcessInfo.processInfo.environment["KEYCRAFT_HOVER"].flatMap { UInt16($0, radix: 16) } ?? hoveredCode }
        #endif
    }
}

/// Equal-width columns that fill the width, like an adaptive LazyVGrid but laid out eagerly:
/// a LazyVGrid inside a List section sometimes reserved its height and drew nothing (seen on Layers).
private struct ChipGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat = 6

    private func metrics(_ width: CGFloat, _ subviews: Subviews) -> (cols: Int, cell: CGFloat, height: CGFloat) {
        let cols = max(1, Int((width + spacing) / (minimum + spacing)))
        let cell = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
        return (cols, cell, height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum * 4 + spacing * 3
        let m = metrics(width, subviews)
        let rows = (subviews.count + m.cols - 1) / m.cols
        return CGSize(width: width, height: CGFloat(rows) * m.height + CGFloat(max(rows - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(bounds.width, subviews)
        for (i, view) in subviews.enumerated() {
            let origin = CGPoint(x: bounds.minX + CGFloat(i % m.cols) * (m.cell + spacing),
                                 y: bounds.minY + CGFloat(i / m.cols) * (m.height + spacing))
            view.place(at: origin, proposal: ProposedViewSize(width: m.cell, height: m.height))
        }
    }
}

/// A key in the picker, shown as a small keycap with its short label; its name and description appear on hover.
private struct KeycodeChip: View {
    let info: KeycodeInfo
    let isCurrent: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

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
        .onHover(perform: onHover)
        .help(info.description.isEmpty ? info.name : "\(info.name): \(info.description)")
        .accessibilityLabel(info.name)
        .accessibilityHint(info.description)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
