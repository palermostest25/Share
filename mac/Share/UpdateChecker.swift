import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class UpdateStatus: ObservableObject {
    static let shared = UpdateStatus()
    @Published var message: String?
}

@MainActor
enum UpdateChecker {
    private static var isChecking = false
    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }
    private struct Asset: Decodable { let name: String; let browser_download_url: URL }

    static func check(silent: Bool = false) async {
        guard !isChecking else { return }
        if silent {
            let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        }
        isChecking = true
        if !silent { UpdateStatus.shared.message = "Checking for updates…" }
        defer {
            isChecking = false
            UpdateStatus.shared.message = nil
        }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/palermostest25/Share/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ShareMac/1.3.1", forHTTPHeaderField: "User-Agent")
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
            guard let asset = release.assets.first(where: { $0.name == "Share-\(latest)-macOS-universal.zip" }),
                  let sums = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else {
                throw UpdateError.missingReleaseAsset
            }
            let prompt = NSAlert()
            UpdateStatus.shared.message = nil
            NSApp.activate(ignoringOtherApps: true)
            prompt.messageText = "Share \(latest) is available"
            prompt.informativeText = "Install this update now? Share will quit and reopen in the menu bar. The previous app will be kept as a backup."
            prompt.addButton(withTitle: "Install and relaunch")
            prompt.addButton(withTitle: "Later")
            if prompt.runModal() != .alertFirstButtonReturn { return }
            if BrowserViewModel.shared?.hasRunningUploads == true {
                alert("Finish uploads first", "The update can install when current uploads have finished.")
                return
            }
            UpdateStatus.shared.message = "Downloading update…"
            try await install(asset: asset, sums: sums, latest: latest, current: current)
        } catch {
            if !silent { alert("Could not check for updates", error.localizedDescription) }
        }
    }

    private enum UpdateError: LocalizedError {
        case missingReleaseAsset, checksumMismatch, invalidApp, extractionFailed, stagingFailed, finderBusy
        var errorDescription: String? {
            switch self {
            case .missingReleaseAsset: "The release is missing its Mac app or checksum file."
            case .checksumMismatch: "The downloaded update did not match its SHA-256 checksum."
            case .invalidApp: "The archive does not contain the expected Share app and version."
            case .extractionFailed: "Could not unpack the update."
            case .stagingFailed: "Could not prepare the update beside the installed app."
            case .finderBusy: "Close files open from Share in Finder, then try the update again."
            }
        }
    }

    private static func install(asset: Asset, sums: Asset, latest: String, current: String) async throws {
        let (temporary, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let (sumData, _) = try await URLSession.shared.data(from: sums.browser_download_url)
        guard let sumText = String(data: sumData, encoding: .utf8),
              let line = sumText.split(separator: "\n").first(where: { $0.hasSuffix("  \(asset.name)") }),
              let expected = line.split(separator: " ").first, expected.count == 64 else {
            throw UpdateError.checksumMismatch
        }
        let actual = SHA256.hash(data: try Data(contentsOf: temporary, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(String(expected)) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ShareUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(asset.name)
        try fm.moveItem(at: temporary, to: archive)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        guard try await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) == 0 else {
            throw UpdateError.extractionFailed
        }
        let candidate = unpacked.appendingPathComponent("Share.app", isDirectory: true)
        guard let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == "dev.denby.share",
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == latest,
              fm.fileExists(atPath: candidate.appendingPathComponent("Contents/MacOS/Share").path) else {
            throw UpdateError.invalidApp
        }

        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard target.lastPathComponent == "Share.app" else { throw UpdateError.invalidApp }
        let parent = target.deletingLastPathComponent()
        let marker = UUID().uuidString.prefix(8)
        let staged = parent.appendingPathComponent(".Share-update-\(marker).app", isDirectory: true)
        let backup = parent.appendingPathComponent("Share-\(current)-backup-\(marker).app", isDirectory: true)
        guard try await run("/usr/bin/ditto", [candidate.path, staged.path]) == 0 else {
            throw UpdateError.stagingFailed
        }
        UpdateStatus.shared.message = "Installing update…"
        guard BrowserViewModel.shared?.unmountFinder() != false else {
            try? fm.removeItem(at: staged)
            throw UpdateError.finderBusy
        }
        try? fm.removeItem(at: work)

        // The helper inherits no credentials. It receives validated absolute
        // paths as separate arguments and replaces the app only after exit.
        let script = """
        target=$1
        staged=$2
        backup=$3
        parent_pid=$4
        n=0
        while /bin/kill -0 "$parent_pid" 2>/dev/null && [ "$n" -lt 60 ]; do
          /bin/sleep 1
          n=$((n + 1))
        done
        if /bin/kill -0 "$parent_pid" 2>/dev/null; then exit 1; fi
        /bin/mv "$target" "$backup" || exit 1
        if /bin/mv "$staged" "$target"; then
          /usr/bin/open "$target"
        else
          /bin/mv "$backup" "$target"
          exit 1
        fi
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "share-updater", target.path, staged.path, backup.path, String(ProcessInfo.processInfo.processIdentifier)]
        try helper.run()
        NSApp.terminate(nil)
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
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
        NSApp.activate(ignoringOtherApps: true)
        let box = NSAlert()
        box.messageText = title
        box.informativeText = message
        box.runModal()
    }
}
