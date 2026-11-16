import SwiftUI

/// Settings (⌘,): only what people might want to change. Panes have a fixed toolbar.
struct SettingsView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            BackupsSettingsPane()
                .tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }
            if let account = store.account {
                SharingSettingsPane(account: account)
                    .tabItem { Label("Sharing", systemImage: "square.and.arrow.up") }
            }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(DeviceStore.self) private var store
    @AppStorage("showDemoKeyboard") private var showDemo = true
    @AppStorage("checkForUpdates") private var checkForUpdates = true

    var body: some View {
        Form {
            Section {
                Toggle("Show Demo Keyboard in sidebar", isOn: $showDemo)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Keep a built-in keyboard in the sidebar for trying things out")
            } footer: {
                Text("The Demo Keyboard works without any hardware. Changes to it never leave this Mac.")
            }
            if store.libraries.canUpdate {
                Section {
                    Toggle("Check for keyboard updates automatically", isOn: $checkForUpdates)
                        .toggleStyle(.switch).controlSize(.mini)
                        .help("Look once a day for keyboards added to the Keycraft library")
                } footer: {
                    Text("Keycraft checks once a day for newly added keyboards.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BackupsSettingsPane: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(store.backupManager.directory.path(percentEncoded: false))
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Show in Finder") {
                    let folder = store.backupManager.directory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                .help("Open the folder that holds your keyboard backups")
            } footer: {
                Text("Keycraft backs up your keyboard automatically before its first change each time you connect it.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SharingSettingsPane: View {
    let account: GitHubAccount

    var body: some View {
        Form {
            Section {
                if account.isSignedIn {
                    LabeledContent("GitHub account", value: account.login ?? "Signed in")
                    Button("Sign Out") { account.signOut() }
                        .help("Forget this GitHub sign-in on this Mac")
                } else {
                    GitHubSignInView(account: account)
                }
            } footer: {
                Text("Optional. Layouts you share while signed in are sent under your GitHub name; without it they are shared anonymously.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { account.refresh() }
    }
}
