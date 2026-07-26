import Foundation
import JellyfinKit

/// Which genre card a remembered backdrop belongs to.
///
/// `libraryId` is optional deliberately. Home's genre shelves are always
/// scoped to a library, but a genre shelf on a media detail page (#108) has no
/// library to scope to — keying on `String?` lets that case store alongside
/// these without a format migration.
struct GenreBackdropKey: Hashable, Sendable {
    var libraryId: String?
    var genre: String

    /// Flattened form used as the dictionary key in `UserDefaults`. The unit
    /// separator can't occur in a library id or a genre name, so a real genre
    /// like "Action/Adventure" can't be confused with a library boundary.
    var storageKey: String {
        "\(libraryId ?? "")\u{1F}\(genre)"
    }
}

/// A genre card's remembered face: the artwork it borrows, plus what the card
/// needs to redraw it and to cycle cheaply.
struct GenreBackdropSelection: Codable, Equatable, Sendable {
    /// The item that owns the image. Not necessarily the item that matched the
    /// genre — `backdropSlot(for:)` falls back to an ancestor's backdrop.
    var itemId: String
    /// `ImageType`'s raw value; the enum has no `Codable` conformance. A value
    /// this build can't map back re-rolls, same as any other unusable entry.
    var imageTypeRawValue: String
    var blurHash: String?
    /// How many items the genre had when this was chosen, so the first cycle
    /// after a relaunch can still pick a random offset without spending a
    /// request to learn the pool size. A stale count just lands on an empty
    /// page, which falls back to a re-roll of the first page.
    var poolCount: Int?

    var imageType: ImageType? {
        ImageType(rawValue: imageTypeRawValue)
    }
}

/// Remembers which item's backdrop stands in for each genre card, so returning
/// to a genre shelf costs no request and shows the same face it showed before.
///
/// `UserDefaults`-backed rather than SwiftData (#24): the whole payload is a
/// map of a few dozen `(library, genre) → item` entries, which doesn't justify
/// blocking on the caching architecture — and migrating a small string map
/// into it later is trivial. Injectable for tests like `HomePreferences`, but
/// reached through `shared` in the app because genre cards are built deep
/// inside Home's shelves with no owner to hand them an instance.
@MainActor
final class GenreBackdropStore {
    static let shared = GenreBackdropStore()

    private static let storageKey = "genreBackdropSelections"

    private let defaults: UserDefaults
    private var selections: [String: GenreBackdropSelection]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selections = Self.decode(defaults.data(forKey: Self.storageKey))
    }

    func selection(for key: GenreBackdropKey) -> GenreBackdropSelection? {
        selections[key.storageKey]
    }

    /// Store a choice, or clear it with `nil`. Writes the whole map — it is
    /// tens of short strings, so there's nothing to gain from a finer write.
    func setSelection(_ selection: GenreBackdropSelection?, for key: GenreBackdropKey) {
        selections[key.storageKey] = selection
        guard let encoded = try? JSONEncoder().encode(selections) else { return }
        defaults.set(encoded, forKey: Self.storageKey)
    }

    /// A payload written by a different (future or corrupted) shape reads as
    /// empty rather than throwing: every card then re-rolls, which is exactly
    /// the cold-start path.
    private static func decode(_ data: Data?) -> [String: GenreBackdropSelection] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: GenreBackdropSelection].self, from: data)
        else { return [:] }
        return decoded
    }
}
