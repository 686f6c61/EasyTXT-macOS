import AppKit

final class MainWindowController: NSWindowController {
    let mainViewController: MainViewController

    init(mainViewController: MainViewController) {
        self.mainViewController = mainViewController
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1280, height: 840),
            styleMask: [.titled, .resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "EasyTXT"
        window.minSize = NSSize(width: 640, height: 420)
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.contentViewController = mainViewController
        window.tabbingMode = .preferred
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
