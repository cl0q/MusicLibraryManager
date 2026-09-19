// ============================================================================
// mlm-auth — keychain access helper for Music Library Manager.
//
// WHY THIS HELPER EXISTS
// ----------------------
// macOS keychain records "Always Allow" access consent against the signing
// identity of the binary that requests an item. The MLM app is rebuilt (and
// re-signed) constantly during development, and an ad-hoc signature yields a
// NEW identity on every build — so consent granted for one build stops being
// valid for the next, and every background token read triggers a keychain
// password prompt (with three keychain items per service and a 60s refresh
// loop, that became a prompt loop).
//
// Fix: ALL keychain access is funneled through this small helper binary,
// which is signed with a STABLE self-signed identity ("MLM Dev", created by
// scripts/setup-dev-signing.sh). One "Always Allow" click for the helper
// survives app rebuilds because the helper's signing identity is stable
// across builds.
//
// In addition, every default operation below is NON-INTERACTIVE
// (kSecUseNoAuthenticationUI): a background read can NEVER prompt or block.
// An item whose ACL does not match fails fast with exit code 2, and the app
// surfaces a one-line "token inaccessible — reconnect" notice instead of a
// prompt loop. Only explicit user-initiated actions (reconnect in Settings)
// pass --interactive and may prompt once.
//
// CLI (machine-readable JSON on stdout, errors as JSON on stderr):
//
//   mlm-auth get <service> [--interactive]        read the token blob
//   mlm-auth set <service> <json> [--interactive] add-or-update the token blob
//   mlm-auth delete <service> [--interactive]     delete blob + legacy items
//   mlm-auth has <service>                        presence check (no data)
//   mlm-auth list                                 JSON array of present services
//   mlm-auth migrate <service> [--interactive]    one-time legacy → single item
//
// Services: spotify | soundcloud | applemusic
//
// Keychain layout (shared with TokenStorage in the MLM target): ONE
// kSecClassGenericPassword item per service —
//   kSecAttrService = "com.mlm.oauth.<service>",
//   kSecAttrAccount = "token",
//   data = JSON {"access_token": String, "refresh_token": String?, "expiry_date": String?}
//
// The legacy layout stored three items per service (accounts
// "access_token" / "refresh_token" / "expiry_date"); `migrate` converts it.
//
// Exit codes:
//   0 = ok (for `get`/`list`/`migrate`, the result is printed on stdout)
//   1 = item absent (not an error)
//   2 = item exists but is inaccessible without user interaction
//       (stderr JSON: {"error": ..., "status": <OSStatus>})
//   3 = usage error or any other failure
// ============================================================================

import Foundation
import Security

// MARK: - Keychain layout (mirrors TokenStorage in the MLM target)

private let tokenAccount = "token"
private let legacyAccounts = ["access_token", "refresh_token", "expiry_date"]
private let services: [String: String] = [
    "spotify": "com.mlm.oauth.spotify",
    "soundcloud": "com.mlm.oauth.soundcloud",
    "applemusic": "com.mlm.oauth.applemusic",
]

// MARK: - Output / error helpers

/// Print a JSON object on stdout (the machine-readable result channel).
@inline(__always)
private func printJSON(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Write a JSON error on stderr and exit with the given code.
private func fail(_ message: String, code: Int32, status: OSStatus? = nil) -> Never {
    var object: [String: Any] = ["error": message]
    if let status {
        object["status"] = status
    }
    printJSONToStderr(object)
    exit(code)
}

@inline(__always)
private func printJSONToStderr(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    FileHandle.standardError.write(data)
    FileHandle.standardError.write(Data("\n".utf8))
}

/// Resolve a CLI service name to its keychain service namespace.
private func resolveServiceID(_ name: String) -> String {
    guard let serviceID = services[name] else {
        fail(
            "unknown service '\(name)' (expected one of: \(services.keys.sorted().joined(separator: ", ")))",
            code: 3
        )
    }
    return serviceID
}

private func usage() -> Never {
    printJSONToStderr([
        "error": "usage: mlm-auth <command> [args]",
        "commands": "get <service> [--interactive] | set <service> <json> [--interactive] | delete <service> [--interactive] | has <service> | list | migrate <service> [--interactive]",
        "services": services.keys.sorted(),
    ])
    exit(3)
}

// MARK: - Keychain primitives

@inline(__always)
private func baseQuery(serviceID: String, account: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceID,
        kSecAttrAccount as String: account,
    ]
}

/// Apply the no-UI flag so the operation can never show an authentication
/// prompt — it fails fast with errSecAuthFailed / errSecInteractionNotAllowed
/// instead. (The deprecated constant is used because the "deny" value for
/// its successor kSecUseAuthenticationUI is not exposed to Swift; semantics
/// are identical.)
@inline(__always)
private func denyUI(_ query: inout [String: Any]) {
    query[kSecUseNoAuthenticationUI as String] = true
}

@inline(__always)
private func isAuthDenied(_ status: OSStatus) -> Bool {
    status == errSecAuthFailed || status == errSecInteractionNotAllowed
}

/// Copy an item's data. Non-interactive unless `interactive` (explicit
/// user-initiated action, may prompt once).
private func copyItem(serviceID: String, account: String, interactive: Bool) -> (status: OSStatus, data: Data?) {
    var query = baseQuery(serviceID: serviceID, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    if !interactive {
        denyUI(&query)
    }
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
}

/// Non-interactive presence check. An item that exists but is inaccessible
/// still counts as present (its ACL simply does not match this binary yet).
private func itemPresent(serviceID: String, account: String) -> Bool {
    var query = baseQuery(serviceID: serviceID, account: account)
    query[kSecReturnData as String] = false
    denyUI(&query)
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess || isAuthDenied(status)
}

/// Best-effort removal of leftover legacy 3-item accounts. Never fatal: a
/// stray legacy item is inert once the single blob item exists.
private func deleteLegacyBestEffort(serviceID: String) {
    for account in legacyAccounts {
        var deleteQuery = baseQuery(serviceID: serviceID, account: account)
        denyUI(&deleteQuery)
        SecItemDelete(deleteQuery as CFDictionary)
    }
}

// MARK: - Commands

private func cmdGet(serviceID: String, interactive: Bool) -> Never {
    let (status, data) = copyItem(serviceID: serviceID, account: tokenAccount, interactive: interactive)
    switch status {
    case errSecSuccess:
        guard let data else {
            fail("keychain item returned no data", code: 3)
        }
        FileHandle.standardOutput.write(data)
        exit(0)
    case errSecItemNotFound:
        exit(1)
    case errSecAuthFailed, errSecInteractionNotAllowed:
        fail("token item is not accessible without user interaction", code: 2, status: status)
    default:
        fail("unexpected keychain status while reading token item", code: 3, status: status)
    }
}

private func cmdSet(serviceID: String, json: String, interactive: Bool) -> Never {
    // Light validation: must be a JSON object with a non-empty access_token.
    guard
        let data = json.data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let accessToken = object["access_token"] as? String,
        !accessToken.isEmpty
    else {
        fail("invalid token JSON (expected an object with a non-empty \"access_token\")", code: 3)
    }

    var query = baseQuery(serviceID: serviceID, account: tokenAccount)
    if !interactive {
        denyUI(&query)
    }

    // Add-or-update.
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = data
        status = SecItemAdd(addQuery as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
        if isAuthDenied(status) {
            fail("token item is not accessible without user interaction", code: 2, status: status)
        }
        fail("failed to write token item", code: 3, status: status)
    }

    // A (re)connect is the new source of truth — remove any leftover legacy
    // items (mirrors the app-side save behavior).
    deleteLegacyBestEffort(serviceID: serviceID)
    exit(0)
}

private func cmdDelete(serviceID: String, interactive: Bool) -> Never {
    var query = baseQuery(serviceID: serviceID, account: tokenAccount)
    if !interactive {
        denyUI(&query)
    }
    let status = SecItemDelete(query as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
        break  // absent is ok
    case errSecAuthFailed, errSecInteractionNotAllowed:
        fail("token item is not accessible without user interaction", code: 2, status: status)
    default:
        fail("failed to delete token item", code: 3, status: status)
    }
    deleteLegacyBestEffort(serviceID: serviceID)
    exit(0)
}

private func cmdHas(serviceID: String) -> Never {
    exit(itemPresent(serviceID: serviceID, account: tokenAccount) ? 0 : 1)
}

private func cmdList() -> Never {
    let present = services.sorted(by: { $0.key < $1.key }).compactMap { name, serviceID in
        itemPresent(serviceID: serviceID, account: tokenAccount) ? name : nil
    }
    printJSON(present)
    exit(0)
}

/// One-time migration from the legacy 3-item layout to the single blob.
///
/// Defensive order: read ALL present legacy items BEFORE any deletion;
/// write and verify the single item; only then delete the legacy items that
/// were present. Any failure stops before any deletion, so the user's tokens
/// are preserved.
///
/// Always prints a JSON result on stdout:
///   {"migrated": true,  "accounts": [...]}                                  exit 0
///   {"migrated": false, "reason": "no-legacy-items", "accounts": []}        exit 0
///   {"migrated": false, "reason": "no-access-token", "accounts": [...]}     exit 0
///   {"migrated": false, "reason": "inaccessible", "accounts": [...], "status": N}  exit 2
///   {"migrated": false, "reason": "read-failed" | "write-failed" | "verification-failed", ...}  exit 3
private func cmdMigrate(serviceID: String, interactive: Bool) -> Never {
    var present: [String] = []
    var values: [String: String] = [:]

    // 1. Read every present legacy item (full reads before anything else).
    for account in legacyAccounts {
        let (status, data) = copyItem(serviceID: serviceID, account: account, interactive: interactive)
        switch status {
        case errSecSuccess:
            guard
                let data,
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty
            else {
                continue
            }
            values[account] = value
            present.append(account)
        case errSecItemNotFound:
            continue
        case errSecAuthFailed, errSecInteractionNotAllowed:
            printJSON(["migrated": false, "reason": "inaccessible", "accounts": present + [account], "status": status])
            exit(2)
        default:
            printJSON(["migrated": false, "reason": "read-failed", "accounts": present + [account], "status": status])
            exit(3)
        }
    }

    guard !present.isEmpty else {
        printJSON(["migrated": false, "reason": "no-legacy-items", "accounts": []])
        exit(0)
    }
    guard let accessToken = values["access_token"] else {
        // Legacy items exist but there is no access token to migrate —
        // leave them untouched.
        printJSON(["migrated": false, "reason": "no-access-token", "accounts": present])
        exit(0)
    }

    // 2. Build the single blob (same JSON shape the app writes).
    var blob: [String: Any] = ["access_token": accessToken]
    if let refreshToken = values["refresh_token"] {
        blob["refresh_token"] = refreshToken
    }
    if let expiryDate = values["expiry_date"] {
        blob["expiry_date"] = expiryDate
    }
    guard let blobData = try? JSONSerialization.data(withJSONObject: blob) else {
        printJSON(["migrated": false, "reason": "write-failed", "accounts": present])
        exit(3)
    }

    // 3. Write the new single item.
    var query = baseQuery(serviceID: serviceID, account: tokenAccount)
    if !interactive {
        denyUI(&query)
    }
    var writeStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: blobData] as CFDictionary)
    if writeStatus == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = blobData
        writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
    }
    guard writeStatus == errSecSuccess else {
        let reason = isAuthDenied(writeStatus) ? "inaccessible" : "write-failed"
        printJSON(["migrated": false, "reason": reason, "accounts": present, "status": writeStatus])
        exit(isAuthDenied(writeStatus) ? 2 : 3)
    }

    // 4. Verify it is readable before touching anything else.
    let (verifyStatus, verifyData) = copyItem(serviceID: serviceID, account: tokenAccount, interactive: interactive)
    guard
        verifyStatus == errSecSuccess,
        let verifyData,
        let verified = (try? JSONSerialization.jsonObject(with: verifyData)) as? [String: Any],
        verified["access_token"] as? String == accessToken
    else {
        printJSON(["migrated": false, "reason": "verification-failed", "accounts": present, "status": verifyStatus])
        exit(3)
    }

    // 5. Only now delete the legacy items that were present.
    var remaining: [String] = []
    for account in present {
        var deleteQuery = baseQuery(serviceID: serviceID, account: account)
        denyUI(&deleteQuery)
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            // The new item is the source of truth; a stray legacy item is
            // inert. Keep it rather than risk data loss.
            remaining.append(account)
        }
    }

    var result: [String: Any] = ["migrated": true, "accounts": present]
    if !remaining.isEmpty {
        result["remaining_legacy"] = remaining
    }
    printJSON(result)
    exit(0)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

guard !arguments.isEmpty else {
    usage()
}

let command = arguments[0]
var rest = Array(arguments.dropFirst())
var interactive = false
if let index = rest.firstIndex(of: "--interactive") {
    interactive = true
    rest.remove(at: index)
}

switch command {
case "get":
    guard rest.count == 1 else {
        usage()
    }
    cmdGet(serviceID: resolveServiceID(rest[0]), interactive: interactive)
case "set":
    guard rest.count == 2 else {
        usage()
    }
    cmdSet(serviceID: resolveServiceID(rest[0]), json: rest[1], interactive: interactive)
case "delete":
    guard rest.count == 1 else {
        usage()
    }
    cmdDelete(serviceID: resolveServiceID(rest[0]), interactive: interactive)
case "has":
    guard rest.count == 1 else {
        usage()
    }
    cmdHas(serviceID: resolveServiceID(rest[0]))
case "list":
    cmdList()
case "migrate":
    guard rest.count == 1 else {
        usage()
    }
    cmdMigrate(serviceID: resolveServiceID(rest[0]), interactive: interactive)
default:
    usage()
}
