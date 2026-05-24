import Foundation
import Testing
@testable import MLM

struct SyncTurboLevelTests {

    @Test func testCoresFraction() {
        #expect(SyncTurboLevel.low.coresFraction == 0.6)
        #expect(SyncTurboLevel.medium.coresFraction == 0.8)
        #expect(SyncTurboLevel.full.coresFraction == 1.0)
    }

    @Test func testWorkerCountCalculation() {
        let totalCores = ProcessInfo.processInfo.activeProcessorCount
        
        let lowExpected = max(1, Int(round(Double(totalCores) * 0.6)))
        let mediumExpected = max(1, Int(round(Double(totalCores) * 0.8)))
        let fullExpected = max(1, Int(round(Double(totalCores) * 1.0)))

        #expect(SyncTurboLevel.low.workerCount() == lowExpected)
        #expect(SyncTurboLevel.medium.workerCount() == mediumExpected)
        #expect(SyncTurboLevel.full.workerCount() == fullExpected)
    }

    @Test func testIdentifiableConformance() {
        #expect(SyncTurboLevel.low.id == "60%")
        #expect(SyncTurboLevel.medium.id == "80%")
        #expect(SyncTurboLevel.full.id == "100%")
    }
}
