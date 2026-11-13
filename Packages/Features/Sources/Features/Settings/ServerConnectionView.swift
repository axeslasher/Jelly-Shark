import DesignSystem
import JellyfinKit
import SwiftUI

/// View for connecting to a Jellyfin server
public struct ServerConnectionView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSession.self) private var session
    @Environment(ServerConnectionViewModel.self) private var viewModel

    /// The saved profile whose Switch / Forget choice is showing
    @State private var chosenProfile: SavedSession?

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
        .navigationTitle(LocalizedStringResource("server.navigationTitle", bundle: #bundle, comment: "Title of the screen for connecting to a Jellyfin server."))
        .profileChoiceDialog(for: $chosenProfile)
        .onAppear {
            viewModel.attach(session: session)
        }
    }

    // MARK: - Connection Form

    private var connectionForm: some View {
        ScrollView {
            VStack(spacing: SpacingTokens.xl) {
                // Header
                VStack(spacing: SpacingTokens.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: SpacingTokens.xxl))
                        .foregroundStyle(theme.accent)

                    Text("signIn.title", bundle: #bundle, comment: "Heading of the sign-in screen. Jellyfin is a product name.")
                        .jsStyle(.headline)
                        .foregroundStyle(theme.primary)

                    Text("signIn.subtitle", bundle: #bundle, comment: "Subheading of the sign-in screen.")
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, SpacingTokens.xxl)

                // Profiles still saved after a sign-out or a revoked token:
                // one press reconnects instead of retyping credentials
                if !viewModel.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                        Text("server.profiles.header", bundle: #bundle, comment: "Heading over the list of saved server sign-ins the viewer can switch to.")
                            .jsStyle(.caption)
                            .foregroundStyle(theme.secondary)

                        ForEach(viewModel.profiles) { profile in
                            Button {
                                chosenProfile = profile
                            } label: {
                                SavedProfileRowLabel(profile: profile)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, SpacingTokens.xl)
                }

                SignInFields()

                // Connect Button
                Button {
                    Task {
                        await viewModel.connect()
                    }
                } label: {
                    Text("signIn.connect", bundle: #bundle, comment: "Button that signs in to the server.")
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

            Text(viewModel.state == .connecting ? LocalizedStringResource("signIn.progress.connecting", bundle: #bundle, comment: "Progress message while reaching the server.") : LocalizedStringResource("signIn.progress.signingIn", bundle: #bundle, comment: "Progress message while checking the username and password."))
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
                            // Requested at 3x so the avatar stays sharp
                            ArtworkImage(url: client.getUserImageURL(userId: user.id, maxWidth: Int(SpacingTokens.xl * 3)))
                                .frame(width: SpacingTokens.xl, height: SpacingTokens.xl)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: SpacingTokens.xl))
                                .foregroundStyle(theme.accent)
                        }

                        VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                            Text(user.name)
                                .jsStyle(.body)
                                .foregroundStyle(theme.primary)

                            Text(user.isAdministrator ? LocalizedStringResource("server.user.administrator", bundle: #bundle, comment: "Account role of a signed-in server administrator.") : LocalizedStringResource("server.user.standard", bundle: #bundle, comment: "Account role of a signed-in user who isn't an administrator."))
                                .jsStyle(.caption)
                                .foregroundStyle(theme.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.success)
                            .jsStyle(.title)
                    }
                    .padding(.vertical, SpacingTokens.xs)
                }

                HStack {
                    Text("server.row.server", bundle: #bundle, comment: "Label for the row showing the connected server's address.")
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)

                    Spacer()

                    // The active profile, not the form's field: Add Profile
                    // edits the field while this session stays connected
                    Text(viewModel.activeProfile?.serverURL.absoluteString ?? viewModel.serverURL)
                        .jsStyle(.caption)
                        .foregroundStyle(theme.primary)
                        .lineLimit(1)
                }
            } header: {
                Text("server.connected", bundle: #bundle, comment: "Status shown once signed in to the server.")
            }

            // Saved Profiles Section
            Section {
                ForEach(viewModel.otherProfiles) { profile in
                    Button {
                        chosenProfile = profile
                    } label: {
                        SavedProfileRowLabel(profile: profile)
                    }
                }

                NavigationLink(value: SettingsView.Destination.addProfile) {
                    AddProfileRowLabel()
                }
            } header: {
                Text("server.profiles.header", bundle: #bundle, comment: "Heading over the list of saved server sign-ins the viewer can switch to.")
            }

            // Libraries Section
            Section {
                if viewModel.libraries.isEmpty {
                    Text("server.noLibraries", bundle: #bundle, comment: "Shown when the server has no libraries for this user.")
                        .jsStyle(.body)
                        .foregroundStyle(theme.secondary)
                } else {
                    ForEach(viewModel.libraries) { library in
                        HStack(spacing: SpacingTokens.md) {
                            Image(systemName: iconForLibrary(library))
                                .jsStyle(.title)
                                .foregroundStyle(theme.accent)
                                .frame(width: SpacingTokens.lg)

                            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                                Text(library.name)
                                    .jsStyle(.body)
                                    .foregroundStyle(theme.primary)

                                if let count = viewModel.libraryCounts[library.id] {
                                    Text("server.library.itemCount \(count)", bundle: #bundle, comment: "Number of items in a library. The variable is the item count.")
                                        .jsStyle(.caption)
                                        .foregroundStyle(theme.secondary)
                                }
                            }
                        }
                        .padding(.vertical, SpacingTokens.xs)
                    }
                }
            } header: {
                Text("server.libraries.header \(viewModel.libraries.count)", bundle: #bundle, comment: "Section heading over the server's libraries. The variable is how many there are.")
            }

            // Sign Out Section
            Section {
                Button(role: .destructive) {
                    Task {
                        await viewModel.disconnect()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("server.signOut", bundle: #bundle, comment: "Button that signs out of the current server account and forgets it. If other accounts are saved, the app switches to one of them.")
                            // Explicit colors so the label ignores the
                            // destructive role's red text, which is illegible
                            // on the themed background at rest. The system
                            // focus platter respects explicit label styles,
                            // so the pill reads the same focused.
                            .jsStyle(.body)
                            .foregroundStyle(theme.primary)
                        Spacer()
                    }
                    .padding(.vertical, SpacingTokens.sm)
                    .background(theme.error, in: .capsule)
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

// MARK: - Add Profile

/// Sign in to another server or user while the current session stays
/// connected. Pops back to the Server page once the new profile is active.
struct AddProfileView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerConnectionViewModel.self) private var viewModel

    /// The sign-in started by Connect, cancelled if the viewer backs out so
    /// a sign-in that finishes later doesn't switch profiles behind them
    @State private var signIn: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: SpacingTokens.xl) {
                Text("addProfile.subtitle", bundle: #bundle, comment: "Subheading of the screen for signing in to another server or user. The current sign-in is kept.")
                    .jsStyle(.body)
                    .foregroundStyle(theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, SpacingTokens.xl)

                SignInFields()

                Button {
                    // Presses while one is running are ignored by the view
                    // model. Not `.disabled`: disabling the focused button
                    // would throw tvOS focus somewhere else on the page.
                    signIn = Task {
                        if await viewModel.addProfile(), !Task.isCancelled {
                            dismiss()
                        }
                    }
                } label: {
                    Group {
                        if viewModel.isAddingProfile {
                            ProgressView()
                        } else {
                            Text("signIn.connect", bundle: #bundle, comment: "Button that signs in to the server.")
                                .jsStyle(.body, .emphasized)
                        }
                    }
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
        .navigationTitle(LocalizedStringResource("addProfile.navigationTitle", bundle: #bundle, comment: "Title of the screen for signing in to another server or user."))
        .onAppear {
            viewModel.prepareAddProfile()
        }
        .onDisappear {
            signIn?.cancel()
        }
    }
}

// MARK: - Shared pieces

/// Server URL, username and password fields with the sign-in error under
/// them; shared by the first sign-in and Add Profile
private struct SignInFields: View {
    @Environment(\.theme) private var theme
    @Environment(ServerConnectionViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: SpacingTokens.xl) {
            VStack(spacing: SpacingTokens.lg) {
                // Server URL
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text("signIn.serverURL.label", bundle: #bundle, comment: "Label above the field for the server's web address.")
                        .jsStyle(.caption)
                        .foregroundStyle(theme.secondary)

                    TextField(LocalizedStringResource("signIn.serverURL.placeholder", bundle: #bundle, comment: "Example address shown in the empty server field. Keep it a valid web address."), text: $viewModel.serverURL)
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
                    Text("signIn.username.label", bundle: #bundle, comment: "Label above the username field.")
                        .jsStyle(.caption)
                        .foregroundStyle(theme.secondary)

                    TextField(LocalizedStringResource("signIn.username.placeholder", bundle: #bundle, comment: "Example username shown in the empty field; it signs in to the public demo server."), text: $viewModel.username)
                    #if os(visionOS)
                        .textFieldStyle(.roundedBorder)
                    #endif
                        .autocorrectionDisabled()
                }

                // Password
                VStack(alignment: .leading, spacing: SpacingTokens.xs) {
                    Text("signIn.password.label", bundle: #bundle, comment: "Label above the password field.")
                        .jsStyle(.caption)
                        .foregroundStyle(theme.secondary)

                    SecureField(LocalizedStringResource("signIn.password.placeholder", bundle: #bundle, comment: "Placeholder in the empty password field."), text: $viewModel.password)
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
                    .foregroundStyle(theme.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SpacingTokens.xl)
            }
        }
    }
}

/// A saved profile: the user's name over the server's. Profiles saved
/// before names were stored fall back to the server's host.
private struct SavedProfileRowLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    let profile: SavedSession

    var body: some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: "person.crop.circle")
                .jsStyle(.title)
                .foregroundStyle(theme.accent)
                .frame(width: SpacingTokens.lg)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(verbatim: profile.userName ?? host)
                    .jsStyle(.body)
                    .foregroundStyle(isFocused ? theme.onPlatter : theme.primary)

                Text(verbatim: profile.serverName ?? host)
                    .jsStyle(.caption)
                    .foregroundStyle(isFocused ? theme.onPlatterSecondary : theme.secondary)
            }
        }
        .padding(.vertical, SpacingTokens.xs)
        .animation(theme.animation, value: isFocused)
    }

    private var host: String {
        profile.serverURL.host() ?? profile.serverURL.absoluteString
    }
}

private struct AddProfileRowLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .jsStyle(.title)
                .foregroundStyle(theme.accent)
                .frame(width: SpacingTokens.lg)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text("server.profiles.add", bundle: #bundle, comment: "Row that opens the form for signing in to another server or user.")
                    .jsStyle(.body)
                    .foregroundStyle(isFocused ? theme.onPlatter : theme.primary)

                Text("server.profiles.add.subtitle", bundle: #bundle, comment: "Explains the Add Profile row: the current sign-in is kept so the viewer can switch back.")
                    .jsStyle(.caption)
                    .foregroundStyle(isFocused ? theme.onPlatterSecondary : theme.secondary)
            }
        }
        .padding(.vertical, SpacingTokens.xs)
        .animation(theme.animation, value: isFocused)
    }
}

private extension View {
    /// Switch to or forget the chosen saved profile. A dialog rather than a
    /// long-press menu, which is slow and unreliable on tvOS (#256).
    func profileChoiceDialog(for profile: Binding<SavedSession?>) -> some View {
        modifier(ProfileChoiceDialog(chosenProfile: profile))
    }
}

private struct ProfileChoiceDialog: ViewModifier {
    @Environment(ServerConnectionViewModel.self) private var viewModel
    @Binding var chosenProfile: SavedSession?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text(verbatim: chosenProfile.map { $0.userName ?? $0.serverURL.host() ?? $0.serverURL.absoluteString } ?? ""),
            isPresented: Binding(
                get: { chosenProfile != nil },
                set: {
                    if !$0 {
                        chosenProfile = nil
                    }
                },
            ),
            titleVisibility: .visible,
            presenting: chosenProfile,
        ) { profile in
            Button {
                Task {
                    await viewModel.switchToProfile(profile.id)
                }
            } label: {
                Text("server.profile.switch", bundle: #bundle, comment: "Dialog button that switches the app to the chosen saved server sign-in.")
            }

            Button(role: .destructive) {
                Task {
                    await viewModel.forgetProfile(profile.id)
                }
            } label: {
                Text("server.profile.forget", bundle: #bundle, comment: "Dialog button that signs the chosen saved account out and removes it from this device.")
            }

            Button(role: .cancel) {} label: {
                Text("common.cancel", bundle: #bundle, comment: "Button that dismisses a prompt without choosing anything.")
            }
        } message: { profile in
            Text(verbatim: profile.serverName ?? profile.serverURL.absoluteString)
        }
    }
}

#if os(tvOS)
    /// The Sign Out pill presents focus itself: under the system list style
    /// its error fill sat lifted on the white focus platter — a pill on a
    /// platter. A custom style means no system platter, and focus is the
    /// theme's focus scale alone — the capsule is the page's only filled
    /// control, so the grow reads without a ring (a ring was tried and read
    /// as clutter on device).
    private struct DestructiveFillButtonStyle: ButtonStyle {
        @Environment(\.theme) private var theme
        @Environment(\.isFocused) private var isFocused

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
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

    #Preview("Add Profile – Standard", traits: .featuresEnvironment) {
        NavigationStack {
            AddProfileView()
        }
    }

    #Preview("Add Profile – Horror", traits: .featuresEnvironment(theme: .horror)) {
        NavigationStack {
            AddProfileView()
        }
    }

    #Preview("Add Profile – Action", traits: .featuresEnvironment(theme: .action)) {
        NavigationStack {
            AddProfileView()
        }
    }

    #Preview("Add Profile – Video Store", traits: .featuresEnvironment(theme: .videoStore)) {
        NavigationStack {
            AddProfileView()
        }
    }

    #Preview("Add Profile – Sci-Fi", traits: .featuresEnvironment(theme: .sciFi)) {
        NavigationStack {
            AddProfileView()
        }
    }
#endif
