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
import JellyfinKit

/// Menu copy for burn-in subtitle tracks: "English (PGS)" rather than
/// Jellyfin's technical DisplayTitle ("English - Default - PGSSUB")
enum BurnInSubtitleLabel {
    /// Codec identifiers mapped to the names people know them by
    private static let formatNames: [String: String] = [
        "pgssub": "PGS",
        "pgs": "PGS",
        "dvdsub": "VobSub",
        "dvbsub": "DVB",
        "xsub": "XSUB",
    ]

    static func title(for stream: MediaStreamInfo) -> String {
        let language = stream.language
            .flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            ?? stream.language
            ?? stream.displayTitle
            ?? "Track \(stream.index)"

        guard let codec = stream.codec?.lowercased() else {
            return language
        }
        let format = formatNames[codec] ?? codec.uppercased()
        return "\(language) (\(format))"
    }
}
