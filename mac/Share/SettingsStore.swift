import AppKit
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static weak var shared: SettingsStore?
    @Published var isLoadingCredentials = true
    @Published var serverURL: String
    @Published var localURL: String
    @Published var accessKey: String
	@Published var username: String
	@Published var password: String
	@Published var sessionToken: String
    @Published var cloudflareClientID: String
    @Published var cloudflareClientSecret: String
    @Published var externalPlayerPath: String

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "https://share.denby.dev"
        localURL = UserDefaults.standard.string(forKey: "localURL") ?? ""
		accessKey = ""
		username = UserDefaults.standard.string(forKey: "username") ?? ""
		password = ""
		sessionToken = ""
        cloudflareClientID = UserDefaults.standard.string(forKey: "cloudflareClientID") ?? ""
        cloudflareClientSecret = ""
        externalPlayerPath = UserDefaults.standard.string(forKey: "externalPlayerPath") ?? Self.detectPlayer()
        Self.shared = self
    }

    func loadCredentials() async {
        let credentials = await Task.detached(priority: .userInitiated) {
            (
                Keychain.read("access-key"),
                Keychain.read("account-password"),
                Keychain.read("session-token"),
                Keychain.read("cloudflare-client-secret")
            )
        }.value
        guard isLoadingCredentials else { return }
        (accessKey, password, sessionToken, cloudflareClientSecret) = credentials
        isLoadingCredentials = false
    }

    var isConfigured: Bool {
		URL(string: serverURL)?.scheme == "https" && ((username.count >= 2 && password.count >= 12) || accessKey.count >= 32)
    }

    func save() {
        isLoadingCredentials = false
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        localURL = localURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(localURL, forKey: "localURL")
        UserDefaults.standard.set(cloudflareClientID, forKey: "cloudflareClientID")
        UserDefaults.standard.set(externalPlayerPath, forKey: "externalPlayerPath")
        Keychain.write(accessKey, account: "access-key")
		UserDefaults.standard.set(username, forKey: "username")
		Keychain.write(password, account: "account-password")
		Keychain.write(sessionToken, account: "session-token")
        Keychain.write(cloudflareClientSecret, account: "cloudflare-client-secret")
    }

    func snapshot(local: Bool = false) throws -> ConnectionSettings {
        if local {
            guard let url = localAddress else { throw ShareError.invalidURL }
			return ConnectionSettings(baseURL: url, accessKey: username.isEmpty ? accessKey : sessionToken, cloudflareClientID: "", cloudflareClientSecret: "")
        }
        guard let url = URL(string: serverURL), url.scheme == "https", url.host != nil else { throw ShareError.invalidURL }
		return ConnectionSettings(baseURL: url, accessKey: username.isEmpty ? accessKey : sessionToken, cloudflareClientID: cloudflareClientID, cloudflareClientSecret: cloudflareClientSecret)
    }

    var localAddress: URL? {
        guard !localURL.isEmpty, let url = URL(string: localURL), url.scheme == "http",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return url }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        let isPrivate = parts[0] == 10 || parts[0] == 127 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168)
        return isPrivate ? url : nil
    }

    static func detectPlayer() -> String {
        let candidates = ["/Applications/IINA.app", "/Applications/VLC.app"]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? ""
    }
}

struct ConnectionSettings: Sendable {
    let baseURL: URL
    let accessKey: String
    let cloudflareClientID: String
    let cloudflareClientSecret: String
}
