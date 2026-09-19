import Testing
import Foundation

/// Source-scan tests verifying that AudioPlayer's LUFS compensation
/// is gated behind the "playback_lufs_normalization" UserDefaults flag
/// and defaults to unity gain (0 dB) when the flag is off.
@Suite("LufsNormalizationGateTests")
struct LufsNormalizationGateTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent() // ServiceTests
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - UserDefaults gate key

    @Test
    func applyLUFSCompensation_readsPlaybackLufsNormalizationKey() throws {
        let src = try readSource("MLM/Services/Audio/AudioPlayer.swift")
        #expect(src.contains("\"playback_lufs_normalization\""),
                "applyLUFSCompensation must read the 'playback_lufs_normalization' UserDefaults key")
    }

    // MARK: - Default-off: unity gain fallback

    @Test
    func applyLUFSCompensation_defaultsToUnityGain_whenNormalizationOff() throws {
        let src = try readSource("MLM/Services/Audio/AudioPlayer.swift")
        // The method must check the flag and fall back to setGain(dB: 0)
        // when the flag is false (default).
        #expect(src.contains("guard enabled else"),
                "applyLUFSCompensation must early-return when normalization is disabled")
        #expect(src.contains("setGain(dB: 0)"),
                "applyLUFSCompensation must set unity gain (0 dB) when normalization is off")
    }

    // MARK: - Enabled path preserves LUFS formula

    @Test
    func applyLUFSCompensation_appliesLUFSFormula_whenEnabled() throws {
        let src = try readSource("MLM/Services/Audio/AudioPlayer.swift")
        // The -14 LUFS target and +6 dB boost cap must still be present
        // for when the user opts in.
        #expect(src.contains("-14.0"),
                "applyLUFSCompensation must retain the -14 LUFS target for the enabled path")
        #expect(src.contains("6.0"),
                "applyLUFSCompensation must retain the +6 dB boost cap for the enabled path")
    }

    // MARK: - Initial gain state

    @Test
    func gainNode_initialGainIsZero() throws {
        let src = try readSource("MLM/Services/Audio/AudioPlayer.swift")
        #expect(src.contains("gainNode.globalGain = 0"),
                "gainNode.globalGain must be initialized to 0 dB (unity) in setupEngine")
    }
}
