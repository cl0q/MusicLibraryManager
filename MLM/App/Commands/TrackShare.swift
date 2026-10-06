import SwiftUI
import UniformTypeIdentifiers

/// One track's file as something the share sheet can send (UC-KIT-19). The file is looked up
/// when the user picks a service, so the menu needs no disk access to be built.
struct ShareableTrackFile: Transferable {
    struct FileNotFound: Error {}
    let track: Track

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { item in
            guard let url = await TrackFileLocator.localURL(for: item.track, container: .shared) else { throw FileNotFound() }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }
}

/// Which tracks `Share…` sends and why it can be off — pure, so the rules are tested.
enum TrackShare {
    /// Tracks whose file can be used now: Local, and not on a disk that is away.
    static func reachable(_ tracks: [Track], offlineVolumePath: String?) -> [Track] {
        tracks.filter { track in
            guard track.isLocal else { return false }
            guard let volume = offlineVolumePath else { return true }
            return !TrackRowBuilder.fileLocation(track.organizedPath).isOnVolume(volume)
        }
    }

    /// The help of a disabled `Share…` (UC-COPY-13).
    static func disabledReason(count: Int, unreachable: Int) -> String {
        if count == 0 { return "Select tracks to share." }
        if unreachable > 0 { return "Can’t share — the library’s drive is not connected." }
        return count == 1 ? "Can’t share — the track isn’t downloaded." : "Can’t share — none of the tracks is downloaded."
    }
}

/// `Share…` (Track menu and track context menu): the system share sheet over the files of the
/// selection; disabled with its reason when no file can be used.
struct TrackShareItem: View {
    let tracks: [Track]
    let reason: String

    var body: some View {
        ShareLink(items: tracks.map(ShareableTrackFile.init), preview: { SharePreview($0.track.title) }) {
            Text(MenuCommand.share.title)
        }
        .disabled(tracks.isEmpty)
        .help(tracks.isEmpty ? reason : "")
    }
}
