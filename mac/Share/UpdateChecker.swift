import AppKit
import Foundation

@MainActor
enum UpdateChecker {
    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }
    private struct Asset: Decodable { let name: String; let browser_download_url: URL }

    static func check(silent: Bool = false) async {
        if silent {
            let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/palermostest25/Share/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ShareMac/1.2.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard compare(latest, current) == .orderedDescending else {
                if !silent { alert("Share is up to date", "You have version \(current).") }
                return
            }
            let prompt = NSAlert()
            prompt.messageText = "Share \(latest) is available"
            prompt.informativeText = "Download the new macOS app from GitHub Releases? This unsigned build requires you to replace the old app manually."
            prompt.addButton(withTitle: "Download update")
            prompt.addButton(withTitle: "Later")
            if prompt.runModal() != .alertFirstButtonReturn { return }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix("macOS-universal.zip") }) else {
                NSWorkspace.shared.open(release.html_url)
                return
            }
            let (temporary, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            var destination = downloads.appendingPathComponent(asset.name)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = downloads.appendingPathComponent("Share-\(latest)-\(UUID().uuidString.prefix(8)).zip")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            alert("Update downloaded", "The archive is in Downloads. Quit Share, expand it, and replace the old app.")
        } catch {
            if !silent { alert("Could not check for updates", error.localizedDescription) }
        }
    }

    private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").compactMap { Int($0) }
        let rhs = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lhs.count, rhs.count) {
            let x = i < lhs.count ? lhs[i] : 0
            let y = i < rhs.count ? rhs[i] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    private static func alert(_ title: String, _ message: String) {
        let box = NSAlert()
        box.messageText = title
        box.informativeText = message
        box.runModal()
    }
}
