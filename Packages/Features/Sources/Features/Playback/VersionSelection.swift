import JellyfinKit
import SwiftUI

// MARK: - Playback Request

/// What a play surface hands the full-screen player cover: the item plus the
/// version the viewer picked, if any (#147). One value carries both, so a
/// launch can never pair a stale version choice with a different item.
struct PlaybackRequest: Identifiable, Equatable {
    let item: MediaItem

    /// The chosen media source; nil plays the server default
    var mediaSourceId: String?

    var id: String {
        item.id
    }
}

// MARK: - Picker Policy

/// How a play surface should offer an item's versions.
enum VersionPickerPresentation: Equatable {
    /// Fewer than two versions: no picker, the surface behaves as it always has
    case none

    /// Long-press context menu on the Play control; a plain press plays the
    /// default version
    case menu

    /// A plain press asks first, every time ("Ask before playing" mode)
    case alert
}

enum VersionPicker {
    /// tvOS alerts stack their buttons full screen; past this many versions
    /// the alert reads badly, so ask mode falls back to the long-press menu.
    static let alertVersionCap = 4

    static func presentation(sourceCount: Int, asksBeforePlaying: Bool) -> VersionPickerPresentation {
        guard sourceCount > 1 else { return .none }
        if asksBeforePlaying, sourceCount <= alertVersionCap {
            return .alert
        }
        return .menu
    }
}

// MARK: - Alert Target

/// The pending ask-before-playing choice, captured at press time — the item
/// that will play and the versions on offer. Captured rather than re-read at
/// selection time so a marquee auto-advance under the alert cannot redirect
/// the choice to another page's item.
struct VersionAlertTarget {
    let item: MediaItem
    let sources: [MediaSource]
}

// MARK: - Shared Presentation

extension View {
    /// Attach the "Select Version" long-press menu to a Play control. Gated
    /// like `shelfContextMenu`: when inactive the control keeps its pre-menu
    /// long-press behavior exactly, rather than owning an empty menu.
    @ViewBuilder
    func versionSelectMenu(
        sources: [MediaSource],
        isActive: Bool,
        onSelect: @escaping (MediaSource) -> Void,
    ) -> some View {
        if isActive {
            contextMenu {
                Section("Select Version") {
                    ForEach(sources) { source in
                        Button {
                            onSelect(source)
                        } label: {
                            Text(source.versionLabel)
                            if let detail = source.versionDetail {
                                Text(detail)
                            }
                        }
                    }
                }
            }
        } else {
            self
        }
    }

    /// Present the ask-before-playing alert for the captured target (#147
    /// mode 2). Dismissing without a choice plays nothing.
    func versionSelectAlert(
        target: Binding<VersionAlertTarget?>,
        onPlay: @escaping (PlaybackRequest) -> Void,
    ) -> some View {
        alert(
            "Select Version",
            isPresented: Binding(
                get: { target.wrappedValue != nil },
                set: {
                    if !$0 {
                        target.wrappedValue = nil
                    }
                },
            ),
            presenting: target.wrappedValue,
        ) { alertTarget in
            ForEach(alertTarget.sources) { source in
                Button(source.versionLabel) {
                    onPlay(PlaybackRequest(item: alertTarget.item, mediaSourceId: source.id))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
