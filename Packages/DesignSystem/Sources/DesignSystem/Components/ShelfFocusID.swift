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
