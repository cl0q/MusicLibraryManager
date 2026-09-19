import Foundation

/// A playlist entry in the library manifest (schema=1).
struct ManifestPlaylist: Codable, Identifiable, Equatable, Hashable {
    let uuid: String
    let name: String
    let file: String

    var id: String { uuid }
}
