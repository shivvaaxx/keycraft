import Foundation

/// Every build-time constant in one place. A nil value turns the feature that needs it off (and hides its controls).
public enum KeycraftConfig {
    /// Where the keyboard library is published: `<base>/manifest.json` points at the data file.
    public static let libraryBaseURL: URL? = URL(string: "https://github.com/shivvaaxx/keycraft-keyboards/releases/download/db-latest")
    /// The GitHub repo new keyboards are shared to (by pull request).
    public static let databaseRepo: (owner: String, name: String)? = (owner: "shivvaaxx", name: "keycraft-keyboards")
    /// Where layouts are shared without a GitHub account (Thistleware's Pages Function opens the pull request).
    public static let shareEndpoint: URL? = URL(string: "https://thistleware.com/api/share-layout")
    /// Public client ID of Keycraft's GitHub OAuth App (device flow). There is deliberately no client secret.
    public static let githubClientID: String? = "Ov23li0k38TEcp6DAb59"
    /// Donation pages (Help menu, README, the repos' Sponsor button).
    public static let koFiURL = URL(string: "https://ko-fi.com/shivvaaxx")!
    public static let githubSponsorsURL = URL(string: "https://github.com/sponsors/shivvaaxx")!
}
