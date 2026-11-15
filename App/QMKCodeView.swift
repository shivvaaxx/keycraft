import AppKit
import KeycraftCore
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Export as QMK Code: the current keymap as a keymap.c that compiles for this keyboard.
@MainActor enum QMKExport {
    static func save(_ session: KeyboardSession) {
        guard let definition = session.definition else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "keymap.c"
        panel.allowedContentTypes = [.cSource]
        panel.message = "Save this keymap as QMK code you can edit and build into firmware."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = QMKKeymap.exportC(keymap: session.keymap, rows: definition.rows, cols: definition.cols,
                                     keyboardName: definition.name, vendorID: definition.vendorID, productID: definition.productID,
                                     protocolVersion: session.protocolVersion)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}

/// Window ▸ QMK Code: open a keymap.c and see what it does, without writing anything to the keyboard.
struct QMKCodeView: View {
    @Environment(DeviceStore.self) private var store
    @State private var file: QMKKeymap.File?
    @State private var fileName = ""
    @State private var error: String?
    @State private var layerIndex = 0
    @State private var showImporter = false
    @State private var explanation: String?
    @State private var explaining = false
    @State private var explainError: String?

    var body: some View {
        Group {
            if let file {
                content(file)
            } else {
                ContentUnavailableView {
                    Label("Open a QMK Keymap", systemImage: "chevron.left.forwardslash.chevron.right")
                } description: {
                    Text(error ?? "Choose a keymap.c to see its layers on your keyboard and what its custom code does. Nothing is sent to the keyboard.")
                } actions: {
                    Button("Open…") { showImporter = true }.keyboardShortcut("o")
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .toolbar {
            if file != nil { Button("Open…", systemImage: "folder") { showImporter = true }.help("Open a different keymap.c") }
        }
        .navigationTitle(fileName.isEmpty ? "QMK Code" : fileName)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.cSource, .cHeader, .plainText]) { open($0) }
        .task {
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["KEYCRAFT_QMK_FILE"] { open(.success(URL(filePath: path))) }
            #endif
        }
    }

    private func open(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 512 * 1024 else { throw QMKKeymap.ParseError.tooLarge }
            let parsed = try QMKKeymap.parse(String(contentsOf: url, encoding: .utf8))
            (file, fileName, error, layerIndex, explanation, explainError) = (parsed, url.lastPathComponent, nil, 0, nil, nil)
        } catch {
            (file, self.error) = (nil, error.localizedDescription)
        }
    }

    // MARK: Content

    private func content(_ file: QMKKeymap.File) -> some View {
        let layer = file.layers[min(layerIndex, file.layers.count - 1)]
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if file.layers.count > 1 {
                    Picker("Layer", selection: $layerIndex) {
                        ForEach(file.layers.indices, id: \.self) { i in Text(title(file.layers[i])).tag(i) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                layerView(layer)
                customCode(file.customCode)
            }
            .padding(20)
        }
    }

    private func title(_ layer: QMKKeymap.Layer) -> String {
        let base = Keycode.layerName(layer.index)
        return layer.name.map { "\(base) (\($0))" } ?? base
    }

    @ViewBuilder private func layerView(_ layer: QMKKeymap.Layer) -> some View {
        let session = store.selected
        if let definition = session?.definition,
           let placed = QMKKeymap.placement(of: layer, rows: definition.rows, cols: definition.cols,
                                            keyOrder: definition.keys.map { ($0.row, $0.col) }) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledLayout(definition: definition) { key in
                    guard let k = placed.keys[key.row * definition.cols + key.col] else { return nil }
                    let info = k.code.map { Keycode.info($0, protocolVersion: VIAProtocol.keycodesV2) }
                    return (info?.label ?? k.text, info?.name ?? "\(k.text) (defined in this file's code)")
                }
                .frame(height: 260)
                Text(placed.isAssumed
                     ? "Shown on \(definition.name). Keys are placed in the order of \(layer.macro ?? "the layout"), which matches most keyboards; check a few keys before relying on it."
                     : "Shown on \(definition.name), using the keyboard's switch matrix.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(session?.definition == nil ? "Connect or pick a keyboard to see this layer drawn on it."
                     : "This layer doesn't match \(session?.definition?.name ?? "the keyboard")'s layout, so its keys are listed in file order.")
                    .font(.callout).foregroundStyle(.secondary)
                KeyList(keys: layer.rows.flatMap { $0 })
            }
        }
        let unknown = Array(Set(layer.rows.flatMap { $0 }.filter { $0.code == nil }.map(\.text))).sorted()
        if !unknown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Defined in This File").font(.headline)
                Text("These keys come from the file's own code, so they only work once it's built into firmware: \(unknown.joined(separator: ", "))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Custom code

    @ViewBuilder private func customCode(_ code: String) -> some View {
        let meaningful = code.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#include")
        }
        if meaningful {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom Code").font(.headline)
                Text("This part of the file changes how the keyboard behaves. It only takes effect when the file is built into firmware and flashed.")
                    .font(.callout).foregroundStyle(.secondary)
                let facts = QMKKeymap.behaviours(in: code)
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(facts, id: \.self) { Label($0, systemImage: "checkmark.circle").labelStyle(FactLabelStyle()) }
                    }
                }
                if let explanation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.plainMarkdown(explanation))
                            .textSelection(.enabled)
                        Label("Written by Apple Intelligence on this Mac. It can be wrong.", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if CodeExplainer.isAvailable {
                    HStack {
                        Button(explaining ? "Explaining…" : facts.isEmpty ? "Explain in Plain English" : "Explain the Rest") { explain(code, facts) }
                            .disabled(explaining)
                            .help("Ask Apple Intelligence, on this Mac, what the custom code does")
                        if explaining { ProgressView().controlSize(.small) }
                    }
                    if code.count > CodeExplainer.maxCharacters {
                        Text("The code is long, so only its first part is explained.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let reason = CodeExplainer.unavailableReason {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                if let explainError { Text(explainError).font(.callout).foregroundStyle(.red) }
                DisclosureGroup("Show Code") {
                    ScrollView(.horizontal) {
                        Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func explain(_ code: String, _ facts: [String]) {
        explaining = true
        explainError = nil
        Task {
            do { explanation = try await CodeExplainer.explain(code, knownFacts: facts) } catch { explainError = error.localizedDescription }
            explaining = false
        }
    }
}

extension QMKCodeView {
    /// Bold and italics from the model's markdown, but no links: nothing in generated text should be clickable.
    static func plainMarkdown(_ text: String) -> AttributedString {
        var a = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in a.runs where run.link != nil { a[run.range].link = nil }
        return a
    }
}

private struct FactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(.green)
            configuration.title
        }
    }
}

/// Keys in file order, for layers that can't be drawn on the current keyboard.
private struct KeyList: View {
    let keys: [QMKKeymap.Key]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                HStack(spacing: 6) {
                    Text(key.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    if let code = key.code {
                        Text(Keycode.info(code, protocolVersion: VIAProtocol.keycodesV2).name).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// A read-only keyboard drawing with a label per key; same geometry as the main canvas.
private struct LabeledLayout: View {
    let definition: VIADefinition
    /// Short label and full name for a key, or nil to leave it blank.
    let label: (PhysicalKey) -> (short: String, name: String)?

    var body: some View {
        GeometryReader { proxy in
            let geometry = KeyboardGeometry(keys: definition.keys)
            let unit = min(proxy.size.width / geometry.bounds.width, proxy.size.height / geometry.bounds.height, KeyboardGeometry.maxUnit)
            let gap = max(2, unit * 0.07)
            ZStack(alignment: .topLeading) {
                ForEach(definition.keys.indices, id: \.self) { i in
                    let key = definition.keys[i]
                    let text = label(key)
                    KeycapView(label: text?.short ?? "", isInherited: text?.short == "▽", isSelected: false, isChanged: false, unit: unit)
                        .frame(width: key.w * unit - gap, height: key.h * unit - gap)
                        .help(text?.name ?? "")
                        .accessibilityElement()
                        .accessibilityLabel(text?.name ?? "Blank")
                        .rotationEffect(.degrees(key.angle))
                        .position(x: geometry.centers[i].x * unit, y: geometry.centers[i].y * unit)
                }
            }
            .frame(width: geometry.bounds.width * unit, height: geometry.bounds.height * unit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
