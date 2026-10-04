import Foundation

/// Decides at launch which library to open, before any database is touched.
///
/// Pure: all filesystem facts arrive in `Input`. Order of precedence:
/// 1. an interrupted adoption is finished first (A0 D7 invariant);
/// 2. a library file the user opened (double-click, Open Library…) wins;
/// 3. an old-style install is offered adoption (asked at every launch until done);
/// 4. otherwise the registry decides — first run, picker, unavailable, or open.
enum LibraryLaunchResolver {
    struct Input {
        var registry: LibraryRegistry
        /// The pre-A3 loose `music_library.db` is still in place.
        var legacyDatabaseExists: Bool
        /// An adoption journal exists, i.e. an adoption was interrupted.
        var adoptionInProgress: Bool
        var openedFileURL: URL?
        var availability: (URL) -> LibraryAvailability
    }

    enum Decision: Equatable {
        case resumeAdoption
        /// `libraryId` is the registry's id for the file, or `nil` if it isn't registered yet.
        case openPackage(URL, libraryId: String?)
        case offerAdoption
        /// No library anywhere: `New Library` sheet, then the first-run wizard.
        case createFirstLibrary
        /// `No library open` placeholder (picker is B1).
        case noLibrary
        case libraryUnavailable(LibraryRegistry.Entry, LibraryAvailability)
    }

    static func resolve(_ input: Input) -> Decision {
        if input.adoptionInProgress {
            return .resumeAdoption
        }
        if let opened = input.openedFileURL {
            return .openPackage(opened, libraryId: input.registry.entry(at: opened)?.libraryId)
        }
        if input.legacyDatabaseExists {
            return .offerAdoption
        }
        if input.registry.libraries.isEmpty {
            return .createFirstLibrary
        }
        guard input.registry.rememberLastLibrary, let last = input.registry.lastActiveEntry else {
            return .noLibrary
        }
        let availability = input.availability(last.url)
        guard availability == .available else {
            return .libraryUnavailable(last, availability)
        }
        return .openPackage(last.url, libraryId: last.libraryId)
    }
}
