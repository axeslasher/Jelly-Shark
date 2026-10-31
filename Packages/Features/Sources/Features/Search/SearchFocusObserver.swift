#if os(tvOS)
    import os
    import SwiftUI
    import UIKit

    /// Reports every tvOS focus move as which part of Search it left and
    /// which part it entered (#340).
    ///
    /// SwiftUI can't see this on its own. The keyboard and suggestions belong
    /// to the system search controller, so no `@FocusState` changes when
    /// focus goes from a result to the sidebar and back to the keyboard, and
    /// `searchFocused` is unavailable on tvOS. UIKit's focus notification
    /// does see it. Measured on the simulator: the results sit inside the
    /// content's own hosting controller, the keyboard and suggestions inside
    /// the `UISearchController`'s view, and the sidebar outside both.
    struct SearchFocusObserver: UIViewRepresentable {
        enum Zone {
            /// The results (or the idle screen's seed pills).
            case results
            /// The system keyboard and suggestions.
            case searchField
            /// Anywhere else, such as the sidebar.
            case outside
        }

        let onMove: (_ from: Zone, _ to: Zone) -> Void

        func makeUIView(context _: Context) -> FocusZoneView {
            let view = FocusZoneView()
            view.isUserInteractionEnabled = false
            view.onMove = onMove
            return view
        }

        func updateUIView(_ view: FocusZoneView, context _: Context) {
            view.onMove = onMove
        }

        final class FocusZoneView: UIView {
            private static let logger = Logger(subsystem: "com.justinlascelle.jellyshark", category: "Search")

            var onMove: ((Zone, Zone) -> Void)?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                let center = NotificationCenter.default
                center.removeObserver(self, name: UIFocusSystem.didUpdateNotification, object: nil)
                guard window != nil else { return }
                // A selector, not a block: the block form is `@Sendable`, so it
                // can't read the main-actor focus context. UIKit posts focus
                // updates on the main thread, and the center doesn't retain `self`.
                center.addObserver(
                    self,
                    selector: #selector(focusDidUpdate(_:)),
                    name: UIFocusSystem.didUpdateNotification,
                    object: nil,
                )
            }

            @objc private func focusDidUpdate(_ note: Notification) {
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                report(from: context?.previouslyFocusedItem, to: context?.nextFocusedItem)
            }

            private func report(from previous: UIFocusItem?, to next: UIFocusItem?) {
                let from = zone(of: previous)
                let to = zone(of: next)
                guard from != to else { return }
                Self.logger.debug("focus zone \(String(describing: from), privacy: .public) → \(String(describing: to), privacy: .public)")
                onMove?(from, to)
            }

            private func zone(of item: UIFocusItem?) -> Zone {
                guard let view = item.flatMap(Self.view(of:)) else { return .outside }
                if let content = nearestController(where: { _ in true })?.view, view.isDescendant(of: content) {
                    return .results
                }
                if let search = nearestController(where: { $0 is UISearchController })?.view, view.isDescendant(of: search) {
                    return .searchField
                }
                return .outside
            }

            private func nearestController(where matches: (UIViewController) -> Bool) -> UIViewController? {
                var responder: UIResponder? = self
                while let current = responder {
                    if let controller = current as? UIViewController, matches(controller) {
                        return controller
                    }
                    responder = current.next
                }
                return nil
            }

            /// The view that hosts a focus item; SwiftUI's items aren't views.
            private static func view(of item: UIFocusItem) -> UIView? {
                var environment: UIFocusEnvironment? = item
                while let current = environment {
                    if let view = current as? UIView {
                        return view
                    }
                    environment = current.parentFocusEnvironment
                }
                return nil
            }
        }
    }
#endif
