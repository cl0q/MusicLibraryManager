import SwiftUI

/// `New Library` (S-NEWLIB, DEC-034, UC-SHEET-01…05): name and location of the library file,
/// the final file name stated before creating, errors inline above the buttons (name taken,
/// location not writable) — the sheet never closes and then fails. From the picker `Create`
/// continues in the in-window setup; with a library open it leads to `Switch to “‹name›”?`
/// and nothing is created until that is confirmed.
struct NewLibrarySheet: View {
    let launch: LibraryLaunchCoordinator
    let defaultName: String

    @State private var name = ""
    @State private var directory: URL?
    @State private var error: NewLibraryError?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New Library")
                .font(.headline)
            Text("A library keeps its own tracks, playlists and settings. Audio files stay where they are.")
                .fixedSize(horizontal: false, vertical: true)
            LibraryFileFields(
                name: $name,
                directory: $directory,
                defaultDirectory: launch.store.librariesDirectory,
                rationale: "The default location is on this Mac, so the library opens even when no external drive is connected."
            )
            if let message = visibleError?.message {
                InlineProblem(message)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { launch.cancelNewLibrary() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || liveProblem != nil || isCreating)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 450)
        .onAppear { name = defaultName }
        .onChange(of: name) { _, _ in error = nil }
        .onChange(of: directory) { _, _ in error = nil }
        .newLibraryCheck(name: name, directory: directory, defaultDirectory: launch.store.librariesDirectory,
                         problem: $liveProblem)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Name taken / location not writable, checked while typing (empty is just disabled).
    @State private var liveProblem: NewLibraryError?

    private var visibleError: NewLibraryError? { error ?? liveProblem }

    private func create() {
        isCreating = true
        Task {
            error = await launch.createLibrary(named: trimmedName, in: directory)
            isCreating = false
        }
    }
}

extension View {
    /// Checks a new library's name and location while typing — debounced, off the main
    /// actor (file-system calls never run per keystroke on the main thread, review N5).
    func newLibraryCheck(
        name: String, directory: URL?, defaultDirectory: URL, problem: Binding<NewLibraryError?>
    ) -> some View {
        task(id: "\(name)\u{0}\(directory?.path ?? "")") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                problem.wrappedValue = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let folder = directory ?? defaultDirectory
            let result = await Task.detached(priority: .userInitiated) {
                LibraryLaunchCoordinator.newLibraryProblem(named: trimmed, in: folder)
            }.value
            guard !Task.isCancelled else { return }
            problem.wrappedValue = result
        }
    }
}

/// Name and location of a library file (S-NEWLIB.E02/N01/N02, V-SETUP.N01–N03).
struct LibraryFileFields: View {
    @Binding var name: String
    /// `nil` = the default folder.
    @Binding var directory: URL?
    let defaultDirectory: URL
    /// The one line about why the default location is the default.
    let rationale: String

    @State private var isChoosing = false

    var body: some View {
        Form {
            TextField("Name", text: $name)
            LabeledContent("Location") {
                HStack(spacing: Spacing.s) {
                    Picker("Location", selection: $directory) {
                        Text("MLM Libraries folder (default)").tag(URL?.none)
                        if let directory {
                            Text(directory.lastPathComponent).tag(URL?.some(directory))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button("Choose…") { isChoosing = true }
                }
            }
            .help(((directory ?? defaultDirectory).path as NSString).abbreviatingWithTildeInPath)
            Text("Saved as “\(LibraryPackage.fileName(forLibraryName: name))”. \(rationale)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.columns)
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { directory = url.standardizedFileURL }
        }
        .fileDialogMessage("Choose a folder for the library file.")
    }
}
