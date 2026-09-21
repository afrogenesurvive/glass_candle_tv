import SwiftUI
import ServiceManagement

/// Connection, display and behaviour settings.
///
/// The API password field is a `SecureField` that never reads its value back
/// from the Keychain — it starts empty and only writes when the user types. That
/// avoids putting the password into a SwiftUI state property, which would make
/// it visible to anything that can read process memory or a crash report.
struct SettingsView: View {

    let client: FreshRSSClient
    /// `@Bindable` is required to get `$prefs` bindings out of an `@Observable`
    /// class. A plain `let` would compile for reads and fail for `$`.
    @Bindable var prefs: PrefsStore

    @State private var password: String = ""
    @State private var confirmClear = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            connectionSection
            displaySection
            behaviourSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 470)
        .onChange(of: password) { _, _ in testResult = nil }
        .onChange(of: prefs.apiBaseURL) { _, _ in testResult = nil }
        .onChange(of: prefs.apiUser) { _, _ in testResult = nil }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("API URL") {
                TextField("", text: $prefs.apiBaseURL, prompt: Text(PrefsStore.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            LabeledContent("Username") {
                TextField("", text: $prefs.apiUser, prompt: Text("admin"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            LabeledContent("API password") {
                VStack(alignment: .trailing, spacing: 6) {
                    SecureField("", text: $password, prompt: Text(keychainHint))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .onSubmit { savePassword() }

                    HStack(spacing: 8) {
                        Button("Save") { savePassword() }
                            .disabled(password.isEmpty)
                        Button("Test") { Task { await test() } }
                        Button("Forget") { confirmClear = true }
                    }
                    .controlSize(.small)
                }
            }

            if let testResult {
                LabeledContent("") {
                    HStack(spacing: 6) {
                        switch testResult {
                        case .success:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Connected successfully").font(.system(size: 11))
                        case .failure(let message):
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 300, alignment: .leading)
                }
            }

            LabeledContent("RSS-Bridge") {
                TextField("", text: $prefs.rssBridgeURL, prompt: Text("http://127.0.0.1:3000"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            Text("RSS-Bridge is only probed for the footer indicator. Clear the field to disable it.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .alert("Forget the stored API password?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                KeychainStore.delete()
                password = ""
                testResult = nil
                Task { await client.reconfigure() }
            }
        } message: {
            Text("The app will stop refreshing until you enter it again.")
        }
    }

    private var keychainHint: String {
        KeychainStore.exists() ? "•••••••• (stored)" : "Required"
    }

    // MARK: Display

    private var displaySection: some View {
        Section("Menu bar") {
            Picker("Show", selection: $prefs.menuBarTextMode) {
                ForEach(MenuBarTextMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Toggle("Show the flame indicator", isOn: $prefs.showFlameIndicator)
            Toggle("Show the candle icon", isOn: $prefs.showIcon)

            Text("The flame colour and height both track unread pressure, so the cue does not rely on colour alone.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        Section("Behaviour") {
            LabeledContent("Refresh every") {
                HStack(spacing: 8) {
                    TextField("", value: $prefs.refreshSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("seconds").foregroundStyle(.secondary)
                }
            }

            Text("Minimum 15 seconds. Twice an hour (3600s) is plenty for most feeds and is kinder to the servers you follow.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Toggle("Show the FreshRSS web UI in the panel", isOn: $prefs.useEmbeddedWebView)

            Text("Off: a native list of unread articles. On: the full FreshRSS interface embedded in the panel.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Toggle("Open at login", isOn: $prefs.launchAtLogin)
                .onChange(of: prefs.launchAtLogin) { _, newValue in
                    LoginItem.setEnabled(newValue)
                }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("black_glass_candle") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Backups") {
                Text("scripts/backup.sh")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Backing up the feed database means snapshotting a Docker volume, which this app cannot do safely from inside the sandbox-free menu bar process. Run scripts/backup.sh from the repository instead, or via the DS-mon style build wrapper.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Status") {
                Text(client.status.label)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Last refresh") {
                Text(client.relativeLastRefresh)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func savePassword() {
        guard !password.isEmpty else { return }
        let saved = KeychainStore.save(password)
        password = ""
        testResult = saved ? nil : .failure("Could not write to the Keychain.")
        Task {
            await client.reconfigure()
            if saved { await test() }
        }
    }

    private func test() async {
        await client.reconfigure()
        switch await client.testConnection() {
        case .success:
            testResult = .success
            await client.refresh(manual: true)
        case .failure(let error):
            testResult = .failure(error.errorDescription ?? "Unknown error")
        }
    }
}

// MARK: - Launch at login

/// Thin wrapper over `SMAppService`.
///
/// `SMAppService.mainApp` is the modern replacement for `SMLoginItemSetEnabled`,
/// which is deprecated. The registration is per-app and stored by the system, so
/// it can genuinely fail (unsigned app, moved bundle) — hence the Bool result
/// rather than a silent no-op.
enum LoginItem {
    static func setEnabled(_ enabled: Bool) {
        Task { @MainActor in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                print("[LoginItem] \(enabled ? "register" : "unregister") failed: \(error)")
            }
        }
    }
}
