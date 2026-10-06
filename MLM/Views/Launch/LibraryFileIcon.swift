import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library-file icon (ICON-MLIBM variant A, DEC-033): the same static `.icns` the app
/// bundle registers for `.mlibm` files, so the picker, Open Recent and Finder agree. Identical
/// for every library — a library's state is always text, never drawn into the icon.
enum LibraryFileIcon {
    @MainActor
    static let nsImage: NSImage = {
        if let url = Bundle.module.url(forResource: "LibraryFile", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Without the resource (should not happen): the system's icon for the type.
        return NSWorkspace.shared.icon(for: LibraryFileType.contentType ?? .package)
    }()

    /// The icon at `size` points (32 in the picker, 16 in menus).
    @MainActor
    static func image(size: CGFloat) -> some View {
        Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// A 16 pt copy for menu items (menus draw `NSImage`s at their own size).
    @MainActor
    static let menuImage: NSImage = {
        let image = nsImage.copy() as? NSImage ?? nsImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }()
}

/// The `.mlibm` type for the system open panel (S-LIBFILE-OPEN, UC-SHEET-24).
enum LibraryFileType {
    /// `com.ilczuk.mlm.library` when the app bundle declares it (A0 D9); under `swift run`
    /// it doesn't exist and library files are folders.
    static var contentType: UTType? {
        guard let type = UTType("com.ilczuk.mlm.library"), type.conforms(to: .package) else { return nil }
        return type
    }

    /// Only library files can be chosen (folders without the declared type).
    static var importerTypes: [UTType] {
        contentType.map { [$0] } ?? [.folder]
    }

    /// UC-SHEET-25, verbatim.
    static let panelMessage = "Choose a library file."
}
