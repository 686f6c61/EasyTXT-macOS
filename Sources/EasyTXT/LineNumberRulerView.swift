import AppKit

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 42
        clientView = textView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager
        else {
            return
        }

        NSColor.clear.set()
        rect.fill()

        let relativePoint = self.convert(NSPoint.zero, from: textView)
        let text = textView.string as NSString
        let lineRange = NSRange(location: 0, length: text.length)

        if lineRange.length == 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let label = "1" as NSString
            let size = label.size(withAttributes: attrs)
            let x = ruleThickness - size.width - 8
            let y = textView.textContainerOrigin.y + relativePoint.y
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            return
        }

        var lineNumber = 1
        var index = 0

        while index < lineRange.length {
            let nextRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: nextRange, actualCharacterRange: nil)
            if glyphRange.location >= layoutManager.numberOfGlyphs {
                break
            }

            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let textOrigin = textView.textContainerOrigin

            let y = fragmentRect.minY + textOrigin.y + relativePoint.y
            if y + fragmentRect.height >= rect.minY, y <= rect.maxY {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attrs)
                let x = ruleThickness - size.width - 8
                let drawY = y + max((fragmentRect.height - size.height) * 0.5, 0)
                label.draw(at: NSPoint(x: x, y: drawY), withAttributes: attrs)
            }

            index = NSMaxRange(nextRange)
            lineNumber += 1
        }
    }
}
