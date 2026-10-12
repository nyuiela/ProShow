import SwiftUI

/// Sign-in only. Channel name, page ID, and ingest are filled after OAuth.
struct ConnectDestinationSheet: View {
    @Bindable var controller: ShowController
    @Binding var isPresented: Bool
    @Binding var message: String?
    var reconnecting: StreamAccount? = nil

    @State private var connecting: StreamPlatform?
    @State private var customURL = ""
    @State private var customKey = ""
    @State private var showsCustom = false

    private var store: SettingsStore { controller.deviceSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            Text(reconnecting == nil ? "Connect" : "Reconnect")
                .font(DeskType.title)
                .foregroundStyle(ProShowTheme.primaryLabel)
                .accessibilityLabel(reconnecting == nil ? "Connect a destination" : "Reconnect \(reconnecting!.platform.title)")
            Text("Sign in. The channel name fills in after.")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("OAuth redirect URIs") {
                VStack(alignment: .leading, spacing: DeskSpace.md) {
                    redirectEditor(
                        title: "YouTube",
                        hint: "Must match the Google client. Consent screen may be named n8n-workflow.",
                        text: Binding(
                            get: { store.document.youtubeRedirectURI },
                            set: { store.document.youtubeRedirectURI = $0; store.save() }
                        ),
                        n8nURI: StreamOAuthConfiguration.n8nRedirectURI,
                        proshowURI: StreamOAuthConfiguration.proshowRedirectURI
                    )
                    redirectEditor(
                        title: "LinkedIn",
                        hint: "Must match Auth → Redirect URLs on the LinkedIn app.",
                        text: Binding(
                            get: { store.document.linkedinRedirectURI },
                            set: { store.document.linkedinRedirectURI = $0; store.save() }
                        ),
                        n8nURI: StreamOAuthConfiguration.n8nRedirectURI,
                        proshowURI: StreamOAuthConfiguration.proshowLinkedInRedirectURI
                    )
                    clientSecretEditor(
                        platform: .youtube,
                        title: "YouTube client secret",
                        hint: "From Google Cloud → Credentials. Required for YouTube sign-in."
                    )
                    clientSecretEditor(
                        platform: .linkedin,
                        title: "LinkedIn client secret",
                        hint: "From the LinkedIn Auth tab. Required to finish connect."
                    )
                    clientSecretEditor(
                        platform: .twitter,
                        title: "X client secret",
                        hint: "Required if the X app is Confidential. Public/native apps can skip this."
                    )
                    redirectEditor(
                        title: "X",
                        hint: "Add this exact Callback URI. Set User authentication to Read and write so ProShow can create the livestream post. Use the OAuth 2.0 Client ID, not the API Key.",
                        text: Binding(
                            get: { store.document.xRedirectURI },
                            set: { store.document.xRedirectURI = $0; store.save() }
                        ),
                        n8nURI: StreamOAuthConfiguration.n8nRedirectURI,
                        proshowURI: StreamOAuthConfiguration.proshowXRedirectURI
                    )
                    redirectEditor(
                        title: "Facebook",
                        hint: "Must match a Valid OAuth Redirect URI on the Facebook app.",
                        text: Binding(
                            get: { store.document.facebookRedirectURI },
                            set: { store.document.facebookRedirectURI = $0; store.save() }
                        ),
                        n8nURI: StreamOAuthConfiguration.n8nRedirectURI,
                        proshowURI: StreamOAuthConfiguration.proshowFacebookRedirectURI
                    )
                }
                .padding(.top, 8)
            }
            .accessibilityLabel("OAuth redirect URIs")

            VStack(spacing: 8) {
                ForEach(platforms, id: \.self) { platform in
                    platformRow(platform)
                }
            }

            if reconnecting == nil {
                DisclosureGroup(isExpanded: $showsCustom) {
                    customServer
                } label: {
                    Text("Custom RTMP or SRT")
                        .font(DeskType.bodyEmph)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                }
                .tint(ProShowTheme.secondaryLabel)
                .accessibilityLabel("Custom RTMP or SRT")
            }

            HStack {
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(DeskPressButtonStyle())
                Spacer()
            }
        }
        .padding(DeskSpace.lg)
        .frame(width: 480)
        .background(ProShowTheme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reconnecting == nil ? "Connect a destination" : "Reconnect destination")
    }

    private var platforms: [StreamPlatform] {
        if let reconnecting {
            return [reconnecting.platform]
        }
        return StreamPlatform.oauthCases
    }

    private func redirectEditor(
        title: String,
        hint: String,
        text: Binding<String>,
        n8nURI: String,
        proshowURI: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            TextField(n8nURI, text: text)
                .textFieldStyle(.roundedBorder)
                .font(DeskType.mono)
                .accessibilityLabel(title)
            HStack(spacing: 8) {
                Button("n8n") {
                    text.wrappedValue = n8nURI
                    store.save()
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityLabel("Use the n8n \(title)")
                Button("ProShow") {
                    text.wrappedValue = proshowURI
                    store.save()
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityLabel("Use the ProShow \(title)")
            }
            Text(hint)
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clientSecretEditor(platform: StreamPlatform, title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            OAuthClientSecretField(platform: platform)
            Text(hint)
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func platformRow(_ platform: StreamPlatform) -> some View {
        let ready = StreamAccountManager.shared.hasClientID(for: platform)
        return Button {
            Task { await connect(platform) }
        } label: {
            HStack(spacing: 12) {
                StreamPlatformBrandIcon(platform: platform, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.title)
                        .font(DeskType.bodyEmph)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                    Text(rowDetail(for: platform, ready: ready))
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                }
                Spacer(minLength: 8)
                if connecting == platform {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Connecting to \(platform.title)")
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .disabled(!ready || connecting != nil)
        .accessibilityLabel("Connect \(platform.title)")
        .accessibilityHint(ready ? "Opens the browser to sign in" : "Client ID is missing")
        .accessibilityAddTraits(.isButton)
    }

    private var customServer: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            TextField("rtmps://live.example.com/app", text: $customURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Custom stream URL")
            SecureField("Stream key", text: $customKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Custom stream key")
            Button("Save custom destination") { saveCustom() }
                .buttonStyle(.borderedProminent)
                .tint(ProShowTheme.accent)
                .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Save custom destination")
        }
        .padding(.top, 8)
    }

    private func connect(_ platform: StreamPlatform) async {
        connecting = platform
        defer { connecting = nil }
        do {
            let existing = reconnecting ?? store.document.accounts.first(where: { $0.platform == platform })
            let redirect = StreamOAuthConfiguration.resolvedLoopbackRedirect(
                preferred: store.document.oauthRedirectURI(for: platform),
                platform: platform
            )
            persistResolvedRedirect(redirect, for: platform)
            let account = try await StreamAccountManager.shared.authenticate(
                platform: platform,
                existing: existing,
                redirectURI: StreamOAuthConfiguration.usesLoopbackRedirect(for: platform) ? redirect : nil
            )
            store.upsert(account, secret: nil)
            message = nil
            isPresented = false
        } catch StreamOAuthError.missingClientID {
            message = "Client ID missing."
        } catch StreamOAuthError.missingClientSecret {
            message = "Client secret missing."
        } catch StreamOAuthError.providerRejected(let reason) {
            message = accessDeniedMessage(for: platform, reason: reason)
        } catch StreamOAuthError.invalidCallback {
            message = "Sign-in failed. Check the redirect."
        } catch StreamOAuthError.cancelled {
            message = nil
        } catch StreamOAuthError.tokenExchangeFailed {
            message = tokenExchangeMessage(for: platform)
        } catch {
            message = "Sign-in failed. Check the redirect."
        }
    }

    private func rowDetail(for platform: StreamPlatform, ready: Bool) -> String {
        if !ready {
            return "Client ID is not configured on this Mac"
        }
        if StreamOAuthConfiguration.requiresClientSecret(for: platform),
           !StreamOAuthConfiguration.hasClientSecret(for: platform) {
            return "Needs the client secret from the Auth tab"
        }
        if platform == .twitter, !StreamOAuthConfiguration.hasClientSecret(for: platform) {
            return "Opens sign-in. Paste the secret if the app is Confidential. Read and write is required to post the livestream."
        }
        return "Opens the sign-in page"
    }

    private func persistResolvedRedirect(_ redirect: URL, for platform: StreamPlatform) {
        let value = redirect.absoluteString
        switch platform {
        case .twitter:
            store.document.xRedirectURI = value
        case .linkedin:
            store.document.linkedinRedirectURI = value
        case .facebook:
            store.document.facebookRedirectURI = value
        case .youtube:
            store.document.youtubeRedirectURI = value
        case .customRtmp, .srt:
            return
        }
        store.save()
    }

    private func accessDeniedMessage(for platform: StreamPlatform, reason: String) -> String {
        if platform == .twitter {
            return "X blocked access. Set the app to Read and write, add \(StreamOAuthConfiguration.proshowXRedirectURI) as the Callback URI, use the OAuth 2.0 Client ID, then try again. \(reason)"
        }
        return "\(platform.title) rejected sign-in: \(reason)"
    }

    private func tokenExchangeMessage(for platform: StreamPlatform) -> String {
        if platform == .twitter {
            return "X rejected the token exchange. Paste the client secret if the X app is Confidential, and match the callback URL. A free X account can still sign in — X Live itself needs Media Studio."
        }
        return "Could not finish sign-in for \(platform.title). Check the client secret and redirect URI, then try again."
    }

    private func saveCustom() {
        let url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), parsed.host != nil else {
            message = "Enter a full rtmp, rtmps, or srt URL."
            return
        }
        let platform: StreamPlatform = url.lowercased().hasPrefix("srt") ? .srt : .customRtmp
        var account = StreamAccount(
            accountName: parsed.host ?? platform.title,
            platform: platform,
            rtmpUrl: url
        )
        account.isAuthenticated = !customKey.isEmpty
        store.upsert(account, secret: customKey.isEmpty ? nil : customKey)
        customKey = ""
        isPresented = false
    }
}

extension StreamPlatform {
    static var oauthCases: [StreamPlatform] {
        [.youtube, .facebook, .twitter, .linkedin]
    }
}
