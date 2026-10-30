import Foundation

/// The app's version as Settings shows it and as the server records it.
///
/// Read from the bundle so it can't drift from `MARKETING_VERSION` (#157).
/// Local builds carry the default build number `1` (CI overrides it per
/// release, see docs/RELEASING.md), which says nothing, so it's omitted:
/// "0.11.0" locally, "0.11.0 (42.1)" from a release build.
enum AppVersion {
    static func text(from info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let version = info?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        guard let build = info?["CFBundleVersion"] as? String, build != "1" else {
            return version
        }
        return "\(version) (\(build))"
    }
}
