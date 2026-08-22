import SwiftUI
import AppKit

/// A modal sheet prompting the user for a playlist name, creating it in the database,
/// and adding the currently selected track IDs to it.
struct NewPlaylistFromSelectionSheet: View {
    let trackIds: Set<Int64>
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    
    @State private var playlistName = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil
    
    @FocusState private var isNameFocused: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Text("New playlist")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("Enter a name for the new playlist. The \(trackIds.count) selected track\(trackIds.count == 1 ? "" : "s") will be added automatically.")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
            
            TextField("Playlist name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .font(MLMFont.body)
                .focused($isNameFocused)
                .onSubmit {
                    if !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        createPlaylist()
                    }
                }
            
            if let errorMessage {
                Text(errorMessage)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button {
                    createPlaylist()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(trackIds.count == 1 ? "Add 1 track" : "Add \(trackIds.count) tracks")
                    }
                }
                .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 400)
        .background(Color.mlmSurface)
        .onAppear {
            isNameFocused = true
        }
    }
    
    private func createPlaylist() {
        guard let playlistRepo = container.playlistRepository else {
            errorMessage = "Playlist repository is not available."
            return
        }
        
        let trimmedName = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        isSubmitting = true
        errorMessage = nil
        
        Task {
            do {
                let playlist = try await playlistRepo.create(name: trimmedName)
                guard let playlistId = playlist.id else {
                    throw NSError(domain: "NewPlaylistSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to resolve new playlist ID."])
                }
                
                let trackIdsArray = Array(trackIds)
                let startPos = String(format: "%06d", 999000)
                try await playlistRepo.addTracks(
                    playlistId: playlistId,
                    trackIds: trackIdsArray,
                    startPosition: startPos
                )
                
                NotificationCenter.default.post(
                    name: .playlistDidChange,
                    object: nil,
                    userInfo: ["playlistId": playlistId]
                )
                
                await MainActor.run {
                    isSubmitting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// A modal sheet prompting the user for a sync profile name and destination output directory,
/// creating it in the database, and adding the currently selected track IDs to it.
struct NewSyncProfileFromSelectionSheet: View {
    let trackIds: Set<Int64>
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    
    @State private var profileName = ""
    @State private var outputFolder = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil
    
    @FocusState private var isNameFocused: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Text("New Sync Profile")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("Create a new sync profile. The \(trackIds.count) selected track\(trackIds.count == 1 ? "" : "s") will be added directly.")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkSecondary)
                
                TextField("For example, Walkman or USB drive", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                    .font(MLMFont.body)
                    .focused($isNameFocused)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Output folder")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkSecondary)
                
                HStack {
                    TextField("No folder selected", text: $outputFolder)
                        .textFieldStyle(.roundedBorder)
                        .font(MLMFont.body)
                        .disabled(true)
                    
                    Button("Browse...") {
                        selectFolder()
                    }
                }
            }
            
            if let errorMessage {
                Text(errorMessage)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button {
                    createSyncProfile()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(trackIds.count == 1 ? "Add 1 track" : "Add \(trackIds.count) tracks")
                    }
                }
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || outputFolder.isEmpty || isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 450)
        .background(Color.mlmSurface)
        .onAppear {
            isNameFocused = true
        }
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        
        if panel.runModal() == .OK {
            if let path = panel.url?.path {
                outputFolder = path
            }
        }
    }
    
    private func createSyncProfile() {
        guard let syncVM = container.syncViewModel else {
            errorMessage = "Sync is unavailable."
            return
        }
        
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && !outputFolder.isEmpty else { return }
        
        isSubmitting = true
        errorMessage = nil
        
        Task {
            do {
                // Creates profile, loads profiles and sets selectedProfile in the VM
                await syncVM.createProfile(name: trimmedName, outputFolder: outputFolder)
                
                // Let's verify we successfully created and selected a profile
                guard let profile = syncVM.selectedProfile, profile.id != nil else {
                    throw NSError(domain: "NewSyncProfileSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to resolve new sync profile ID."])
                }
                
                let trackIdsArray = Array(trackIds)
                await syncVM.addTracks(trackIdsArray)
                
                await MainActor.run {
                    isSubmitting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// Identifiable wrapper for track selections, used for robust sheet presentations in SwiftUI.
struct TrackSelectionContainer: Identifiable {
    let id = UUID()
    let trackIds: Set<Int64>
}
