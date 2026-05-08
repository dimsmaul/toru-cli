import SwiftUI
import AppKit

/// Reaches the underlying `NSWindow` from inside SwiftUI and applies a one-shot
/// configuration block. Used to enable a transparent titlebar / full-size content
/// view so the frosted background extends edge-to-edge.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Apply transparent-titlebar styling required for the HUD-style appearance.
    /// Frosted background itself is rendered by `VisualEffectBackground` placed
    /// in the SwiftUI hierarchy at the root, with `.ignoresSafeArea()` so it
    /// extends under the titlebar.
    func configureToruWindow() -> some View {
        background(
            WindowConfigurator { window in
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.isMovableByWindowBackground = true
            }
        )
    }
}
