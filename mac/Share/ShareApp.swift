import SwiftUI

@main
struct ShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var browser: BrowserViewModel

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _browser = StateObject(wrappedValue: BrowserViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(browser)
                .frame(minWidth: 820, minHeight: 520)
				.task { await UpdateChecker.check(silent: true) }
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
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(browser)
                .frame(width: 520)
                .padding(22)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        browser.clearTemporaryFiles()
        return .terminateNow
    }
}
