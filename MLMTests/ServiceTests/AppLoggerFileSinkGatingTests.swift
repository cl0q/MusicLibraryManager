import Foundation
import Testing
@testable import MLM

/// Tests for the file-sink gating logic in `AppLogger`.
///
/// These tests run inside a test process, so the auto-detection will identify
/// this as a test run. Tests that need to exercise file-sink-*enabled* behaviour
/// use the internal `init(fileSinkEnabled:fileSinkDirectory:)` to create a
/// private logger instance pointing at a controlled temp directory.
///
/// **None of these tests read or write `~/Library/Logs/MLM/`.**
struct AppLoggerFileSinkGatingTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_logger_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Stub class-lookup that simulates "XCTestCase is loaded".
    private let xAxisPresent: (String) -> Any? = { name in
        name == "XCTestCase" ? NSObject.self : nil
    }

    /// Stub class-lookup that simulates "no test framework loaded".
    private let noTestClass: (String) -> Any? = { _ in nil }

    /// Poll a logger's `entries` until a matching entry appears or the budget
    /// expires. The logger dispatches to main asynchronously, so a synchronous
    /// read right after the call may miss it.
    /// Mirrors the pattern in `ActivityViewModelTests.waitForLogEntry`.
    ///
    /// `@MainActor` ensures the polling loop yields to the main executor during
    /// `Task.sleep`, allowing `DispatchQueue.main.async` blocks to drain.
    @MainActor
    private func waitForLogEntry(
        in logger: AppLogger,
        matching predicate: (AppLogger.LogEntry) -> Bool,
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02
    ) async -> AppLogger.LogEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = logger.entries.last(where: predicate) {
                return hit
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    /// Poll until `entries.count` reaches `expected` or the budget expires.
    @MainActor
    private func waitForEntryCount(
        in logger: AppLogger,
        toReach expected: Int,
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = logger.entries.count
            if current >= expected { return current }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return logger.entries.count
    }

    /// Poll until `entries` is empty or the budget expires.
    @MainActor
    private func waitForEntriesEmpty(
        in logger: AppLogger,
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if logger.entries.isEmpty { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return logger.entries.isEmpty
    }

    // MARK: - Detection predicate (pure function)

    @Test
    func detection_detectedViaXCTestConfigurationFilePath() {
        let env = ["XCTestConfigurationFilePath": "/tmp/some.xctestconfig"]
        #expect(AppLogger.isTestProcess(environment: env, classLookup: noTestClass) == true)
    }

    @Test
    func detection_detectedViaXCTestBundlePath() {
        let env = ["XCTestBundlePath": "/tmp/Tests.xctest"]
        #expect(AppLogger.isTestProcess(environment: env, classLookup: noTestClass) == true)
    }

    @Test
    func detection_detectedViaXcodeBuiltProductsDir() {
        let env = ["__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/tmp/Build/Products"]
        #expect(AppLogger.isTestProcess(environment: env, classLookup: noTestClass) == true)
    }

    @Test
    func detection_detectedViaXCTestCaseClass() {
        // No env vars, but XCTestCase is loadable → test process.
        let env: [String: String] = [:]
        #expect(AppLogger.isTestProcess(environment: env, classLookup: xAxisPresent) == true)
    }

    @Test
    func detection_plainAppEnvironment_notDetected() {
        // Simulate a normal app launch: no test env vars, no XCTestCase class.
        let env = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "APP_NAME": "MLM",
        ]
        #expect(AppLogger.isTestProcess(environment: env, classLookup: noTestClass) == false)
    }

    @Test
    func detection_emptyEnvironment_safeDefaultIsNotTest() {
        // Empty environment with no test class → safe default: not a test process.
        let env: [String: String] = [:]
        #expect(AppLogger.isTestProcess(environment: env, classLookup: noTestClass) == false)
    }

    // MARK: - Override semantics

    @Test
    func override_forceOn_inTestEnvironment_enablesFileSink() {
        let env: [String: String] = [
            "XCTestConfigurationFilePath": "/tmp/config",
            "MLM_LOGGER_FILE_SINK": "force-on",
        ]
        #expect(AppLogger.resolveFileSinkEnabled(environment: env, classLookup: xAxisPresent) == true)
    }

    @Test
    func override_forceOff_inAppEnvironment_disablesFileSink() {
        let env: [String: String] = [
            "HOME": "/Users/test",
            "MLM_LOGGER_FILE_SINK": "force-off",
        ]
        #expect(AppLogger.resolveFileSinkEnabled(environment: env, classLookup: noTestClass) == false)
    }

    @Test
    func override_winsOverAutoDetection_forceOn() {
        // XCTest env says "test", but override says "force-on" → enabled.
        let env: [String: String] = [
            "XCTestConfigurationFilePath": "/tmp/config",
            "XCTestBundlePath": "/tmp/Tests.xctest",
            "MLM_LOGGER_FILE_SINK": "force-on",
        ]
        #expect(AppLogger.resolveFileSinkEnabled(environment: env, classLookup: xAxisPresent) == true)
    }

    @Test
    func override_winsOverAutoDetection_forceOff() {
        // Clean app env, but override says "force-off" → disabled.
        let env: [String: String] = [
            "HOME": "/Users/test",
            "MLM_LOGGER_FILE_SINK": "force-off",
        ]
        #expect(AppLogger.resolveFileSinkEnabled(environment: env, classLookup: noTestClass) == false)
    }

    @Test
    func override_unknownValue_fallsThroughToAutoDetection() {
        // Unrecognised override value → auto-detection takes over.
        let testEnv: [String: String] = [
            "XCTestConfigurationFilePath": "/tmp/config",
            "MLM_LOGGER_FILE_SINK": "yes-please",  // not "force-on" or "force-off"
        ]
        #expect(AppLogger.resolveFileSinkEnabled(environment: testEnv, classLookup: xAxisPresent) == false,
                "Unknown override should fall through; test env detected → disabled")

        let appEnv: [String: String] = [
            "HOME": "/Users/test",
            "MLM_LOGGER_FILE_SINK": "garbage",
        ]
        #expect(AppLogger.resolveFileSinkEnabled(environment: appEnv, classLookup: noTestClass) == true,
                "Unknown override should fall through; app env not detected → enabled")
    }

    @Test
    func fileSinkOverride_returnsNilForUnset() {
        #expect(AppLogger.fileSinkOverride(environment: [:]) == nil)
    }

    @Test
    func fileSinkOverride_returnsNilForUnrecognised() {
        #expect(AppLogger.fileSinkOverride(environment: ["MLM_LOGGER_FILE_SINK": "maybe"]) == nil)
    }

    // MARK: - In-memory buffer still works when file sink is disabled

    @Test
    func inMemoryBuffer_recordsEntriesWhenFileSinkDisabled() async {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logger = AppLogger(fileSinkEnabled: false, fileSinkDirectory: tmp)
        logger.info("buffered message", source: "Test")

        let hit = await waitForLogEntry(in: logger, matching: { $0.message == "buffered message" })
        #expect(hit != nil, "Entry should appear in the in-memory buffer")
    }

    // MARK: - entries / clear() behave normally

    @Test
    func entriesAndClear_workNormally() async {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logger = AppLogger(fileSinkEnabled: false, fileSinkDirectory: tmp)
        logger.info("one")
        logger.warn("two")
        logger.error("three")

        let count = await waitForEntryCount(in: logger, toReach: 3)
        #expect(count >= 3, "Expected at least 3 entries, got \(count)")

        logger.clear()
        let emptied = await waitForEntriesEmpty(in: logger)
        #expect(emptied, "entries should be empty after clear()")
    }

    // MARK: - File-sink disabled → no file created

    @Test
    func fileSinkDisabled_noFileCreatedInTargetDirectory() async {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logger = AppLogger(fileSinkEnabled: false, fileSinkDirectory: tmp)
        logger.info("should not hit disk")
        logger.error("also not on disk")

        // Wait for the entry to be buffered (confirms log() ran), then check disk.
        _ = await waitForEntryCount(in: logger, toReach: 2)

        let expectedFile = tmp.appendingPathComponent("mlm.log")
        #expect(!FileManager.default.fileExists(atPath: expectedFile.path),
                "File sink disabled: mlm.log must NOT be created in \(tmp.path)")
    }

    // MARK: - File-sink enabled → writes to controlled directory

    @Test
    func fileSinkEnabled_writesToControlledDirectory() async {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logger = AppLogger(fileSinkEnabled: true, fileSinkDirectory: tmp)
        logger.info("file-sink probe", source: "Gating")

        // Wait for the in-memory buffer (confirms log() ran), then poll the file.
        _ = await waitForLogEntry(in: logger, matching: { $0.message == "file-sink probe" })

        let logFile = tmp.appendingPathComponent("mlm.log")
        // File write is async on fileQueue; poll for it.
        let fileDeadline = Date().addingTimeInterval(2.0)
        while Date() < fileDeadline, !FileManager.default.fileExists(atPath: logFile.path) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(FileManager.default.fileExists(atPath: logFile.path),
                "File sink enabled: mlm.log should exist in \(tmp.path)")

        if let content = try? String(contentsOf: logFile, encoding: .utf8) {
            #expect(content.contains("file-sink probe"),
                    "Log file should contain the message we wrote")
            #expect(content.contains("[Gating]"),
                    "Log file should contain the source tag")
        }
    }

    // MARK: - Caching: pure function invokes classLookup once per call

    @Test
    func resolveFileSinkEnabled_callsClassLookupOncePerInvocation() {
        // When no env-var signals fire and no override is set, the predicate
        // falls through to the classLookup. Verify it is called exactly once
        // per call to the pure function — proving the function does not scan
        // or retry the class lookup.
        var callCount = 0
        let countingLookup: (String) -> Any? = { name in
            callCount += 1
            return name == "XCTestCase" ? NSObject.self : nil
        }

        let env: [String: String] = ["HOME": "/Users/test"]
        callCount = 0
        _ = AppLogger.resolveFileSinkEnabled(environment: env, classLookup: countingLookup)
        #expect(callCount == 1, "classLookup should be invoked exactly once per resolveFileSinkEnabled call")

        // A second independent call also invokes it exactly once.
        callCount = 0
        _ = AppLogger.resolveFileSinkEnabled(environment: env, classLookup: countingLookup)
        #expect(callCount == 1, "each resolveFileSinkEnabled call should invoke classLookup exactly once")
    }

    @Test
    func isTestProcess_skipsClassLookupWhenEnvVarMatches() {
        // When an env-var signal fires, classLookup must NOT be called at all
        // (short-circuit evaluation).
        var callCount = 0
        let countingLookup: (String) -> Any? = { _ in
            callCount += 1
            return nil
        }

        let env = ["XCTestConfigurationFilePath": "/tmp/config"]
        callCount = 0
        let result = AppLogger.isTestProcess(environment: env, classLookup: countingLookup)
        #expect(result == true)
        #expect(callCount == 0, "classLookup should not be called when an env-var signal already matched")
    }

    // MARK: - Auto-detection in this test process

    @Test
    func autoDetection_thisProcess_isDetectedAsTest() {
        // We ARE running inside a test harness, so the shared logger's
        // file sink should be disabled.
        #expect(AppLogger.fileSinkEnabled == false,
                "Inside swift test, fileSinkEnabled should be false")
    }

    // MARK: - Thread-safety smoke test

    @Test
    func concurrentLogging_noCrash_saneEntryCount() async {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logger = AppLogger(fileSinkEnabled: false, fileSinkDirectory: tmp)
        let iterations = 100
        let taskCount = 4

        await withTaskGroup(of: Void.self) { group in
            for t in 0..<taskCount {
                group.addTask {
                    for i in 0..<iterations {
                        logger.info("concurrent-\(t)-\(i)")
                    }
                }
            }
        }

        let total = await waitForEntryCount(in: logger, toReach: taskCount * iterations)
        #expect(total == taskCount * iterations,
                "Expected \(taskCount * iterations) entries, got \(total)")
    }

    // MARK: - logFileURL reflects the configured directory

    @Test
    func logFileURL_pointsToConfiguredDirectory() {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logger = AppLogger(fileSinkEnabled: false, fileSinkDirectory: tmp)
        #expect(logger.logFileURL.path == tmp.appendingPathComponent("mlm.log").path)
    }
}
