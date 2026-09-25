import AppKit
import QuickLookUI

@MainActor
enum QuickLookPresenter {
    private static var controller: NSWindowController?
    private static var currentURL: URL?

    static func show(url: URL, title: String) {
        if currentURL == url, controller?.window?.isVisible == true {
            controller?.close()
            return
        }
        controller?.close()
        guard let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 900, height: 620), style: .normal) else { return }
        preview.previewItem = url as NSURL
        let window = PreviewWindow(contentRect: preview.frame,
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = title
        window.contentView = preview
        window.center()
        let next = NSWindowController(window: window)
        controller = next
        currentURL = url
        next.showWindow(nil)
    }
}

private final class PreviewWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}
