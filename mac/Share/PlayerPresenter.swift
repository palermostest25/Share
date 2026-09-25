import AppKit
import AVKit
import AVFoundation

@MainActor
enum PlayerPresenter {
    private static var windows: [NSWindowController] = []

    static func open(url: URL, title: String) {
        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        playerView.controlsStyle = .floating
        playerView.player = AVPlayer(url: url)
        let controller = NSViewController()
        controller.view = playerView
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.setContentSize(NSSize(width: 900, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        let wc = NSWindowController(window: window)
        windows.append(wc)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                playerView.player?.pause()
                windows.removeAll { $0 === wc }
            }
        }
        wc.showWindow(nil)
        playerView.player?.play()
    }
}
