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
import Observation

/// User preferences for the Home screen layout, UserDefaults-backed like
/// `ThemeManager`'s theme choice. Lives in Features (not DesignSystem)
/// because it's browsing business logic, not visual language. RootView owns
/// an instance and injects it into the environment; no singleton, so tests
/// and previews can construct their own over a scratch defaults suite.
@MainActor
@Observable
public final class HomePreferences {
    /// Fold Next Up into Continue Watching as one lane ordered by
    /// last-engagement recency (the default). Off restores the separate
    /// Continue Watching and Next Up shelves.
    public var mergesContinueWatching: Bool {
        didSet {
            defaults.set(mergesContinueWatching, forKey: Self.mergesKey)
        }
    }

    private let defaults: UserDefaults
    private static let mergesKey = "mergesContinueWatching"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // object(forKey:), not bool(forKey:): absence must default to true.
        mergesContinueWatching = defaults.object(forKey: Self.mergesKey) as? Bool ?? true
    }
}
