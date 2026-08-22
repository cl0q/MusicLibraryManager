import Foundation
import Testing
@testable import MLM

/// Tests for `SoundCloudDownloader.collapseDoubledAudioExtension`.
///
/// SCDL-02 / RESEARCH Pitfall 4: `scdl` can emit a doubled audio
/// container extension (e.g. `.m4a.m4a`). This pure static helper
/// collapses a trailing IDENTICAL extension pair to a single extension
/// and leaves everything else — including a stem containing an
/// unrelated dot, and a pair of two DIFFERENT audio extensions —
/// untouched. No I/O involved, so it is unit-testable directly.
struct SoundCloudDownloaderTests {

    @Test
    func collapsesDoubledM4A() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("song.m4a.m4a")
        #expect(result == "song.m4a")
    }

    @Test
    func collapsesDoubledFlac() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("track.flac.flac")
        #expect(result == "track.flac")
    }

    @Test
    func collapsesDoubledCaseInsensitive() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("Song.MP3.mp3")
        #expect(result.lowercased().hasSuffix(".mp3"))
        // Only one extension remains — no second ".mp3"/".MP3" suffix pair.
        #expect(!result.lowercased().hasSuffix(".mp3.mp3"))
        #expect(result == "Song.mp3")
    }

    @Test
    func leavesSingleExtensionUnchanged() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("song.m4a")
        #expect(result == "song.m4a")
    }

    @Test
    func leavesDotInStemUnchanged() {
        // A dot in the stem is not a doubled container extension.
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("my.song.opus")
        #expect(result == "my.song.opus")
    }

    @Test
    func leavesDifferentExtensionPairUnchanged() {
        // Two DIFFERENT audio extensions is not the observed .m4a.m4a
        // doubling symptom — do not guess a canonical one.
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("song.mp3.m4a")
        #expect(result == "song.mp3.m4a")
    }
}
