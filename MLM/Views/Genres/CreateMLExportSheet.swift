import SwiftUI
import UniformTypeIdentifiers

/// **Export Create ML Training Set…** (`s-export`, ST-STUDIO-EXPORT, DEC-044): what qualifies,
/// where it goes, what is skipped, how long it runs — then `Export n Tracks` hands the work to
/// Activity (`Create ML export · ‹folder›`, Cancel After This File) and the sheet closes
/// (UC-SHEET-07). The result is said in the status bar with `Show in Finder`; Activity keeps it.
/// Writes only into the chosen folder; library files are only read.
///
/// Opened from Genres ▸ More and File ▸ Export ▸ Create ML Training Set… (same sheet).
struct CreateMLExportSheet: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(\.openSettings) private var openSettings

    @AppStorage(CreateMLExporter.destinationKey) private var destinationPath = ""
    @AppStorage(CreateMLExporter.minimumKey) private var minimumTracks = CreateMLExportPlan.defaultMinimum

    @State private var tracks: [Track]?
    @State private var loadFailed = false
    @State private var choosingFolder = false
    @State private var showsLeftOut = false
    @State private var freeBytes: Int64?

    private var destination: URL? {
        destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath, isDirectory: true)
    }

    private var plan: CreateMLExportPlan? {
        tracks.map { CreateMLExportPlan.make(tracks: $0, minimumTracks: minimumTracks) }
    }

    private var workers: Int { BatchControl.workerCount(turboMode: false) }

    var body: some View {
        let plan = self.plan
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Create ML Training Set")
                .font(.headline)
                .padding([.horizontal, .top], Spacing.l)
            Form {
                Section {
                    Text("Copies the tracks of every genre that is large enough into one folder per genre — ‹Genre›/‹Artist› - ‹Title›.m4a — ready to train a sound classifier in Apple’s Create ML.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent {
                        Button("Choose…") { choosingFolder = true }
                    } label: {
                        Text("Destination")
                        Text(destinationLine)
                            .truncationMode(.middle)
                    }
                    LabeledContent {
                        TextField("Minimum tracks per genre", value: $minimumTracks, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                    } label: {
                        Text("Minimum tracks per genre")
                        Text("Smaller genres are left out — a classifier needs enough examples of each.")
                    }
                    LabeledContent("Format", value: "AAC 248 kbps (.m4a)")
                    LabeledContent {
                        Button("Change…") { openSettings(tab: .maintenance) }
                    } label: {
                        Text("Speed")
                        Text("\(workers == 1 ? "1 file" : "\(workers) files") at a time — the Background processing setting.")
                    }
                }
                if let plan {
                    Section {
                        LabeledContent("Included", value: "\(GenreText.genres(plan.included.count)) · \(StatusBarText.tracks(plan.includedTrackCount))")
                            .monospacedDigit()
                        LabeledContent("Left out", value: "\(GenreText.genres(plan.leftOut.count)) · \(StatusBarText.tracks(plan.leftOutTrackCount))")
                            .monospacedDigit()
                        if !plan.leftOut.isEmpty {
                            DisclosureGroup("Left-out genres (\(plan.leftOut.count))", isExpanded: $showsLeftOut) {
                                Text("These genres have too few tracks. Merge Genres… can combine spelling variants so they qualify.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(plan.leftOut.map { "\($0.name) \($0.trackCount)" }.joined(separator: " · "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } footer: {
                        Text(Self.warning(plan))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if loadFailed {
                    Section {
                        Text("Can’t read the genres — the library database didn’t answer.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .formStyle(.grouped)
            footer(plan)
        }
        .frame(minWidth: 560, idealWidth: 580, minHeight: 520)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { destinationPath = url.path }
        }
        .fileDialogMessage("Choose a folder for the Create ML training set")
        .fileDialogConfirmationLabel("Choose")
        .task {
            guard let repository = GenreRepository.live(container) else { return }
            do {
                tracks = try await repository.tracksWithGenre()
            } catch {
                loadFailed = true
            }
        }
        .task(id: destinationPath) { freeBytes = Self.freeSpace(at: destination) }
    }

    private var destinationLine: String {
        guard let destination else { return "No folder chosen" }
        let path = (destination.path as NSString).abbreviatingWithTildeInPath
        guard let freeBytes else { return path }
        return "\(path) · \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free"
    }

    // MARK: Footer

    private func footer(_ plan: CreateMLExportPlan?) -> some View {
        let problem = problem(plan)
        let count = plan?.items.count ?? 0
        return VStack(alignment: .leading, spacing: Spacing.s) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Runs in Activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Export 1 Track" : "Export \(count.formatted(.number)) Tracks") { export(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || count == 0 || destination == nil)
            }
        }
        .padding(Spacing.l)
    }

    /// Why the export can't start now (UC-SHEET-05: inline, above the buttons).
    private func problem(_ plan: CreateMLExportPlan?) -> String? {
        let drive = LibraryDriveState.current(container)
        if drive.isOffline {
            return "Can’t export now — “\(drive.volumeName ?? "the library disk")” is not connected."
        }
        if CreateMLExporter.shared.isRunning { return "An export is running. Wait for it to finish, or cancel it in Activity." }
        guard let plan, destination != nil else { return nil }
        if let freeBytes, plan.estimatedBytes > freeBytes {
            return "Not enough space — the export needs about \(Self.size(plan.estimatedBytes)), \(Self.size(freeBytes)) are free."
        }
        return nil
    }

    static func warning(_ plan: CreateMLExportPlan) -> String { plan.warning }

    static func size(_ bytes: Int64) -> String { CreateMLExportPlan.size(bytes) }

    static func freeSpace(at url: URL?) -> Int64? {
        guard let url else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Export

    private func export(_ plan: CreateMLExportPlan?) {
        guard let plan, let destination, problem(plan) == nil, !plan.items.isEmpty else { return }
        let statusBar = self.statusBar
        CreateMLExporter.shared.run(plan, into: destination, writer: .live(container), workers: workers) { summary in
            // After Activity's own end message: the result with the way to the files.
            statusBar?.post(summary.sentence, actions: [
                StatusAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) },
            ])
        }
        dismiss()
    }
}
