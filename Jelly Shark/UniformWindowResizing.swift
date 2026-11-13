#if os(visionOS)
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
            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard let window, let scene = window.windowScene else { return }
                // Uniform resizing keeps whatever shape the window already has,
                // so correct a restored non-16:9 window first. A size sent
                // unconditionally overrides `defaultSize` with whatever the
                // window measured when it first appeared. Width is kept so a
                // window the viewer already scaled stays roughly that size.
                let width = window.bounds.width
                let height = (width * 9 / 16).rounded()
                let size = abs(window.bounds.height - height) > 1 ? CGSize(width: width, height: height) : nil
                scene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
            }
        }
    }
#endif
