import XCTest
@testable import MLMMobile

final class ManifestDecodingTests: XCTestCase {

    /// Exact schema fixture from IOS_SIDECAR_PLAN.md §3.
    private let fixtureJSON = """
    {
      "schema": 1,
      "profile": "iPhone",
      "generated_at": "2026-09-04T12:00:00Z",
      "tracks": [
        {
          "uuid": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
          "title": "Test Song",
          "artist": "Test Artist",
          "album_artist": "Test Album Artist",
          "album": "Test Album",
          "duration": 254,
          "path": "Test Artist/Test Album/Test Song.m4a",
          "energy_bucket": 3,
          "lufs_i": -14.2
        },
        {
          "uuid": "B2C3D4E5-F6A7-8901-BCDE-F12345678901",
          "title": "Chill Track",
          "artist": "Ambient Artist",
          "album_artist": "Ambient Artist",
          "album": "Ambient Album",
          "duration": 180,
          "path": "Ambient Artist/Ambient Album/Chill Track.mp3",
          "energy_bucket": 1,
          "lufs_i": -20.5
        }
      ],
      "playlists": [
        { "uuid": "P1-UUID", "name": "Workout", "file": "Workout.m3u8" },
        { "uuid": "P2-UUID", "name": "Chill", "file": "Chill.m3u8" }
      ]
    }
    """

    func testDecodesManifestSchema1() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)

        XCTAssertEqual(manifest.schema, 1)
        XCTAssertEqual(manifest.profile, "iPhone")
        XCTAssertEqual(manifest.generatedAt, "2026-09-04T12:00:00Z")
        XCTAssertEqual(manifest.tracks.count, 2)
        XCTAssertEqual(manifest.playlists.count, 2)
    }

    func testDecodesTrackFields() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
        let track = manifest.tracks[0]

        XCTAssertEqual(track.uuid, "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
        XCTAssertEqual(track.title, "Test Song")
        XCTAssertEqual(track.artist, "Test Artist")
        XCTAssertEqual(track.albumArtist, "Test Album Artist")
        XCTAssertEqual(track.album, "Test Album")
        XCTAssertEqual(track.duration, 254)
        XCTAssertEqual(track.path, "Test Artist/Test Album/Test Song.m4a")
        XCTAssertEqual(track.energyBucket, 3)
        XCTAssertEqual(track.lufsI, -14.2)
    }

    func testDecodesPlaylistFields() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
        let playlist = manifest.playlists[0]

        XCTAssertEqual(playlist.uuid, "P1-UUID")
        XCTAssertEqual(playlist.name, "Workout")
        XCTAssertEqual(playlist.file, "Workout.m3u8")
    }

    func testTrackFormattedDuration() {
        let track = ManifestTrack(
            uuid: "test",
            title: "T",
            artist: "A",
            albumArtist: "AA",
            album: "Al",
            duration: 254,
            path: "p",
            energyBucket: 3,
            lufsI: -14.0
        )
        XCTAssertEqual(track.formattedDuration, "4:14")
    }

    func testTrackFormattedDurationZero() {
        let track = ManifestTrack(
            uuid: "test",
            title: "T",
            artist: "A",
            albumArtist: "AA",
            album: "Al",
            duration: 0,
            path: "p",
            energyBucket: 1,
            lufsI: -20.0
        )
        XCTAssertEqual(track.formattedDuration, "0:00")
    }

    func testRejectsMissingRequiredField() {
        let json = """
        {
          "schema": 1,
          "profile": "Test",
          "generated_at": "2026-01-01T00:00:00Z",
          "tracks": [
            {
              "uuid": "x",
              "title": "T",
              "artist": "A",
              "album_artist": "AA",
              "album": "Al",
              "duration": 100,
              "path": "p",
              "energy_bucket": 2
            }
          ],
          "playlists": []
        }
        """
        let data = json.data(using: .utf8)!
        // lufs_i is required per schema — decoding should fail without it.
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryManifest.self, from: data))
    }

    func testRoundTripEncodeDecode() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let original = try JSONDecoder().decode(LibraryManifest.self, from: data)
        let reEncoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LibraryManifest.self, from: reEncoded)
        XCTAssertEqual(original, decoded)
    }
}
