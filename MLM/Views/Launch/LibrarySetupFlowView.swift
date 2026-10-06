import SwiftUI

/// First-run setup step 1 (V-SETUP, DEC-034, THOUGHTS §7.18): in the window, no overlay —
/// name and location of the library file. Replaces the scrim wizard (S-WIZARD) and the
/// first-run use of the New Library sheet. From `Create Library` on a library exists and the
/// remaining steps can be skipped.
struct FirstRunSetupView: View {
    let launch: LibraryLaunchCoordinator

    @State private var name = LibraryPickerRows.legacyName
    @State private var directory: URL?
    @State private var error: NewLibraryError?
    @State private var isCreating = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var liveProblem: NewLibraryError? {
        trimmedName.isEmpty ? nil : launch.newLibraryProblem(named: trimmedName, in: directory)
    }

    var body: some View {
        SetupColumn(step: 1, title: "Create your library",
                    lead: "A library keeps its own tracks, playlists and settings in one library file. Audio files stay where they are.") {
            LibraryFileFields(
                name: $name,
                directory: $directory,
                defaultDirectory: launch.store.librariesDirectory,
                rationale: "The default location is on this Mac, so the library opens even when your music drive isn’t connected. You can move the file in Finder later."
            )
            if let message = (error ?? liveProblem)?.message {
                InlineProblem(message)
            }
        } footer: {
            Button("Open Other…") { launch.chooseLibraryFile() }
            Spacer()
            Button("Create Library") {
                isCreating = true
                Task {
                    error = await launch.createLibrary(named: trimmedName, in: directory)
                    isCreating = false
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedName.isEmpty || liveProblem != nil || isCreating)
        }
        .onChange(of: name) { _, _ in error = nil }
    }
}

/// Setup steps 2 and 3 and the result, for a library that was just created (V-SETUP).
struct LibrarySetupStepsView: View {
    let model: LibrarySetupModel
    let launch: LibraryLaunchCoordinator

    var body: some View {
        switch model.stage {
        case .folder:
            FolderStep(model: model, launch: launch)
        case .importing:
            ImportStep(model: model, launch: launch)
        case .finished(let outcome):
            SetupDone(model: model, outcome: outcome, launch: launch)
        }
    }
}

// MARK: - Step 2: library folder

private struct FolderStep: View {
    let model: LibrarySetupModel
    let launch: LibraryLaunchCoordinator

    @State private var isChoosing = false
    @State private var isTargeted = false

    var body: some View {
        SetupColumn(step: 2, title: "Where is your music?",
                    lead: "Choose the folder that contains your audio files — for example a folder on an external drive. MLM reads MP3, FLAC, AAC, M4A, OGG, WAV, AIFF and ALAC.") {
            dropZone
            if let problem = model.problem {
                InlineProblem(problem)
            }
            Text("MLM will create folders like “Downloads (SoundCloud)” inside this folder when you import from sources. Your existing files are not moved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Set Up Later") { launch.endSetup() }
            Spacer()
            if case .notConnected = model.reachability {
                Button("Scan When Connected") {
                    Task {
                        await model.scanWhenConnected()
                        if model.problem == nil { launch.endSetup() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Scan and Import") { Task { await model.scanAndImport() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConnected)
                    .help(isConnected ? "Scan the folder and import its music" : "Choose your music folder first.")
            }
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
        .fileDialogMessage("Choose the folder that contains your music.")
    }

    private var isConnected: Bool {
        if case .connected = model.reachability { return true }
        return false
    }

    /// D-WIZ-FOLDERDROP: drop a folder from Finder, or use the button.
    private var dropZone: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let folder = model.folder {
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                reachabilityLine
            } else {
                Text("Drop your music folder here")
            }
            Button(model.folder == nil ? "Choose Folder…" : "Choose Another Folder…") { isChoosing = true }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: isTargeted ? [] : [5, 4]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.choose(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music folder")
    }

    @ViewBuilder
    private var reachabilityLine: some View {
        if let text = model.reachabilityText {
            switch model.reachability {
            case .notConnected(let volume)?:
                VStack(spacing: Spacing.xxs) {
                    Label(text, systemImage: "externaldrive.badge.xmark")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange, .primary)
                    Text("MLM remembers the folder and scans it when “\(volume)” is connected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .missing?:
                Label(text, systemImage: "questionmark.folder")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
            default:
                Label(text, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 3: scan and import

private struct ImportStep: View {
    let model: LibrarySetupModel
    let launch: LibraryLaunchCoordinator

    var body: some View {
        SetupColumn(step: 3, title: title,
                    lead: "You can start using MLM now; tracks appear in All Tracks as they are imported.") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                let progress = model.importer?.progress
                HStack {
                    Text(progress?.phase ?? "Preparing…")
                    Spacer()
                    if let progress, progress.total > 0 {
                        Text("\(progress.processed.formatted(.number)) of \(progress.total.formatted(.number)) files")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let progress, progress.total > 0 {
                    ProgressView(value: progress.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let file = progress?.currentFile {
                    Text(file)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(Spacing.m)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } footer: {
            Button("Stop") { model.stop() }
                .help("Keeps what is already imported")
            Spacer()
            Button("Continue in Background") { launch.endSetup() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var title: String {
        guard let folder = model.folder else { return "Scanning your music" }
        let place = LibraryPickerRows.volumeName(of: folder).map { "on \($0)" } ?? "on this Mac"
        return "Scanning “\(folder.lastPathComponent)” \(place)"
    }
}

// MARK: - Result

private struct SetupDone: View {
    let model: LibrarySetupModel
    let outcome: LibrarySetupModel.Outcome
    let launch: LibraryLaunchCoordinator

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("“\(model.libraryName)” is ready")
                .font(.title3.bold())
            result
            HStack(spacing: Spacing.xxs) {
                Text("Downloads from sources go into folders MLM creates inside your library folder — see")
                Button("Settings ▸ Library") { openSettings(tab: .library) }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Done") { launch.endSetup() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var result: some View {
        switch outcome {
        case .imported(let tracks, let skipped):
            HStack(spacing: Spacing.xs) {
                Text(skipped > 0
                     ? "Imported \(tracks.formatted(.number)) \(tracks == 1 ? "track" : "tracks") · \(skipped.formatted(.number)) skipped"
                     : "Imported \(tracks.formatted(.number)) \(tracks == 1 ? "track" : "tracks")")
                    .monospacedDigit()
                Button("Show") { ActivityRouter.shared.requestWindow(tab: .operations) }
                    .buttonStyle(.link)
            }
        case .stopped(let imported, let total):
            Text("Stopped — imported \(imported.formatted(.number)) of \(total.formatted(.number)) files. Scan again any time from Library ▸ Scan Library Folder.")
                .multilineTextAlignment(.center)
        case .failed(let message):
            Text("The import didn’t finish — \(message) Scan again any time from Library ▸ Scan Library Folder.")
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Shared layout

/// The setup's centred column: `Step n of 3`, heading, lead, content, footer buttons.
private struct SetupColumn<Content: View, Footer: View>: View {
    let step: Int
    let title: String
    let lead: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Step \(step) of 3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.title2.bold())
                    Text(lead)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
                HStack(spacing: Spacing.s) { footer }
                    .controlSize(.large)
                    .padding(.top, Spacing.xs)
            }
            .frame(maxWidth: 540)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One sentence where the problem happened (UC-SHEET-05/17).
struct InlineProblem: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.orange, .primary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
