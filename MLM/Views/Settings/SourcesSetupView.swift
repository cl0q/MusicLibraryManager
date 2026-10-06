import SwiftUI

/// Settings ▸ Sources (ST-SRC, DEC-004, DEC-037): the single place for accounts, the download
/// tools and the Qobuz access cookie. Accounts and tools belong to this Mac, so the tab works
/// without a library (connecting needs one: the account is linked to the library's sources).
///
/// Account states come from `SourceAccounts` — the one model Settings, the sidebar and the
/// import sheet read (§11.1 #9): `Connected` / `Disconnected` / `Sign-in expired`, each with the
/// one action that fits, in place.
struct SourcesSetupView: View {
    @Environment(\.container) private var container
    @State private var sources: SourcesViewModel?
    @State private var pendingDisconnect: TokenStorage.Service?
    @State private var connecting: Set<TokenStorage.Service> = []
    @State private var signInError: [TokenStorage.Service: String] = [:]
    @State private var credentialsFileFound = true

    private var accounts: SourceAccounts { .shared }
    private var tools: DownloadToolsModel { .shared }

    /// Sources with a sign-in in MLM, in the mockup's order.
    static let signInServices: [TokenStorage.Service] = [.soundcloud, .spotify]

    var body: some View {
        Form {
            accountsSection
            toolsSection
            QobuzCookieSection()
        }
        .formStyle(.grouped)
        .task(id: container.isInitialized) { await load() }
        .alert(
            "Disconnect \(pendingDisconnect?.displayName ?? "")?",
            isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
            presenting: pendingDisconnect
        ) { service in
            Button("Disconnect", role: .destructive) { Task { await disconnect(service) } }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
                .keyboardShortcut(.defaultAction)
        } message: { service in
            Text(Self.disconnectMessage(service))
        }
    }

    /// A-SET-DISCONNECT: applies to all libraries; says what stops (refreshing).
    static func disconnectMessage(_ service: TokenStorage.Service) -> String {
        "This removes the saved \(service.displayName) sign-in from this Mac, for all libraries. Linked playlists stay in your library but can’t be refreshed until you connect again."
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        Section {
            ForEach(Self.signInServices, id: \.self) { service in
                accountRow(service)
            }
            LabeledContent {
                EmptyView()
            } label: {
                HStack(spacing: Spacing.s) {
                    SourceBrandDot(source: "YouTube")
                    SettingsRowLabel("YouTube") {
                        Text("No sign-in in MLM · public playlists and links work without an account")
                    }
                }
            }
            LabeledContent {
                EmptyView()
            } label: {
                HStack(spacing: Spacing.s) {
                    SourceBrandDot(source: "Apple Music")
                    SettingsRowLabel("Apple Music") { Text("Not available yet") }
                }
            }
            .foregroundStyle(.secondary)
            if !credentialsFileFound {
                LabeledContent {
                    Button("Show Where It Goes") { SettingsRouter.shared.select(.advanced) }
                } label: {
                    SettingsRowLabel("") {
                        SettingsState(text: "Credentials file not found", systemImage: "exclamationmark.triangle", tone: .problem)
                        Text("SoundCloud and Spotify can’t be connected without it.")
                    }
                }
            }
        } header: {
            HStack {
                Text("Accounts")
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountRow(_ service: TokenStorage.Service) -> some View {
        let state = accounts.state(for: service)
        let isConnecting = connecting.contains(service)
        let lastRefreshed = sources?.lastSyncDate(for: service).map { SettingsDate.text($0) }
        return LabeledContent {
            HStack {
                switch state {
                case .connected, .notAvailable:
                    EmptyView()
                case .disconnected:
                    Button("Connect…") { connect(service) }
                        .disabled(!canConnect(service) || isConnecting)
                        .help(connectHelp(service))
                case .signInExpired, .keychainLocked:
                    Button("Reconnect") { connect(service) }
                        .disabled(!canConnect(service) || isConnecting)
                        .help(connectHelp(service))
                }
                if state != .disconnected {
                    Button("Disconnect…", role: .destructive) { pendingDisconnect = service }
                        .disabled(isConnecting)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                SourceBrandDot(source: service.displayName)
                SettingsRowLabel(service.displayName) {
                    if isConnecting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the sign-in in your browser…")
                        }
                    } else {
                        HStack(spacing: 4) {
                            SettingsState(text: state.word, systemImage: Self.symbol(state),
                                          tone: state.isConnected ? .ok : (state.needsSignIn ? .problem : .neutral))
                            let detail = SourceAccounts.detail(for: state, cause: accounts.expiredCause(for: service),
                                                               service: service, lastRefreshed: lastRefreshed)
                            if !detail.isEmpty { Text("· \(detail)") }
                        }
                        if let error = signInError[service] ?? sources?.error(for: service) {
                            Text("Couldn’t connect — \(error)")
                        }
                    }
                }
            }
        }
    }

    static func symbol(_ state: SourceAccountState) -> String? {
        switch state {
        case .connected: "checkmark.circle"
        case .disconnected, .notAvailable: nil
        case .signInExpired, .keychainLocked: "exclamationmark.triangle"
        }
    }

    private func canConnect(_ service: TokenStorage.Service) -> Bool {
        sources != nil && CredentialsLoader.hasCredentials(for: service)
    }

    private func connectHelp(_ service: TokenStorage.Service) -> String {
        if sources == nil { return "Open a library first — the account is linked to the library’s sources." }
        if !CredentialsLoader.hasCredentials(for: service) { return "The credentials file has no app keys for \(service.displayName)." }
        return ""
    }

    // MARK: - Download tools

    private var toolsSection: some View {
        Section {
            if tools.rows.isEmpty {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
            ForEach(tools.rows) { row in
                LabeledContent {
                    if row.isFound {
                        Text(row.neededFor).font(.caption).foregroundStyle(.secondary)
                    } else {
                        InstallHelpButton(row: row)
                    }
                } label: {
                    SettingsRowLabel(row.name) {
                        if row.isFound {
                            SettingsState(text: row.statusText, systemImage: "checkmark.circle", tone: .ok)
                                .textSelection(.enabled)
                        } else {
                            SettingsState(text: row.statusText, systemImage: "exclamationmark.triangle", tone: .problem)
                        }
                    }
                }
            }
            LabeledContent {
                Button("Check Again") { Task { await tools.check() } }
                    .disabled(tools.isChecking)
            } label: {
                Text(tools.checkedText ?? "").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Download tools")
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        credentialsFileFound = FileManager.default.fileExists(atPath: CredentialsLoader.envFilePath.path)
        if let storage = container.tokenStorage, let sourceRepository = container.sourceRepository {
            let model = sources ?? SourcesViewModel(
                tokenStorage: storage, sourceRepository: sourceRepository, oauthManager: container.oauthManager,
                trackRepository: container.trackRepository, playlistRepository: container.playlistRepository,
                tokenAccessStatus: container.tokenAccessStatus, tokenRefreshService: container.tokenRefreshService)
            sources = model
            await model.loadSources()
        } else {
            sources = nil
            await accounts.reload(using: TokenStorage())
        }
        await tools.check()
    }

    /// `Connect…` / `Reconnect`: the keychain once (Reconnect), then the browser sign-in; returns
    /// here (DEC-004).
    /// `Connect…` / `Reconnect` (review S1): a locked keychain item is read once with permission;
    /// a refused or expired sign-in and a new connection go straight to the browser sign-in, whose
    /// success clears the refusal (`signIn` → `didConnect`).
    private func connect(_ service: TokenStorage.Service) {
        guard let sources else { return }
        connecting.insert(service)
        Task {
            defer { connecting.remove(service) }
            switch ReconnectStep.step(for: accounts.state(for: service)) {
            case .allowKeychainAccess:
                if let storage = container.tokenStorage,
                   (try? storage.getCredentials(service: service, interactive: true)) != nil {
                    container.tokenAccessStatus?.markAccessible(service)
                    accounts.markKeychainReadable(service)
                    await container.tokenRefreshService?.clearBackoff(service: service)
                } else {
                    accounts.recordKeychainDenied(service)
                }
            case .browserSignIn:
                signInError[service] = nil
                do {
                    try await sources.signIn(service)
                } catch is CancellationError {
                } catch {
                    signInError[service] = error.localizedDescription
                }
            }
            await sources.loadSources()
        }
    }

    private func disconnect(_ service: TokenStorage.Service) async {
        pendingDisconnect = nil
        if let sources {
            await sources.disconnectSource(service)
        } else {
            do {
                try TokenStorage().deleteCredentials(service: service)
                accounts.didDisconnect(service)
            } catch {
                AppLogger.shared.error("Couldn’t remove the \(service.displayName) sign-in: \(error.localizedDescription)",
                                       source: "Sources")
            }
        }
    }
}

// MARK: - Qobuz access cookie (ST-SRC.E05–E11)

/// `Lossless downloads (Qobuz)`: the access cookie with its state, Save (never an empty value)
/// and `Clear…` (A-SET-COOKIECLEAR). A value in the credentials file takes precedence.
private struct QobuzCookieSection: View {
    @State private var cookie = ""
    @State private var savedAt: Date?
    @State private var confirmsClear = false
    @State private var expired = SquidWtfClient.isCookieExpired

    static let savedAtKey = "squid_cookie_saved_at"

    private var trimmed: String { cookie.trimmingCharacters(in: .whitespaces) }
    private var stored: String? { UserDefaults.standard.string(forKey: SquidWtfClient.userDefaultsKey) }
    private var setInCredentialsFile: Bool {
        ["MLM_SQUID_CAPTCHA", "MLM_SQUID_CF_COOKIE"].contains { !(CredentialsLoader.credential(key: $0) ?? "").isEmpty }
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    TextField("Access cookie", text: $cookie, prompt: Text("For example: 1779157770721"))
                        .labelsHidden()
                        .frame(width: 160)
                        .onSubmit(save)
                        // Review S8: the credentials file's value takes precedence; the field is
                        // read-only while it is set there.
                        .disabled(setInCredentialsFile)
                    Button("Save", action: save)
                        .disabled(setInCredentialsFile || trimmed.isEmpty || trimmed == stored)
                    Button("Clear…", role: .destructive) { confirmsClear = true }
                        .disabled(setInCredentialsFile || stored == nil)
                }
            } label: {
                SettingsRowLabel("Access cookie") { status }
            }
            DisclosureGroup("How to get the cookie") {
                Text("Open qobuz.squid.wtf, complete one download (this passes the captcha), then copy the value of the “captcha_verified_at” cookie from your browser’s developer tools and paste it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text("Lossless downloads (Qobuz)")
                Text("This Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .qobuzCookieStatusDidChange)) { _ in load() }
        .alert("Clear the Qobuz access cookie?", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive, action: clear)
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Lossless downloads are skipped until you paste a new one.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if setInCredentialsFile {
            HStack(spacing: 4) {
                SettingsState(text: "Active", systemImage: "checkmark.circle", tone: .ok)
                Text("· set in the credentials file, which takes precedence over this field")
            }
        } else if stored == nil {
            HStack(spacing: 4) {
                SettingsState(text: "Not configured")
                Text("· lossless downloads are skipped")
            }
        } else if expired {
            HStack(spacing: 4) {
                SettingsState(text: "Expired — renew", systemImage: "exclamationmark.triangle", tone: .problem)
                Text("· lossless downloads fall back to other sources")
            }
        } else {
            HStack(spacing: 4) {
                SettingsState(text: "Active", systemImage: "checkmark.circle", tone: .ok)
                if let savedAt {
                    Text("· saved \(savedAt.formatted(.relative(presentation: .named)))")
                }
            }
        }
    }

    private func load() {
        cookie = stored ?? ""
        savedAt = UserDefaults.standard.object(forKey: Self.savedAtKey) as? Date
        expired = SquidWtfClient.isCookieExpired
    }

    /// Return or `Save`; an empty value is never saved (ST-SRC.E06) — `Clear…` removes it.
    private func save() {
        guard !setInCredentialsFile, !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: SquidWtfClient.userDefaultsKey)
        SquidWtfClient.isCookieExpired = false
        let now = Date()
        UserDefaults.standard.set(now, forKey: Self.savedAtKey)
        AppLogger.shared.info("Squid: captcha_verified_at stored via Settings", source: "Download")
        load()
    }

    private func clear() {
        UserDefaults.standard.removeObject(forKey: SquidWtfClient.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.savedAtKey)
        SquidWtfClient.isCookieExpired = false
        AppLogger.shared.info("Squid: captcha_verified_at cleared via Settings", source: "Download")
        load()
    }
}
