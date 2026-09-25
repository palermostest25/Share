import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browser: BrowserViewModel
    @State private var selection = Set<DriveEntry.ID>()
    @State private var folderName = "untitled folder"
    @State private var renameName = ""
    @State private var showingTransfers = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if let error = browser.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Retry") { Task { await browser.refresh() } }
                    Button("Settings…") { openSettings() }
                }
                .padding(10).background(.yellow.opacity(0.08))
            }
            table
            statusBar
        }
        .toolbar { toolbar }
        .task { await browser.refresh() }
        .onChange(of: browser.path) { _, _ in selection.removeAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await browser.refresh(silently: true) } }
        .sheet(isPresented: $browser.showSetup) { SetupView().environmentObject(settings).environmentObject(browser) }
        .alert("New Folder", isPresented: $browser.newFolderRequested) {
            TextField("Folder name", text: $folderName)
            Button("Create") { Task { await browser.createFolder(named: folderName); folderName = "untitled folder" } }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename", isPresented: Binding(get: { browser.renameTarget != nil }, set: { if !$0 { browser.renameTarget = nil } })) {
            TextField("Name", text: $renameName)
            Button("Rename") { if let entry = browser.renameTarget { Task { await browser.rename(entry, to: renameName) } }; browser.renameTarget = nil }
            Button("Cancel", role: .cancel) { browser.renameTarget = nil }
        }
        .alert("Delete \(browser.deleteTargets.count) item\(browser.deleteTargets.count == 1 ? "" : "s")?", isPresented: Binding(get: { !browser.deleteTargets.isEmpty }, set: { if !$0 { browser.deleteTargets = [] } })) {
            Button("Delete", role: .destructive) { Task { await browser.deleteConfirmed() } }
            Button("Cancel", role: .cancel) { browser.deleteTargets = [] }
        } message: {
            Text("They’ll be gone for both of you. ZFS snapshots are the recovery path.")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                _ = browser.acceptDrop(urls)
            }
            return true
        }
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            ForEach(breadcrumbs, id: \.path) { crumb in
                if crumb.path != "/" { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(crumb.name) { Task { await browser.navigate(to: crumb.path) } }.buttonStyle(.plain)
            }
            Spacer()
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $browser.filter).textFieldStyle(.plain).frame(width: 180)
        }
        .padding(.horizontal, 14).frame(height: 42).background(.bar)
    }

    private var table: some View {
        DriveTableView(path: browser.path, entries: browser.visibleEntries, selection: $selection, browser: browser)
        .overlay { if browser.visibleEntries.isEmpty && !browser.isLoading { ContentUnavailableView("This folder is empty", systemImage: "folder") } }
    }

    private var statusBar: some View {
        HStack {
            Text("\(browser.visibleEntries.count) items")
            Spacer()
            if browser.isLoading { ProgressView().controlSize(.small) }
            if let name = browser.previewingName { Text("Preparing preview: \(name)").foregroundStyle(.secondary) }
            if !browser.uploads.isEmpty {
                Button { showingTransfers.toggle() } label: {
                    Label(browser.hasRunningUploads ? "Transfers running" : "Transfers", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingTransfers, arrowEdge: .top) { transferPopover }
            }
            Text("\(browser.connectionLabel) · Files stay on your NAS").foregroundStyle(.secondary)
        }
        .font(.caption).padding(.horizontal, 14).frame(height: 30).background(.bar)
    }

    private var transferPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { browser.clearFinishedUploads() }.font(.caption)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(browser.uploads) { upload in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(upload.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if upload.status.canCancel {
                                    Button("Cancel") { browser.cancelUpload(upload.id) }
                                        .font(.caption)
                                } else if upload.status.canRetry {
                                    Button("Retry") { browser.retryUpload(upload.id) }
                                        .font(.caption)
                                }
                            }
                            ProgressView(value: upload.fraction)
                            Text(upload.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 420)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await browser.goBack() } } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack)
            Button { Task { await browser.goUp() } } label: { Image(systemName: "arrow.up") }.disabled(!browser.canGoUp).keyboardShortcut(.upArrow, modifiers: .command)
            Button { Task { await browser.refresh() } } label: { Image(systemName: "arrow.clockwise") }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { browser.showInFinder() } label: {
                Label(browser.isMountingFinder ? "Connecting Finder…" : "Show in Finder", systemImage: "sidebar.left")
            }
            .disabled(browser.isMountingFinder || !settings.isConfigured)
            Button { browser.requestNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Button { browser.chooseUploads() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
        }
    }

    private var breadcrumbs: [(name: String, path: String)] {
        var result = [("Share", "/")], current = ""
        for part in browser.path.split(separator: "/") { current += "/" + part; result.append((String(part), current)) }
        return result
    }

    private func openSettings() { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
}

struct SetupView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browser: BrowserViewModel
    @State private var testing = false
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 35)).foregroundStyle(.tint); Text("Connect to Share").font(.title.bold()) }
            Text("Your files remain on the NAS. The key is saved only in macOS Keychain.").foregroundStyle(.secondary)
            SettingsFields()
            if !result.isEmpty { Text(result).foregroundStyle(result == "Connection successful." ? .green : .red) }
            HStack {
                Button("Test Connection") { test() }.disabled(testing || settings.accessKey.count < 32)
                Spacer()
                Button("Connect") { browser.configured() }.buttonStyle(.borderedProminent).disabled(!settings.isConfigured)
            }
        }
        .padding(28).frame(width: 520)
    }

    private func test() {
        settings.save(); testing = true; result = ""
        Task {
            await browser.refresh()
            result = browser.errorMessage ?? "Connection successful."
            testing = false
        }
    }
}
