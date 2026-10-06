import AppKit
import Foundation
import UserNotifications

/// System notifications for finished work (UC-JOB-12, THOUGHTS §6): **opt-in, off by default**
/// (Settings ▸ General `Notify me when background work finishes`), only while MLM is not
/// frontmost, only for imports, syncs and backups (their results and failures). Permission is
/// asked when the user turns the setting on — never at launch. Only inside a real `.app` bundle
/// (a bare SwiftPM executable has no bundle identity for the notification center).
@MainActor
final class ActivitySystemNotifier: ActivityFinishNotifying {
    static let shared = ActivitySystemNotifier()
    static let settingKey = "activity.notifyWhenFinished"

    /// What may notify (Settings ▸ General, ST-GENERAL.N02 — W3-SET). Each is on unless the user
    /// turned it off, so the setting means what it meant before.
    enum Category: String, CaseIterable, Sendable {
        case importsAndDownloads = "activity.notify.imports"
        case sync = "activity.notify.sync"
        case backups = "activity.notify.backups"

        var title: String {
            switch self {
            case .importsAndDownloads: "Imports and downloads"
            case .sync: "Sync to a device"
            case .backups: "Backups and restores"
            }
        }

        init?(kind: ActivityKind) {
            switch kind {
            case .download, .folderScan: self = .importsAndDownloads
            case .sync: self = .sync
            case .backup, .restore: self = .backups
            default: return nil
            }
        }

        func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
            defaults.object(forKey: rawValue) as? Bool ?? true
        }
    }

    /// Whether a notification may be posted for `operation` (pure; tested).
    static func shouldNotify(_ operation: ActivityOperation, enabled: Bool, appIsActive: Bool) -> Bool {
        guard enabled, !appIsActive, operation.kind.mayNotify, !operation.isFromHistory else { return false }
        // Automatic work (a scheduled backup) only when it failed.
        return !operation.isAutomatic || operation.state == .failed
    }

    static var canUseNotificationCenter: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func operationDidFinish(_ operation: ActivityOperation) {
        guard Self.canUseNotificationCenter,
              Self.shouldNotify(operation, enabled: UserDefaults.standard.bool(forKey: Self.settingKey),
                                appIsActive: NSApp?.isActive ?? true),
              Category(kind: operation.kind)?.isEnabled() ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = operation.title
        content.body = ActivityPresentation.endMessage(operation)
        let request = UNNotificationRequest(identifier: operation.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.shared.warn("Couldn’t post a notification: \(error.localizedDescription)", source: "Activity")
            }
        }
    }

    /// Asked once, when the user turns the setting on.
    static func requestPermission() {
        guard canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLogger.shared.warn("Notification permission: \(error.localizedDescription)", source: "Activity")
            } else if !granted {
                AppLogger.shared.info("Notifications were not allowed in System Settings", source: "Activity")
            }
        }
    }
}

extension ActivityCenter {
    /// A test run (never the app): XCTest's configuration, Swift Testing's environment or a
    /// loaded `XCTestCase` — not Xcode's build-product paths, which a debug app run also has (N7).
    nonisolated static func isTestProcess(environment: [String: String] = ProcessInfo.processInfo.environment,
                                          classLookup: (String) -> Any? = { NSClassFromString($0) }) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment.keys.contains(where: { $0.hasPrefix("SWT_") }) { return true }
        return classLookup("XCTestCase") != nil
    }

    /// At launch (app only, never in tests): the app-level history (operations without a
    /// library, `ActivityAppLevelStore` next to the library registry) and the opt-in notifier.
    func startForApp() {
        guard !Self.isTestProcess() else { return }
        finishNotifier = ActivitySystemNotifier.shared
        Task { await attachAppLevel(store: ActivityAppLevelStore()) }
    }
}
