import SwiftUI
import DesignSystem
import JellyfinKit

/// View for connecting to a Jellyfin server
public struct ServerConnectionView: View {
    @Environment(\.theme) private var theme
    @State private var viewModel = ServerConnectionViewModel()

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
    }

    // MARK: - Connection Form

    private var connectionForm: some View {
        ScrollView {
            VStack(spacing: SpacingTokens.xl) {
                // Header
                VStack(spacing: SpacingTokens.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.accent)

                    Text("Connect to Jellyfin")
                        .font(.jsHeadline)
                        .foregroundStyle(theme.primary)

                    Text("Enter your server details to get started")
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, SpacingTokens.xxl)

                // Form Fields
                VStack(spacing: SpacingTokens.lg) {
                    // Server URL
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("Server URL")
                            .font(.jsCaption)
                            .foregroundStyle(theme.secondary)

                        TextField("https://demo.jellyfin.org", text: $viewModel.serverURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(tvOS)
                            .keyboardType(.URL)
                            #endif
                    }

                    // Username
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("Username")
                            .font(.jsCaption)
                            .foregroundStyle(theme.secondary)

                        TextField("demo", text: $viewModel.username)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }

                    // Password
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("Password")
                            .font(.jsCaption)
                            .foregroundStyle(theme.secondary)

                        SecureField("Password (leave empty for demo)", text: $viewModel.password)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, SpacingTokens.xl)

                // Error Message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.jsCaption)
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
                        .font(.jsBody)
                        .fontWeight(.semibold)
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
                .font(.jsBody)
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
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(theme.accent)

                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(user.name)
                                .font(.jsBody)
                                .foregroundStyle(theme.primary)

                            Text(user.isAdministrator ? "Administrator" : "User")
                                .font(.jsCaption)
                                .foregroundStyle(theme.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.jsTitle)
                    }
                    .padding(.vertical, SpacingTokens.xs)
                }

                HStack {
                    Text("Server")
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)

                    Spacer()

                    Text(viewModel.serverURL)
                        .font(.jsCaption)
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
                        .font(.jsBody)
                        .foregroundStyle(theme.secondary)
                } else {
                    ForEach(viewModel.libraries) { library in
                        HStack(spacing: SpacingTokens.md) {
                            Image(systemName: iconForLibrary(library))
                                .font(.jsTitle)
                                .foregroundStyle(theme.accent)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                                Text(library.name)
                                    .font(.jsBody)
                                    .foregroundStyle(theme.primary)

                                if let count = library.childCount {
                                    Text("\(count) items")
                                        .font(.jsCaption)
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
                            .font(.jsBody)
                        Spacer()
                    }
                }
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

#Preview {
    NavigationStack {
        ServerConnectionView()
    }
    .withThemeEnvironment()
}
