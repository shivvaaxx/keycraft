import KeycraftCore
import SwiftUI

struct BackupsView: View {
    let session: KeyboardSession
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var records: [BackupRecord] = []
    @State private var selection: BackupRecord.ID?
    @State private var status: String?
    @State private var confirming: BackupRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backups — \(session.displayName)").font(.title3.bold())
                Text("Keycraft backs up your keyboard automatically before its first change each time you connect it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if records.isEmpty {
                ContentUnavailableView("No Backups Yet", systemImage: "tray",
                                       description: Text("Choose Back Up Now, or make a change. Keycraft saves one first."))
                    .frame(maxHeight: .infinity)
            } else {
                List(records, selection: $selection) { record in
                    BackupRow(record: record).tag(record.id)
                }
            }
            if let status {
                Divider()
                Text(status).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Back Up Now") { backUp() }
                    .disabled(session.isBusy)
                    .help("Save the keymap and macros from the keyboard right now")
                Button("Restore Keymap") { confirming = selectedRecord }
                    .disabled(selectedRecord.map { !canRestore($0) } ?? true)
                    .help("Replace the keymap on the keyboard with the selected backup")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selectedRecord?.url ?? store.backupManager.directory]) }
                    .help("Reveal the backup files on this Mac")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 440)
        .onAppear(perform: reload)
        .backupAlert()
        .alert("Restore keymap from \(confirming.map(dateText) ?? "")?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { record in
            Button("Cancel", role: .cancel) {}
            Button("Restore") { restore(record) }
        } message: { _ in
            Text("This replaces the keymap on \(session.displayName).")
        }
    }

    private var selectedRecord: BackupRecord? { records.first { $0.id == selection } }

    private func reload() { records = store.backupManager.list(device: session.info) }

    private func canRestore(_ record: BackupRecord) -> Bool {
        guard record.file.keymapData != nil, !session.isBusy else { return false }
        return session.isReady
    }

    private func backUp() {
        Task {
            guard let missing = await store.backUpNow(session) else { status = "Couldn't back up this keyboard."; return }
            status = missing.isEmpty ? "Backed up." : "Backed up. Not included: \(missing.map(\.name).joined(separator: ", "))."
            reload()
        }
    }

    private func restore(_ record: BackupRecord) {
        status = "Restoring…"
        Task {
            let ok = await store.restoreKeymap(record, on: session)
            status = ok ? "Keymap restored and checked against the keyboard."
                        : (session.writeError ?? "Restore cancelled. Nothing was changed.")
            reload()
        }
    }

    private func dateText(_ record: BackupRecord) -> String {
        guard let date = ISO8601DateFormatter().date(from: record.file.createdAt) else { return record.file.createdAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct BackupRow: View {
    let record: BackupRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date.map { $0.formatted(.relative(presentation: .named)).capitalized } ?? record.file.createdAt).font(.headline)
                Text(date?.formatted(date: .abbreviated, time: .standard) ?? "").font(.caption).foregroundStyle(.secondary)
                Text(contents).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if record.file.proceededWithoutFullBackup {
                Label("Incomplete", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
                    .help("This backup was made while some items couldn't be saved")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var date: Date? { try? Date(record.file.createdAt, strategy: .iso8601) }

    private var contents: String {
        let saved = record.file.items.filter { $0.status == .saved }.map { $0.id == "keymap" ? "Keymap" : $0.name }
        return saved.isEmpty ? "Nothing saved" : saved.joined(separator: ", ")
    }
}
