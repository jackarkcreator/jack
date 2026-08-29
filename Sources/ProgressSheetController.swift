// A minimal determinate-progress sheet ("Recognizing text… page 4 of 13").
import AppKit

final class ProgressSheetController {
    let window: NSWindow
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init(title: String, total: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let content = window.contentView!

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 60, width: 300, height: 18)
        content.addSubview(titleLabel)

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(1, total))
        bar.frame = NSRect(x: 20, y: 36, width: 300, height: 16)
        content.addSubview(bar)

        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.frame = NSRect(x: 20, y: 14, width: 300, height: 16)
        content.addSubview(label)
    }

    func update(done: Int, of total: Int) {
        bar.maxValue = Double(max(1, total))
        bar.doubleValue = Double(done)
        label.stringValue = "Page \(done) of \(total)"
    }
}
