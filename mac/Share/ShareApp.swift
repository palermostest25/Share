import SwiftUI

@main
struct ShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var browser: BrowserViewModel

    init() {
        let settings = SettingsStore()
        let browser = BrowserViewModel(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _browser = StateObject(wrappedValue: browser)
    }

    var body: some Scene {
        MenuBarExtra("Share", systemImage: "externaldrive.connected.to.line.below") {
            ShareMenuBarContent()
                .environmentObject(settings)
                .environmentObject(browser)
        }
        .menuBarExtraStyle(.menu)
        mainWindow
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(browser)
                .frame(width: 520)
                .padding(22)
        }
    }

    private var mainWindow: some Scene {
        WindowGroup("Share", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(browser)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Upload…") { browser.chooseUploads() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("New Folder") { browser.requestNewFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                Button("Show Share in Finder") { browser.showInFinder() }
                Toggle("Show Hidden Files", isOn: $browser.showHidden)
                Button("Refresh") { Task { await browser.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
			CommandMenu("Help") { Button("Check for Updates…") { Task { await UpdateChecker.check() } } }
        }
    }
}

private struct ShareMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updateStatus = UpdateStatus.shared
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browser: BrowserViewModel

    var body: some View {
        Button("Open Share") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(browser.isMountingFinder ? "Connecting Finder…" : "Show Share in Finder") {
            browser.showInFinder()
        }
        .disabled(!settings.isConfigured || browser.isMountingFinder)
        Button("Reconnect Finder") {
            browser.resetFinderRetry()
            Task { await browser.refresh(silently: true) }
        }
        .disabled(!settings.isConfigured || browser.isMountingFinder)
        Divider()
        Text(settings.isLoadingCredentials ? "Waiting for macOS Keychain…" : browser.finderMountURL == nil ? "Finder: disconnected" : "Finder: connected")
        Text(browser.hasRunningUploads ? "Uploads in progress" : browser.connectionLabel)
        Divider()
        SettingsLink { Text("Settings…") }
        Button(updateStatus.message ?? "Check for Updates…") { Task { await UpdateChecker.check() } }
            .disabled(updateStatus.message != nil)
        Divider()
        Button("Quit Share") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task {
            await UpdateChecker.check(silent: true)
        }
        Task {
            await SettingsStore.shared?.loadCredentials()
            await BrowserViewModel.shared?.refresh(silently: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let browser = BrowserViewModel.shared else { return .terminateNow }
        if browser.hasRunningUploads {
            let alert = NSAlert()
            alert.messageText = "Uploads are still running"
            alert.informativeText = "Quitting now abandons them. The server will remove incomplete uploads after 24 hours."
            alert.addButton(withTitle: "Keep Uploading")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        if !browser.unmountFinder() { return .terminateCancel }
        browser.clearTemporaryFiles()
        return .terminateNow
    }
}
