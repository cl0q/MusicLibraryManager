import AppKit
import SwiftUI
import XCTest
@testable import MLM

/// The track table at library size, hosted in a real AppKit window: how many cell views exist,
/// and what a sort change, a scroll through the list and a live-state change cost on the main
/// actor. A sort change on 12,000 rows once hung the app for minutes (2026-10-07).
///
/// Baseline on redesign/b3 (5d83664), M-series Mac, 1,200 × 800 window:
/// 1k rows: sort ~200 ms, refresh with identical rows ~30 ms, click ~11 ms.
/// 12k rows: sort ~1,200 ms (model sort alone 50 ms), identical refresh ~300 ms, click ~38 ms.
/// The sort cost is SwiftUI turning a reorder into one animated `NSOutlineView` move per row.
@MainActor
final class TrackTablePerformanceTests: XCTestCase {
    private static let windowSize = NSSize(width: 1_200, height: 800)

    /// Takes ~20 s, so it runs only on request: `MLM_PERF=1 swift test --filter TrackTablePerformanceTests`.
    func testProbeReport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLM_PERF"] == "1", "set MLM_PERF=1 to run the table probe")
        for count in [1_000, 12_000] {
            let report = try await probe(rowCount: count)
            print("[TrackTablePerf] \(report)")
        }
    }

    // MARK: - Probe

    struct Report: CustomStringConvertible {
        var rows = 0
        var firstLayoutMS = 0.0
        var cellsAfterLoad = 0
        var scrollThroughMS = 0.0
        var cellsAfterScroll = 0
        var sortMS: [Double] = []
        var cellsAfterSort = 0
        var liveCellObjects = 0
        var modelSortMS = 0.0
        var clickMS = 0.0
        var refreshMS = 0.0

        var description: String {
            let sorts = sortMS.map { String(format: "%.0f", $0) }.joined(separator: "/")
            return "rows=\(rows) firstLayout=\(Int(firstLayoutMS))ms cells(load)=\(cellsAfterLoad) "
                + "scrollThrough=\(Int(scrollThroughMS))ms cells(scroll)=\(cellsAfterScroll) "
                + "sort=[\(sorts)]ms cells(sort)=\(cellsAfterSort) liveCellObjects=\(liveCellObjects) "
                + "modelSortOnly=\(Int(modelSortMS))ms click=\(Int(clickMS))ms refresh=\(Int(refreshMS))ms"
        }
    }

    private func probe(rowCount: Int) async throws -> Report {
        var report = Report(rows: rowCount)
        let model = TrackListModel(sortOrder: nil)
        model.setTracksNow(Self.tracks(rowCount))

        let host = NSHostingView(rootView: TrackListTable(model: model, configuration: .allTracks(activate: nil, totals: nil)) {
            EmptyView()
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height))
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        report.firstLayoutMS = try await measure {
            try await self.settle(host) { Self.table(in: host)?.numberOfRows == rowCount }
            try await self.settleQuiet(host)
        }
        let table = try XCTUnwrap(Self.table(in: host))
        report.cellsAfterLoad = Self.cellViews(in: host)

        // Scroll the whole list in screen-sized steps, as a user dragging the scroller would.
        report.scrollThroughMS = try await measure {
            let step = max(1, Int(table.visibleRect.height / max(table.rowHeight, 1)))
            var row = 0
            while row < rowCount {
                table.scrollRowToVisible(row)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                row += step * 4
            }
            table.scrollRowToVisible(rowCount / 2)
            try await self.settleQuiet(host)
        }
        report.cellsAfterScroll = Self.cellViews(in: host)

        let orders: [TrackSortOrder] = [
            .init(column: .title, ascending: true),
            .init(column: .artist, ascending: true),
            .init(column: .title, ascending: false),
            .init(column: .added, ascending: true),
        ]
        // Profiling aid: MLM_PERF_SORT_LOOP=1 keeps sorting the big list for 25 s (attach `sample`).
        if rowCount >= 10_000, ProcessInfo.processInfo.environment["MLM_PERF_SORT_LOOP"] == "1" {
            let end = ContinuousClock.now.advanced(by: .seconds(25))
            var index = 0
            while ContinuousClock.now < end {
                await model.setSortOrder(orders[index % orders.count])
                try await settleQuiet(host)
                index += 1
            }
        }
        for order in orders {
            report.sortMS.append(try await measure {
                await model.setSortOrder(order)
                try await self.settleQuiet(host)
            })
        }
        report.cellsAfterSort = Self.cellViews(in: host)

        // A click on a row, as AppKit reports it, until SwiftUI has published the selection.
        report.clickMS = try await measure {
            for row in stride(from: 10, to: 30, by: 2) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                try await self.settleQuiet(host)
            }
        } / 10
        // A refresh that brings the same rows (scan, availability check, metadata write).
        let tracks = model.tracks
        report.refreshMS = try await measure {
            await model.setTracks(tracks)
            try await self.settleQuiet(host)
        }
        report.liveCellObjects = Self.liveObjects(matching: "TableCellHostingView<ModifiedContent<TrackCell")
        let source = model.sourceRows
        report.modelSortMS = try await measure {
            _ = TrackListModel.Prepared.make(source, order: .init(column: .artist, ascending: false))
        }
        return report
    }

    // MARK: - Helpers

    /// Lets SwiftUI and AppKit run their update passes until `done` holds (30 s cap).
    private func settle(_ host: NSView, until done: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        repeat {
            Self.pump(host)
            await Task.yield()
            if done() {
                // One more pass so trailing updates of the same change are counted.
                host.layoutSubtreeIfNeeded()
                host.window?.displayIfNeeded()
                return
            }
        } while clock.now < deadline
        throw XCTSkip("table did not settle within 30 s")
    }

    /// Runs update passes until three passes in a row are quick: the change is applied and the
    /// autorelease pools holding its discarded views are drained (120 s cap).
    private func settleQuiet(_ host: NSView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        var quiet = 0
        while quiet < 3 {
            guard clock.now < deadline else { throw XCTSkip("table did not settle within 120 s") }
            let start = clock.now
            Self.pump(host)
            await Task.yield()
            quiet = clock.now - start < .milliseconds(5) ? quiet + 1 : 0
        }
    }

    /// One AppKit pass: layout, display, and a turn of the run loop (SwiftUI's update observer).
    private static func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }

    private func measure(_ work: () async throws -> Void) async throws -> Double {
        let start = ContinuousClock.now
        try await work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Instances of a class whose `heap` name contains `needle`, alive in this process now
    /// (attached, in a reuse queue or waiting in an autorelease pool).
    static func liveObjects(matching needle: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").reduce(0) { total, line in
            guard line.contains(needle), !line.contains("NSKVONotifying"),
                  let count = Int(line.split(separator: " ").first ?? "") else { return total }
            return total + count
        }
    }

    static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = table(in: subview) { return table }
        }
        return nil
    }

    /// Hosting views of track cells attached to the window's view tree (shown or prepared).
    static func cellViews(in view: NSView) -> Int {
        let own = String(describing: type(of: view)).contains("TableCellHostingView") ? 1 : 0
        return view.subviews.reduce(own) { $0 + cellViews(in: $1) }
    }

    /// Library-shaped tracks: varied titles, artists, dates — a sort permutes most rows.
    static func tracks(_ count: Int) -> [Track] {
        (0..<count).map { index in
            let scrambled = (index &* 7_919) % count
            var track = Track(
                artist: "Artist \((index &* 31) % 997)",
                album: "Album \((index &* 17) % 1_499)",
                title: "Title \(scrambled)",
                format: index % 3 == 0 ? "flac" : "m4a",
                originalPath: "/orig/\(index).m4a"
            )
            track.id = Int64(index + 1)
            track.organizedPath = "A/\(index).m4a"
            track.duration = 120 + index % 300
            track.bpm = 80 + index % 90
            track.bitrate = 256
            track.genre = "Genre \(index % 40)"
            track.dateAddedLibrary = String(format: "2026-%02d-%02dT10:00:00Z", 1 + index % 12, 1 + index % 28)
            track.energyBucket = 1 + index % 5
            return track
        }
    }
}
