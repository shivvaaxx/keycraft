import KeycraftCore
import SwiftUI

/// Window ▸ Keyboard Library: every keyboard Keycraft can draw, as cards showing each layout.
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
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                        ForEach(entries(library)) { LibraryCard(entry: $0, library: library) }
                    }
                    .padding([.horizontal, .bottom], 16)
                }
                .overlay {
                    if !query.isEmpty, entries(library).isEmpty { ContentUnavailableView.search(text: query) }
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
        .frame(minWidth: 480, idealWidth: 760, minHeight: 360, idealHeight: 620)
    }

    private func subtitle(_ library: KeyboardLibrary?) -> String {
        guard let library else { return "" }
        let count = "\(library.count.formatted()) keyboards"
        guard let built = library.builtAt else { return count }
        return "\(count) · Updated \(built.formatted(date: .abbreviated, time: .omitted))"
    }

    private func entries(_ library: KeyboardLibrary) -> [LibraryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? library.entries : library.entries.filter {
            [$0.name, $0.maker, $0.id].contains { $0.lowercased().contains(q) }
        }
        return hits.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

/// One keyboard as a card: its real layout drawn small, then name and USB ID.
private struct LibraryCard: View {
    let entry: LibraryEntry
    let library: KeyboardLibrary
    @State private var geometry: KeyboardGeometry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LayoutThumbnail(geometry: geometry)
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                // Only the exception gets a badge; "Built in" on all 2,000 cards would be noise.
                if entry.source == .imported {
                    Text("Added by you").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("A layout file you loaded yourself")
                }
            }
            HStack {
                Text(entry.maker.isEmpty ? "Other" : entry.maker).lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.id).monospaced()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .combine)
        .task(id: entry.id) {
            // Decoded only when the card scrolls into view; LazyVGrid keeps this to the visible few.
            geometry = library.definition(vendorID: entry.vendorID, productID: entry.productID).map { KeyboardGeometry(keys: $0.keys) }
        }
    }
}

/// Every cap as a rounded outline, rotated where the layout rotates it, scaled to fit.
private struct LayoutThumbnail: View {
    let geometry: KeyboardGeometry?

    var body: some View {
        Canvas { context, size in
            guard let geometry, !geometry.keys.isEmpty else { return }
            let b = geometry.bounds
            let unit = min(size.width / b.width, size.height / b.height)
            let origin = CGPoint(x: (size.width - b.width * unit) / 2, y: (size.height - b.height * unit) / 2)
            let gap = max(unit * 0.12, 0.8)
            for key in geometry.keys {
                let rect = CGRect(x: -key.w * unit / 2 + gap / 2, y: -key.h * unit / 2 + gap / 2,
                                  width: key.w * unit - gap, height: key.h * unit - gap)
                var cap = context
                cap.translateBy(x: origin.x + (key.center.x - b.minX) * unit, y: origin.y + (key.center.y - b.minY) * unit)
                cap.rotate(by: .degrees(key.angle))
                cap.fill(Path(roundedRect: rect, cornerRadius: unit * 0.15), with: .style(.secondary.opacity(0.55)))
            }
        }
        .accessibilityHidden(true)
    }
}
