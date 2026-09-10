import SwiftUI

/// Identifies one card on one shelf, for focus restoration.
///
/// The row matters: a media item can appear on several shelves at once
/// (Continue Watching and Recently Added, say), and keying focus on the
/// item alone would bind every copy to the same value (#236 § 11).
public struct ShelfFocusID: Hashable, Sendable {
    public let row: String
    public let item: String

    public init(row: String, item: String) {
        self.row = row
        self.item = item
    }
}

/// `.focused` takes a non-optional binding, so an optional one needs a
/// branch. The arms are different view types (`ViewModifier.body` is a
/// result-builder context), so callers must pass both `binding` and `id`
/// — or neither — and keep that constant for the card's life. Flipping it
/// on a mounted card rebuilds the subtree and drops focus (#236 § 3).
struct OptionalShelfFocus: ViewModifier {
    let binding: FocusState<ShelfFocusID?>.Binding?
    let id: ShelfFocusID?

    func body(content: Content) -> some View {
        if let binding, let id {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}
