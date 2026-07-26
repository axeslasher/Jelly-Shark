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

#if canImport(UIKit)
    import DesignSystem
    import JellyfinKit
    import SwiftUI
    import UIKit

    /// The player's "Cast & Crew" info tab
    ///
    /// AVKit presents `customInfoViewControllers` as tabs below the transport
    /// bar (tvOS) or in the info area (visionOS). The hosted SwiftUI tree is
    /// detached from the app's, so the theme environment is re-applied here.
    /// Display-only: the player is presented outside the tab's
    /// `NavigationStack`, so cards cannot push `PersonDetailView`.
    final class CastInfoViewController: UIHostingController<CastInfoPanel> {
        init(people: [CastMember], headshotURL: @escaping (CastMember) -> URL?) {
            super.init(rootView: CastInfoPanel(people: people, headshotURL: headshotURL))
            // AVKit reads the title for the tab label at attach time
            title = String(localized: "Cast & Crew")
            // tvOS stretches tabs to full width; visionOS reads both axes
            preferredContentSize = CGSize(width: 960, height: 360)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        @MainActor dynamic required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    /// Horizontal row of cast cards for the info tab
    struct CastInfoPanel: View {
        let people: [CastMember]
        let headshotURL: (CastMember) -> URL?

        var body: some View {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SpacingTokens.lg) {
                    ForEach(people) { member in
                        CastCard(
                            url: headshotURL(member),
                            name: member.name,
                            role: member.role ?? member.kind,
                            width: 180,
                        )
                    }
                }
                .padding(.horizontal, SpacingTokens.xl)
                .padding(.vertical, SpacingTokens.lg)
            }
            .scrollClipDisabled()
            .withThemeEnvironment()
        }
    }
#endif
