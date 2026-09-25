import AppKit
import Foundation
import NetFS
import UniformTypeIdentifiers

@MainActor
final class BrowserViewModel: ObservableObject {
    static weak var shared: BrowserViewModel?
    @Published var path = "/"
    @Published var entries: [DriveEntry] = []
    @Published var filter = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var connectionLabel = "Remote"
    @Published var uploads: [UploadProgress] = []
    @Published var showHidden = false
    @Published var showSetup = false
    @Published var newFolderRequested = false
    @Published var renameTarget: DriveEntry?
    @Published var deleteTargets: [DriveEntry] = []
    @Published var isMountingFinder = false
    @Published var finderMountURL: URL?
    @Published var previewingName: String?

    private let settings: SettingsStore
    private let api = APIClient()
    private var backStack: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var usingLocal = false
    private var pendingUploads: [PendingFile] = []
    private var activeUploadTasks: [UUID: Task<Void, Never>] = [:]
    private var retryableUploads: [UUID: PendingFile] = [:]

    private var activeSettings: ConnectionSettings { get throws { try settings.snapshot(local: usingLocal) } }

    init(settings: SettingsStore) {
        self.settings = settings
        Self.shared = self
        clearTemporaryFiles()
        showSetup = !settings.isConfigured
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if NSApp.isActive { await self?.refresh(silently: true) }
            }
        }
    }

    deinit { refreshTask?.cancel() }

    var visibleEntries: [DriveEntry] {
        entries.filter { entry in
            (showHidden || !entry.name.hasPrefix(".")) &&
            (filter.isEmpty || entry.name.localizedCaseInsensitiveContains(filter))
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { path != "/" }
    var hasRunningUploads: Bool { !pendingUploads.isEmpty || !activeUploadTasks.isEmpty }

    func configured() {
        settings.save()
        showSetup = false
        Task { await refresh() }
    }

    func showInFinder() {
        guard !isMountingFinder else { return }
        isMountingFinder = true
        Task {
            defer { isMountingFinder = false }
            do {
                let connection: ConnectionSettings
                if settings.localAddress != nil,
                   let local = try? settings.snapshot(local: true),
                   (try? await api.list("/", settings: local, timeout: 2)) != nil {
                    connection = local
                } else {
                    connection = try settings.snapshot()
                    if !settings.cloudflareClientID.isEmpty {
                        throw ShareError.finderAccessUnsupported
                    }
                }
                guard let davURL = URL(string: "/Share/", relativeTo: connection.baseURL)?.absoluteURL else {
                    throw ShareError.invalidURL
                }
                let key = connection.accessKey
                let mountedPath = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    var points: Unmanaged<CFArray>?
                    let status = NetFSMountURLSync(davURL as CFURL, nil, "share" as CFString, key as CFString, nil, nil, &points)
                    guard status == 0 else { throw ShareError.finderMountFailed(Int(status)) }
                    guard let path = (points?.takeRetainedValue() as? [String])?.first else {
                        throw ShareError.finderMountFailed(-1)
                    }
                    return path
                }.value
                let url = URL(fileURLWithPath: mountedPath, isDirectory: true)
                finderMountURL = url
                NSWorkspace.shared.open(url)
            } catch { errorMessage = "Finder: \(error.localizedDescription)" }
        }
    }

    func refresh(silently: Bool = false) async {
        guard settings.isConfigured else { showSetup = true; return }
        if !silently { isLoading = true }
        defer { isLoading = false }
        do {
            let result: ListResponse
            if settings.localAddress != nil {
                do {
                    result = try await api.list(path, settings: settings.snapshot(local: true), timeout: 2)
                    usingLocal = true
                    connectionLabel = "Local network"
                    entries = result.entries
                    errorMessage = nil
                    return
                } catch ShareError.unauthorized {
                    throw ShareError.unauthorized
                } catch {
                    usingLocal = false
                }
            }
            result = try await api.list(path, settings: settings.snapshot())
            connectionLabel = "Remote"
            entries = result.entries
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func navigate(to newPath: String) async {
        if newPath != path { backStack.append(path); path = newPath }
        await refresh()
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        path = previous
        await refresh()
    }

    func goUp() async {
        guard path != "/" else { return }
        let parts = path.split(separator: "/").dropLast()
        await navigate(to: parts.isEmpty ? "/" : "/" + parts.joined(separator: "/"))
    }

    func fullPath(_ name: String) -> String { (path == "/" ? "" : path) + "/" + name }

    func open(_ entry: DriveEntry) async {
        if entry.isDirectory { await navigate(to: fullPath(entry.name)); return }
        do {
            let config = try activeSettings
            let filePath = fullPath(entry.name)
            let extensionName = (entry.name as NSString).pathExtension.lowercased()
            let nativeMedia: Set<String> = ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "aac", "wav"]
            let externalMedia: Set<String> = ["mkv", "avi", "flac", "ogg"]
            if nativeMedia.contains(extensionName) {
                PlayerPresenter.open(url: try await api.link(filePath, settings: config), title: entry.name)
            } else if externalMedia.contains(extensionName) {
                let streamURL = try await api.link(filePath, settings: config)
                try openExternally(streamURL)
            } else {
                if (entry.size ?? 0) > 2_000_000_000 && !confirmLargeOpen(entry) { return }
                let folder = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(entry.name)
                try await api.download(filePath, to: destination, settings: config)
                try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
                NSWorkspace.shared.open(destination)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func preview(_ entry: DriveEntry) async {
        guard !entry.isDirectory else { return }
        let extensionName = (entry.name as NSString).pathExtension.lowercased()
        let media: Set<String> = ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "aac", "wav", "mkv", "avi", "flac", "ogg"]
        if media.contains(extensionName) {
            await open(entry)
            return
        }
        do {
            if (entry.size ?? 0) > 512_000_000 && !confirmLargeOpen(entry) { return }
            previewingName = entry.name
            defer { previewingName = nil }
            let folder = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(entry.name)
            try await api.download(fullPath(entry.name), to: destination, settings: activeSettings)
            QuickLookPresenter.show(url: destination, title: entry.name)
        } catch { errorMessage = error.localizedDescription }
    }

    private func openExternally(_ url: URL) throws {
        let app = settings.externalPlayerPath.isEmpty ? SettingsStore.detectPlayer() : settings.externalPlayerPath
        guard !app.isEmpty else { throw ShareError.externalPlayerMissing }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: configuration)
    }

    private func confirmLargeOpen(_ entry: DriveEntry) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download \((entry.size ?? 0).fileSizeText) to open this file?"
        alert.informativeText = "Non-media files need a temporary local copy. Share deletes its temporary folder when it quits."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func requestNewFolder() { newFolderRequested = true }

    func createFolder(named rawName: String) async {
        let name = rawName.precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { return }
        do { try await api.mkdir(fullPath(name), settings: activeSettings); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func rename(_ entry: DriveEntry, to rawName: String) async {
        let name = rawName.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != entry.name else { return }
        do { try await api.move(from: fullPath(entry.name), to: fullPath(name), settings: activeSettings); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func move(_ names: [String], into destinationFolder: String) async {
        guard !names.isEmpty else { return }
        do {
            let config = try activeSettings
            _ = try await api.list(destinationFolder, settings: config)
            for name in names {
                let source = fullPath(name)
                let destination = (destinationFolder == "/" ? "" : destinationFolder) + "/" + name
                if source == destination { continue }
                if destinationFolder == source || destinationFolder.hasPrefix(source + "/") {
                    throw ShareError.server("bad_path", "A folder cannot be moved inside itself.", nil)
                }
                try await api.move(from: source, to: destination, settings: config)
            }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func moveWithPrompt(_ entry: DriveEntry) {
        let alert = NSAlert()
        alert.messageText = "Move \(entry.name)"
        alert.informativeText = "Enter the destination folder path on Share."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = path
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let destination = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await move([entry.name], into: destination.isEmpty ? "/" : destination) }
        }
    }

    func deleteConfirmed() async {
        let targets = deleteTargets
        deleteTargets = []
        do {
            let config = try activeSettings
            for entry in targets { try await api.delete(fullPath(entry.name), settings: config) }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func download(_ entry: DriveEntry) async {
        guard !entry.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try await api.download(fullPath(entry.name), to: destination, settings: activeSettings) }
        catch { errorMessage = error.localizedDescription }
    }

    func chooseUploads() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        enqueueUploads(urls: panel.urls, destination: path)
    }

    func acceptDrop(_ urls: [URL], into destination: String? = nil) -> Bool {
        guard !urls.isEmpty else { return false }
        enqueueUploads(urls: urls, destination: destination ?? path)
        return true
    }

    private func enqueueUploads(urls: [URL], destination: String) {
        let files = collectFiles(urls, destination: destination)
        for item in files {
            uploads.append(UploadProgress(id: item.id, name: item.url.lastPathComponent, sent: 0, total: item.size))
            pendingUploads.append(item)
        }
        pumpUploads()
    }

    private func pumpUploads() {
        while activeUploadTasks.count < 2 && !pendingUploads.isEmpty {
            let item = pendingUploads.removeFirst()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.uploadOne(item)
                self.activeUploadTasks.removeValue(forKey: item.id)
                self.pumpUploads()
            }
            activeUploadTasks[item.id] = task
        }
        if hasRunningUploads {
            if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Uploading to Share") }
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            Task { await refresh() }
        }
    }

    func cancelUpload(_ id: UUID) {
        if let index = pendingUploads.firstIndex(where: { $0.id == id }) {
            pendingUploads.remove(at: index)
            updateProgress(id) { $0.status = .cancelled }
            pumpUploads()
            return
        }
        if let task = activeUploadTasks[id] {
            updateProgress(id) { $0.status = .cancelling }
            task.cancel()
        }
    }

    func retryUpload(_ id: UUID) {
        guard let item = retryableUploads.removeValue(forKey: id) else { return }
        updateProgress(id) { $0.sent = 0; $0.bytesPerSecond = 0; $0.status = .queued }
        pendingUploads.append(item)
        pumpUploads()
    }

    func clearFinishedUploads() {
        uploads.removeAll {
            switch $0.status { case .completed, .cancelled: return true; default: return false }
        }
    }

    private func updateProgress(_ id: UUID, _ edit: (inout UploadProgress) -> Void) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        edit(&uploads[index])
    }

    struct PendingFile: Sendable {
        let id: UUID
        let url: URL
        let accessRoot: URL
        let remotePath: String
        let size: Int64
    }

    private func collectFiles(_ urls: [URL], destination: String) -> [PendingFile] {
        var output: [PendingFile] = []
        let skip: Set<String> = [".DS_Store", ".localized", "Icon\r"]
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let rootName = url.lastPathComponent.precomposedStringWithCanonicalMapping
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let file as URL in enumerator {
                        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                              !skip.contains(file.lastPathComponent), !file.lastPathComponent.hasPrefix("._") else { continue }
                        let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
                        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        output.append(PendingFile(id: UUID(), url: file, accessRoot: url, remotePath: (destination == "/" ? "" : destination) + "/" + rootName + "/" + relative.precomposedStringWithCanonicalMapping, size: size))
                    }
                }
            } else if !skip.contains(url.lastPathComponent) && !url.lastPathComponent.hasPrefix("._") {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                output.append(PendingFile(id: UUID(), url: url, accessRoot: url, remotePath: (destination == "/" ? "" : destination) + "/" + url.lastPathComponent.precomposedStringWithCanonicalMapping, size: size))
            }
        }
        return output
    }

    private func uploadOne(_ item: PendingFile) async {
        let url = item.url
        let remotePath = item.remotePath
        let progressID = item.id
        var serverID: String?
        let started = Date()
        do {
            try Task.checkCancellation()
            let rootScope = item.accessRoot.startAccessingSecurityScopedResource()
            defer { if rootScope { item.accessRoot.stopAccessingSecurityScopedResource() } }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values.fileSize ?? 0)
            let parent = (remotePath as NSString).deletingLastPathComponent
            if parent != path { try? await api.mkdir(parent, settings: activeSettings) }
            updateProgress(progressID) { $0.status = .uploading }
            var created: UploadCreated
            do { created = try await api.beginUpload(path: remotePath, size: size, modified: values.contentModificationDate ?? Date(), overwrite: false, settings: activeSettings) }
            catch ShareError.server(let code, _, _) where code == "exists" {
                guard confirmReplace(url.lastPathComponent) else { updateProgress(progressID) { $0.status = .cancelled }; return }
                created = try await api.beginUpload(path: remotePath, size: size, modified: values.contentModificationDate ?? Date(), overwrite: true, settings: activeSettings)
            }
            serverID = created.id
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var offset = created.received
            try handle.seek(toOffset: UInt64(offset))
            while offset < size {
                try Task.checkCancellation()
                let count = Int(min(created.chunkSize, size - offset))
                guard let data = try handle.read(upToCount: count), !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
                var attempt = 0
                while true {
                    let chunkStart = offset
                    do {
                        offset = try await api.putChunk(id: created.id, offset: offset, data: data, settings: activeSettings) { [weak self] sentInChunk in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                let current = min(size, chunkStart + sentInChunk)
                                let elapsed = max(Date().timeIntervalSince(started), 0.1)
                                self.updateProgress(progressID) { $0.sent = current; $0.bytesPerSecond = Double(current) / elapsed }
                            }
                        }
                        break
                    }
                    catch ShareError.server(let code, _, let received) where code == "offset_mismatch" {
                        if let received {
                            offset = received
                        } else {
                            offset = try await api.uploadStatus(id: created.id, settings: activeSettings).received
                        }
                        try handle.seek(toOffset: UInt64(offset))
                        break
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        attempt += 1; if attempt >= 10 { throw error }
                        try await Task.sleep(for: .seconds(min(30, 1 << min(attempt - 1, 4))))
                        await refresh(silently: true)
                        offset = try await api.uploadStatus(id: created.id, settings: activeSettings).received
                        try handle.seek(toOffset: UInt64(offset))
                    }
                }
                let elapsed = max(Date().timeIntervalSince(started), 0.1)
                updateProgress(progressID) { $0.sent = offset; $0.bytesPerSecond = Double(offset) / elapsed }
            }
            try Task.checkCancellation()
            try await api.completeUpload(id: created.id, settings: activeSettings)
            serverID = nil
            updateProgress(progressID) { $0.sent = size; $0.status = .completed }
        } catch is CancellationError {
            if let serverID, let config = try? activeSettings {
                let cleanup = Task { await api.abortUpload(id: serverID, settings: config) }
                await cleanup.value
            }
            updateProgress(progressID) { $0.status = .cancelled }
        } catch {
            if Task.isCancelled {
                if let serverID, let config = try? activeSettings {
                    let cleanup = Task { await api.abortUpload(id: serverID, settings: config) }
                    await cleanup.value
                }
                updateProgress(progressID) { $0.status = .cancelled }
                return
            }
            if let serverID, let config = try? activeSettings {
                let cleanup = Task { await api.abortUpload(id: serverID, settings: config) }
                await cleanup.value
            }
            updateProgress(progressID) { $0.status = .failed(error.localizedDescription) }
            retryableUploads[progressID] = item
            errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func confirmReplace(_ name: String) -> Bool {
        let alert = NSAlert(); alert.messageText = "Replace \(name)?"; alert.informativeText = "An item with this name already exists for both people."; alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Skip")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var tempRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true) }
    func clearTemporaryFiles() { try? FileManager.default.removeItem(at: tempRoot) }
}
