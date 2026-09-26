import Foundation
import Testing
@testable import MLM

@Suite("LOGIC-001 artwork replacement atomicity")
struct ArtworkReplaceAtomicityTests {

    @Test func failedReplacementPreservesOriginalAudio() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("original.m4a")
        let generatedURL = directory.appendingPathComponent("generated.m4a")
        let original = Data("original audio".utf8)
        try original.write(to: originalURL)
        try Data("artwork embedded audio".utf8).write(to: generatedURL)

        let replaced = ArtworkService.replaceArtworkOutput(
            generatedURL,
            into: originalURL,
            replaceItem: { _, _ in throw ReplaceFailure.injected }
        )

        #expect(!replaced)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(try Data(contentsOf: originalURL) == original)
        #expect(!FileManager.default.fileExists(atPath: generatedURL.path))
    }

    @Test func successfulReplacementUsesGeneratedAudio() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("original.m4a")
        let generatedURL = directory.appendingPathComponent("generated.m4a")
        try Data("original audio".utf8).write(to: originalURL)
        let generated = Data("artwork embedded audio".utf8)
        try generated.write(to: generatedURL)

        #expect(ArtworkService.replaceArtworkOutput(generatedURL, into: originalURL))
        #expect(try Data(contentsOf: originalURL) == generated)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkReplaceAtomicityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private enum ReplaceFailure: Error {
        case injected
    }
}
