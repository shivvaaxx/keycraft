import AppKit
import KeycraftCore
import SwiftUI

/// The GitHub sign-in shared by the Sharing sheet and Settings. The token itself lives only in the Keychain
/// (inside `GitHubSharing`); this keeps the signed-in state and the device-flow progress for the UI.
@MainActor @Observable
final class GitHubAccount {
    enum SignIn: Equatable { case idle, requesting, waiting(DeviceCode), failed(String) }

    let sharing: GitHubSharing
    private(set) var isSignedIn = false
    private(set) var login: String? = UserDefaults.standard.string(forKey: "githubLogin")
    private(set) var signIn = SignIn.idle
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Nil when this build has no GitHub configuration: sharing then has no sign-in option.
    init?() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var tokens: any GitHubTokenStore = KeychainTokenStore()
        #if DEBUG   // KEYCRAFT_GITHUB_SERVICE=<name>: a separate Keychain item, to see the signed-out sheet without signing out
        if let service = ProcessInfo.processInfo.environment["KEYCRAFT_GITHUB_SERVICE"] { tokens = KeychainTokenStore(service: service) }
        #endif
        guard let sharing = GitHubSharing(tokens: tokens, appVersion: version) else { return nil }
        self.sharing = sharing
    }

    /// Reads the Keychain; called when a view that needs the answer appears, not at launch.
    func refresh() {
        isSignedIn = sharing.isSignedIn
        if isSignedIn, login == nil { Task { await fetchLogin() } }
    }

    private func fetchLogin() async {
        guard let name = try? await sharing.login() else { return }
        login = name
        UserDefaults.standard.set(name, forKey: "githubLogin")
    }

    func startSignIn() {
        task?.cancel()
        signIn = .requesting
        task = Task {
            do {
                let code = try await sharing.requestDeviceCode()
                signIn = .waiting(code)
                try await sharing.completeSignIn(code)
                // Leave .waiting before the sign-in view disappears: its onDisappear cancels a sign-in still waiting,
                // which used to cancel the account-name fetch below.
                signIn = .idle
                isSignedIn = true
                await fetchLogin()
            } catch {
                signIn = Task.isCancelled || error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        task?.cancel()
        signIn = .idle
    }

    func signOut() {
        cancelSignIn()
        sharing.signOut()
        UserDefaults.standard.removeObject(forKey: "githubLogin")
        isSignedIn = false
        login = nil
    }
}

/// "Sign In with GitHub" and, once started, the code to type on github.com.
struct GitHubSignInView: View {
    let account: GitHubAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch account.signIn {
            case .idle, .failed:
                Text("Sign in to have the pull request opened under your GitHub name. You approve access on github.com, so Keycraft never sees your password.")
                    .foregroundStyle(.secondary)
                if case .failed(let message) = account.signIn {
                    Text(message).foregroundStyle(.red)
                }
                Button("Sign In with GitHub") { account.startSignIn() }
                    .help("Get a code to approve on github.com")
            case .requesting:
                ProgressView("Contacting GitHub…")
            case .waiting(let code):
                Text("Enter this code on GitHub").foregroundStyle(.secondary)
                Text(code.userCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    // No .textSelection here: selectable Text plus a custom accessibilityLabel recurses in SwiftUI's
                    // accessibility code until the stack overflows (crashed with VoiceOver/AX queries). Copy Code covers copying.
                    .accessibilityLabel("Code \(code.userCode.map(String.init).joined(separator: " "))")
                HStack {
                    Button("Copy Code", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                    }
                    .help("Copy the code so you can paste it on GitHub")
                    Button("Open GitHub", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(code.verificationURL) }
                        .help("Open github.com/login/device in your browser")
                    Button("Cancel") { account.cancelSignIn() }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve on GitHub…").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { if case .waiting = account.signIn { account.cancelSignIn() } }
    }
}

/// The sheet behind File ▸ Share Keyboard Layout…: what will be shared, then send. Signed in to GitHub, the pull request
/// is the user's own; otherwise it goes through thistleware.com and its bot opens it.
struct SharingSheet: View {
    let session: KeyboardSession
    let account: GitHubAccount?
    let anonymous: AnonymousSharing?
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable { case form, sharing(String), shared(URL, alreadyShared: Bool), failed(String) }
    @State private var stage = Stage.form
    @State private var name = ""
    @State private var maker = ""
    @State private var showSignIn = false

    private var signedIn: Bool { account?.isSignedIn ?? false }

    private var raw: Data? { store.libraries.library?.rawDefinition(vendorID: session.info.vendorID, productID: session.info.productID) }
    private var submission: Result<Submission, SharingError> {
        guard let raw else { return .failure(.invalid(["Keycraft can't find this layout file."])) }
        do { return .success(try GitHubSharing.prepare(definition: raw, name: name, maker: maker)) }
        catch { return .failure(error as? SharingError ?? .invalid([error.localizedDescription])) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share Keyboard Layout").font(.title2.bold())
            switch stage {
            case .form: form
            case .sharing(let text):
                ProgressView(text).frame(maxWidth: .infinity, minHeight: 120)
            case .shared(let url, let alreadyShared):
                VStack(alignment: .leading, spacing: 10) {
                    if alreadyShared {
                        Label("Someone already shared this keyboard. Their layout is waiting for review.", systemImage: "clock")
                    } else {
                        Label("Shared. Maintainers will review it.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Link("View Pull Request", destination: url).help("Open the pull request on GitHub")
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            case .failed(let message):
                Text(message).foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            }
            HStack {
                Spacer()
                switch stage {
                case .shared:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { stage = .form }.keyboardShortcut(.defaultAction)
                case .sharing:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                case .form:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if signedIn || anonymous != nil {
                        Button("Share") { share() }
                            .keyboardShortcut(.defaultAction)
                            .disabled({ if case .failure = submission { true } else { false } }())
                            .help("Send this layout to the Keycraft library for review")
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            account?.refresh()
            name = session.definition?.name ?? session.displayName
            maker = session.maker ?? ""
        }
    }

    @ViewBuilder private var form: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Maker", text: $maker, prompt: Text("For example, Keychron"))
            LabeledContent("USB ID") { Text(session.info.vidPid).monospaced() }
            LabeledContent("Keys", value: (session.definition?.keys.count ?? 0).formatted())
            if let definition = session.definition {
                LayoutPreview(definition: definition).frame(height: 90)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        if case .failure(let error) = submission {
            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
        }
        if let account, account.isSignedIn {
            Text("Only the layout file is shared — nothing about your keymap or this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Label("Signed in to GitHub" + (account.login.map { " as \($0)" } ?? ""), systemImage: "person.crop.circle.badge.checkmark")
                .font(.callout).foregroundStyle(.secondary)
        } else if anonymous != nil {
            Text("Only the layout file is shared — nothing about your keymap. It goes through thistleware.com, which keeps a one-way hash of your IP address for an hour to limit spam.")
                .font(.callout).foregroundStyle(.secondary)
            if let account {
                DisclosureGroup("Get credit on GitHub (optional)", isExpanded: $showSignIn) {
                    GitHubSignInView(account: account).padding(.top, 6)
                }
                .font(.callout)
            }
        } else if let account {
            Text("Only the layout file is shared — nothing about your keymap or this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            GitHubSignInView(account: account)
        }
    }

    private func share() {
        guard case .success(let submission) = submission else { return }
        stage = .sharing("Creating pull request…")
        Task {
            do {
                if let account, account.isSignedIn {
                    let url = try await account.sharing.share(submission) { text in Task { @MainActor in if case .sharing = stage { stage = .sharing(text) } } }
                    stage = .shared(url, alreadyShared: false)
                } else if let anonymous {
                    let shared = try await anonymous.share(submission)
                    stage = .shared(shared.url, alreadyShared: shared.alreadyShared)
                }
            } catch {
                account?.refresh()   // a rejected token signs the user out
                stage = .failed(error.localizedDescription)
            }
        }
    }
}

/// A flat outline of the keys, just enough to confirm "yes, that's my keyboard".
private struct LayoutPreview: View {
    let definition: VIADefinition

    var body: some View {
        Canvas { context, size in
            let bounds = definition.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let origin = CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                 y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            for key in definition.keys {
                var path = Path()
                let corners = key.corners.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
                path.addLines(corners)
                path.closeSubpath()
                context.fill(path, with: .color(.secondary.opacity(0.25)))
                context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 0.5)
            }
        }
    }
}

/// Offered above the canvas right after the user loads a layout file for a keyboard the library doesn't have.
struct ShareBanner: View {
    let session: KeyboardSession
    @Environment(DeviceStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            Text("Share this layout with the Keycraft library?")
            Spacer()
            Button("Share…") { store.showSharing = true }
                .help("Send this layout to the Keycraft library for review")
            Button("Not Now") { session.offerShare = false }
                .help("Hide this message")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
