import KeycraftCore
import Observation
import SwiftUI

/// The keyboard library loads once, off the main thread, and is reloaded after the user imports a layout file.
@MainActor @Observable
final class LibraryProvider {
    enum UpdateStatus: Equatable { case idle, checking, upToDate, updated(Int), failed(String) }

    private(set) var library: KeyboardLibrary?
    /// Update results show in the Keyboard Library window only, never as alerts.
    private(set) var updateStatus = UpdateStatus.idle
    @ObservationIgnored private var task: Task<KeyboardLibrary, Never>?
    @ObservationIgnored private let updater = LibraryUpdater()
    var canUpdate: Bool { updater.isConfigured }

    init() { reload() }

    func get() async -> KeyboardLibrary {
        if let task { return await task.value }
        return await KeyboardLibrary.load()
    }

    func checkForUpdates() async {
        guard updater.isConfigured, updateStatus != .checking else { return }
        updateStatus = .checking
        let active = await get().builtAt
        do {
            switch try await updater.check(activeBuiltAt: active) {
            case .upToDate: updateStatus = .upToDate
            case .updated(let count, _):
                reload()
                updateStatus = .updated(count)
            }
        } catch {
            updateStatus = .failed(error.localizedDescription)
        }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "libraryLastUpdateCheck")
    }

    /// At most one automatic check a day, and only while "Check for keyboard updates automatically" is on.
    func checkAutomaticallyIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        let last = defaults.double(forKey: "libraryLastUpdateCheck")
        guard Date.now.timeIntervalSince1970 - last >= 24 * 3600 else { return }
        await checkForUpdates()
    }

    func reload() {
        let load = Task { await KeyboardLibrary.load() }
        task = load
        Task {
            let loaded = await load.value
            library = loaded
        }
    }
}

/// One connected (or demo) keyboard: its VIA client, definition and keymap.
@MainActor @Observable
final class KeyboardSession: Identifiable {
    enum Phase { case loading, ready, notSupported, noDefinition, failed(String) }

    /// A key whose assignment was changed this session (shown with an accent dot).
    struct ChangedKey: Hashable { let layer: Int; let position: Int }

    let info: HIDDeviceInfo
    let isDemo: Bool
    let client: VIAClient
    private let transport: any HIDTransport
    private let libraries: LibraryProvider

    nonisolated var id: String { info.id }
    var phase: Phase = .loading
    var definition: VIADefinition?
    var maker: String?
    var protocolVersion = 0
    var layerCount = 0
    var keymap: [[UInt16]] = []
    var layer = 0
    var selectedKey: Int?           // index into definition.keys
    var isBusy = false              // a write (or its backup prompt) is in flight
    var writeError: String?
    var retryCode: UInt16?          // the assignment that failed, for "Try Again"
    var saveCount = 0               // bumps after every successful write; drives "Saved to keyboard"
    var changed: Set<ChangedKey> = []
    var offerShare = false          // a layout file was just loaded for a keyboard the library doesn't have
    var pickerFocusRequest = 0      // bumps when Return/Space asks the inspector to take the search field
    /// Backup decision is per connection: once made (all saved, or Change Anyway) later writes don't re-prompt.
    var backupDecided = false
    private var loadStarted = false

    /// `unsupported`: the monitor already found that no interface answers VIA, so start in that state.
    init(info: HIDDeviceInfo, transport: any HIDTransport, isDemo: Bool, libraries: LibraryProvider, unsupported: Bool = false) {
        self.info = info
        self.transport = transport
        self.isDemo = isDemo
        self.libraries = libraries
        client = VIAClient(transport: transport)
        if unsupported { phase = .notSupported; loadStarted = true }
    }

    var displayName: String { isDemo ? "Demo Keyboard" : info.productName }
    var isReady: Bool { if case .ready = phase { true } else { false } }

    /// Sidebar subtitle: the state in words.
    var statusText: String {
        switch phase {
        case .ready: "Ready"
        case .loading: "Reading keymap…"
        case .notSupported: "Not supported"
        case .noDefinition: "Layout needed"
        case .failed: "Can't read keymap"
        }
    }

    func close() { transport.close() }

    func loadIfNeeded() async {
        guard !loadStarted else { return }
        loadStarted = true
        await load()
    }

    func load() async {
        phase = .loading
        do {
            do { protocolVersion = try await client.protocolVersion() } catch HIDError.timeout {
                phase = .notSupported   // no reply to the very first command: VIA isn't turned on in this firmware
                return
            }
            layerCount = try await client.layerCount()
            guard layerCount > 0 else { throw VIAError.unsupportedProtocol(protocolVersion) }
            let library = await libraries.get()
            maker = library.entry(vendorID: info.vendorID, productID: info.productID)?.maker
            guard let definition = library.definition(vendorID: info.vendorID, productID: info.productID) else {
                self.definition = nil
                phase = .noDefinition
                return
            }
            self.definition = definition
            keymap = try await client.readKeymap(layers: layerCount, rows: definition.rows, cols: definition.cols)
            layer = min(layer, layerCount - 1)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func importDefinition(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try VIADefinition.importFile(url)
            libraries.reload()
            offerShare = true
            await load()
        } catch {
            phase = .failed("That file isn't a valid layout file: \(error.localizedDescription)")
        }
    }
}

struct BackupWarning: Identifiable {
    let id = UUID()
    let missing: [BackupEntry]
    let vendorID: Int
    let productID: Int
    /// Every missing item is permanently unsupported, so "Don't warn again" makes sense.
    var canSuppress: Bool { BackupWarningPolicy.canOfferSuppression(missing: missing) }
}

@MainActor @Observable
final class DeviceStore {
    private(set) var sessions: [KeyboardSession] = []      // real keyboards
    let libraries = LibraryProvider()
    /// Nil when this build can't share (no GitHub configuration): every Share control is then hidden.
    let account = GitHubAccount()
    private(set) var demo: KeyboardSession
    var selectedID: String?
    var warning: BackupWarning?
    // Window-level state that menu commands and toolbar buttons share.
    var showBackups = false
    var showImporter = false
    var showSharing = false
    var showInspector = true

    let backupManager: BackupManager
    private let warningPolicy = BackupWarningPolicy()
    private let monitor = HIDDeviceMonitor()
    private var started = false
    private var warningContinuation: CheckedContinuation<Bool, Never>?

    var selected: KeyboardSession? {
        selectedID == demo.id ? demo : sessions.first { $0.id == selectedID }
    }

    /// `KEYCRAFT_BACKUP_DIR` redirects backups (used to test the UI without touching ~/Library).
    init() {
        let mock = MockVIADevice()
        demo = KeyboardSession(info: mock.info, transport: mock, isDemo: true, libraries: libraries)
        let override = ProcessInfo.processInfo.environment["KEYCRAFT_BACKUP_DIR"]
        backupManager = override.map { BackupManager(directory: URL(filePath: $0, directoryHint: .isDirectory)) } ?? BackupManager()
    }

    /// `KEYCRAFT_DEMO_ONLY=1` skips hardware detection entirely (screenshots / demos on a Mac with a real board attached).
    /// `KEYCRAFT_DEMO_KEYBOARD=VVVV:PPPP` (hex) makes the Demo Keyboard emulate that library entry and selects it.
    func start() {
        guard !started else { return }
        started = true
        let environment = ProcessInfo.processInfo.environment
        Task { await demo.loadIfNeeded() }   // so the sidebar says "Ready" rather than "Reading keymap…"
        if let spec = environment["KEYCRAFT_DEMO_KEYBOARD"] {
            Task { await emulateDemo(spec) }
        }
        guard environment["KEYCRAFT_DEMO_ONLY"] != "1" else { return }
        Task { await libraries.checkAutomaticallyIfDue() }
        monitor.start()
        Task {
            for await event in monitor.events { handle(event) }
        }
    }

    /// Only a layout file the user loaded for a keyboard the database doesn't have can be shared.
    func canShare(_ session: KeyboardSession) -> Bool {
        guard account != nil, !session.isDemo, session.isReady, let library = libraries.library else { return false }
        let (vid, pid) = (session.info.vendorID, session.info.productID)
        return library.entry(vendorID: vid, productID: pid)?.source == .imported && !library.databaseContains(vendorID: vid, productID: pid)
    }

    func selectDemo() {
        selectedID = demo.id
        Task { await demo.loadIfNeeded() }
    }

    private func emulateDemo(_ spec: String) async {
        let parts = spec.split(separator: ":").compactMap { Int($0, radix: 16) }
        guard parts.count == 2 else { return }
        let library = await libraries.get()
        if (parts[0], parts[1]) != (0x4335, 0x0002) {   // the default Demo Keyboard already is the GH60 Satan
            guard let definition = library.definition(vendorID: parts[0], productID: parts[1]) else { return }
            let mock = MockVIADevice(definition: definition)
            demo = KeyboardSession(info: mock.info, transport: mock, isDemo: true, libraries: libraries)
        }
        selectDemo()
    }

    private func handle(_ event: HIDDeviceEvent) {
        switch event {
        case .added(let info, let transport):
            add(KeyboardSession(info: info, transport: transport, isDemo: false, libraries: libraries))
        case .unsupported(let info, let transport):
            add(KeyboardSession(info: info, transport: transport, isDemo: false, libraries: libraries, unsupported: true))
        case .removed(let id):
            sessions.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        case .openFailed:
            break // e.g. another app has the interface seized; it will be retried when re-plugged
        }
    }

    private func add(_ session: KeyboardSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        if selectedID == nil || selectedID == demo.id { selectedID = session.id }
        Task { await session.loadIfNeeded() }   // so the sidebar shows a real status for every keyboard
    }

    // MARK: Writes (every write goes through the backup gate)

    /// Runs `operation` after the per-connection backup step. Returns true if it ran and succeeded.
    @discardableResult
    func performWrite(on session: KeyboardSession, _ operation: () async throws -> Void) async -> Bool {
        guard !session.isBusy, let definition = session.definition else { return false }
        session.isBusy = true
        defer { session.isBusy = false }
        session.writeError = nil
        session.retryCode = nil
        do {
            if !session.backupDecided {
                let items = session.client.backupItems(layers: session.layerCount, rows: definition.rows, cols: definition.cols)
                let outcome = try await backupManager.backUp(items: items, device: session.info) { [self] missing in
                    await askToProceed(missing, for: session)
                }
                guard outcome.proceed else { return false }   // Cancel: the write is never sent
                session.backupDecided = true
            }
            try await operation()
            return true
        } catch {
            session.writeError = error.localizedDescription
            return false
        }
    }

    func assign(_ code: UInt16, on session: KeyboardSession) async {
        guard let definition = session.definition, let index = session.selectedKey, definition.keys.indices.contains(index) else { return }
        let key = definition.keys[index]
        let layer = session.layer
        let ok = await performWrite(on: session) {
            try await session.client.setKeycode(layer: layer, row: key.row, col: key.col, keycode: code) // verifies by reading back
            session.keymap[layer][key.row * definition.cols + key.col] = code
        }
        if ok {
            session.changed.insert(.init(layer: layer, position: key.row * definition.cols + key.col))
            session.saveCount += 1
        } else if session.writeError != nil {
            session.retryCode = code
        }
    }

    func restoreKeymap(_ record: BackupRecord, on session: KeyboardSession) async -> Bool {
        guard let data = record.file.keymapData, let definition = session.definition else { return false }
        return await performWrite(on: session) {
            try await session.client.writeKeymapBytes([UInt8](data), layers: session.layerCount, rows: definition.rows, cols: definition.cols)
            session.keymap = try await session.client.readKeymap(layers: session.layerCount, rows: definition.rows, cols: definition.cols)
        }
    }

    /// "Back Up Now": always saves a file and never asks anything; returns the items that could not be saved.
    func backUpNow(_ session: KeyboardSession) async -> [BackupEntry]? {
        guard !session.isBusy, let definition = session.definition else { return nil }
        session.isBusy = true
        defer { session.isBusy = false }
        let items = session.client.backupItems(layers: session.layerCount, rows: definition.rows, cols: definition.cols)
        return try? await backupManager.backUp(items: items, device: session.info) { _ in true }.missing
    }

    private func askToProceed(_ missing: [BackupEntry], for session: KeyboardSession) async -> Bool {
        let (vid, pid) = (session.info.vendorID, session.info.productID)
        guard warningPolicy.shouldWarn(missing: missing, vendorID: vid, productID: pid) else { return true }
        return await withCheckedContinuation { continuation in
            warningContinuation = continuation
            warning = BackupWarning(missing: missing, vendorID: vid, productID: pid)
        }
    }

    func resolveWarning(proceed: Bool, suppress: Bool = false) {
        if proceed, suppress, let warning, warning.canSuppress {
            warningPolicy.suppress(vendorID: warning.vendorID, productID: warning.productID)
        }
        warning = nil
        warningContinuation?.resume(returning: proceed)
        warningContinuation = nil
    }
}
