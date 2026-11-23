import SwiftUI
import NextupKit

/// WebDAV sync: sign in once (pCloud, Koofr or any WebDAV server) and this device stays in step with
/// your other iPhone, iPad and Mac. The same account can bring everything over from the Flutter app.
struct SyncSettingsView: View {
    @Environment(SyncController.self) private var sync
    @State private var draft = WebDAVAccount()
    @State private var password = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            if sync.isConnected {
                connected
            } else {
                signIn
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .onAppear { draft = sync.account }
    }

    private var connected: some View {
        Group {
            Section {
                LabeledContent("Server", value: sync.account.preset == .custom ? (sync.account.endpoint?.host ?? "WebDAV") : sync.account.preset.displayName)
                LabeledContent("Account", value: sync.account.username)
                LabeledContent("Folder", value: sync.account.folder)
                LabeledContent("Last synced") {
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    else { Text(sync.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Never") }
                }
                Button("Sync Now") { Task { await sync.syncNow() } }.disabled(sync.isSyncing)
            } footer: {
                Text(sync.lastError ?? "Addons, accounts, favorites, watchlist and Continue Watching sync between your Apple devices when the app opens and closes.")
            }

            Section {
                Button(working ? "Importing…" : "Import from the Flutter App") { Task { await importFlutter() } }
                    .disabled(working)
            } footer: {
                Text(message ?? "Reads the Flutter app's WebDAV sync in the same folder and adds its debrid keys, Trakt and addons here. The Flutter sync itself is left untouched.")
            }

            Section {
                Button("Sign Out", role: .destructive) { sync.disconnect() }
            }
        }
    }

    private var signIn: some View {
        Group {
            Section {
                Picker("Server", selection: $draft.preset) {
                    ForEach(WebDAVPreset.allCases) { Text($0.displayName).tag($0) }
                }
                if draft.preset == .custom {
                    TextField("Server address", text: $draft.customURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }
                TextField(draft.preset == .custom ? "Username" : "Email", text: $draft.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Password", text: $password)
                    .textContentType(.password)
                TextField("Folder", text: $draft.folder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } footer: {
                Text("Use the account and folder the Flutter app syncs to (“Debrify” unless you changed it). pCloud: your pCloud email and password; pick the region your account was created in.")
            }

            Section {
                Button(working ? "Connecting…" : "Connect") { Task { await connect() } }
                    .disabled(working || draft.username.isEmpty || password.isEmpty)
                if draft.preset == .pCloudEU || draft.preset == .pCloudUS {
                    Link("pCloud WebDAV help", destination: URL(string: "https://help.pcloud.com/article/connect-to-pcloud-using-webdav-and-rsync")!)
                }
            } footer: {
                if let message { Text(message) }
            }
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        do {
            try await sync.connect(account: draft, password: password)
            password = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func importFlutter() async {
        working = true
        defer { working = false }
        do {
            message = try await sync.importFromFlutter()
        } catch {
            message = error.localizedDescription
        }
    }
}
