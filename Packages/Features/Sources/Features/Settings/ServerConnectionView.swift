import DesignSystem
import JellyfinKit
import SwiftUI

/// View for connecting to a Jellyfin server
public struct ServerConnectionView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var viewModel

    public init() {}

    public var body: some View {
        Group {
            switch viewModel.state {
            case .disconnected:
                connectionForm
            case .connecting, .authenticating:
                connectingView
            case .connected:
                connectedView
            }
        }
        .navigationTitle("Server")
        .onAppear {
            viewModel.attach(session: session)
        }
    }

    // MARK: - Connection Form

    private var connectionForm: some View {
        @Bindable var viewModel = viewModel
        return ScrollView {
            VStack(spacing: SpacingTokens.xl) {
                // Header
                VStack(spacing: SpacingTokens.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.accent)

                    Text("Connect to Jellyfin")
                        .jsStyle(.headline)
                        .foregroundStyle(theme.primary)

                    Text("Enter your server details to get started")
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, SpacingTokens.xxl)

                // Form Fields
                VStack(spacing: SpacingTokens.lg) {
                    // Server URL
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("Server URL")
                            .jsStyle(.caption)
                            .foregroundStyle(theme.secondary)

                        TextField("https://demo.jellyfin.org/stable", text: $viewModel.serverURL)
                        #if os(visionOS)
                            .textFieldStyle(.roundedBorder)
                        #endif
                            .autocorrectionDisabled()
                        #if os(tvOS)
                            .keyboardType(.URL)
                        #endif
                    }

                    // Username
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("Username")
                            .jsStyle(.caption)
                            .foregroundStyle(theme.secondary)

                        TextField("demo", text: $viewModel.username)
                        #if os(visionOS)
                            .textFieldStyle(.roundedBorder)
                        #endif
                            .autocorrectionDisabled()
                    }

                    // Password
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("Password")
                            .jsStyle(.caption)
                            .foregroundStyle(theme.secondary)

                        SecureField("Password (leave empty for demo)", text: $viewModel.password)
                        #if os(visionOS)
                            .textFieldStyle(.roundedBorder)
                        #endif
                    }
                }
                .padding(.horizontal, SpacingTokens.xl)

                // Error Message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .jsStyle(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SpacingTokens.xl)
                }

                // Connect Button
                Button {
                    Task {
                        await viewModel.connect()
                    }
                } label: {
                    Text("Connect")
                        .jsStyle(.body, .emphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SpacingTokens.md)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .padding(.horizontal, SpacingTokens.xl)

                Spacer()
            }
        }
        .background(theme.background)
    }

    // MARK: - Connecting View

    private var connectingView: some View {
        VStack(spacing: SpacingTokens.lg) {
            ProgressView()
                .scaleEffect(1.5)

            Text(viewModel.state == .connecting ? "Connecting to server..." : "Signing in...")
                .jsStyle(.body)
                .foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    // MARK: - Connected View

    private var connectedView: some View {
        List {
            // User Info Section
            Section {
                if let user = viewModel.connectedUser {
                    HStack(spacing: SpacingTokens.md) {
                        if let client = session.client, user.primaryImageTag != nil {
                            ArtworkImage(url: client.getUserImageURL(userId: user.id, maxWidth: 120))
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(theme.accent)
                        }

                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(user.name)
                                .jsStyle(.body)
                                .foregroundStyle(theme.primary)

                            Text(user.isAdministrator ? "Administrator" : "User")
                                .jsStyle(.caption)
                                .foregroundStyle(theme.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .jsStyle(.title)
                    }
                    .padding(.vertical, SpacingTokens.xs)
                }

                HStack {
                    Text("Server")
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)

                    Spacer()

                    Text(viewModel.serverURL)
                        .jsStyle(.caption)
                        .foregroundStyle(theme.primary)
                        .lineLimit(1)
                }
            } header: {
                Text("Connected")
            }

            // Libraries Section
            Section {
                if viewModel.libraries.isEmpty {
                    Text("No libraries found")
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)
                } else {
                    ForEach(viewModel.libraries) { library in
                        HStack(spacing: SpacingTokens.md) {
                            Image(systemName: iconForLibrary(library))
                                .jsStyle(.title)
                                .foregroundStyle(theme.accent)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                                Text(library.name)
                                    .jsStyle(.body)
                                    .foregroundStyle(theme.primary)

                                if let count = library.childCount {
                                    Text("\(count) items")
                                        .jsStyle(.caption)
                                        .foregroundStyle(theme.secondary)
                                }
                            }
                        }
                        .padding(.vertical, SpacingTokens.xs)
                    }
                }
            } header: {
                Text("Libraries (\(viewModel.libraries.count))")
            }

            // Disconnect Section
            Section {
                Button(role: .destructive) {
                    Task {
                        await viewModel.disconnect()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Disconnect")
                            // Explicit colors so the label ignores the
                            // destructive role's red text, which is illegible
                            // on the themed background at rest. The system
                            // focus platter respects explicit label styles,
                            // so the pill reads the same focused.
                            .jsStyle(.body)
                            .foregroundStyle(theme.primary)
                        Spacer()
                    }
                    .padding(.vertical, SpacingTokens.xs)
                    .background(theme.error, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                #if os(tvOS)
                .buttonStyle(DestructiveFillButtonStyle())
                #endif
            }
        }
        .background(theme.background)
    }

    // MARK: - Helpers

    private func iconForLibrary(_ library: Library) -> String {
        guard let collectionType = library.collectionType else {
            return "folder.fill"
        }

        switch collectionType {
        case .movies:
            return "film.fill"
        case .tvshows:
            return "tv.fill"
        case .music:
            return "music.note.list"
        case .books:
            return "book.fill"
        case .photos:
            return "photo.fill"
        case .homevideos:
            return "video.fill"
        case .musicvideos:
            return "music.note.tv.fill"
        case .boxsets:
            return "square.stack.fill"
        case .playlists:
            return "list.bullet"
        case .livetv:
            return "antenna.radiowaves.left.and.right"
        case .folders, .unknown:
            return "folder.fill"
        }
    }
}

#if os(tvOS)
    /// The Disconnect pill presents focus itself: under the system list style
    /// its error fill sat lifted on the white focus platter — a pill on a
    /// platter. A custom style means no system platter, so focus is a ring
    /// plus the theme's focus scale. The ring is `primary`, not `focusRing` —
    /// Horror's and Action's rings are red-family and vanish on the error
    /// fill, while `primary` is what already reads on it (the label).
    private struct DestructiveFillButtonStyle: ButtonStyle {
        @Environment(\.theme) private var theme
        @Environment(\.isFocused) private var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(theme.primary, lineWidth: 4)
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(isFocused ? theme.focusScale : 1)
                .scaleEffect(configuration.isPressed ? MotionTokens.pressedScale : 1)
                .animation(theme.animation, value: isFocused)
                .animation(MotionTokens.fast, value: configuration.isPressed)
        }
    }
#endif

#if DEBUG
    #Preview("Standard", traits: .featuresEnvironment) {
        NavigationStack {
            ServerConnectionView()
        }
    }

    #Preview("Horror", traits: .featuresEnvironment(theme: .horror)) {
        NavigationStack {
            ServerConnectionView()
        }
    }

    #Preview("Action", traits: .featuresEnvironment(theme: .action)) {
        NavigationStack {
            ServerConnectionView()
        }
    }

    #Preview("Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        NavigationStack {
            ServerConnectionView()
        }
    }

    #Preview("Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        NavigationStack {
            ServerConnectionView()
        }
    }
#endif
