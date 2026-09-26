import SwiftUI

/// Settings tab for source-pipeline credentials that don't fit in
/// Keychain-backed OAuth flows.
///
/// Currently hosts the Squid.wtf `captcha_verified_at` cookie. The
/// cookie is persisted in UserDefaults so users don't have to paste it
/// in on every launch. Empty value clears the entry.
struct SourcesSetupView: View {
    @Environment(\.container) private var container
    @State private var squidCookie: String = ""
    @State private var savedAt: Date?
    @State private var pendingDisconnect: TokenStorage.Service?
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        Form {
            Section("Connected sources") {
                sourceRow("SoundCloud", service: .soundcloud)
                sourceRow("Spotify", service: .spotify)
                sourceRow("Apple Music", service: .appleMusic)
                sourceRow("YouTube", service: nil)
            }

            Section("Squid.wtf (Qobuz Mirror)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("captcha_verified_at Cookie")
                        .font(MLMFont.sectionLabel)
                        .foregroundColor(.mlmInkSecondary)
                    TextField(
                        "For example: 1779157770721",
                        text: $squidCookie
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    Text("Open qobuz.squid.wtf, complete one download (this passes the captcha), then copy the value of the 'captcha_verified_at' cookie from your browser's developer tools and paste it here.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // Cookie Status Indicator
                    HStack(spacing: 6) {
                        if SquidWtfClient.captchaCookie == nil {
                            Label("Not configured", systemImage: "xmark.circle.fill")
                                .font(MLMFont.muted)
                                .foregroundColor(.red)
                        } else if SquidWtfClient.isCookieExpired {
                            Label("Expired — renew", systemImage: "exclamationmark.triangle.fill")
                                .font(MLMFont.muted)
                                .foregroundColor(.orange)
                        } else {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(MLMFont.muted)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 2)
                    
                    HStack(spacing: 8) {
                        Button("Save") { save() }
                            .disabled(squidCookie.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Clear", role: .destructive) {
                            squidCookie = ""
                            save()
                        }
                        if let savedAt {
                            Text("Saved \(Self.relative(savedAt))")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            squidCookie = UserDefaults.standard.string(forKey: SquidWtfClient.userDefaultsKey) ?? ""
            savedAt = UserDefaults.standard.object(forKey: "squid_cookie_saved_at") as? Date
        }
        .onReceive(NotificationCenter.default.publisher(for: .qobuzCookieStatusDidChange)) { _ in
            squidCookie = UserDefaults.standard.string(forKey: SquidWtfClient.userDefaultsKey) ?? ""
        }
        .alert(
            "Disconnect \(pendingDisconnect?.displayName ?? "source")?",
            isPresented: $showingDisconnectConfirmation,
            presenting: pendingDisconnect
        ) { service in
            Button("Disconnect", role: .destructive) {
                disconnect(service)
            }
            Button("Cancel", role: .cancel) {
                pendingDisconnect = nil
            }
        } message: { service in
            Text("This removes the saved \(service.displayName) credentials from this Mac. Syncing will stop until you reconnect.")
        }
    }

    private func save() {
        let trimmed = squidCookie.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: SquidWtfClient.userDefaultsKey)
            SquidWtfClient.isCookieExpired = false
        } else {
            UserDefaults.standard.set(trimmed, forKey: SquidWtfClient.userDefaultsKey)
            SquidWtfClient.isCookieExpired = false // Clear expired status
        }
        savedAt = Date()
        UserDefaults.standard.set(savedAt, forKey: "squid_cookie_saved_at")
        AppLogger.shared.info(
            "Squid: captcha_verified_at \(trimmed.isEmpty ? "cleared" : "stored") via Settings",
            source: "Download"
        )
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func sourceRow(_ name: String, service: TokenStorage.Service?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(connectionStatus(for: service))
                    .font(MLMFont.muted)
                    .foregroundColor(connectionStatus(for: service) == "Connected" ? .mlmSuccess : .mlmInkMuted)
            }
            Spacer()
            if connectionStatus(for: service) == "Connected" {
                Button("Disconnect", role: .destructive) {
                    pendingDisconnect = service
                    showingDisconnectConfirmation = service != nil
                }
            } else if let service {
                Button("Reconnect") {
                    reconnect(service)
                }
            } else {
                Button("Reconnect") {
                    AppDelegate.shared?.showSettingsWindow()
                }
            }
        }
    }

    /// Removes saved credentials for a source after the user confirms the
    /// consequence in the disconnect alert.
    private func disconnect(_ service: TokenStorage.Service) {
        defer { pendingDisconnect = nil }
        do {
            try container.tokenStorage?.deleteCredentials(service: service)
        } catch {
            AppLogger.shared.error(
                "Failed to remove \(service.displayName) credentials: \(error.localizedDescription)",
                source: "Sources"
            )
        }
    }

    private func connectionStatus(for service: TokenStorage.Service?) -> String {
        guard let service, let storage = container.tokenStorage else {
            return "Disconnected"
        }
        do {
            guard let credentials = try storage.getCredentials(service: service) else {
                return "Disconnected"
            }
            return credentials.isExpired ? "Sign-in expired" : "Connected"
        } catch TokenStorage.KeychainError.itemInaccessible {
            return "Token inaccessible"
        } catch {
            return "Disconnected"
        }
    }

    /// User-initiated reconnect: one interactive keychain read, which may
    /// prompt once. On success the shared access state and refresh backoff
    /// are cleared so background checks resume immediately.
    private func reconnect(_ service: TokenStorage.Service) {
        Task { @MainActor in
            guard let storage = container.tokenStorage else { return }
            guard (try? storage.getCredentials(service: service, interactive: true)) != nil else {
                return
            }
            await container.tokenRefreshService?.clearBackoff(service: service)
            container.tokenAccessStatus?.markAccessible(service)
            AppLogger.shared.info(
                "\(service.displayName) token readable again after interactive keychain read (Settings)",
                source: "Sources"
            )
        }
    }
}
