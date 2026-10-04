import Testing
import Foundation
@testable import MLM

/// A3 Wave 1: pure launch decision — which library (if any) to open at launch
/// (A0 D4/D5/D7, Step-0 decisions 1, 6, 9).
@Suite("LibraryLaunchResolver (A3 Wave 1)")
struct LibraryLaunchResolverTests {

    private let mainURL = URL(fileURLWithPath: "/lib/Main Library.mlibm")
    private let devURL = URL(fileURLWithPath: "/Volumes/Disk/Dev.mlibm")

    private func registry(lastActive: String? = "main", remember: Bool = true) -> LibraryRegistry {
        var registry = LibraryRegistry(rememberLastLibrary: remember)
        registry.upsert(libraryId: "main", url: mainURL, name: "Main Library")
        registry.upsert(libraryId: "dev", url: devURL, name: "Dev")
        registry.lastActiveLibraryId = lastActive
        return registry
    }

    private func resolve(
        registry: LibraryRegistry = LibraryRegistry(),
        legacy: Bool = false,
        adoptionInProgress: Bool = false,
        opened: URL? = nil,
        availability: LibraryAvailability = .available
    ) -> LibraryLaunchResolver.Decision {
        LibraryLaunchResolver.resolve(.init(
            registry: registry,
            legacyDatabaseExists: legacy,
            adoptionInProgress: adoptionInProgress,
            openedFileURL: opened,
            availability: { _ in availability }
        ))
    }

    @Test func interruptedAdoptionResumesFirst() {
        #expect(resolve(registry: registry(), legacy: true, adoptionInProgress: true, opened: devURL) == .resumeAdoption)
    }

    @Test func openedRegisteredFileOpensWithItsId() {
        #expect(resolve(registry: registry(), opened: devURL) == .openPackage(devURL, libraryId: "dev"))
    }

    @Test func openedUnregisteredFileOpensWithoutId() {
        let other = URL(fileURLWithPath: "/tmp/Other.mlibm")
        #expect(resolve(registry: registry(), opened: other) == .openPackage(other, libraryId: nil))
    }

    @Test func openedFileWinsOverPendingLegacyAndRememberOff() {
        #expect(resolve(registry: registry(remember: false), legacy: true, opened: devURL)
                == .openPackage(devURL, libraryId: "dev"))
    }

    @Test func legacyInstallIsOfferedAdoption() {
        #expect(resolve(legacy: true) == .offerAdoption)
        #expect(resolve(registry: registry(), legacy: true) == .offerAdoption)
    }

    @Test func emptyRegistryStartsFirstLibraryCreation() {
        #expect(resolve() == .createFirstLibrary)
    }

    @Test func rememberOffShowsNoLibrary() {
        #expect(resolve(registry: registry(remember: false)) == .noLibrary)
    }

    @Test func noLastActiveShowsNoLibrary() {
        #expect(resolve(registry: registry(lastActive: nil)) == .noLibrary)
        #expect(resolve(registry: registry(lastActive: "deleted-id")) == .noLibrary)
    }

    @Test func lastActiveAvailableIsOpened() {
        #expect(resolve(registry: registry()) == .openPackage(mainURL, libraryId: "main"))
    }

    @Test func lastActiveNotFoundIsReported() {
        let decision = resolve(registry: registry(), availability: .notFound)
        #expect(decision == .libraryUnavailable(registry().entry(withId: "main")!, .notFound))
    }

    @Test func lastActiveNotConnectedIsReported() {
        let decision = resolve(registry: registry(lastActive: "dev"), availability: .notConnected)
        #expect(decision == .libraryUnavailable(registry().entry(withId: "dev")!, .notConnected))
    }

    @Test func availabilityIsCheckedForTheLastActiveEntryOnly() {
        var checked: [URL] = []
        _ = LibraryLaunchResolver.resolve(.init(
            registry: registry(),
            legacyDatabaseExists: false,
            adoptionInProgress: false,
            openedFileURL: nil,
            availability: { checked.append($0); return .available }
        ))
        #expect(checked == [mainURL])
    }
}
