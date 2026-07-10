import Foundation
import SoundAnalysis
import CoreML

do {
    // Check if SNAnalyzeAudioFeaturePrintRequest exists and can be initialized
    let request = try SNAnalyzeAudioFeaturePrintRequest()
    print("Successfully initialized SNAnalyzeAudioFeaturePrintRequest!")
} catch {
    print("Error initializing request: \(error)")
}
