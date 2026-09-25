import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browser: BrowserViewModel
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share Settings").font(.title2.bold())
            SettingsFields()
            if !result.isEmpty { Text(result).font(.callout).foregroundStyle(result == "Connection successful." ? .green : .red) }
            HStack {
                Button("Test Connection") { test() }
                Spacer()
                Button("Save") { settings.save(); Task { await browser.refresh() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func test() {
        settings.save(); result = "Testing…"
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
            SecureField("Access key", text: $settings.accessKey)
            Section("Optional Cloudflare Access") {
                TextField("Client ID", text: $settings.cloudflareClientID)
                SecureField("Client secret", text: $settings.cloudflareClientSecret)
            }
            TextField("External player", text: $settings.externalPlayerPath, prompt: Text("Auto-detect IINA or VLC"))
        }
        .formStyle(.grouped)
    }
}
