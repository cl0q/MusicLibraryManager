import SwiftUI
import UniformTypeIdentifiers

/// Custom spring-loaded hover modifier.
///
/// When an active drag of `UTType.trackDrag` hovers over the element,
/// a visual blinking/pulsing outline overlay is displayed, and a timer is started.
/// If the hover remains continuous for 600ms, the `onTrigger` closure is invoked
/// to trigger the navigation routing action.
struct SpringLoadableHover: ViewModifier {
    let onTrigger: () -> Void
    
    @State private var isTargeted = false
    @State private var timer: Timer? = nil
    @State private var pulse = false
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(pulse ? 0.3 : 0.8)
                        .scaleEffect(pulse ? 1.01 : 0.99)
                        .animation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true), value: pulse)
                        .onAppear {
                            DispatchQueue.main.async {
                                pulse = true
                            }
                        }
                        .onDisappear {
                            pulse = false
                        }
                }
            }
            .onDrop(of: [.trackDrag], isTargeted: $isTargeted) { _ in
                // Return false to not consume the drop operation, allowing it to pass through
                // to the actual playlist drop destinations.
                return false
            }
            .onChange(of: isTargeted) { _, targeted in
                if targeted {
                    // Hover started: start timer for 600ms (0.6 seconds)
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                        Task { @MainActor in
                            onTrigger()
                        }
                    }
                } else {
                    // Hover ended: cancel timer
                    timer?.invalidate()
                    timer = nil
                }
            }
    }
}

extension View {
    /// Enables spring-loaded hover navigation when a track is dragged over the view.
    ///
    /// - Parameter onTrigger: The closure to execute when the hover duration exceeds 600ms.
    func springLoadableHover(onTrigger: @escaping () -> Void) -> some View {
        modifier(SpringLoadableHover(onTrigger: onTrigger))
    }
}
