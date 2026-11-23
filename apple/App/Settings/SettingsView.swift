import SwiftUI
import NextupKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        // The Mac Settings window uses tabs, like other Mac apps.
        TabView {
            Form { MetadataSection(); DebridSection() }.formStyle(.grouped)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            Form { TraktSection() }.formStyle(.grouped)
                .tabItem { Label("Tracking", systemImage: "chart.line.uptrend.xyaxis") }
            Form { AddonsSection() }.formStyle(.grouped)
                .tabItem { Label("Addons", systemImage: "puzzlepiece.extension") }
            Form { AboutSection() }.formStyle(.grouped)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
        #else
        Form {
            MetadataSection()
            DebridSection()
            TraktSection()
            AddonsSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #endif
    }
}

// MARK: Metadata

private struct MetadataSection: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        Section {
            SecureField("TMDB read access token", text: $token)
                .textContentType(.password)
                .autocorrectionDisabled()
            HStack {
                Button("Save") { model.setSecret(token, for: SecretKey.tmdbToken) }
                    .disabled(token == model.secret(SecretKey.tmdbToken))
                Spacer()
                Link("Get a token", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            }
        } header: {
            Text("Metadata")
        } footer: {
            Text(model.hasTMDB ? "TMDB is connected. Home rows, search and title pages use it."
                               : "TMDB powers Home rows, search and title pages. Without it, Nextup uses your catalog addons.")
        }
        .onAppear { token = model.secret(SecretKey.tmdbToken) }
    }
}

// MARK: Debrid

private struct DebridSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            ForEach(DebridService.allCases) { service in
                DebridAccountRow(service: service)
            }
            if model.configuredDebrid.count > 1 {
                Picker("Play torrents with", selection: $model.preferredDebrid) {
                    Text("Automatic").tag(DebridService?.none)
                    ForEach(model.configuredDebrid) { Text($0.displayName).tag(DebridService?.some($0)) }
                }
            }
        } header: {
            Text("Debrid services")
        } footer: {
            Text("Keys are stored in the Keychain on this device.")
        }
    }
}

private struct DebridAccountRow: View {
    @Environment(AppModel.self) private var model
    let service: DebridService
    @State private var key = ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(service.displayName).font(.headline)
                Spacer()
                Link("Get API key", destination: service.apiKeyPageURL).font(.footnote)
            }
            SecureField("API key", text: $key)
                .textContentType(.password)
                .autocorrectionDisabled()
            HStack {
                Button(checking ? "Checking…" : "Save & Verify") { Task { await verify() } }
                    .disabled(key.isEmpty || checking)
                if !model.secret(service.secretKey).isEmpty {
                    Button("Remove", role: .destructive) {
                        key = ""
                        status = nil
                        model.setSecret(nil, for: service.secretKey)
                    }
                }
                Spacer()
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 4)
        .onAppear { key = model.secret(service.secretKey) }
    }

    private func verify() async {
        checking = true
        defer { checking = false }
        model.setSecret(key, for: service.secretKey)
        guard let provider = DebridFactory.provider(service, secrets: model.secrets) else { return }
        do {
            let account = try await provider.account()
            var text = account.username + (account.isPremium ? " · Premium" : " · Not premium")
            if let until = account.premiumUntil { text += " until \(until.formatted(date: .abbreviated, time: .omitted))" }
            status = text
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: Trakt

private struct TraktSection: View {
    @Environment(AppModel.self) private var model
    @State private var showingSignIn = false
    @State private var signedIn = false

    var body: some View {
        Section {
            if signedIn {
                Label("Connected to Trakt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Sign out", role: .destructive) {
                    model.trakt.signOut()
                    model.accountsChanged()
                    signedIn = false
                }
            } else {
                Button("Connect Trakt") { showingSignIn = true }
            }
        } header: {
            Text("Trakt")
        } footer: {
            Text("Scrobbles what you watch and shows your paused items and watchlist in Library.")
        }
        .onAppear { signedIn = model.trakt.isSignedIn }
        .sheet(isPresented: $showingSignIn, onDismiss: { signedIn = model.trakt.isSignedIn }) {
            TraktSignInView()
                .environment(model)
        }
    }
}

/// Device-code sign-in: works the same on iPhone, iPad and Mac, no web view needed.
private struct TraktSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: TraktDeviceCode?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let code {
                    Text("Go to the address below and enter this code").foregroundStyle(.secondary)
                    Text(code.user_code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy Code") { Clipboard.copy(code.user_code) }.buttonStyle(.bordered)
                        if let url = URL(string: code.verification_url) {
                            Button("Open \(url.host ?? "trakt.tv")") { openURL(url) }.buttonStyle(.borderedProminent)
                        }
                    }
                    ProgressView("Waiting for approval…")
                } else {
                    ProgressView()
                }
                if let message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .padding(32)
            .navigationTitle("Connect Trakt")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await run() }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private func run() async {
        do {
            let code = try await model.trakt.requestDeviceCode()
            self.code = code
            var interval = UInt64(max(code.interval, 5))
            let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
            while Date() < deadline, !Task.isCancelled {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                switch try await model.trakt.poll(deviceCode: code.device_code) {
                case .authorized:
                    model.accountsChanged()
                    dismiss()
                    return
                case .pending: continue
                case .slowDown: interval += 1
                case .expired: message = "The code expired. Close and try again."; return
                case .denied: message = "Access was denied on Trakt."; return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: Addons

private struct AddonsSection: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var installing = false
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        Section {
            ForEach($model.addons) { $addon in
                Toggle(isOn: $addon.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(addon.manifest.name)
                        Text(capabilities(addon)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { model.removeAddons(at: $0) }
            .onMove { model.moveAddons(from: $0, to: $1) }

            HStack {
                TextField("Addon URL (https:// or stremio://)", text: $url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button(installing ? "Installing…" : "Install") { Task { await install(url) } }
                    .disabled(url.isEmpty || installing)
            }
            if !model.addons.contains(where: { $0.manifest.id == "com.linvo.cinemeta" }) {
                Button("Install Cinemeta (catalogs and metadata)") {
                    Task { await install("https://v3-cinemeta.strem.io/manifest.json") }
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Addons")
        } footer: {
            Text("Addons are asked for streams in this order. Swipe to remove, drag to reorder.")
        }
    }

    private func capabilities(_ addon: InstalledAddon) -> String {
        let names = addon.manifest.resources.map(\.name)
        return (["v" + addon.manifest.version] + names).joined(separator: " · ")
    }

    private func install(_ raw: String) async {
        installing = true
        defer { installing = false }
        do {
            try await model.install(addonURL: raw)
            url = ""
            message = "Installed."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: About

private struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            Link("Nextup on GitHub", destination: URL(string: "https://github.com/Alehaaaa/nextup")!)
            Text("Nextup is an unofficial fork of Debrify. It is not affiliated with or endorsed by the Debrify project.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
