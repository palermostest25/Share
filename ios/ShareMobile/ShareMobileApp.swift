import SwiftUI
import WebKit

@main
struct ShareMobileApp: App {
    @StateObject private var browser = ShareBrowser()

    var body: some Scene {
        WindowGroup {
            ShareMobileView()
                .environmentObject(browser)
        }
    }
}

struct ShareMobileView: View {
    @EnvironmentObject private var browser: ShareBrowser
    @State private var editingServer = false
    @State private var serverInput = ""
    @State private var addressError = false

    var body: some View {
        VStack(spacing: 0) {
            ShareWebView(browser: browser)
            HStack {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                if browser.isLoading { ProgressView() }
                Text("Share").font(.subheadline.bold())
                Spacer()
                Button { serverInput = browser.server; editingServer = true } label: { Image(systemName: "server.rack") }
                Button { UIApplication.shared.open(URL(string: "https://github.com/palermostest25/Share/releases/latest")!) } label: { Image(systemName: "arrow.down.circle") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(.bar)
        }
        .alert("Share server", isPresented: $editingServer) {
            TextField("https://share.denby.dev", text: $serverInput)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { }
            Button("Connect") {
                if !browser.connect(serverInput) { addressError = true }
            }
        } message: {
            Text("Use HTTPS remotely, or private-LAN HTTP on a trusted network.")
        }
        .alert("Invalid server address", isPresented: $addressError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Enter an HTTPS address or private-LAN HTTP address without a path.")
        }
    }
}

private struct ShareWebView: UIViewRepresentable {
    let browser: ShareBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

final class ShareBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published private(set) var canGoBack = false
    @Published private(set) var isLoading = false
    @Published private(set) var server: String
    let webView: WKWebView

    override init() {
        server = UserDefaults.standard.string(forKey: "server") ?? "https://share.denby.dev"
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        load()
    }

    func load() { if let url = URL(string: server) { webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)) } }
    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }

    func connect(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard Self.valid(candidate) else { return false }
        server = candidate
        UserDefaults.standard.set(candidate, forKey: "server")
        load()
        return true
    }

    private static func valid(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168)
    }

    private func sameOrigin(_ url: URL) -> Bool {
        guard let current = URLComponents(string: server), let next = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return current.scheme?.lowercased() == next.scheme?.lowercased() &&
            current.host?.lowercased() == next.host?.lowercased() && current.port == next.port
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if !sameOrigin(url) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if sameOrigin(url) { webView.load(navigationAction.request) }
            else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = (suggestedFilename as NSString).lastPathComponent
        var destination = documents.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let name = (safeName as NSString).deletingPathExtension
            let ext = (safeName as NSString).pathExtension
            destination = documents.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : "." + ext)")
        }
        completionHandler(destination)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false; canGoBack = webView.canGoBack }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false }
}
