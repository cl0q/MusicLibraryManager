import SwiftUI

/// Non-blocking toast shown when Rockbox smart-defaults are applied (D-03).
///
/// GREENFIELD — no existing toast component in MLM.
/// Overlay on SyncView root, auto-dismisses after 3 seconds.
/// UI-SPEC Surface 12.
///
/// Standard message: "Rockbox iPod erkannt — Device-Defaults aktiviert"
struct SyncToast: View {
    let message: String
    var isShowing: Bool

    var body: some View {
        if isShowing {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.mlmSuccess)
                    .frame(width: 4)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.mlmSuccess)
                    .font(.system(size: 14))
                Text(message)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                Spacer()
            }
            .frame(height: 44)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: isShowing)
        }
    }
}
