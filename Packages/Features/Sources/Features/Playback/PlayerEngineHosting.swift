#if canImport(UIKit)
    import AVKit
    import UIKit
#endif

// MARK: - Render Route

/// How an engine puts frames on screen, which decides what
/// `PlaybackContainerView` mounts for it.
public enum PlayerRenderRoute {
    #if canImport(UIKit)
        /// The engine ends in an `AVPlayer`. The app hosts it in its own
        /// `AVPlayerViewController`, with the app's track menus, info tabs,
        /// reconnecting card and Up Next card.
        case avPlayer(AVPlayer)

        /// The engine draws its own frames and supplies the whole player
        /// surface, controls included. The app mounts the controller as is.
        ///
        /// What the app's player would otherwise provide becomes the
        /// engine's to provide: a way out (send `.dismissRequested`), track
        /// menus, and the tvOS pre-roll Up Next card, which has no
        /// counterpart on this route. On visionOS the app's post-roll Up
        /// Next overlay still draws over the surface.
        case hostedViewController(UIViewController)
    #endif
}

// MARK: - Hosting

/// The view half of an engine: what `PlaybackContainerView` needs to put it
/// on screen. Kept apart from `PlayerEngine` so the session layer and its
/// tests stay free of AVKit and UIKit types.
@MainActor
public protocol PlayerEngineHosting: AnyObject {
    /// The current route, or nil until the first `load` has something to
    /// show.
    ///
    /// Obligations:
    /// - Observable: the container reads this in its body, so the
    ///   conforming class must be `@Observable` (or otherwise participate in
    ///   Observation), or the first load never reaches the screen.
    /// - Stable for a session, rebuilds included. A changed route, or a
    ///   different `AVPlayer` in `.avPlayer`, unmounts the player view, and
    ///   doing that while AVKit's fullscreen window is up on visionOS leaves
    ///   the app's own window hidden with nothing to restore it (#183).
    var renderRoute: PlayerRenderRoute? { get }

    #if canImport(UIKit)
        /// The app's `AVPlayerViewController` for the `.avPlayer` route is
        /// ready for the engine's own additions: views in
        /// `contentOverlayView` (a held frame, a subtitle layer) and
        /// controller settings such as
        /// `appliesPreferredDisplayCriteriaAutomatically`.
        ///
        /// Called once per controller, on the first pass where
        /// `contentOverlayView` exists. Anything added must take no input
        /// and never be focusable, so focus stays on AVKit's controls.
        /// On visionOS add plain views only, never child view controllers:
        /// AVKit re-hosts the player into a window of its own and aborts on
        /// the containment (#309).
        func playerViewControllerDidMount(_ controller: AVPlayerViewController)

        /// The controller is leaving the hierarchy. Remove and unbind
        /// whatever `playerViewControllerDidMount` added.
        func playerViewControllerWillDismantle(_ controller: AVPlayerViewController)
    #endif
}

#if canImport(UIKit)
    public extension PlayerEngineHosting {
        /// Engines that add nothing to the player need no hooks.
        func playerViewControllerDidMount(_: AVPlayerViewController) {}

        func playerViewControllerWillDismantle(_: AVPlayerViewController) {}
    }
#endif

// MARK: - Registry

/// Where the app target supplies a playback engine from outside `Features`.
///
/// Set once at launch, before any player is presented. Consulted at every
/// presentation, so a factory can decide per session (a Settings switch,
/// say) and return nil to fall back to the default AVFoundation engine.
/// A static rather than an environment value because the engine has to
/// exist when `PlaybackContainerView.init` builds its view model, before
/// any environment can be read.
@MainActor
public enum PlayerEngineRegistry {
    /// Builds an engine for one session. The argument is the viewer's
    /// streaming ceiling in bits per second (#168), nil at the default tier;
    /// the engine reports it back through `streamingBitrateCap` and narrows
    /// its `capabilities` with it.
    public typealias Factory = @MainActor (_ streamingBitrateCap: Int?) -> (any PlayerEngine & PlayerEngineHosting)?

    public static var factory: Factory?

    static func makeEngine(streamingBitrateCap: Int?) -> any PlayerEngine & PlayerEngineHosting {
        factory?(streamingBitrateCap) ?? AVFoundationPlayerEngine(streamingBitrateCap: streamingBitrateCap)
    }
}
