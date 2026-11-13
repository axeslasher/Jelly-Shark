#if os(visionOS)
    import OSLog
    import SwiftUI
    import UIKit

    extension View {
        /// Locks the hosting window to 16:9 and lets the viewer scale it
        /// uniformly only, matching Apple's TV app. SwiftUI's
        /// `WindowResizability` has no uniform mode, so this reaches the
        /// UIKit scene through a hidden background view.
        func uniformWindowResizing() -> some View {
            background(UniformWindowResizingAnchor())
        }
    }

    private struct UniformWindowResizingAnchor: UIViewRepresentable {
        func makeUIView(context _: Context) -> AnchorView {
            AnchorView()
        }

        func updateUIView(_: AnchorView, context _: Context) {}

        final class AnchorView: UIView {
            private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Window")

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard let window, let scene = window.windowScene else { return }
                // Uniform resizing keeps whatever shape the window has, so a
                // window that isn't 16:9 is corrected, keeping its width. A 16:9
                // window is sent no size, because one would override `defaultSize`.
                let width = window.bounds.width
                let height = (width * 9 / 16).rounded()
                let size = abs(window.bounds.height - height) > 1 ? CGSize(width: width, height: height) : nil
                scene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform)) { error in
                    Self.logger.error("Window geometry request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
#endif
