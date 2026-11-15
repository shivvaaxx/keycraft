import KeycraftCore
import SwiftUI

/// Window ▸ Keyboard Library: every keyboard Keycraft can draw, grouped by maker.
struct LibraryWindowView: View {
    @Environment(DeviceStore.self) private var store
    @State private var query = ""

    var body: some View {
        let library = store.libraries.library
        VStack(spacing: 0) {
            if let library {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(subtitle(library)).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if store.libraries.canUpdate {
                            Button("Check for Updates") { Task { await store.libraries.checkForUpdates() } }
                                .disabled(store.libraries.updateStatus == .checking)
                                .help("Look for keyboards added to the Keycraft library since this version")
                        }
                    }
                    UpdateStatusLine(status: store.libraries.updateStatus)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 16).padding(.bottom, 8)
                List {
                    ForEach(groups(library)) { group in
                        Section(group.maker) {
                            ForEach(group.entries) { LibraryRow(entry: $0) }
                        }
                    }
                }
                .overlay {
                    if !query.isEmpty, groups(library).isEmpty { ContentUnavailableView.search(text: query) }
                }
            } else {
                ProgressView("Loading keyboards…").frame(maxHeight: .infinity)
            }
            Divider()
            Text("If your keyboard isn't listed, load its VIA layout file from the File menu.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .navigationTitle("Keyboard Library")
        .frame(minWidth: 480, minHeight: 360)
    }

    private func subtitle(_ library: KeyboardLibrary?) -> String {
        guard let library else { return "" }
        let count = "\(library.count.formatted()) keyboards"
        guard let built = library.builtAt else { return count }
        return "\(count) · Updated \(built.formatted(date: .abbreviated, time: .omitted))"
    }

    private struct Group: Identifiable { let maker: String; let entries: [LibraryEntry]; var id: String { maker } }

    private func groups(_ library: KeyboardLibrary) -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? library.entries : library.entries.filter {
            [$0.name, $0.maker, $0.id].contains { $0.lowercased().contains(q) }
        }
        return Dictionary(grouping: hits) { $0.maker.isEmpty ? "Other" : $0.maker }
            .map { Group(maker: $0.key, entries: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.maker.localizedCaseInsensitiveCompare($1.maker) == .orderedAscending }
    }
}

private struct UpdateStatusLine: View {
    let status: LibraryProvider.UpdateStatus

    var body: some View {
        switch status {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for new keyboards…").foregroundStyle(.secondary) }.font(.callout)
        case .upToDate:
            Text("The keyboard library is up to date.").font(.callout).foregroundStyle(.secondary)
        case .updated(let count):
            Text("Updated. The library now has \(count.formatted()) keyboards.").font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Label("Couldn't check for updates. \(message)", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
        }
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack {
            Text(entry.name)
            Spacer()
            Text(entry.id).font(.callout.monospaced()).foregroundStyle(.secondary)
            // Only the exception gets a badge; "Built in"/"Updated" on all 2,000 rows was noise.
            if entry.source == .imported {
                Text("Added by you")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("A layout file you loaded yourself")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
