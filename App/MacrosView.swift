import KeycraftCore
import SwiftUI

/// Edit the keyboard's macros: record key presses (captured only, never acted on by the Mac), add text and
/// waits, then save them all to the keyboard.
struct MacrosView: View {
    let session: KeyboardSession
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [[MacroStep]] = []
    @State private var selection = 0
    @State private var saved = false
    private let recorder = MacroRecorder.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Macros — \(session.displayName)").font(.title3.bold())
                Text("A macro plays a set of key presses when you press its key. To use one, pick a key and choose it under Macros in Key Details.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                List(draft.indices, id: \.self, selection: Binding(get: { selection }, set: { if let s = $0 { selection = s } })) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Macro \(i)")
                        Text(Macros.summary(draft[i])).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(i)
                }
                .frame(width: 210)
                .disabled(recorder.isRecording)
                Divider()
                if draft.indices.contains(selection) {
                    MacroEditor(steps: $draft[selection], index: selection, recorder: recorder)
                        .id(selection)
                }
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .onAppear { draft = session.macros ?? [] }
        .onDisappear { recorder.stop() }
        .backupAlert()
    }

    private var bytesUsed: Int { Macros.encode(draft).count }
    private var limit: Int { max(session.macroBufferSize - 1, 0) }
    private var hasChanges: Bool { draft != session.macros }

    private var footer: some View {
        HStack {
            // Each macro also takes one separator byte, so that's left out of both numbers.
            Text("\(bytesUsed - draft.count) of \(limit - draft.count) bytes used")
                .font(.callout).monospacedDigit()
                .foregroundStyle(bytesUsed > limit ? .red : .secondary)
            if let error = session.writeError { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
            else if saved && !hasChanges { Label("Saved to keyboard", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
            Spacer()
            Button("Revert") { draft = session.macros ?? [] }
                .disabled(!hasChanges || recorder.isRecording)
            Button(hasChanges ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save to Keyboard") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || bytesUsed > limit || session.isBusy || recorder.isRecording)
        }
        .padding(12)
    }

    private func save() {
        let macros = draft
        Task { saved = await store.saveMacros(macros, on: session) }
    }
}

/// One macro's steps, the recorder and the add buttons.
private struct MacroEditor: View {
    @Binding var steps: [MacroStep]
    let index: Int
    let recorder: MacroRecorder
    @State private var permitted = MacroRecorder.hasPermission
    @State private var tapFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Macro \(index)").font(.headline)
                Spacer()
                Group {
                    Button("Add Text", systemImage: "textformat") { steps.append(.text("")) }
                        .help("Type text, as if on a US keyboard layout")
                    Button("Add Wait", systemImage: "timer") { steps.append(.delay(100)) }
                        .help("Pause before the next step, e.g. while a window opens")
                }
                .disabled(recorder.isRecording)
                Button("Clear", role: .destructive) { steps = [] }
                    .disabled(steps.isEmpty || recorder.isRecording)
            }
            recordArea
            if recorder.isRecording {
                StepList(steps: .constant(recorder.preview), editable: false)
            } else if steps.isEmpty {
                ContentUnavailableView("No Steps", systemImage: "keyboard",
                                       description: Text("Record key presses, or add text and waits."))
                    .frame(maxHeight: .infinity)
            } else {
                StepList(steps: $steps, editable: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permitted = MacroRecorder.hasPermission
        }
    }

    @ViewBuilder private var recordArea: some View {
        if recorder.isRecording {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording").font(.headline)
                    Text("Press the keys for this macro. Until you stop, they go only into the macro and do nothing on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { recorder.stop() }.controlSize(.large)
            }
            .padding(12)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if !permitted {
            VStack(alignment: .leading, spacing: 8) {
                Text("To record, Keycraft needs Accessibility permission. It uses it only while recording, to keep your key presses from reaching other apps.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Allow in System Settings…") { MacroRecorder.requestPermission() }
                    Button("Check Again") { permitted = MacroRecorder.hasPermission }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Record", systemImage: "record.circle") { record() }
                        .help("Capture key presses into this macro; they won't act on your Mac while recording")
                    Text("New presses are added to the end.").font(.callout).foregroundStyle(.secondary)
                }
                if MacroRecorder.secureInputIsOn {
                    Label("A password field in another app is blocking key capture. Close it or switch away from it first.",
                          systemImage: "lock.fill").font(.callout).foregroundStyle(.orange)
                }
                if tapFailed {
                    Text("Recording couldn't start. Check Keycraft is allowed in System Settings ▸ Privacy & Security ▸ Accessibility.")
                        .font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    private func record() {
        tapFailed = !recorder.start { recorded in steps = Macros.simplify(steps + recorded) }
    }
}

/// The steps as rows. Text and wait steps can be edited in place; any step can be moved or removed.
private struct StepList: View {
    @Binding var steps: [MacroStep]
    let editable: Bool

    var body: some View {
        List {
            ForEach(steps.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    Image(systemName: icon(steps[i])).foregroundStyle(.secondary).frame(width: 18)
                    content(i)
                    Spacer()
                    if editable {
                        Button("Remove", systemImage: "minus.circle") { steps.remove(at: i) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
            .onMove { if editable { steps.move(fromOffsets: $0, toOffset: $1) } }
        }
        .listStyle(.bordered)
    }

    private func icon(_ step: MacroStep) -> String {
        switch step {
        case .text: "textformat"
        case .tap: "keyboard"
        case .down: "arrow.down.to.line"
        case .up: "arrow.up.to.line"
        case .delay: "timer"
        }
    }

    @ViewBuilder private func content(_ i: Int) -> some View {
        switch steps[i] {
        case .text(let s):
            if editable {
                TextField("Text to type", text: Binding(get: { s }, set: { steps[i] = .text(String($0.unicodeScalars.filter(Macros.isTypeable))) }))
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("Type “\(s)”")
            }
        case .tap(let kc): Text("Press \(Keycode.info(UInt16(kc)).name)")
        case .down(let kc): Text("Hold \(Keycode.info(UInt16(kc)).name)")
        case .up(let kc): Text("Release \(Keycode.info(UInt16(kc)).name)")
        case .delay(let ms):
            if editable {
                HStack {
                    Text("Wait")
                    TextField("ms", value: Binding(get: { ms }, set: { steps[i] = .delay(min(max($0, 0), 60_000)) }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("ms")
                }
            } else {
                Text("Wait \(ms) ms")
            }
        }
    }
}
