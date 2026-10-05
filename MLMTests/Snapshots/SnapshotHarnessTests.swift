import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import MLM

/// Statically written on Windows; compile, record and compare on the user's Mac.
@MainActor
final class SnapshotsTests: XCTestCase {
    private let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    func testInventoryMatchesProductionFiles() throws {
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MLM/Views", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ))
        var paths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" {
                paths.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        // W1-2 added Settings/GeneralSettingsView.swift (deferred) and Settings/SettingsTab.swift (non-view).
        // W2-F added Shell/UndoCenter.swift and Shell/ShellEdits.swift (non-view) and removed the
        // new-playlist sheet fixture (S-SEL-NEWPLAYLIST: no sheet).
        XCTAssertEqual(paths.count, 83, "Re-audit inventory changes explicitly.")
        XCTAssertEqual(Set(SnapshotFixtures.inventory.map(\.path)), paths)
        XCTAssertEqual(SnapshotFixtures.inventory.count, paths.count)
        XCTAssertFalse(SnapshotFixtures.inventory.contains { $0.disposition.isEmpty })
        XCTAssertEqual(Set(SnapshotFixtures.fixtures.map(\.id)).count, SnapshotFixtures.fixtures.count)
        XCTAssertFalse(SnapshotFixtures.fixtures.isEmpty)
        XCTAssertEqual(SnapshotFixtures.fixtures.count, 29)
        XCTAssertEqual(SnapshotFixtures.renderedPaths.count, 24)
        XCTAssertEqual(SnapshotFixtures.inventory.filter { $0.disposition.hasPrefix("Non-view:") }.count, 17)
        XCTAssertEqual(SnapshotFixtures.inventory.filter { $0.disposition.hasPrefix("Deferred:") }.count, 42)
        for fixture in SnapshotFixtures.fixtures where fixture.expectedTableRows != nil {
            if case .swiftUI = fixture.backend {
                XCTFail("\(fixture.id): table readiness requires the AppKit backend.")
            }
        }
    }

    func testNormalizedPixelComparisonAndDiff() throws {
        let black = try SnapshotPixels(width: 1, height: 1, rgba: [0, 0, 0, 255])
        let red = try SnapshotPixels(width: 1, height: 1, rgba: [255, 0, 0, 255])
        let wider = try SnapshotPixels(width: 2, height: 1, rgba: [
            0, 0, 0, 255, 0, 0, 0, 255,
        ])
        XCTAssertEqual(black.comparison(to: black), .matches)
        XCTAssertEqual(black.comparison(to: red), .pixelsDiffer)
        XCTAssertEqual(black.comparison(to: wider), .dimensionsDiffer)
        let diff = try black.difference(from: wider)
        XCTAssertEqual(diff.width, 2)
        XCTAssertEqual(diff.height, 1)
        XCTAssertEqual(Array(diff.rgba.suffix(4)), [255, 0, 255, 255])
        XCTAssertThrowsError(try SnapshotPixels(width: 2, height: 1, rgba: [0, 0, 0, 255]))
    }

    func testRecordCompareMissingAndCorruptBaselines() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLM-snapshot-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { XCTFail("Snapshot test cleanup failed: \(error)") }
        }
        let file = temporary.appendingPathComponent("baseline.png")
        let black = try SnapshotPixels(width: 1, height: 1, rgba: [0, 0, 0, 255])
        let red = try SnapshotPixels(width: 1, height: 1, rgba: [255, 0, 0, 255])
        XCTAssertEqual(try SnapshotFiles.compare(black, to: file), .missing)
        try SnapshotFiles.record(black, to: file)
        XCTAssertEqual(try SnapshotFiles.compare(black, to: file), .matches)
        XCTAssertEqual(try SnapshotFiles.compare(red, to: file), .pixelsDiffer)
        XCTAssertEqual(try SnapshotFiles.compare(black, to: file), .matches, "Compare must not rewrite references.")
        try Data("not a PNG".utf8).write(to: file)
        XCTAssertThrowsError(try SnapshotFiles.compare(black, to: file))
    }

    func testBaselineSetRejectsPaths() throws {
        XCTAssertEqual(try SnapshotFiles.baselineSet(nil), "default")
        XCTAssertEqual(try SnapshotFiles.baselineSet("macos26-xcode26-arm64"), "macos26-xcode26-arm64")
        XCTAssertThrowsError(try SnapshotFiles.baselineSet("../escape"))
        XCTAssertThrowsError(try SnapshotFiles.baselineSet(""))
        XCTAssertThrowsError(try SnapshotFiles.baselineSet("folder/name"))
    }

    func testSeededStoreAndFactoriesAreServiceFree() throws {
        try requireRenderingOptIn()
        let store = try SnapshotFixtureStore.makeSeeded()
        let before = try counts(in: store)
        XCTAssertEqual(before, [5, 2, 2])
        for fixture in SnapshotFixtures.fixtures {
            _ = try fixture.view(store: store)
        }
        XCTAssertEqual(try counts(in: store), before, "Factory construction must not mutate fixture data.")
        XCTAssertNotNil(store.container.trackRepository)
        XCTAssertNotNil(store.container.albumRepository)
        XCTAssertNotNil(store.container.playlistRepository)
        XCTAssertNil(store.container.audioPlayer)
        XCTAssertNil(store.container.tokenStorage)
        XCTAssertNil(store.container.unifiedSearchService)
    }

    func testRendererDimensionsAndPNGRoundTrip() async throws {
        try requireRenderingOptIn()
        struct ProbeRow: Identifiable {
            let id: Int
            let title: String
        }
        for scheme in SnapshotAppearance.allCases {
            let pixels = try await SnapshotRenderer.render(
                Text("Snapshot").padding(8),
                size: CGSize(width: 160, height: 60),
                scheme: scheme,
                backend: .swiftUI
            )
            XCTAssertEqual(pixels.width, 320)
            XCTAssertEqual(pixels.height, 120)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: pixels.pngData()))
            let decoded = try SnapshotPixels(image: XCTUnwrap(bitmap.cgImage))
            XCTAssertEqual(pixels.comparison(to: decoded), .matches)
            XCTAssertGreaterThan(Set(pixels.rgba).count, 2, "Text should produce more than a blank flat bitmap.")
            let native = try await SnapshotRenderer.render(
                Table([ProbeRow(id: 1, title: "Native snapshot row")]) {
                    TableColumn("Title", value: \.title)
                },
                size: CGSize(width: 320, height: 120),
                scheme: scheme,
                backend: .appKit,
                expectedTableRows: 1
            )
            XCTAssertEqual(native.width, 640)
            XCTAssertEqual(native.height, 240)
            XCTAssertGreaterThan(Set(native.rgba).count, 2, "Native table must draw actual content.")
        }
    }

    func testRegisteredSnapshots() async throws {
        try requireRenderingOptIn()
        let record = ProcessInfo.processInfo.environment["MLM_SNAPSHOT_RECORD"] == "1"
        let baselineSet = try SnapshotFiles.baselineSet(
            ProcessInfo.processInfo.environment["MLM_SNAPSHOT_SET"]
        )
        let baselines = directory.appendingPathComponent("__Snapshots__", isDirectory: true)
            .appendingPathComponent(baselineSet, isDirectory: true)
        let failures = directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mlm-snapshot-failures", isDirectory: true)
            .appendingPathComponent(baselineSet, isDirectory: true)
        for fixture in SnapshotFixtures.fixtures {
            for scheme in SnapshotAppearance.allCases {
                // A fresh store per case prevents order-dependent fixture contamination.
                let store = try SnapshotFixtureStore.makeSeeded()
                let actual = try await SnapshotRenderer.render(
                    try fixture.view(store: store),
                    size: fixture.size,
                    scheme: scheme,
                    backend: fixture.backend,
                    expectedTableRows: fixture.expectedTableRows
                )
                let name = "\(fixture.id)-\(scheme.rawValue)"
                let reference = baselines.appendingPathComponent("\(name).png")
                if record {
                    try SnapshotFiles.record(actual, to: reference)
                    continue
                }
                let result = try SnapshotFiles.compare(actual, to: reference)
                guard result != .matches else { continue }
                try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
                try SnapshotFiles.record(actual, to: failures.appendingPathComponent("\(name)-actual.png"))
                attach(try actual.pngData(), named: "\(name)-actual")
                if result != .missing {
                    let expected = try SnapshotFiles.read(reference)
                    let diff = try expected.difference(from: actual)
                    try SnapshotFiles.record(diff, to: failures.appendingPathComponent("\(name)-diff.png"))
                    attach(try expected.pngData(), named: "\(name)-expected")
                    attach(try diff.pngData(), named: "\(name)-diff")
                }
                XCTFail(
                    "\(name): \(result.rawValue). Reference: \(reference.path). "
                    + "Record deliberately with MLM_SNAPSHOTS=1 MLM_SNAPSHOT_RECORD=1 "
                    + "MLM_SNAPSHOT_SET=\(baselineSet) "
                    + "swift test --filter Snapshots. Diagnostics: \(failures.path)"
                )
            }
        }
    }

    private func counts(in store: SnapshotFixtureStore) throws -> [Int] {
        try store.database.read { db in
            try ["tracks", "playlists", "playlist_tracks"].map { table in
                try XCTUnwrap(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"))
            }
        }
    }

    private func requireRenderingOptIn() throws {
        guard ProcessInfo.processInfo.environment["MLM_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Set MLM_SNAPSHOTS=1 for macOS fixture construction and rendering.")
        }
    }

    private func attach(_ png: Data, named name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

enum SnapshotAppearance: String, CaseIterable {
    case light, dark

    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var appKitName: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
}

@MainActor
enum SnapshotRenderer {
    static func render<V: View>(
        _ view: V,
        size: CGSize,
        scheme: SnapshotAppearance,
        backend: SnapshotBackend,
        expectedTableRows: Int? = nil
    ) async throws -> SnapshotPixels {
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite,
              let appearance = NSAppearance(named: scheme.appKitName),
              let timeZone = TimeZone(secondsFromGMT: 0) else {
            throw SnapshotError.invalidConfiguration
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let content = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme.colorScheme)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.timeZone, timeZone)
            .environment(\.calendar, calendar)
            .tint(Color(red: 0.1, green: 0.4, blue: 0.85))
            .accentColor(Color(red: 0.1, green: 0.4, blue: 0.85))
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }

        if case .appKit = backend {
            _ = NSApplication.shared
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = appearance
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            if let expectedTableRows {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(3))
                while !containsTable(host, rows: expectedTableRows) {
                    guard clock.now < deadline else {
                        throw SnapshotError.renderFailed("Native table did not expose \(expectedTableRows) rows within 3 seconds; refusing a loading/blank baseline.")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                    host.layoutSubtreeIfNeeded()
                }
            }
            let width = Int(size.width * 2)
            let height = Int(size.height * 2)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32
            ), let bytes = bitmap.bitmapData else {
                throw SnapshotError.renderFailed("Could not allocate AppKit capture bitmap.")
            }
            bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            bitmap.size = size
            appearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            guard let image = bitmap.cgImage else {
                throw SnapshotError.renderFailed("AppKit capture has no CGImage.")
            }
            let pixels = try SnapshotPixels(image: image)
            guard pixels.width == width, pixels.height == height else {
                throw SnapshotError.renderFailed("AppKit capture did not retain configured pixel dimensions.")
            }
            return pixels
        }

        var result: Result<SnapshotPixels, Error>?
        appearance.performAsCurrentDrawingAppearance {
            result = Result {
                let renderer = ImageRenderer(content: content)
                renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
                renderer.scale = 2
                guard let image = renderer.cgImage else {
                    throw SnapshotError.renderFailed("ImageRenderer returned no CGImage.")
                }
                return try SnapshotPixels(image: image)
            }
        }
        guard let result else { throw SnapshotError.renderFailed("Appearance callback did not execute.") }
        let pixels = try result.get()
        guard pixels.width == Int(size.width * 2), pixels.height == Int(size.height * 2) else {
            throw SnapshotError.renderFailed("Renderer did not produce the configured 2x pixel dimensions.")
        }
        return pixels
    }

    private static func containsTable(_ view: NSView, rows: Int) -> Bool {
        if let table = view as? NSTableView, table.numberOfRows == rows { return true }
        return view.subviews.contains { containsTable($0, rows: rows) }
    }
}

enum SnapshotComparison: String {
    case matches
    case missing = "missing baseline"
    case dimensionsDiffer = "dimensions differ"
    case pixelsDiffer = "pixels differ"
}

enum SnapshotError: LocalizedError {
    case invalidConfiguration
    case invalidPixels
    case renderFailed(String)
    case unreadableBaseline(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid snapshot dimensions, appearance or time zone."
        case .invalidPixels: "Pixel dimensions must match nonempty RGBA data."
        case let .renderFailed(message): message
        case let .unreadableBaseline(path): "Could not decode snapshot PNG: \(path)"
        }
    }
}

struct SnapshotPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0,
              width <= Int.max / 4 / height, rgba.count == width * height * 4 else {
            throw SnapshotError.invalidPixels
        }
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= Int.max / 4 / height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SnapshotError.invalidPixels
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                throw SnapshotError.renderFailed("Could not allocate normalized sRGB context.")
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        try self.init(width: width, height: height, rgba: bytes)
    }

    func comparison(to other: SnapshotPixels) -> SnapshotComparison {
        guard width == other.width, height == other.height else { return .dimensionsDiffer }
        return rgba == other.rgba ? .matches : .pixelsDiffer
    }

    func difference(from other: SnapshotPixels) throws -> SnapshotPixels {
        let width = max(self.width, other.width)
        let height = max(self.height, other.height)
        guard width <= Int.max / 4 / height else { throw SnapshotError.invalidPixels }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let inBoth = x < self.width && x < other.width && y < self.height && y < other.height
                let changed: Bool
                if inBoth {
                    let left = (y * self.width + x) * 4
                    let right = (y * other.width + x) * 4
                    changed = (0..<4).contains { rgba[left + $0] != other.rgba[right + $0] }
                } else {
                    changed = true
                }
                bytes[offset] = changed ? 255 : 0
                bytes[offset + 2] = changed ? 255 : 0
                bytes[offset + 3] = 255
            }
        }
        return try SnapshotPixels(width: width, height: height, rgba: bytes)
    }

    func pngData() throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed("Could not encode normalized pixels as PNG.")
        }
        return png
    }
}

enum SnapshotFiles {
    static func baselineSet(_ value: String?) throws -> String {
        guard let value else { return "default" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !value.isEmpty, value.count <= 80,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SnapshotError.renderFailed("MLM_SNAPSHOT_SET must be a nonempty alphanumeric, hyphen/underscore label (max 80 characters).")
        }
        return value
    }

    static func record(_ pixels: SnapshotPixels, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pixels.pngData().write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> SnapshotPixels {
        let data = try Data(contentsOf: url)
        guard let image = NSBitmapImageRep(data: data)?.cgImage else {
            throw SnapshotError.unreadableBaseline(url.path)
        }
        return try SnapshotPixels(image: image)
    }

    static func compare(_ actual: SnapshotPixels, to url: URL) throws -> SnapshotComparison {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return try read(url).comparison(to: actual)
    }
}
