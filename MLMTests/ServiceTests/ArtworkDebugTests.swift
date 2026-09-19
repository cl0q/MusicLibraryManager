import Testing
import Foundation
@testable import MLM

@Suite("ArtworkDebugTests")
struct ArtworkDebugTests {
    @Test(.disabled("Environment-bound debug helper: requires /Volumes/Lexxar and crashes the full-suite runner (2026-09-04). Re-enable manually for artwork debugging."))
    func debugExtraction() async {
        let organizedPath = "00_Artists/Get down-Potatoheadz feat. Da Rook MC.m4a"
        let libraryRoot = "/Volumes/Lexxar/Music"
        
        let trackURL = URL(fileURLWithPath: libraryRoot).appendingPathComponent(organizedPath)
        print("--- DEBUG ARTWORK EXTRACTION ---")
        print("Track URL path: \(trackURL.path)")
        print("File exists: \(FileManager.default.fileExists(atPath: trackURL.path))")
        
        // Locate ffmpeg
        let ffmpeg = ProcessRunner.findExecutable("ffmpeg")
        print("ffmpeg executable path: \(String(describing: ffmpeg))")
        
        if let ffmpegPath = ffmpeg {
            let tmpOutput = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".jpg")
            print("Tmp output path: \(tmpOutput.path)")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-i", trackURL.path,
                "-an", "-vcodec", "mjpeg", "-vframes", "1",
                "-y", tmpOutput.path
            ]
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                print("ffmpeg exit code: \(process.terminationStatus)")
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                print("stdout length: \(stdoutData.count)")
                print("stderr length: \(stderrData.count)")
                if let stderrString = String(data: stderrData, encoding: .utf8), !stderrString.isEmpty {
                    print("--- ffmpeg stderr ---")
                    print(stderrString)
                }
                
                let fileExistsAfter = FileManager.default.fileExists(atPath: tmpOutput.path)
                print("Extracted cover exists: \(fileExistsAfter)")
                if fileExistsAfter {
                    let data = try Data(contentsOf: tmpOutput)
                    print("Extracted data size: \(data.count) bytes")
                    try? FileManager.default.removeItem(at: tmpOutput)
                }
            } catch {
                print("Process execution failed: \(error)")
            }
        }
        
        print("--- RUNNING STANDARD METHOD ---")
        if let data = await ArtworkService.extractEmbeddedArtwork(from: trackURL) {
            print("Standard extraction succeeded! Size: \(data.count) bytes")
        } else {
            print("Standard extraction returned nil!")
        }
        print("--------------------------------")
    }
}
