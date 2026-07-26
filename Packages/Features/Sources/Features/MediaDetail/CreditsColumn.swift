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

import DesignSystem
import SwiftUI

/// Director / Starring credit stacks, list-formatted so separators and
/// conjunctions follow the locale ("A, B, and C"). Renders nothing when both
/// name lists are empty.
struct CreditsColumn: View {
    let directorNames: [String]
    let castNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            if !directorNames.isEmpty {
                CreditEntry(
                    label: directorNames.count > 1 ? "Directed by" : "Director",
                    value: directorNames.formatted(.list(type: .and)),
                )
            }
            if !castNames.isEmpty {
                CreditEntry(
                    label: "Starring",
                    value: castNames.formatted(.list(type: .and)),
                )
            }
        }
    }
}
