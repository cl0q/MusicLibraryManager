import Foundation
import AVFoundation
import Vision
import Cocoa

// Helper to run OCR and print sizes
func analyzeReel(url: URL) async {
    print("Analyzing Reel: \(url.lastPathComponent)")
    let asset = AVURLAsset(url: url)
    guard let durationTime = try? await asset.load(.duration) else {
        print("Failed to load duration.")
        return
    }
    let duration = CMTimeGetSeconds(durationTime)
    print("Duration: \(duration)s")
    
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    
    // Sample at 3 points (30%, 50%, 70%)
    let percentages = [0.3, 0.5, 0.7]
    
    for pct in percentages {
        let offset = duration * pct
        let time = CMTime(seconds: offset, preferredTimescale: 600)
        print("\n--- Keyframe at \(String(format: "%.1f", offset))s (\(Int(pct * 100))%) ---")
        
        do {
            let (cgImage, _) = try await generator.image(at: time)
            
            // Run Vision OCR
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    print("  No text observations found.")
                    return
                }
                
                print("  Observations found: \(observations.count)")
                for (idx, obs) in observations.enumerated() {
                    let candidates = obs.topCandidates(3)
                    let text = candidates.first?.string ?? ""
                    let box = obs.boundingBox
                    print(String(format: "  [%02d] Text: \"%@\"", idx + 1, text))
                    print(String(format: "       Box: x=%.4f, y=%.4f, w=%.4f, h=%.4f", box.origin.x, box.origin.y, box.size.width, box.size.height))
                }
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["de-DE", "en-US"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            
        } catch {
            print("  Failed to extract image at \(offset)s: \(error)")
        }
    }
}

let fileURL = URL(fileURLWithPath: "/Volumes/Lexxar/Music/07_reels/58199bdddfe04f5eaf4f1b10bd769dba.MP4")

let sema = DispatchSemaphore(value: 0)
Task {
    await analyzeReel(url: fileURL)
    sema.signal()
}
sema.wait()
