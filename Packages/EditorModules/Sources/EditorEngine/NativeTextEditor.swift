import SwiftUI
import AppKit
import EditorCore
import DesignSystem

public struct NativeTextEditor: NSViewRepresentable {
    @Binding private var text: String
    private let session: EditorSession
    private let style: WritingStyle
    private let documentURL: URL?
    private let isOpeningDocument: Bool
    /// Pieza Lego (gestos): informa texto+selección para instantáneas del
    /// documento. `nil` sin la pieza; el editor funciona igual.
    private let onTextActivity: ((String, NSRange) -> Void)?

    public init(text: Binding<String>, session: EditorSession, style: WritingStyle = WritingStyle(), documentURL: URL? = nil, isOpeningDocument: Bool = false, onTextActivity: ((String, NSRange) -> Void)? = nil) {
        _text = text
        self.session = session
        self.style = style
        self.documentURL = documentURL
        self.isOpeningDocument = isOpeningDocument
        self.onTextActivity = onTextActivity
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let view = WritingTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 28, height: 24)
        view.style = style
        view.documentURL = documentURL
        view.isEditable = !session.readingMode && !isOpeningDocument
        view.isSelectable = !session.readingMode && !isOpeningDocument
        WritingTextView.apply(style: style, to: view)
        view.string = text
        view.setAccessibilityLabel("Contenido del documento")
        view.delegate = context.coordinator
        scroll.documentView = view
        session.textView = view
        context.coordinator.lastText = text
        session.refreshOutline(text)
        session.onPreviewCommitted = { [weak coordinator = context.coordinator] committed in
            coordinator?.syncPreview(committed)
        }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? WritingTextView else { return }
        // Durante la preview el NSTextView manda: reescribirlo borraría la
        // opción provisional. Al terminar, syncPreview ya actualizó el binding.
        // `lastText` es lo que ya muestra la vista: tras cada tecla el binding
        // devuelve ese mismo String y la comparación no recorre el documento.
        if !session.isPreviewing, text != context.coordinator.lastText {
            context.coordinator.lastText = text
            if view.string.nativeCopy() != text {
                let selection = view.selectedRange()
                view.string = text
                view.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
                session.refreshOutline(text)
            }
        }
        if view.style != style {
            view.style = style
            WritingTextView.apply(style: style, to: view)
            session.refreshOutline(view.string)
        }
        if view.documentURL != documentURL {
            view.documentURL = documentURL
            session.refreshOutline(view.string)
        }
        if view.paragraphFocus != session.paragraphFocus {
            view.paragraphFocus = session.paragraphFocus
            view.updateParagraphHighlight()
        }
        if view.typewriterMode != session.typewriterMode {
            view.typewriterMode = session.typewriterMode
            view.updateInsets()
            if view.typewriterMode { view.centerInsertionPoint() }
            view.updateParagraphHighlight()
        }
        let wasHidden = scroll.isHidden
        scroll.isHidden = session.readingMode
        view.isEditable = !session.readingMode && !isOpeningDocument
        view.isSelectable = !session.readingMode && !isOpeningDocument
        if wasHidden && !scroll.isHidden { view.window?.makeFirstResponder(view) }
    }

    public static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.delegate = nil
        coordinator.parent.session.stop()
    }

    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor
        /// Copia nativa del texto de la vista fuera de la preview.
        var lastText = ""
        init(_ parent: NativeTextEditor) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? WritingTextView else { return }
            // La preview no toca el binding ni el índice: es provisional hasta
            // confirmar o cancelar (entonces syncPreview sincroniza).
            guard !parent.session.isPreviewing else { return }
            let text = view.string.nativeCopy()
            lastText = text
            parent.text = text
            parent.session.refreshOutline(text)
            parent.onTextActivity?(text, view.selectedRange())
            view.typingAttributes = view.styleAttributes
            if view.typewriterMode && !view.hasMarkedText() { view.centerInsertionPoint() }
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            parent.session.selectionChanged()
            // Durante la preview el texto es provisional: empujarlo haría que
            // el módulo lo confundiera con una edición externa y cancelara la
            // sesión al primer movimiento. Al terminar, syncPreview empuja.
            if !parent.session.isPreviewing, let view = notification.object as? WritingTextView {
                parent.onTextActivity?(lastText, view.selectedRange())
            }
        }

        /// Sincroniza el binding tras confirmar o cancelar una preview.
        func syncPreview(_ committed: String) {
            let committed = committed.nativeCopy()
            lastText = committed
            parent.text = committed
            parent.session.refreshOutline(committed)
            if let view = parent.session.textView {
                parent.onTextActivity?(committed, view.selectedRange())
            }
        }
    }
}

@MainActor final class WritingTextView: NSTextView, @MainActor NSTextStorageDelegate {
    var documentURL: URL?
    var style = WritingStyle() {
        didSet { if style != oldValue { cachedAttributes = nil } }
    }
    private var cachedAttributes: [NSAttributedString.Key: Any]?
    /// `style.attributes` crea fuente y estilo de párrafo; se pide en cada tecla.
    var styleAttributes: [NSAttributedString.Key: Any] {
        if let cachedAttributes { return cachedAttributes }
        let attributes = style.attributes
        cachedAttributes = attributes
        return attributes
    }
    var paragraphFocus = false
    var typewriterMode = false
    private var paragraphRect = NSRect.zero
    private var decoratedLines: [MarkdownLine] = []
    private var decoratedStyle: WritingStyle?
    private var changedRange: NSRange?
    private struct ImageBlock {
        let range: NSRange
        let raw: String
        let source: MarkdownImage
        let image: NSImage
    }
    private var images: [ImageBlock] = []
    private var imageCache: [URL: NSImage] = [:]
    private var imageAccessURL: URL?
    private var selectedImage: Int?
    private var hoveredImage: Int?
    private var dragStart: NSPoint?
    private var resizing = false
    private var previewWidth: CGFloat?

    static func apply(style: WritingStyle, to view: NSTextView) {
        view.font = style.font
        view.defaultParagraphStyle = style.attributes[.paragraphStyle] as? NSParagraphStyle
        view.typingAttributes = style.attributes
        view.textColor = style.effectiveTextColor
        view.backgroundColor = style.effectiveBackgroundColor
        view.insertionPointColor = style.accentHex == "auto" ? style.effectiveTextColor : style.effectiveAccentColor
        view.selectedTextAttributes = [
            .backgroundColor: style.effectiveAccentColor.withAlphaComponent(0.28),
            .foregroundColor: style.effectiveTextColor,
        ]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    func applyAnalysis(_ document: MarkdownDocument) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        var first = 0
        var last = document.lines.count
        if decoratedStyle == style {
            let dirty = changedRange ?? NSRange(location: storage.length, length: 0)
            while first < min(last, decoratedLines.count),
                  NSMaxRange(document.lines[first].range) < dirty.location,
                  document.lines[first] == decoratedLines[first] {
                first += 1
            }
            var oldLast = decoratedLines.count
            while last > first, oldLast > first {
                let line = document.lines[last - 1]
                let previous = decoratedLines[oldLast - 1]
                guard line.range.location > NSMaxRange(dirty),
                      line.range.length == previous.range.length,
                      line.content == previous.content, line.kind == previous.kind,
                      line.prefixLength == previous.prefixLength,
                      line.trailingLength == previous.trailingLength else { break }
                last -= 1
                oldLast -= 1
            }
        }
        // Presentation attributes do not replace text or participate in its undo history.
        storage.beginEditing()
        MarkdownAppearance.decorate(storage, document: document, style: style, lines: first..<last)
        images = document.lines.compactMap { line in
            guard case .text = line.kind,
                  let documentURL, let source = MarkdownImage(line: line.content) else { return nil }
            if imageAccessURL != documentURL {
                DocumentImageAccess.start(for: documentURL)
                imageAccessURL = documentURL
            }
            guard let url = source.fileURL(relativeTo: documentURL),
                  let image = imageCache[url] ?? ((try? Data(contentsOf: url)).flatMap { NSImage(data: $0) }),
                  image.size.width > 0, image.size.height > 0 else { return nil }
            imageCache[url] = image
            let visible = NSRange(location: line.range.location, length: (line.content as NSString).length)
            guard visible.length > 0 else { return nil }
            return ImageBlock(range: visible, raw: line.content, source: source, image: image)
        }
        updateImageLayout(in: storage)
        storage.endEditing()
        decoratedLines = document.lines
        decoratedStyle = style
        changedRange = nil
        storage.delegate = self
        typingAttributes = styleAttributes
        updateParagraphHighlight()
        needsDisplay = true
    }

    private func updateImageLayout(in storage: NSTextStorage? = nil) {
        guard let storage = storage ?? textStorage else { return }
        for block in images where NSMaxRange(block.range) <= storage.length {
            guard (storage.string as NSString).substring(with: block.range) == block.raw else { continue }
            let width = min(CGFloat(block.source.width), max(80, textContainer?.size.width ?? 480))
            let height = width * block.image.size.height / block.image.size.width
            let paragraph = (styleAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.minimumLineHeight = height + 16
            paragraph.maximumLineHeight = height + 16
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: block.range)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: block.range)
        }
        needsDisplay = true
    }

    /// Borde superior de la línea en coordenadas del contenedor. Con TextKit 2
    /// no se toca `layoutManager`: pedirlo pasa la vista a TextKit 1 para
    /// siempre y obliga a maquetar todo el documento de forma contigua.
    private func lineTop(at location: Int) -> CGFloat? {
        if let textLayoutManager {
            guard let content = textLayoutManager.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: location) else { return nil }
            textLayoutManager.ensureLayout(for: NSTextRange(location: start))
            guard let fragment = textLayoutManager.textLayoutFragment(for: start) else { return nil }
            let offset = content.offset(from: fragment.rangeInElement.location, to: start)
            let lines = fragment.textLineFragments
            // El marco del fragmento coincide con la línea de TextKit 1; las
            // líneas internas ya incluyen el interlineado previo.
            guard let index = lines.firstIndex(where: { $0.characterRange.contains(offset) }), index > 0 else {
                return fragment.layoutFragmentFrame.minY
            }
            return fragment.layoutFragmentFrame.minY + lines[index].typographicBounds.minY
        }
        guard let layoutManager else { return nil }
        let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        guard glyph.length > 0 else { return nil }
        return layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil).minY
    }

    func imageRect(at index: Int, width override: CGFloat? = nil) -> NSRect? {
        guard images.indices.contains(index), let textContainer else { return nil }
        let block = images[index]
        guard let top = lineTop(at: block.range.location) else { return nil }
        let width = override ?? min(CGFloat(block.source.width), max(80, textContainer.size.width))
        let height = width * block.image.size.height / block.image.size.width
        let x: CGFloat
        switch block.source.alignment {
        case .left: x = textContainerOrigin.x
        case .center: x = textContainerOrigin.x + max(0, (textContainer.size.width - width) / 2)
        case .right: x = textContainerOrigin.x + max(0, textContainer.size.width - width)
        }
        return NSRect(x: x, y: textContainerOrigin.y + top + 8, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in images.indices {
            guard let rect = imageRect(at: index, width: selectedImage == index ? previewWidth : nil), rect.intersects(dirtyRect) else { continue }
            images[index].image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if selectedImage == index || hoveredImage == index {
                style.effectiveAccentColor.setStroke()
                NSBezierPath(rect: rect).stroke()
                if selectedImage == index {
                    style.effectiveAccentColor.setFill()
                    NSBezierPath(rect: NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 8, height: 8)).fill()
                }
            }
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: insertionPointRect(rect, at: selectedRange().location), color: color, turnedOn: flag)
    }

    func insertionPointRect(_ rect: NSRect, at offset: Int) -> NSRect {
        guard images.contains(where: { $0.range.location <= offset && offset <= NSMaxRange($0.range) }) else {
            return rect
        }
        let height = style.font.ascender - style.font.descender + style.font.leading
        return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, height))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let selectedImage, let rect = imageRect(at: selectedImage) else { return }
        addCursorRect(NSRect(x: rect.maxX - 18, y: rect.maxY - 18, width: 18, height: 18),
                      cursor: NSCursor.frameResize(position: .bottomRight, directions: .all))
    }

    private func imageIndex(at point: NSPoint) -> Int? {
        images.indices.first { imageRect(at: $0)?.insetBy(dx: -3, dy: -3).contains(point) == true }
    }

    func imageRange(at point: NSPoint?) -> NSRange? {
        let index = point.flatMap { imageIndex(at: $0) }
        if hoveredImage != index {
            hoveredImage = index
            needsDisplay = true
        }
        return index.map { images[$0].range }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = imageIndex(at: point), let rect = imageRect(at: index) else {
            selectedImage = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            super.mouseDown(with: event)
            return
        }
        selectedImage = index
        window?.invalidateCursorRects(for: self)
        setSelectedRange(images[index].range)
        dragStart = point
        resizing = point.x >= rect.maxX - 18 && point.y >= rect.maxY - 18
        previewWidth = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = selectedImage, let start = dragStart else { super.mouseDragged(with: event); return }
        if resizing {
            let point = convert(event.locationInWindow, from: nil)
            let maxWidth = max(80, textContainer?.size.width ?? 480)
            let width = min(maxWidth, max(80, (imageRect(at: index)?.width ?? CGFloat(images[index].source.width)) + point.x - start.x))
            previewWidth = width
            if let storage = textStorage {
                let paragraph = (storage.attribute(.paragraphStyle, at: images[index].range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                let height = width * images[index].image.size.height / images[index].image.size.width
                paragraph.minimumLineHeight = height + 16
                paragraph.maximumLineHeight = height + 16
                storage.addAttribute(.paragraphStyle, value: paragraph, range: images[index].range)
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; resizing = false; previewWidth = nil; window?.invalidateCursorRects(for: self); needsDisplay = true }
        guard let index = selectedImage, let start = dragStart else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        if resizing, let previewWidth {
            replaceImage(at: index, with: MarkdownImage(alt: images[index].source.alt, path: images[index].source.path, width: Int(previewWidth.rounded()), alignment: images[index].source.alignment))
        } else if hypot(point.x - start.x, point.y - start.y) > 8 {
            moveImage(at: index, to: point)
        }
    }

    private func replaceImage(at index: Int, with image: MarkdownImage) {
        let range = images[index].range
        insertText(image.markdown, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (image.markdown as NSString).length))
        applyAnalysis(MarkdownDocument(string))
        selectedImage = images.firstIndex { $0.range.location == range.location }
        window?.invalidateCursorRects(for: self)
    }

    private func moveImage(at index: Int, to point: NSPoint) {
        let source = string as NSString
        let range = source.paragraphRange(for: images[index].range)
        let target = source.paragraphRange(for: NSRange(location: min(characterIndexForInsertion(at: point), source.length), length: 0)).location
        guard target < range.location || target > NSMaxRange(range) else { return }
        let block = source.substring(with: range)
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        insertText("", replacementRange: range)
        let adjusted = target > range.location ? target - range.length : target
        insertText(block, replacementRange: NSRange(location: adjusted, length: 0))
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: adjusted, length: (images[index].raw as NSString).length))
        applyAnalysis(MarkdownDocument(string))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = imageIndex(at: point) else { return super.menu(for: event) }
        selectedImage = index
        setSelectedRange(images[index].range)
        needsDisplay = true
        let menu = NSMenu()
        for (title, action) in [("Alinear a la izquierda", #selector(alignImageLeft)), ("Centrar", #selector(alignImageCenter)), ("Alinear a la derecha", #selector(alignImageRight)), ("Ancho 25 %", #selector(sizeImageQuarter)), ("Ancho 50 %", #selector(sizeImageHalf)), ("Ancho 100 %", #selector(sizeImageFull))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func alignImageLeft() { setImageAlignment(.left) }
    @objc private func alignImageCenter() { setImageAlignment(.center) }
    @objc private func alignImageRight() { setImageAlignment(.right) }
    @objc private func sizeImageQuarter() { setImageFraction(0.25) }
    @objc private func sizeImageHalf() { setImageFraction(0.5) }
    @objc private func sizeImageFull() { setImageFraction(1) }

    private func setImageAlignment(_ alignment: MarkdownImage.Alignment) {
        guard let index = selectedImage else { return }
        let source = images[index].source
        replaceImage(at: index, with: MarkdownImage(alt: source.alt, path: source.path, width: source.width, alignment: alignment))
    }

    private func setImageFraction(_ fraction: CGFloat) {
        guard let index = selectedImage else { return }
        let source = images[index].source
        replaceImage(at: index, with: MarkdownImage(alt: source.alt, path: source.path, width: Int((textContainer?.size.width ?? 480) * fraction), alignment: source.alignment))
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        selectedImage = nil
        window?.invalidateCursorRects(for: self)
        previewWidth = nil
        if let previous = changedRange {
            // El rango anterior sigue a las inserciones y borrados antes de él.
            let start = min(previous.location, editedRange.location)
            let end = max(NSMaxRange(editedRange), NSMaxRange(previous) + delta)
            changedRange = NSRange(location: start, length: end - start)
        } else {
            changedRange = editedRange
        }
    }

    func updateInsets() {
        let height = typewriterMode ? max(24, (enclosingScrollView?.contentSize.height ?? 0) * 0.42) : 24
        let inset = NSSize(width: 28, height: height)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = frame.width != newSize.width
        super.setFrameSize(newSize)
        updateInsets()
        if changedWidth && !images.isEmpty {
            updateImageLayout()
            window?.invalidateCursorRects(for: self)
        }
        if changedWidth && paragraphFocus {
            Task { @MainActor [weak self] in self?.updateParagraphHighlight() }
        }
    }

    func centerInsertionPoint() {
        guard let scroll = enclosingScrollView, let window else { return }
        let screen = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        guard !screen.isEmpty else { return }
        let local = convert(window.convertFromScreen(screen), from: nil)
        let y = max(0, min(frame.height - scroll.contentSize.height, local.midY - scroll.contentSize.height * 0.42))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func updateParagraphHighlight() {
        let previous = paragraphRect
        paragraphRect = .zero
        // Solo se repinta la franja que cambia, no toda la vista en cada tecla.
        defer {
            if paragraphRect != previous {
                setNeedsDisplay(previous.insetBy(dx: -1, dy: -1))
                setNeedsDisplay(paragraphRect.insetBy(dx: -1, dy: -1))
            }
        }
        guard paragraphFocus, let window, !string.isEmpty else { return }
        let text = string as NSString
        let range = text.paragraphRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0))
        let first = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let last = firstRect(forCharacterRange: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0), actualRange: nil)
        let a = convert(window.convertFromScreen(first), from: nil)
        let b = convert(window.convertFromScreen(last), from: nil)
        paragraphRect = NSRect(x: 16, y: min(a.minY, b.minY) - 4, width: max(0, bounds.width - 32), height: max(a.maxY, b.maxY) - min(a.minY, b.minY) + 8)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard paragraphFocus, !paragraphRect.isEmpty else { return }
        let base = style.accentHex == "auto" ? NSColor.controlAccentColor : style.effectiveAccentColor
        base.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.17 : 0.06).setFill()
        NSBezierPath(roundedRect: paragraphRect, xRadius: 4, yRadius: 4).fill()
    }
}
