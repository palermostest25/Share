import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browser: BrowserViewModel
    @State private var result = ""
    @State private var openAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share Settings").font(.title2.bold())
            SettingsFields()
            Toggle("Keep Share in the menu bar after login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        result = "Login item: \(error.localizedDescription)"
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if !result.isEmpty { Text(result).font(.callout).foregroundStyle(result == "Connection successful." ? .green : .red) }
            HStack {
                Button("Test Connection") { test() }
				Button("Check for Updates") { Task { await UpdateChecker.check() } }
                Spacer()
                Button("Save") { settings.save(); browser.resetConnection(); Task { await browser.refresh() } }.buttonStyle(.borderedProminent)
            }
        }
        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func test() {
        settings.save(); browser.resetConnection(); result = "Testing…"
        Task {
            await browser.refresh()
            result = browser.errorMessage ?? "Connection successful."
        }
    }
}

struct SettingsFields: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            TextField("Server URL", text: $settings.serverURL, prompt: Text("https://share.denby.dev"))
            TextField("Local URL (optional)", text: $settings.localURL, prompt: Text("http://192.168.1.10:8080"))
			TextField("Username", text: $settings.username)
			SecureField("Password", text: $settings.password)
			SecureField("Legacy access key (optional)", text: $settings.accessKey)
			Text("Create your account in the web UI first. Credentials are kept in macOS Keychain. Local HTTP sign-in sends credentials over your LAN; use a trusted network or HTTPS.").font(.caption).foregroundStyle(.secondary)
            Section("Optional Cloudflare Access") {
                TextField("Client ID", text: $settings.cloudflareClientID)
                SecureField("Client secret", text: $settings.cloudflareClientSecret)
            }
            TextField("External player", text: $settings.externalPlayerPath, prompt: Text("Auto-detect IINA or VLC"))
        }
        .formStyle(.grouped)
    }
}
