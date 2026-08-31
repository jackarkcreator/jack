// Overlay on the menu bar icon: forwards clicks (toggle popover) and accepts file drops.
import AppKit

final class StatusDropView: NSView {
    var onClick: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    /// Spring-loading (the Finder-folder gesture): a drag hovering the tiny icon opens the
    /// popover, whose WHOLE surface is the drop zone — the 20px target becomes 300pt.
    var onDragHover: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { isPDFURL($0) || isImageURL($0) || ConvertEngine.isConvertible($0) || ConvertEngine.isRefused($0) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onDragHover?()
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        onDrop?(u)
        return true
    }
}
