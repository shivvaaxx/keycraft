import KeycraftCore
import SwiftUI

/// The system alert shown when something important couldn't be backed up. Cancel is the default (Return);
/// "Don't warn again" appears only when every missing item is permanently unsupported.
/// `isActive` lets exactly one host present it, since a window can't show an alert over its own sheet.
struct BackupAlert: ViewModifier {
    @Environment(DeviceStore.self) private var store
    let isActive: Bool
    @State private var suppress = false

    // The alert hangs off an invisible background view: switching between the two branches below would otherwise
    // give the wrapped content a new identity, resetting its state (and re-running onAppear) mid-write.
    func body(content: Content) -> some View {
        content.background { host }
    }

    @ViewBuilder private var host: some View {
        let shown = Binding(
            get: { store.warning != nil && isActive },
            set: { if !$0, isActive, store.warning != nil { store.resolveWarning(proceed: false) } })
        let alerting = Color.clear
            .alert("Unable to back up", isPresented: shown, presenting: store.warning) { _ in
                Button("Change Anyway", role: .destructive) { store.resolveWarning(proceed: true, suppress: suppress) }
                Button("Cancel", role: .cancel) { store.resolveWarning(proceed: false) }
                    .keyboardShortcut(.defaultAction)   // Return = Cancel
            } message: { warning in
                Text(message(for: warning))
            }
            .onChange(of: store.warning?.id) { suppress = false }
        if store.warning?.canSuppress == true {
            alerting.dialogSuppressionToggle("Don't warn again for this keyboard", isSuppressed: $suppress)
        } else {
            alerting
        }
    }

    private func message(for warning: BackupWarning) -> String {
        let lines = warning.missing.map { "• \($0.name): \($0.reason ?? "couldn't be saved")" }
        return lines.joined(separator: "\n") + "\n\nIf something goes wrong, these can't be restored."
    }
}

extension View {
    func backupAlert(isActive: Bool = true) -> some View { modifier(BackupAlert(isActive: isActive)) }
}
