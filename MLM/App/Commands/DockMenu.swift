import AppKit

// MARK: - Dock menu (M-DOCK, UC-DOCK-01)

/// The Dock menu's items, in order (UC-DOCK-01): the now-playing line as a disabled header
/// (`Not playing` when idle), Play / Pause, Next, Previous, then `Open Recent` with the other
/// known libraries and their state. The system appends its own items. Pure, so it is tested
/// without AppKit.
struct DockMenuModel: Equatable {
    enum Action: Equatable {
        case playPause
        case next
        case previous
        case openLibrary(URL)
    }

    struct Item: Equatable {
        let title: String
        /// `nil`: a header line (always disabled).
        let action: Action?
        let isEnabled: Bool
        var isSeparator = false

        static let separator = Item(title: "", action: nil, isEnabled: false, isSeparator: true)
    }

    struct RecentLibrary: Equatable {
        let title: String
        let url: URL
        let isAvailable: Bool
    }

    let items: [Item]

    static let notPlaying = "Not playing"

    init(nowPlaying: (title: String, artist: String)?, isPlaying: Bool, recents: [RecentLibrary]) {
        let hasTrack = nowPlaying != nil
        var items: [Item] = []
        let header: String
        if let nowPlaying {
            header = nowPlaying.artist.isEmpty ? nowPlaying.title : "\(nowPlaying.title) — \(nowPlaying.artist)"
        } else {
            header = Self.notPlaying
        }
        items.append(Item(title: header, action: nil, isEnabled: false))
        items.append(Item(title: isPlaying ? "Pause" : "Play", action: .playPause, isEnabled: hasTrack))
        items.append(Item(title: "Next", action: .next, isEnabled: hasTrack))
        items.append(Item(title: "Previous", action: .previous, isEnabled: hasTrack))
        if !recents.isEmpty {
            items.append(.separator)
            items.append(Item(title: "Open Recent", action: nil, isEnabled: false))
            for recent in recents {
                items.append(Item(title: recent.title, action: .openLibrary(recent.url), isEnabled: recent.isAvailable))
            }
        }
        self.items = items
    }

    static func == (lhs: DockMenuModel, rhs: DockMenuModel) -> Bool { lhs.items == rhs.items }
}

/// Builds the `NSMenu` for `applicationDockMenu(_:)` from the live player and library list.
@MainActor
enum DockMenuBuilder {
    static func model(container: DependencyContainer, launch: LibraryLaunchCoordinator) -> DockMenuModel {
        let playback = container.playbackViewModel
        let nowPlaying = playback?.currentTrack.map { (title: $0.title, artist: $0.artist) }
        let recents = launch.recentLibraries.map { recent in
            DockMenuModel.RecentLibrary(
                title: LibraryFooter.recentTitle(recent),
                url: recent.entry.url,
                isAvailable: recent.availability == .available
            )
        }
        return DockMenuModel(nowPlaying: nowPlaying, isPlaying: playback?.isPlaying == true, recents: recents)
    }

    /// The menu; each item calls `perform(_:)` on `target` with the item's action.
    static func menu(_ model: DockMenuModel, target: DockMenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in model.items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: item.action == nil ? nil : #selector(DockMenuTarget.performDockItem(_:)), keyEquivalent: "")
            menuItem.isEnabled = item.isEnabled
            if let action = item.action {
                menuItem.target = target
                menuItem.representedObject = DockMenuTarget.Box(action)
            }
            menu.addItem(menuItem)
        }
        return menu
    }
}

/// Receives the Dock menu's clicks and runs them on the shared player / library coordinator.
@MainActor
final class DockMenuTarget: NSObject {
    final class Box: NSObject {
        let action: DockMenuModel.Action
        init(_ action: DockMenuModel.Action) { self.action = action }
    }

    @objc func performDockItem(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? Box)?.action else { return }
        let playback = DependencyContainer.shared.playbackViewModel
        switch action {
        case .playPause:
            playback?.togglePlayPause()
        case .next:
            Task { await playback?.next() }
        case .previous:
            Task { await playback?.back() }
        case .openLibrary(let url):
            MainWindowPresenter.shared.openLibrary(url, launch: .shared)
        }
    }
}
