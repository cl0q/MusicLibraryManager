import Foundation

/// The only folders MLM creates inside a library root for imported audio.
/// Directories are created by the download finalizer, never during app launch.
enum ManagedLibraryLayout {
    static let soundCloudDownloads = "Downloads (SoundCloud)"
    static let youtubeDownloads = "Downloads (YouTube)"
    static let transcodeOriginals = "Transcode originals"

    static let folderNames = [
        soundCloudDownloads,
        youtubeDownloads,
        transcodeOriginals,
    ]

    static func isManagedFolder(_ url: URL, libraryRoot: URL?) -> Bool {
        guard let libraryRoot else { return false }
        let relative = url.standardizedFileURL.path
            .replacingOccurrences(of: libraryRoot.standardizedFileURL.path + "/", with: "")
        return folderNames.contains(relative)
    }
}
