// Copyright 2026 Justin Lascelle
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
@testable import JellyfinKit
import Testing

@Suite("MediaItem user-data updates")
struct MediaItemUserDataTests {
    private func item(userData: UserData?) -> MediaItem {
        MediaItem(id: "item-1", name: "Item", type: .movie, userData: userData)
    }

    @Test("Marking played clears resume progress and the unwatched count")
    func settingPlayedClearsProgress() {
        let updated = item(userData: UserData(
            playbackPositionTicks: 5_000_000_000,
            playCount: 1,
            isFavorite: true,
            played: false,
            unplayedItemCount: 4,
        )).settingPlayed(true)

        #expect(updated.userData?.played == true)
        #expect(updated.userData?.playbackPositionTicks == nil)
        #expect(updated.userData?.unplayedItemCount == 0)
        // Untouched flags survive the copy
        #expect(updated.userData?.isFavorite == true)
        #expect(updated.userData?.playCount == 1)
    }

    @Test("Marking unplayed clears progress and hides the unwatched count until refresh")
    func settingUnplayedClearsProgress() {
        let updated = item(userData: UserData(
            playbackPositionTicks: 5_000_000_000,
            played: true,
            unplayedItemCount: 0,
        )).settingPlayed(false)

        #expect(updated.userData?.played == false)
        #expect(updated.userData?.playbackPositionTicks == nil)
        // The real count of newly-unwatched children isn't known locally
        #expect(updated.userData?.unplayedItemCount == nil)
    }

    @Test("Setting played on an item without user data creates it")
    func settingPlayedWithoutUserData() {
        let updated = item(userData: nil).settingPlayed(true)

        #expect(updated.userData?.played == true)
        #expect(updated.userData?.isFavorite == false)
    }

    @Test("Setting favorite flips only the favorite flag")
    func settingFavoriteLeavesTheRestAlone() {
        let updated = item(userData: UserData(
            playbackPositionTicks: 5_000_000_000,
            playCount: 2,
            isFavorite: false,
            played: true,
            unplayedItemCount: 3,
        )).settingFavorite(true)

        #expect(updated.userData?.isFavorite == true)
        #expect(updated.userData?.played == true)
        #expect(updated.userData?.playbackPositionTicks == 5_000_000_000)
        #expect(updated.userData?.playCount == 2)
        #expect(updated.userData?.unplayedItemCount == 3)

        let reverted = updated.settingFavorite(false)
        #expect(reverted.userData?.isFavorite == false)
    }
}
