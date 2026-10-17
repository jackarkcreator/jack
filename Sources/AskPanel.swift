// v3.2 Ask panel: a thread for the open document, page citations that jump to the page,
// progress you can stop, and a "the document doesn't say" answer instead of a guess.
// Approved mock (F1–F6): https://claude.ai/artifact/8WQfukTdP9PAmn76QqGigp
//
// Every color is a dynamic color resolved at draw time, so the panel follows Light/Dark
// live (3.1 set a CGColor once and kept the old appearance). Nothing here is written into
// the PDF or kept on disk; the thread lives as long as the window.
import AppKit
import PDFKit

final class AskPanelView: NSView {

    var documentProvider: () -> PDFDocument? = { nil }
    var titleProvider: () -> String = { "this document" }
    var onGoToPage: (Int) -> Void = { _ in }

    /// The question field, so the window can focus it when the panel opens.
    var composerTextView: NSTextView { composer.textView }

    enum Outcome { case answer(String), missing, stopped, message(String) }
    struct Turn { let question: String; var outcome: Outcome? }
    enum Starter: CaseIterable {
        case summarize, dates, amounts
        var title: String { switch self { case .summarize: "Summarize"; case .dates: "Key dates"; case .amounts: "Amounts" } }
        var purpose: String {
            switch self {
            case .summarize: "A short paragraph and the key facts"
            case .dates: "Every date and deadline, in order"
            case .amounts: "Every dollar amount and what it\u{2019}s for"
            }
        }
        var symbol: [String] { switch self { case .summarize: ["text.alignleft"]; case .dates: ["calendar"]; case .amounts: ["dollarsign", "dollarsign.circle"] } }
        var prompt: String? {
            switch self {
            case .summarize: nil
            case .dates: "List every date and deadline mentioned in the document, in order."
            case .amounts: "List every dollar amount mentioned and what it is for."
            }
        }
    }

    private(set) var turns: [Turn] = []
    private var progress: (done: Int, total: Int)?
    private var task: Task<Void, Never>?
    private var generation = 0

    private static let headerHeight: CGFloat = 52
    private let header = FlippedView()
    private let newButton = PanelIconButton(symbol: ["square.and.pencil"], label: "New conversation")
    private let scroll = NSScrollView()
    private let thread = AskThreadView()
    private let composer = AskComposerView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Ask")

        let plate = IconPlate(symbol: ["sparkles", "wand.and.stars"], size: 28, radius: 8)
        plate.frame = NSRect(x: 16, y: 12, width: 28, height: 28)
        header.addSubview(plate)
        let title = NSTextField(labelWithString: "Ask")
        title.font = Chrome.titleFont
        title.frame = NSRect(x: 54, y: 10, width: 120, height: 17)
        header.addSubview(title)
        let lock = NSImageView(image: Chrome.symbol(["lock.fill"], "", .init(pointSize: 8, weight: .semibold)) ?? NSImage())
        lock.contentTintColor = .tertiaryLabelColor
        lock.frame = NSRect(x: 54, y: 28, width: 10, height: 12)
        header.addSubview(lock)
        let privacy = NSTextField(labelWithString: "On this Mac \u{00B7} nothing is uploaded")
        privacy.font = Chrome.metaFont
        privacy.textColor = .tertiaryLabelColor
        privacy.frame = NSRect(x: 66, y: 26, width: 220, height: 15)
        header.addSubview(privacy)
        newButton.toolTip = "New conversation (clears this thread)"
        newButton.target = self
        newButton.action = #selector(newConversation(_:))
        header.addSubview(newButton)
        addSubview(header)

        // No visible scroll bar (UI law: panes scroll, the gutter never shows). With "Show scroll
        // bars: Automatically" macOS flips to legacy bars when a mouse is used, so don't rely on overlay.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = thread
        addSubview(scroll)

        thread.owner = self
        composer.onSubmit = { [weak self] text in self?.ask(question: text) }
        composer.onStop = { [weak self] in self?.stop() }
        composer.onStarter = { [weak self] s in self?.ask(starter: s) }
        addSubview(composer)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Chrome.panelFill.setFill(); bounds.fill()
            Chrome.separator.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        thread.reloadColors()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        header.frame = NSRect(x: 1, y: 0, width: w - 1, height: Self.headerHeight - 1)
        newButton.frame = NSRect(x: w - 1 - 12 - 28, y: 12, width: 28, height: 28)
        let ch = composer.preferredHeight
        composer.frame = NSRect(x: 1, y: bounds.height - ch, width: w - 1, height: ch)
        scroll.frame = NSRect(x: 1, y: Self.headerHeight, width: w - 1, height: max(0, composer.frame.minY - Self.headerHeight))
        thread.relayout(width: scroll.contentSize.width, minHeight: scroll.contentSize.height)
    }

    // MARK: Asking

    func ask(starter: Starter) {
        if let p = starter.prompt { run(question: starter.title, prompt: p, summarize: false) }
        else { run(question: starter.title, prompt: nil, summarize: true) }
    }

    func ask(question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        run(question: q, prompt: q, summarize: false)
    }

    /// Re-reads the document title for the empty state (called when the panel opens).
    func refresh() { if turns.isEmpty { reload() } }

    var isWorking: Bool { turns.last.map { $0.outcome == nil } ?? false }

    private func run(question: String, prompt: String?, summarize: Bool) {
        guard !isWorking, let doc = documentProvider() else { return }
        generation += 1
        let gen = generation
        turns.append(Turn(question: question, outcome: nil))
        progress = nil
        composer.clear()
        reload()
        task = Task { [weak self] in
            var outcome: Outcome
            do {
                let text: String
                if summarize {
                    text = try await AskEngine.summarize(doc: doc) { done, total in
                        DispatchQueue.main.async {
                            guard let self, self.generation == gen else { return }
                            self.progress = (done, total)
                            self.thread.updateWorking(self.workingStatus, progress: self.progress)
                        }
                    }
                } else {
                    text = try await AskEngine.answer(question: prompt ?? question, doc: doc)
                }
                outcome = AskEngine.outcome(of: text)
            } catch is CancellationError {
                outcome = .stopped
            } catch {
                outcome = .message("Couldn\u{2019}t get an answer: \(error.localizedDescription)")
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen, self.isWorking else { return }
                self.finish(outcome)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !turns.isEmpty else { return }
        turns[turns.count - 1].outcome = outcome
        progress = nil
        task = nil
        reload()
        let spoken: String
        switch outcome {
        case .answer(let a): spoken = a
        case .missing: spoken = AskEngine.missingMessage
        case .stopped: spoken = "Stopped."
        case .message(let m): spoken = m
        }
        if let w = window {
            NSAccessibility.post(element: w, notification: .announcementRequested,
                                 userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func stop() {
        guard isWorking else { return }
        task?.cancel()
        generation += 1          // a late answer from the cancelled run is ignored
        finish(.stopped)
    }

    @objc private func newConversation(_ sender: Any?) {
        task?.cancel()
        generation += 1
        task = nil
        turns.removeAll()
        progress = nil
        reload()
        window?.makeFirstResponder(composer.textView)
    }

    var workingStatus: String {
        if let p = progress {
            return p.done >= p.total ? "Combining page notes" : "Reading page group \(p.done) of \(p.total)"
        }
        let pages = documentProvider()?.pageCount ?? 0
        return pages > 0 ? "Looking through \(pages) page\(pages == 1 ? "" : "s")" : "Thinking"
    }

    private func reload() {
        newButton.isEnabled = !turns.isEmpty
        composer.showsStarters = !turns.isEmpty
        composer.working = isWorking
        thread.rebuild(turns: turns, title: titleProvider(), status: workingStatus, progress: progress)
        needsLayout = true
        layoutSubtreeIfNeeded()
        thread.scrollToBottom()
    }

    /// Harness only: a real mouse down/up on the first citation chip, through NSTextView's own
    /// link tracking (the mouse-up is queued first because mouseDown runs a tracking loop).
    func showcaseClickFirstChip() -> Bool {
        func find(_ v: NSView) -> ChipTextView? { (v as? ChipTextView).flatMap { $0.textStorage?.string.contains("p.\u{00A0}") == true ? $0 : nil } ?? v.subviews.lazy.compactMap(find).first }
        guard let tv = find(thread), let ts = tv.textStorage, let lm = tv.layoutManager, let tc = tv.textContainer, let w = window else { return false }
        var target: NSRange?
        ts.enumerateAttribute(.askChip, in: NSRange(location: 0, length: ts.length)) { v, r, stop in if v != nil { target = r; stop.pointee = true } }
        guard let r = target else { return false }
        var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        rect.origin.x += tv.textContainerOrigin.x; rect.origin.y += tv.textContainerOrigin.y
        let p = tv.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
        }
        guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return false }
        NSApp.postEvent(up, atStart: true)
        tv.mouseDown(with: down)
        return true
    }

    /// Harness only (JACK_SHOWCASE=askdemo:<state>): canned turns for window captures, no model.
    /// The balance answer is the real on-device reply captured from 3.1.0.
    func showcase(_ state: String) {
        let balance = Turn(question: "When is the balance due, and how much is it?",
                           outcome: .answer("The balance of $7,380.00 is due within 15 days of final inspection (p. 2)."))
        let summary = Turn(question: "Summarize", outcome: .answer(
            "Ground Up Renovations hires **Westside Tile & Stone** to tile a kitchen floor and two bathrooms at 1418 Rose Avenue, Venice, for $18,450 (p. 1).\n" +
            "- Work starts by October 20, 2026; bathrooms done November 6, kitchen November 20 (p. 1)\n" +
            "- 20% deposit, a progress payment, and the balance within 15 days of final inspection (p. 2)\n" +
            "- $1,000,000 liability insurance, certificates due by October 13 (pp. 2, 3)\n" +
            "- Two-year workmanship warranty (p. 3)"))
        task?.cancel(); generation += 1; progress = nil
        switch state {
        case "answer": turns = [balance]
        case "thread": turns = [summary, balance]
        case "missing": turns = [Turn(question: "Who pays for the dumpster?", outcome: .missing)]
        case "working": turns = [Turn(question: "Summarize", outcome: nil)]; progress = (2, 3)
        default: turns = []
        }
        reload()
    }
}

extension AskPanelView.Outcome: Equatable {}

extension AskEngine {
    static let missingToken = "NOT_IN_DOCUMENT"
    static let missingMessage = "This document doesn\u{2019}t say. I looked at the passages that best match your question and none of them mention it.\nTry other words, or Summarize to see what it covers."

    /// What the panel shows for a model reply.
    static func outcome(of text: String) -> AskPanelView.Outcome {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains(missingToken) { return .missing }
        if t == unavailableMessage || t == noTextMessage { return .message(t) }
        return .answer(t)
    }
}

// MARK: - Thread

final class AskThreadView: NSView {
    weak var owner: AskPanelView?
    override var isFlipped: Bool { true }
    private var items: [NSView] = []
    private weak var working: AskWorkingView?
    private static let pad: CGFloat = 16, gap: CGFloat = 16

    func rebuild(turns: [AskPanelView.Turn], title: String, status: String, progress: (done: Int, total: Int)?) {
        items.forEach { $0.removeFromSuperview() }
        items = []
        if turns.isEmpty {
            let empty = AskEmptyView(title: title)
            empty.onStarter = { [weak self] s in self?.owner?.ask(starter: s) }
            items.append(empty)
        }
        for t in turns {
            items.append(AskQuestionBubble(text: t.question))
            if let outcome = t.outcome {
                let a = AskAnswerView(outcome: outcome)
                a.onGoToPage = { [weak self] n in self?.owner?.onGoToPage(n) }
                items.append(a)
            } else {
                let w = AskWorkingView()
                w.update(status: status, progress: progress)
                working = w
                items.append(w)
            }
        }
        items.forEach(addSubview)
    }

    func updateWorking(_ status: String, progress: (done: Int, total: Int)?) {
        guard let working else { return }
        let before = working.frame.height
        working.update(status: status, progress: progress)
        if working.height(for: working.frame.width) != before { superview?.superview?.needsLayout = true }
    }

    func reloadColors() { items.forEach { $0.needsDisplay = true; $0.subviews.forEach { $0.needsDisplay = true } } }

    func relayout(width: CGFloat, minHeight: CGFloat) {
        var y = Self.pad
        let inner = width - 2 * Self.pad
        for v in items {
            if let b = v as? AskQuestionBubble {
                let size = b.size(maxWidth: (inner * 0.86).rounded(.down))
                b.frame = NSRect(x: Self.pad + inner - size.width, y: y, width: size.width, height: size.height)
            } else if let h = v as? AskHeightProviding {
                v.frame = NSRect(x: Self.pad, y: y, width: inner, height: h.height(for: inner))
            }
            y = v.frame.maxY + Self.gap
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(minHeight, y - Self.gap + Self.pad))
    }

    /// Show the end of the thread, but never scroll the newest question out of view: a long
    /// answer is read from its start.
    func scrollToBottom() {
        guard let clip = enclosingScrollView?.contentView else { return }
        var y = max(0, frame.height - clip.bounds.height)
        if let q = items.last(where: { $0 is AskQuestionBubble }) { y = min(y, max(0, q.frame.minY - Self.pad)) }
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

protocol AskHeightProviding { func height(for width: CGFloat) -> CGFloat }

/// A wrapping label sized from its own cell.
private func wrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text)
    f.font = font
    f.textColor = color
    f.isSelectable = false
    return f
}
private func labelHeight(_ f: NSTextField, _ width: CGFloat) -> CGFloat {
    ceil(f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)).height ?? 16)
}

final class AskEmptyView: NSView, AskHeightProviding {
    var onStarter: ((AskPanelView.Starter) -> Void)?
    override var isFlipped: Bool { true }
    private let heading: NSTextField
    private let body: NSTextField
    private var tiles: [StarterTile] = []

    init(title: String) {
        heading = wrappingLabel("Ask about \(title)", font: .systemFont(ofSize: 15, weight: .bold), color: .labelColor)
        body = wrappingLabel("Answers come only from this document and name the page they used. Check the page before you rely on one.",
                             font: .systemFont(ofSize: 12.5), color: .secondaryLabelColor)
        super.init(frame: .zero)
        addSubview(heading)
        addSubview(body)
        for s in AskPanelView.Starter.allCases {
            let t = StarterTile(starter: s)
            t.target = self
            t.action = #selector(tapped(_:))
            tiles.append(t)
            addSubview(t)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped(_ sender: StarterTile) { onStarter?(sender.starter) }

    func height(for width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let hh = labelHeight(heading, width), bh = labelHeight(body, width)
        heading.frame = NSRect(x: 0, y: y, width: width, height: hh); y += hh + 8
        body.frame = NSRect(x: 0, y: y, width: width, height: bh); y += bh + 14
        for t in tiles { t.frame = NSRect(x: 0, y: y, width: width, height: 52); y += 52 + 8 }
        return y - 8
    }
}

final class AskQuestionBubble: NSView {
    private let label: NSTextField
    private static let padX: CGFloat = 11, padY: CGFloat = 7
    override var isFlipped: Bool { true }
    init(text: String) {
        label = wrappingLabel(text, font: .systemFont(ofSize: 12.5), color: .labelColor)
        label.isSelectable = true
        super.init(frame: .zero)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("You asked: \(text)")
    }
    required init?(coder: NSCoder) { fatalError() }

    func size(maxWidth: CGFloat) -> NSSize {
        let inner = maxWidth - 2 * Self.padX
        let natural = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 40)).width ?? inner)
        let w = min(inner, natural)
        let h = labelHeight(label, w)
        label.frame = NSRect(x: Self.padX, y: Self.padY, width: w, height: h)
        return NSSize(width: w + 2 * Self.padX, height: h + 2 * Self.padY)
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = bounds, rad: CGFloat = 12, tail: CGFloat = 4
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + rad, y: r.minY))
            p.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
            p.curve(to: NSPoint(x: r.maxX, y: r.minY + rad), controlPoint1: NSPoint(x: r.maxX, y: r.minY), controlPoint2: NSPoint(x: r.maxX, y: r.minY))
            p.line(to: NSPoint(x: r.maxX, y: r.maxY - tail))
            p.curve(to: NSPoint(x: r.maxX - tail, y: r.maxY), controlPoint1: NSPoint(x: r.maxX, y: r.maxY), controlPoint2: NSPoint(x: r.maxX, y: r.maxY))
            p.line(to: NSPoint(x: r.minX + rad, y: r.maxY))
            p.curve(to: NSPoint(x: r.minX, y: r.maxY - rad), controlPoint1: NSPoint(x: r.minX, y: r.maxY), controlPoint2: NSPoint(x: r.minX, y: r.maxY))
            p.line(to: NSPoint(x: r.minX, y: r.minY + rad))
            p.curve(to: NSPoint(x: r.minX + rad, y: r.minY), controlPoint1: NSPoint(x: r.minX, y: r.minY), controlPoint2: NSPoint(x: r.minX, y: r.minY))
            p.close()
            Chrome.askBubble.setFill()
            p.fill()
        }
    }
}

final class AskAnswerView: NSView, AskHeightProviding, NSTextViewDelegate {
    var onGoToPage: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    private let text: ChipTextView
    private var raw = ""
    private var pages: [Int] = []
    private var copyButton: SmallActionButton?
    private var sourceLabel: NSTextField?
    private var pageButtons: [PageChipButton] = []

    init(outcome: AskPanelView.Outcome) {
        text = ChipTextView.make()
        super.init(frame: .zero)
        text.delegate = self
        addSubview(text)
        switch outcome {
        case .answer(let a):
            raw = a
            let built = AskAnswerView.attributed(a)
            pages = built.pages
            text.textStorage?.setAttributedString(built.text)
            let copy = SmallActionButton(symbol: "doc.on.doc", title: "Copy")
            copy.target = self
            copy.action = #selector(copyAnswer(_:))
            copy.setAccessibilityLabel("Copy answer")
            addSubview(copy)
            copyButton = copy
            if !pages.isEmpty {
                let l = NSTextField(labelWithString: pages.count > 1 ? "From pages" : "From page")
                l.font = .systemFont(ofSize: 11)
                l.textColor = .tertiaryLabelColor
                addSubview(l)
                sourceLabel = l
                for n in pages {
                    let b = PageChipButton(page: n)
                    b.target = self
                    b.action = #selector(pageTapped(_:))
                    pageButtons.append(b)
                    addSubview(b)
                }
            }
        case .missing: setMuted(AskEngine.missingMessage)
        case .stopped: setMuted("Stopped.")
        case .message(let m): setMuted(m)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setMuted(_ s: String) {
        text.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: AskAnswerView.body()]))
    }

    func height(for width: CGFloat) -> CGFloat {
        let th = text.fittedHeight(width: width)
        text.frame = NSRect(x: 0, y: 0, width: width, height: th)
        guard let copy = copyButton else { return th }
        let y = th + 8
        copy.frame = NSRect(x: -6, y: y, width: copy.intrinsicContentSize.width, height: 24)
        var x = copy.frame.maxX + 6
        if let l = sourceLabel {
            let lw = ceil(l.intrinsicContentSize.width)
            l.frame = NSRect(x: x, y: y + 5, width: lw + 2, height: 14); x += lw + 7
            for b in pageButtons {
                let bw = b.intrinsicContentSize.width
                b.frame = NSRect(x: x, y: y + 3, width: bw, height: 18); x += bw + 4
            }
        }
        return y + 24
    }

    @objc private func copyAnswer(_ sender: SmallActionButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        sender.flash("Copied")
    }
    @objc private func pageTapped(_ sender: PageChipButton) { onGoToPage?(sender.page) }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "jack-page", let n = Int(url.host ?? url.absoluteString.replacingOccurrences(of: "jack-page:", with: "")) else { return false }
        onGoToPage?(n)
        return true
    }

    static func body() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3.5
        p.paragraphSpacing = 4
        return p
    }

    /// The model's reply with "(p. N)" citations as chips, "- " bullets as "•" with a hanging
    /// indent, and **bold** as semibold. Returns the cited pages in order.
    static func attributed(_ reply: String) -> (text: NSAttributedString, pages: [Int]) {
        let base = NSFont.systemFont(ofSize: 13), bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let out = NSMutableAttributedString()
        var pages: [Int] = []
        let cite = try! NSRegularExpression(pattern: "\\((?:pp?\\.|pages?)\\s*(\\d+(?:\\s*(?:,|and|–|-|&)\\s*(?:p\\.\\s*)?\\d+)*)\\)", options: [.caseInsensitive])
        // Blank lines the model adds become paragraph spacing, not empty lines.
        var lines: [String] = [], gapBefore: Set<Int> = []
        for l in reply.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).isEmpty { if !lines.isEmpty { gapBefore.insert(lines.count) } }
            else { lines.append(l) }
        }
        for (li, rawLine) in lines.enumerated() {
            var line = rawLine
            let para = NSMutableParagraphStyle()
            para.setParagraphStyle(body())
            if gapBefore.contains(li) { para.paragraphSpacingBefore = 6 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let m = ["- ", "* ", "\u{2022} "].first(where: { trimmed.hasPrefix($0) }) {
                line = "\u{2022}\t" + trimmed.dropFirst(m.count)
                para.headIndent = 12
                para.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
                para.defaultTabInterval = 12
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
            // Split on citations, then on **bold**.
            let ns = line as NSString
            var cursor = 0
            func plain(_ s: String) {
                let parts = s.components(separatedBy: "**")
                for (i, part) in parts.enumerated() where !part.isEmpty {
                    var a = attrs
                    if i % 2 == 1 { a[.font] = bold }
                    out.append(NSAttributedString(string: part, attributes: a))
                }
            }
            for match in cite.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                plain(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                let nums = ns.substring(with: match.range(at: 1)).split { !$0.isNumber }.compactMap { Int($0) }
                for (i, n) in nums.enumerated() {
                    if !pages.contains(n) { pages.append(n) }
                    if i > 0 { out.append(NSAttributedString(string: " ", attributes: attrs)) }
                    var c = attrs
                    c[.font] = chipFont
                    c[.foregroundColor] = Chrome.tint
                    c[.link] = URL(string: "jack-page:\(n)")!
                    c[.askChip] = true
                    out.append(NSAttributedString(string: "\u{2009}p.\u{00A0}\(n)\u{2009}", attributes: c))
                }
                cursor = match.range.location + match.range.length
            }
            plain(ns.substring(from: cursor))
            if li < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
        }
        // Collapse runs of blank lines the model sometimes adds.
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return (out, pages)
    }
}

extension NSAttributedString.Key { static let askChip = NSAttributedString.Key("JackAskChip") }

/// A read-only, selectable TextKit 1 text view that draws a rounded plate behind citation chips.
final class ChipTextView: NSTextView {
    static func make() -> ChipTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let v = ChipTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 20), textContainer: container)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.isVerticallyResizable = false
        v.linkTextAttributes = [.foregroundColor: Chrome.tint, .cursor: NSCursor.pointingHand]
        return v
    }

    func fittedHeight(width: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 20 }
        tc.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height) + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Chrome.tintSoft.setFill()
                ts.enumerateAttribute(.askChip, in: NSRange(location: 0, length: ts.length)) { v, range, _ in
                    guard v != nil, let font = ts.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                    let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    lm.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                        let g = NSIntersectionRange(glyphs, lineGlyphs)
                        guard g.length > 0 else { return }
                        let r = lm.boundingRect(forGlyphRange: g, in: tc)
                        let baseline = lineRect.minY + lm.location(forGlyphAt: g.location).y
                        let h = ceil(font.capHeight) + 9
                        let plate = NSRect(x: r.minX + self.textContainerOrigin.x, y: baseline - font.capHeight - 4.5 + self.textContainerOrigin.y,
                                           width: r.width, height: h)
                        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
                    }
                }
            }
        }
        super.draw(dirtyRect)
    }
}

final class AskWorkingView: NSView, AskHeightProviding {
    override var isFlipped: Bool { true }
    private let dots = DotsView()
    private let status = NSTextField(labelWithString: "")
    private var progress: (done: Int, total: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        addSubview(dots)
        addSubview(status)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(status s: String, progress p: (done: Int, total: Int)?) {
        status.stringValue = s
        progress = p
        setAccessibilityLabel(s)
        needsDisplay = true
    }

    func height(for width: CGFloat) -> CGFloat {
        dots.frame = NSRect(x: 0, y: 6, width: 18, height: 6)
        status.frame = NSRect(x: 24, y: 0, width: width - 24, height: 17)
        return (progress != nil ? 30 : 22) + 3 * 9 + 2 * 8
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var y: CGFloat = 25
            if let p = progress, p.total > 0 {
                let track = NSRect(x: 0, y: y, width: bounds.width, height: 4)
                Chrome.groupFill.setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                var fill = track
                fill.size.width = track.width * CGFloat(min(p.done, p.total)) / CGFloat(p.total)
                Chrome.tint.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
                y += 12
            } else { y += 4 }
            Chrome.groupFill.setFill()
            for (i, f) in [0.92, 0.78, 0.60].enumerated() {
                let r = NSRect(x: 0, y: y + CGFloat(i) * 17, width: bounds.width * f, height: 9)
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

/// Three pulsing dots (still when Reduce Motion is on).
final class DotsView: NSView {
    private var phase = 0
    private var timer: Timer?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 1) % 4
            self.needsDisplay = true
        }
    }
    override func removeFromSuperview() { timer?.invalidate(); timer = nil; super.removeFromSuperview() }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for i in 0..<3 {
                let on = timer == nil || i == phase % 3
                Chrome.tint.withAlphaComponent(on ? 1 : 0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(i) * 7, y: 1, width: 4, height: 4)).fill()
            }
        }
    }
}

// MARK: - Composer

final class AskComposerView: NSView {
    var onSubmit: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onStarter: ((AskPanelView.Starter) -> Void)?
    var showsStarters = false { didSet { chips.forEach { $0.isHidden = !showsStarters }; needsLayout = true } }
    var working = false { didSet { send.mode = working ? .stop : .send; updateSend() } }
    override var isFlipped: Bool { true }

    let textView = ComposerTextView()
    private let box = ComposerBox()
    private let textScroll = NSScrollView()
    private let send = SendButton()
    private var chips: [StarterChip] = []
    private let legend = NSTextField(labelWithString: "Return to ask \u{00B7} Shift-Return for a new line")

    var preferredHeight: CGFloat { 10 + (showsStarters ? 24 + 8 : 0) + 48 + 6 + 14 + 10 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for s in AskPanelView.Starter.allCases {
            let c = StarterChip(starter: s)
            c.target = self
            c.action = #selector(chipTapped(_:))
            c.isHidden = true
            chips.append(c)
            addSubview(c)
        }
        addSubview(box)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = true
        textView.minSize = NSSize(width: 0, height: 36)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.placeholder = "Ask about this document"
        textView.setAccessibilityLabel("Question")
        textView.onReturn = { [weak self] in self?.submit() }
        textView.onChange = { [weak self] in self?.updateSend() }
        textView.onFocus = { [weak self] f in self?.box.focused = f }
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = false
        textScroll.documentView = textView
        box.addSubview(textScroll)
        send.target = self
        send.action = #selector(sendTapped(_:))
        box.addSubview(send)
        legend.font = Chrome.metaFont
        legend.textColor = .tertiaryLabelColor
        legend.alignment = .center
        addSubview(legend)
        updateSend()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Chrome.separator.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 10
        if showsStarters {
            var x: CGFloat = 12
            for c in chips { let cw = c.intrinsicContentSize.width; c.frame = NSRect(x: x, y: y, width: cw, height: 24); x += cw + 6 }
            y += 24 + 8
        }
        box.frame = NSRect(x: 12, y: y, width: w - 24, height: 48)
        send.frame = NSRect(x: box.bounds.width - 6 - 26, y: box.bounds.height - 6 - 26, width: 26, height: 26)
        textScroll.frame = NSRect(x: 11, y: 6, width: box.bounds.width - 11 - 6 - 26 - 6, height: 36)
        textView.frame.size.width = textScroll.contentSize.width
        legend.frame = NSRect(x: 12, y: box.frame.maxY + 6, width: w - 24, height: 14)
    }

    func clear() { textView.string = ""; textView.needsDisplay = true; updateSend() }

    private func updateSend() {
        send.isEnabled = working || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.needsDisplay = true
    }
    private func submit() {
        guard !working else { return }
        let q = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        onSubmit?(q)
    }
    @objc private func sendTapped(_ sender: Any?) { if working { onStop?() } else { submit() } }
    @objc private func chipTapped(_ sender: StarterChip) { onStarter?(sender.starter) }
}

final class ComposerTextView: NSTextView {
    var placeholder = ""
    var onReturn: (() -> Void)?
    var onChange: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { insertNewlineIgnoringFieldEditor(nil) }
            else { onReturn?() }
            return
        }
        super.doCommand(by: selector)
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true; onChange?() }
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { onFocus?(true) }; return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); if ok { onFocus?(false) }; return ok }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y),
                                       withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
    }
}

final class ComposerBox: NSView {
    var focused = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = bounds.insetBy(dx: 0.25, dy: 0.25)
            let p = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
            Chrome.askField.setFill(); p.fill()
            (focused ? Chrome.tint.withAlphaComponent(0.55) : Chrome.groupStroke).setStroke()
            p.lineWidth = focused ? 1 : 0.5
            p.stroke()
        }
    }
}

final class SendButton: NSButton {
    enum Mode { case send, stop }
    var mode: Mode = .send {
        didSet {
            setAccessibilityLabel(mode == .send ? "Ask" : "Stop")
            toolTip = mode == .send ? "Ask (Return)" : "Stop"
            needsDisplay = true
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Ask")
        toolTip = "Ask (Return)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let circle = NSBezierPath(ovalIn: bounds)
            (isEnabled ? Chrome.tint : Chrome.groupFill).setFill()
            circle.fill()
            if isEnabled && isHighlighted { Chrome.pressFill.setFill(); circle.fill() }
            let name = mode == .send ? "arrow.up" : "stop.fill"
            guard let img = Chrome.symbol([name], "", .init(pointSize: mode == .send ? 12 : 10, weight: .bold)) else { return }
            let s = img.size
            tinted(img, isEnabled ? Chrome.onTint : .tertiaryLabelColor)
                .draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

// MARK: - Small controls

/// A rounded plate in soft teal with a teal symbol (the panel header and starter tiles).
final class IconPlate: NSView {
    private let image: NSImage?
    private let radius: CGFloat
    init(symbol: [String], size: CGFloat, radius: CGFloat) {
        image = Chrome.symbol(symbol, "", .init(pointSize: size * 0.5, weight: .medium))
        self.radius = radius
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Chrome.tintSoft.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            guard let img = image else { return }
            let s = img.size
            tinted(img, Chrome.tint).draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

/// Hover-filled square icon button (New conversation).
final class PanelIconButton: NSButton {
    private var hovering = false
    init(symbol: [String], label: String) {
        super.init(frame: .zero)
        image = Chrome.symbol(symbol, label, Chrome.stripSymbol)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isEnabled && (hovering || isHighlighted) {
                (isHighlighted ? Chrome.pressFill : Chrome.hoverFill).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            }
            guard let img = image else { return }
            let s = img.size
            tinted(img, isEnabled ? Chrome.toolIcon : NSColor.tertiaryLabelColor.withAlphaComponent(0.5))
                .draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

final class StarterTile: NSButton {
    let starter: AskPanelView.Starter
    private var hovering = false
    private let icon: NSImage?
    init(starter: AskPanelView.Starter) {
        self.starter = starter
        icon = Chrome.symbol(starter.symbol, starter.title, .init(pointSize: 14, weight: .medium))
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel("\(starter.title). \(starter.purpose)")
        focusRingType = .default
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            Chrome.panelTile.setFill(); p.fill()
            if isHighlighted { Chrome.pressFill.setFill(); p.fill() }
            (hovering ? Chrome.tint : Chrome.groupStroke).setStroke()
            p.lineWidth = hovering ? 1 : 0.5
            p.stroke()
            let plate = NSRect(x: 10, y: (bounds.height - 32) / 2, width: 32, height: 32)
            Chrome.tintSoft.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8).fill()
            if let img = icon {
                let s = img.size
                tinted(img, Chrome.tint).draw(in: NSRect(x: plate.midX - s.width / 2, y: plate.midY - s.height / 2, width: s.width, height: s.height))
            }
            let tx = plate.maxX + 10
            (starter.title as NSString).draw(at: NSPoint(x: tx, y: 9), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor])
            (starter.purpose as NSString).draw(with: NSRect(x: tx, y: 27, width: bounds.width - tx - 8, height: 16),
                                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                               attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

/// Capsule chip used for the starters above the field and for "Go to page" buttons.
class CapsuleButton: NSButton {
    private var hovering = false
    fileprivate var label: String
    fileprivate var labelFont: NSFont
    fileprivate var padX: CGFloat
    fileprivate var accent = false
    init(label: String, font: NSFont, padX: CGFloat) {
        self.label = label; self.labelFont = font; self.padX = padX
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .default
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((label as NSString).size(withAttributes: [.font: labelFont]).width) + 2 * padX, height: 24)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let rad = accent ? 5 : bounds.height / 2
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: rad, yRadius: rad)
            let color: NSColor
            if accent {
                (hovering || isHighlighted ? Chrome.tint : Chrome.tintSoft).setFill(); p.fill()
                color = hovering || isHighlighted ? Chrome.onTint : Chrome.tint
            } else {
                Chrome.panelTile.setFill(); p.fill()
                (hovering ? Chrome.tint : Chrome.groupStroke).setStroke()
                p.lineWidth = hovering ? 1 : 0.5
                p.stroke()
                color = hovering ? Chrome.tint : Chrome.toolText
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
            let s = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
        }
    }
}

final class StarterChip: CapsuleButton {
    let starter: AskPanelView.Starter
    init(starter: AskPanelView.Starter) {
        self.starter = starter
        super.init(label: starter.title, font: .systemFont(ofSize: 11.5, weight: .medium), padX: 10)
        setAccessibilityLabel(starter.title)
        toolTip = starter.purpose
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PageChipButton: CapsuleButton {
    let page: Int
    init(page: Int) {
        self.page = page
        super.init(label: "\(page)", font: .systemFont(ofSize: 11, weight: .semibold), padX: 6)
        accent = true
        setAccessibilityLabel("Go to page \(page)")
        toolTip = "Go to page \(page)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: max(18, super.intrinsicContentSize.width), height: 18) }
}

/// Icon + label text button with a hover plate (Copy).
final class SmallActionButton: NSButton {
    private var hovering = false
    private var label: String
    private let icon: NSImage?
    private let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    init(symbol: String, title: String) {
        label = title
        icon = Chrome.symbol([symbol], title, .init(pointSize: 11, weight: .regular))
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        setButtonType(.momentaryChange)
        focusRingType = .default
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(8 + 13 + 5 + (label as NSString).size(withAttributes: [.font: labelFont]).width + 8), height: 24)
    }
    func flash(_ s: String) {
        let old = label
        label = s; needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.label = old; self?.needsDisplay = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if hovering || isHighlighted {
                (isHighlighted ? Chrome.pressFill : Chrome.hoverFill).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            let color: NSColor = hovering ? .labelColor : .tertiaryLabelColor
            if let img = icon {
                let s = img.size
                tinted(img, color).draw(in: NSRect(x: 8 + (13 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
            let s = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: 8 + 13 + 5, y: (bounds.height - s.height) / 2), withAttributes: attrs)
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A brief teal outline over a page, so a citation jump shows where it landed.
final class PageFlashView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
            p.lineWidth = 3
            Chrome.tint.setStroke()
            p.stroke()
        }
    }
}
