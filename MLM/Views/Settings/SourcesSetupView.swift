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
                    if let service { try? container.tokenStorage?.deleteCredentials(service: service) }
                }
            } else {
                Button("Reconnect") {
                    AppDelegate.shared?.showSettingsWindow()
                }
            }
        }
    }

    private func connectionStatus(for service: TokenStorage.Service?) -> String {
        guard let service,
              let credentials = try? container.tokenStorage?.getCredentials(service: service) else {
            return "Disconnected"
        }
        return credentials.isExpired ? "Sign-in expired" : "Connected"
    }
}
