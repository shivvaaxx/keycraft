#if PAID_BUILD
import KeycraftCore
import SwiftUI

/// The stored, verified licence. Nil means the app shows the activation screen.
@Observable @MainActor final class LicenceState {
    private static let defaultsKey = "licenceKey"
    private(set) var license: License?

    init() {
        license = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap { try? Licensing.verify($0) }
    }

    func activate(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        license = try Licensing.verify(trimmed)
        UserDefaults.standard.set(trimmed, forKey: Self.defaultsKey)
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        license = nil
    }
}

struct ActivationView: View {
    @Environment(LicenceState.self) private var licence
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Activate Keycraft").font(.title.bold())
            Text("Paste the licence key from your purchase.").foregroundStyle(.secondary)
            TextEditor(text: $key)
                .font(.system(.body, design: .monospaced))
                .frame(width: 380, height: 66)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Licence key")
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button("Activate", action: activate)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            HStack(spacing: 16) {
                Link("Buy Keycraft", destination: URL(string: "https://thistleware.com/keycraft/")!)
                Link("Lost your key?", destination: URL(string: "mailto:hello@thistleware.com")!)
            }
            .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activate() {
        do { try licence.activate(key); error = nil } catch LicenseError.wrongProduct {
            error = "That key is for a different app."
        } catch {
            self.error = "That key isn't valid. Copy the whole key, starting with KC1."
        }
    }
}
#endif
