import SwiftUI

/// Settings tab for source-pipeline credentials that don't fit in
/// Keychain-backed OAuth flows.
///
/// Currently hosts the Squid.wtf `captcha_verified_at` cookie. The
/// cookie is persisted in UserDefaults so users don't have to paste it
/// in on every launch. Empty value clears the entry.
struct SourcesSetupView: View {
    @State private var squidCookie: String = ""
    @State private var savedAt: Date?

    var body: some View {
        Form {
            Section("Squid.wtf (Qobuz Mirror)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("captcha_verified_at Cookie")
                        .font(MLMFont.sectionLabel)
                        .foregroundColor(.mlmInkSecondary)
                    TextField(
                        "z. B. 1779157770721",
                        text: $squidCookie
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    Text("Öffne qobuz.squid.wtf, suche & lade ein Lied (löst die Captcha aus), dann Dev-Tools → Storage → Cookies → Wert von 'captcha_verified_at' kopieren und hier einfügen.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // Cookie Status Indicator
                    HStack(spacing: 6) {
                        if SquidWtfClient.captchaCookie == nil {
                            Label("Kein Cookie konfiguriert", systemImage: "xmark.circle.fill")
                                .font(MLMFont.muted)
                                .foregroundColor(.red)
                        } else if SquidWtfClient.isCookieExpired {
                            Label("Cookie abgelaufen! Bitte erneuern.", systemImage: "exclamationmark.triangle.fill")
                                .font(MLMFont.muted)
                                .foregroundColor(.orange)
                        } else {
                            Label("Aktiv und gültig", systemImage: "checkmark.circle.fill")
                                .font(MLMFont.muted)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 2)
                    
                    HStack(spacing: 8) {
                        Button("Speichern") { save() }
                            .disabled(squidCookie.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Löschen", role: .destructive) {
                            squidCookie = ""
                            save()
                        }
                        if let savedAt {
                            Text("Gespeichert \(Self.relative(savedAt))")
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
}
