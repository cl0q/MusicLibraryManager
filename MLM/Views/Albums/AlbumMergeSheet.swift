import SwiftUI

/// **Merge with Another Album…** (S-ALB-MERGE, IMP-094, DEC-041): the album picker, `Merge as` —
/// the same album, or another edition with its name — and the consequence in numbers before the
/// button. One undo step (`Merge Albums`). Possible duplicates are not decided here; Review ▸
/// Duplicates lists them.
struct AlbumMergeSheet: View {
    let albumID: Int64
    let albumTitle: String
    let albumArtist: String

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(ShellActions.self) private var shell: ShellActions?

    private enum Kind: Hashable { case same, edition }

    @State private var query: String
    @State private var selection: AlbumCandidate?
    @State private var kind = Kind.same
    @State private var editionName = ""
    /// The name last offered; a name the person changed is not replaced by the next offer.
    @State private var offeredName = ""
    @State private var plan: AlbumMergePlan?
    @State private var nameIsTaken = false
    @State private var isMerging = false
    @State private var failure: String?

    init(albumID: Int64, albumTitle: String, albumArtist: String) {
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        _query = State(initialValue: albumTitle)
    }

    private var trimmedName: String { editionName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var mode: AlbumMergeMode { kind == .same ? .sameAlbum : .edition(name: trimmedName) }

    /// The sentence above the buttons that says why Merge is off, if it is.
    private var problem: String? {
        guard selection != nil, kind == .edition else { return nil }
        if trimmedName.isEmpty { return AlbumMergeText.editionNameRequired }
        if nameIsTaken { return AlbumMergeText.editionNameTaken(trimmedName) }
        return nil
    }

    private var canMerge: Bool { selection != nil && problem == nil && plan != nil && !isMerging }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(AlbumMergeText.title(albumTitle))
                .font(.headline)
            Form {
                Section {
                    AlbumPicker(reference: AlbumPickReference(title: albumTitle, albumArtist: albumArtist), excludingGroupOf: albumID,
                                preselectsSameAlbum: true, query: $query, selection: $selection)
                }
                Section {
                    Picker(AlbumMergeText.mergeAs, selection: $kind) {
                        Text(AlbumMergeText.sameAlbumTitle).tag(Kind.same)
                        Text(AlbumMergeText.editionTitle).tag(Kind.edition)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if kind == .edition {
                        TextField(AlbumMergeText.editionNameLabel, text: $editionName)
                    }
                } header: {
                    Text(AlbumMergeText.mergeAs)
                } footer: {
                    if let selection, let plan {
                        Text(AlbumMergeText.consequence(plan: plan, mode: mode, this: albumTitle, other: selection.album.title))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Choose the album to merge with.")
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .padding(.top, Spacing.l)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 620)
        .task(id: selection?.id) { await refresh() }
        .task(id: editionName) { await checkName() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let message = failure ?? problem {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AlbumMergeText.button) { merge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMerge)
            }
        }
        .padding([.horizontal, .bottom], Spacing.l)
    }

    // MARK: Work

    /// A new choice: the numbers, and the edition name offered for it.
    private func refresh() async {
        failure = nil
        guard let selection, let repository = container.albumRepository else {
            plan = nil
            return
        }
        plan = try? await repository.mergePlan(into: albumID, from: selection.id)
        if editionName.isEmpty || editionName == offeredName {
            offeredName = AlbumMergeText.editionNameDefault(this: albumTitle, other: selection.album.title)
            editionName = offeredName
        }
        await checkName()
    }

    private func checkName() async {
        guard let selection, kind == .edition, !trimmedName.isEmpty, let repository = container.albumRepository else {
            nameIsTaken = false
            return
        }
        nameIsTaken = (try? await repository.editionNameIsTaken(trimmedName, forAlbum: selection.id)) ?? false
    }

    private func merge() {
        guard canMerge, let selection, let edits = shell?.edits else { return }
        isMerging = true
        failure = nil
        let mode = self.mode
        Task {
            do {
                try await edits.mergeAlbums(into: albumID, from: selection.id, mode: mode)
                dismiss()
            } catch let error as AlbumMergeError where error == .editionNameTaken {
                nameIsTaken = true
                isMerging = false
            } catch {
                failure = "Couldn’t merge the albums — the library database didn’t answer. Nothing was changed."
                isMerging = false
            }
        }
    }
}
