import Foundation
import JellyfinAPI

extension Chapter {
    /// Build from the SDK DTO at its position in the server's chapter array,
    /// rejecting entries without a usable start position. The index is kept
    /// even when siblings are dropped — it keys the chapter image endpoint
    /// and the "Chapter N" name fallback.
    init?(from dto: JellyfinAPI.ChapterInfo, index: Int) {
        guard let startTicks = dto.startPositionTicks, startTicks >= 0 else {
            return nil
        }

        let trimmedName = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            name: trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)",
            startTicks: Int64(startTicks),
            imageIndex: index,
            imageTag: dto.imageTag,
        )
    }

    /// Map the server's chapter array, dropping malformed entries while
    /// preserving each survivor's original position
    static func chapters(from dtos: [JellyfinAPI.ChapterInfo]) -> [Chapter] {
        dtos.enumerated().compactMap { index, dto in
            Chapter(from: dto, index: index)
        }
    }
}
