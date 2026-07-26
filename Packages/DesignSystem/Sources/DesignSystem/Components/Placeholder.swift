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

import SwiftUI

/// A placeholder view for components under development
/// Use this to represent components that will be implemented later
public struct ComponentPlaceholder: View {
    let name: String
    let icon: String

    @Environment(\.theme) private var theme

    public init(name: String, icon: String = "puzzlepiece.fill") {
        self.name = name
        self.icon = icon
    }

    public var body: some View {
        VStack(spacing: SpacingTokens.md) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(theme.secondary)

            Text(name)
                .jsStyle(.title)
                .foregroundStyle(theme.primary)

            Text("Coming Soon")
                .jsStyle(.caption)
                .foregroundStyle(theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
    }
}

#Preview {
    ComponentPlaceholder(name: "Media Card")
        .withThemeEnvironment()
}
