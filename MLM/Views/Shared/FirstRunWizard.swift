import SwiftUI

/// First-run wizard for setting up the music library root.
///
/// Appears when no `library_root` has been configured in `app_config`.
/// Guides the user through selecting their music library folder,
/// then triggers an initial import scan.
///
/// ## Steps
/// 1. Welcome — Explain what MLM does
/// 2. Select Folder — Pick the library root via `NSOpenPanel`
/// 3. Scanning — Show import progress
/// 4. Done — Summary of imported tracks
struct FirstRunWizard: View {
    @Environment(\.container) private var container
    @State private var viewModel: ImportViewModel?
    @State private var step: WizardStep = .welcome
    @State private var selectedPath: String?
    @State private var isSelectingFolder = false
    @State private var importTask: Task<Void, Never>?

    /// Callback when the wizard completes (library root is set).
    var onComplete: () -> Void

    enum WizardStep {
        case welcome
        case selectFolder
        case scanning
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:
                welcomeStep
            case .selectFolder:
                selectFolderStep
            case .scanning:
                scanningStep
            case .done:
                doneStep
            }
        }
        .frame(width: 520, height: 420)
        .background(Color.mlmSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .onAppear {
            setupViewModel()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.mlmAccent, .mlmAccentBright],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 8) {
                Text("Welcome to MLM")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)

                Text("Music Library Manager")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
            }

            Text("To get started, point MLM at your music library folder.\nMLM will scan it for audio files and organize your collection.")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    step = .selectFolder
                }
            } label: {
                Text("Get Started")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmBase)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.mlmAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 60)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step 2: Select Folder

    private var selectFolderStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.mlmAccent)

            VStack(spacing: 8) {
                Text("Select Library Folder")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)

                Text("Choose the folder that contains your music files.\nMLM supports MP3, FLAC, AAC, M4A, OGG, WAV, AIFF, and ALAC.")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Selected path display
            if let path = selectedPath {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.mlmAccent)
                    Text(path)
                        .font(MLMFont.data)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.mlmRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    selectFolder()
                } label: {
                    Text(selectedPath == nil ? "Choose Folder..." : "Change Folder...")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(selectedPath == nil ? .mlmBase : .mlmInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedPath == nil ? Color.mlmAccent : Color.mlmRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if selectedPath != nil {
                    Button {
                        startImport()
                    } label: {
                        Text("Scan & Import")
                            .font(MLMFont.bodyBold)
                            .foregroundColor(.mlmBase)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.mlmAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step 3: Scanning

    private var scanningStep: some View {
        VStack(spacing: 24) {
            Spacer()

            if let progress = viewModel?.progress {
                VStack(spacing: 16) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(.mlmAccent)
                        .frame(width: 300)

                    Text(progress.phase)
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)

                    if progress.total > 0 {
                        Text("\(progress.processed) / \(progress.total) files")
                            .font(MLMFont.data)
                            .foregroundColor(.mlmInkSecondary)
                    }

                    if let currentFile = progress.currentFile {
                        Text(currentFile)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing...")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
            }

            Spacer()

            Button("Cancel") {
                importTask?.cancel()
                importTask = nil
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .selectFolder
                }
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.mlmSuccess)

            VStack(spacing: 8) {
                Text("Import Complete")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)

                if let result = viewModel?.lastResult {
                    VStack(spacing: 4) {
                        resultRow(
                            icon: "checkmark.circle",
                            color: .mlmSuccess,
                            text: "\(result.succeeded) tracks imported"
                        )

                        if result.skipped > 0 {
                            resultRow(
                                icon: "arrow.right.circle",
                                color: .mlmInkMuted,
                                text: "\(result.skipped) already in library"
                            )
                        }

                        if result.failed > 0 {
                            resultRow(
                                icon: "exclamationmark.triangle",
                                color: .mlmWarning,
                                text: "\(result.failed) failed"
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }

            if let error = viewModel?.errorMessage {
                Text(error)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmError)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Text("MLM will create folders like \"Downloads (SoundCloud)\" inside your library when you import from sources — see Settings → Library for details.")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("Open Library")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmBase)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.mlmAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 60)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Helpers

    private func resultRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
            Text(text)
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
    }

    private func setupViewModel() {
        guard let importService = container.importService,
              let configRepo = container.configRepository else { return }
        viewModel = ImportViewModel(
            importService: importService,
            configRepository: configRepo
        )
    }

    /// Open an NSOpenPanel to select the library root folder.
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Music Library Folder"
        panel.message = "Choose the root folder of your music library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
        }
    }

    /// Save library root and start the import.
    private func startImport() {
        guard let path = selectedPath else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            step = .scanning
        }

        importTask?.cancel()
        importTask = Task {
            await viewModel?.setLibraryRoot(path)
            await viewModel?.importLibrary()
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.3)) {
                step = .done
            }
            importTask = nil
        }
    }
}
