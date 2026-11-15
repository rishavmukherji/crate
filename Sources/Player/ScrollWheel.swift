#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Reports trackpad / mouse-wheel scrolling over the window, in covers (positive = toward the start).
    func onScrollWheel(_ action: @escaping (Double) -> Void) -> some View {
        modifier(ScrollWheelModifier(action: action))
    }
}

private struct ScrollWheelModifier: ViewModifier {
    let action: (Double) -> Void
    @State private var monitor: Any?

    /// Trackpad points that move the flow by one cover.
    private static var pointsPerCover: Double { 40 }

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    let horizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                    let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                    guard delta != 0 else { return event }
                    if event.hasPreciseScrollingDeltas {
                        action(delta / Self.pointsPerCover)
                    } else {
                        // Notched mouse wheel: one notch, one cover.
                        action(delta > 0 ? 1 : -1)
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#endif
