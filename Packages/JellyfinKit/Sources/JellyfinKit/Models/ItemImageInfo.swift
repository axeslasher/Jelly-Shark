import Foundation

/// Metadata for one image an item carries on the server (GET
/// /Items/{itemId}/Images) — the pixel dimensions callers need to judge
/// whether an image can fill a large slot before requesting it.
public struct ItemImageInfo: Sendable, Equatable, Hashable {
    public let imageType: ImageType

    /// Pixel width of the stored image (nil when the server doesn't know)
    public let width: Int?

    /// Pixel height of the stored image (nil when the server doesn't know)
    public let height: Int?

    public init(imageType: ImageType, width: Int? = nil, height: Int? = nil) {
        self.imageType = imageType
        self.width = width
        self.height = height
    }
}
