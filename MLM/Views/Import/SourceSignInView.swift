import SwiftUI

// MARK: - Account problems in place (S-SRC-OAUTH, A-SRC-KEYCHAIN, DEC-004, F-20)

/// A source account that needs the user, shown where it blocks (import sheet, Add from Link):
/// `Sign-in expired · Reconnect`, `Disconnected · Connect`, the keychain line with `Allow…`, and
/// — once the browser is open — the waiting state with `Cancel` / `Open Browser Again`
/// (S-SRC-OAUTH, in the place that asked). On success `onSignedIn` repeats the interrupted
/// step; the chosen playlist or link is kept.
struct SourceAccountProblemView: View {
    let service: TokenStorage.Service
    let state: SourceAccountState
    let accounts: any SourceAccountStateReading
    /// The sentence under the title (`SoundCloud asked MLM to sign in again. …`).
    var message: String? = nil
    var compact = false
    var onSignedIn: () -> Void = {}

    @State private var signIn: SourceSignInModel?
    @Environment(StatusBarCenter.self) private var statusBar

    private var name: String { service.displayName }

    var body: some View {
        Group {
            if let signIn, signIn.phase != .idle, signIn.phase != .succeeded {
                SourceSignInWaitingView(model: signIn, compact: compact, retry: start)
            } else {
                problem
            }
        }
    }

    @ViewBuilder
    private var problem: some View {
        switch state {
        case .keychainLocked:
            block(symbol: "lock", title: "Sign-in expired",
                  text: "MLM needs your permission to read the saved sign-in.",
                  button: "Allow…") {
                Task {
                    if await accounts.allowKeychainAccess(service) { onSignedIn() }
                }
            }
        case .signInExpired:
            block(symbol: "person.crop.circle.badge.exclamationmark", title: compact ? "Sign-in expired (\(name))" : "Sign-in expired",
                  text: message ?? "\(name) asked MLM to sign in again. Your imported playlists and tracks are not affected.",
                  button: "Reconnect", action: start)
        case .disconnected:
            block(symbol: "person.crop.circle", title: "Disconnected",
                  text: message ?? "Connect your \(name) account to see its playlists.",
                  button: "Connect", action: start)
        case .connected, .notAvailable:
            EmptyView()
        }
    }

    private func start() {
        let model = signIn ?? SourceSignInModel(service: service, accounts: accounts, post: { [statusBar] in statusBar.post($0) })
        signIn = model
        model.start(onSuccess: onSignedIn)
    }

    @ViewBuilder
    private func block(symbol: String, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        if compact {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.orange).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(button, action: action)
            }
        } else {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(text)
            } actions: {
                Button(button, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// `Waiting for ‹Source› in your browser…` with `Cancel` and `Open Browser Again`; after 5
/// minutes `Sign-in wasn’t finished · Try Again`. No primary button (UC-SHEET-04).
struct SourceSignInWaitingView: View {
    let model: SourceSignInModel
    var compact = false
    let retry: () -> Void

    var body: some View {
        switch model.phase {
        case .waiting:
            content(progress: true, title: model.waitingText, text: SourceSignInModel.waitingDetail) {
                Button("Cancel") { model.cancel() }
                Button("Open Browser Again", action: retry)
            }
        case .timedOut:
            content(progress: false, title: SourceSignInModel.timedOutText, text: nil) {
                Button("Try Again", action: retry)
            }
        case .failed(let cause):
            content(progress: false, title: SourceSignInModel.timedOutText, text: cause) {
                Button("Try Again", action: retry)
            }
        case .idle, .succeeded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func content<Buttons: View>(progress: Bool, title: String, text: String?,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        if compact {
            HStack(alignment: .top, spacing: 10) {
                if progress { ProgressView().controlSize(.small).frame(width: 20) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    if let text { Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                buttons()
            }
        } else {
            VStack(spacing: 8) {
                if progress { ProgressView().controlSize(.small) }
                Text(title).font(.headline)
                if let text { Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                HStack { buttons() }.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}
