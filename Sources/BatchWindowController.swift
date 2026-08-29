// Batch window: drop a folder on Jack (or use the launcher) → run one operation across
// every PDF inside. Outputs go to a "Jack Processed" subfolder; originals never touched.
import AppKit
import PDFKit

final class BatchWindowController: NSWindowController, NSWindowDelegate {
    private let folder: URL
    private let files: [URL]

    private let opPopup = NSPopUpButton()
    private let optionsBox = NSView()
    private let runButton = NSButton()
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let results = NSTextView()
    private var running = false

    // Bates options
    private let batesPrefix = NSTextField()
    private let batesStart = NSTextField()
    private let batesDigits = NSPopUpButton()
    private let batesCorner = NSPopUpButton()
    // Watermark options
    private let wmText = NSTextField()
    private let wmStrength = NSPopUpButton()

    init(folder: URL) {
        self.folder = folder
        self.files = BatchEngine.pdfFiles(in: folder)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Batch — \(folder.lastPathComponent)"
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI()
        AppDelegate.batchers.append(self)
        AppDelegate.updateActivationPolicy()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.batchers.removeAll { $0 === self }
            AppDelegate.updateActivationPolicy()
        }
    }

    private func buildUI() {
        guard let v = window?.contentView else { return }
        let W: CGFloat = 500, H: CGFloat = 430

        let header = NSTextField(labelWithString: "\(files.count) PDF\(files.count == 1 ? "" : "s") in “\(folder.lastPathComponent)”")
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        header.frame = NSRect(x: 20, y: H - 40, width: W - 40, height: 20)
        v.addSubview(header)

        let outLabel = NSTextField(labelWithString: "Output: \(folder.lastPathComponent)/\(BatchEngine.outputFolderName) — originals are never touched")
        outLabel.font = .systemFont(ofSize: 11)
        outLabel.textColor = .secondaryLabelColor
        outLabel.frame = NSRect(x: 20, y: H - 60, width: W - 40, height: 16)
        v.addSubview(outLabel)

        let opLabel = NSTextField(labelWithString: "Operation:")
        opLabel.frame = NSRect(x: 20, y: H - 96, width: 80, height: 18)
        v.addSubview(opLabel)
        opPopup.frame = NSRect(x: 100, y: H - 101, width: 240, height: 26)
        opPopup.addItems(withTitles: ["Make Searchable (OCR)", "Bates Numbering", "Watermark", "Compress"])
        opPopup.target = self
        opPopup.action = #selector(opChanged)
        v.addSubview(opPopup)

        optionsBox.frame = NSRect(x: 20, y: H - 150, width: W - 40, height: 40)
        v.addSubview(optionsBox)
        buildOptions()

        runButton.title = "Run on \(files.count) file\(files.count == 1 ? "" : "s")"
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        runButton.target = self
        runButton.action = #selector(run)
        runButton.frame = NSRect(x: W - 180, y: H - 194, width: 160, height: 30)
        runButton.isEnabled = !files.isEmpty
        v.addSubview(runButton)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = Double(max(1, files.count))
        progressBar.frame = NSRect(x: 20, y: H - 218, width: W - 40, height: 14)
        v.addSubview(progressBar)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: H - 238, width: W - 40, height: 16)
        v.addSubview(statusLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 16, width: W - 40, height: H - 264))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        results.frame = scroll.bounds
        results.isEditable = false
        results.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        results.autoresizingMask = [.width]
        scroll.documentView = results
        v.addSubview(scroll)

        opChanged()
    }

    private func buildOptions() {
        // Bates
        batesPrefix.placeholderString = "Prefix (e.g. TRC-)"
        batesPrefix.frame = NSRect(x: 0, y: 8, width: 130, height: 24)
        batesStart.placeholderString = "Start"
        batesStart.stringValue = "1"
        batesStart.frame = NSRect(x: 138, y: 8, width: 60, height: 24)
        batesDigits.frame = NSRect(x: 204, y: 6, width: 90, height: 26)
        batesDigits.addItems(withTitles: ["4 digits", "6 digits", "8 digits"])
        batesDigits.selectItem(at: 1)
        batesCorner.frame = NSRect(x: 300, y: 6, width: 130, height: 26)
        batesCorner.addItems(withTitles: ["Bottom Right", "Bottom Left", "Top Right", "Top Left"])
        // Watermark
        wmText.stringValue = "CONFIDENTIAL"
        wmText.frame = NSRect(x: 0, y: 8, width: 200, height: 24)
        wmStrength.frame = NSRect(x: 208, y: 6, width: 110, height: 26)
        wmStrength.addItems(withTitles: ["Light", "Medium", "Strong"])
        wmStrength.selectItem(at: 1)
        [batesPrefix, batesStart, batesDigits, batesCorner, wmText, wmStrength].forEach {
            optionsBox.addSubview($0)
        }
    }

    @objc private func opChanged() {
        let i = opPopup.indexOfSelectedItem
        [batesPrefix, batesStart, batesDigits, batesCorner].forEach { $0.isHidden = i != 1 }
        [wmText, wmStrength].forEach { $0.isHidden = i != 2 }
    }

    private func currentOperation() -> BatchEngine.Operation {
        switch opPopup.indexOfSelectedItem {
        case 1:
            return .bates(prefix: batesPrefix.stringValue,
                          start: Int(batesStart.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
                          digits: [4, 6, 8][max(0, batesDigits.indexOfSelectedItem)],
                          corner: StampEngine.Corner(rawValue: batesCorner.indexOfSelectedItem) ?? .bottomRight)
        case 2:
            return .watermark(text: wmText.stringValue.isEmpty ? "CONFIDENTIAL" : wmText.stringValue,
                              opacity: [0.10, 0.18, 0.28][max(0, wmStrength.indexOfSelectedItem)])
        case 3: return .compress
        default: return .ocr
        }
    }

    @objc private func run() {
        guard !running, !files.isEmpty else { return }
        running = true
        runButton.isEnabled = false
        opPopup.isEnabled = false
        results.string = ""
        let op = currentOperation()
        let outDir = folder.appendingPathComponent(BatchEngine.outputFolderName)
        let fileList = files
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = BatchEngine.run(op, files: fileList, outputDir: outDir) { i, n, name in
                DispatchQueue.main.async {
                    self?.progressBar.doubleValue = Double(i - 1)
                    self?.statusLabel.stringValue = "Processing \(i) of \(n): \(name)"
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progressBar.doubleValue = self.progressBar.maxValue
                self.statusLabel.stringValue = "Done — \(summary.processed.count) processed, \(summary.skipped.count) skipped"
                var report = summary.processed.map { "✓ \($0)" }
                report += summary.skipped.map { "✗ \($0.name) — \($0.reason)" }
                if summary.bytesBefore > 0, case .compress = op {
                    let fmt = ByteCountFormatter()
                    report.append("")
                    report.append("Total: \(fmt.string(fromByteCount: Int64(summary.bytesBefore))) → \(fmt.string(fromByteCount: Int64(summary.bytesAfter)))")
                }
                self.results.string = report.joined(separator: "\n")
                if !summary.processed.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([outDir])
                    NSSound(named: "Glass")?.play()
                }
                self.running = false
                self.runButton.isEnabled = true
                self.opPopup.isEnabled = true
            }
        }
    }
}
