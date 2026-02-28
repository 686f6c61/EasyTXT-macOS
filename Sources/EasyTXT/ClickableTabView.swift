import AppKit

@MainActor
final class ClickableTabView: NSTabView {
    var onSelectedTabClicked: (() -> Void)?
    var onCloseTabRequested: ((NSTabViewItem) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedItem = tabViewItem(at: location)
        if let clickedItem, shouldCloseTab(clickedItem, at: location, event: event) {
            onCloseTabRequested?(clickedItem)
            return
        }

        let selectedBefore = selectedTabViewItem

        super.mouseDown(with: event)

        guard event.clickCount >= 1,
              let clickedItem,
              clickedItem === selectedBefore,
              clickedItem === selectedTabViewItem
        else {
            return
        }

        onSelectedTabClicked?()
    }

    private func shouldCloseTab(_ item: NSTabViewItem, at location: NSPoint, event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.option) {
            return true
        }

        guard let tabRect = tabRect(of: item), tabRect.width > 24 else {
            return false
        }

        let closeWidth: CGFloat = min(22, max(14, tabRect.width * 0.26))
        let closeRect = NSRect(
            x: tabRect.maxX - closeWidth,
            y: tabRect.minY,
            width: closeWidth,
            height: tabRect.height
        )
        return closeRect.contains(location)
    }

    private func tabRect(of item: NSTabViewItem) -> NSRect? {
        if let buttonRect = tabButtonRect(of: item) {
            return buttonRect
        }

        let selectors = [
            "_tabRectForTabViewItem:",
            "rectOfTabViewItem:",
        ]

        for name in selectors {
            let selector = NSSelectorFromString(name)
            guard responds(to: selector), let imp = method(for: selector) else {
                continue
            }

            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> NSRect
            let function = unsafeBitCast(imp, to: Fn.self)
            let rect = function(self, selector, item)
            if rect.width > 0, rect.height > 0 {
                return rect
            }
        }
        return nil
    }

    private func tabButtonRect(of item: NSTabViewItem) -> NSRect? {
        let selector = NSSelectorFromString("_tabViewButtons")
        guard responds(to: selector),
              let imp = method(for: selector)
        else {
            return nil
        }

        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let function = unsafeBitCast(imp, to: Fn.self)
        guard let rawButtons = function(self, selector) else {
            return nil
        }

        let index = indexOfTabViewItem(item)
        guard index != NSNotFound else {
            return nil
        }

        if let buttons = rawButtons as? [NSView], buttons.indices.contains(index) {
            return buttons[index].frame
        }
        if let buttons = rawButtons as? NSArray,
           index < buttons.count,
           let buttonView = buttons[index] as? NSView
        {
            return buttonView.frame
        }
        return nil
    }
}
