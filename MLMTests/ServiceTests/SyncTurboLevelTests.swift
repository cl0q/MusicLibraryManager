import Foundation
import Testing
@testable import MLM

struct SyncTurboLevelTests {

    @Test func testCoresFraction() {
        #expect(SyncTurboLevel.conservative.coresFraction == 0.6)
        #expect(SyncTurboLevel.standard.coresFraction == 0.8)
        #expect(SyncTurboLevel.fast.coresFraction == 1.0)
    }

    @Test func testWorkerCountCalculation() {
        let totalCores = ProcessInfo.processInfo.activeProcessorCount
        
        let conservativeExpected = max(1, Int(round(Double(totalCores) * 0.6)))
        let standardExpected = max(1, Int(round(Double(totalCores) * 0.8)))
        let fastExpected = max(1, Int(round(Double(totalCores) * 1.0)))

        #expect(SyncTurboLevel.conservative.workerCount() == conservativeExpected)
        #expect(SyncTurboLevel.standard.workerCount() == standardExpected)
        #expect(SyncTurboLevel.fast.workerCount() == fastExpected)
    }

    @Test func testIdentifiableConformance() {
        #expect(SyncTurboLevel.conservative.id == "60%")
        #expect(SyncTurboLevel.standard.id == "80%")
        #expect(SyncTurboLevel.fast.id == "100%")
    }
}
