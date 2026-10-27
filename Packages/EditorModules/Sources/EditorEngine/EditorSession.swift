import AppKit
import Observation
import EditorCore
import DesignSystem

@MainActor @Observable
public final class EditorSession {
    public var focusMode = false
    public var paragraphFocus = false
    public var typewriterMode = false
    public var readingMode = false
    public private(set) var headings: [DocumentHeading] = []
    public private(set) var statistics = DocumentStatistics()
    public private(set) var selectedCharacters = 0
    public private(set) var selectedWords = 0
    public private(set) var cursorOffset = 0
    public private(set) var analysisRevision = 0
    @ObservationIgnored public weak var textView: NSTextView?
    @ObservationIgnored public private(set) var analysis = MarkdownDocument("")
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    // Previsualización atómica (gestos). Mientras está activa, el texto del
    // NSTextView muestra una opción provisional: el binding, el autosave y el
    // índice la ignoran (ver NativeTextEditor), y el undo no se ensucia.
    // `onPreviewCommitted` sincroniza el binding al terminar.
    @ObservationIgnored public private(set) var isPreviewing = false
    @ObservationIgnored public var onPreviewCommitted: ((String) -> Void)?
    @ObservationIgnored private var previewLocation = 0
    @ObservationIgnored private var previewOriginal = ""
    @ObservationIgnored private var previewCurrent = ""
    @ObservationIgnored private var previewLength = 0
    @ObservationIgnored private var voicePreviewActive = false
    /// Reescritura con IA (voz). Por defecto Foundation Models on-device;
    /// en pruebas se inyecta un doble sin modelo.
    @ObservationIgnored private let rewriteProvider: any RewriteProvider
    @ObservationIgnored private var rewriteRequestID = UUID()
    @ObservationIgnored private var rewriteProposal: (view: NSTextView, document: String, documentURL: URL?, range: NSRange, replacement: String)?

    public init(rewriteProvider: (any RewriteProvider)? = nil) {
        self.rewriteProvider = rewriteProvider ?? FoundationModelsRewriteProvider()
    }

    public func imageRange(atNormalizedPoint point: CGPoint?) -> NSRange? {
        guard let view = textView as? WritingTextView,
              let clip = view.enclosingScrollView?.contentView else { return nil }
        guard let point, !readingMode, (0...1).contains(point.x), (0...1).contains(point.y) else {
            return view.imageRange(at: nil)
        }
        let x = clip.bounds.minX + point.x * clip.bounds.width
        let y = clip.isFlipped
            ? clip.bounds.minY + point.y * clip.bounds.height
            : clip.bounds.maxY - point.y * clip.bounds.height
        return view.imageRange(at: view.convert(NSPoint(x: x, y: y), from: clip))
    }

    public func textLocation(atNormalizedPoint point: CGPoint) -> Int? {
        guard let view = textView, let clip = view.enclosingScrollView?.contentView,
              !readingMode, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let x = clip.bounds.minX + point.x * clip.bounds.width
        let y = clip.isFlipped
            ? clip.bounds.minY + point.y * clip.bounds.height
            : clip.bounds.maxY - point.y * clip.bounds.height
        let location = view.convert(NSPoint(x: x, y: y), from: clip)
        guard view.bounds.contains(location) else { return nil }
        return view.characterIndexForInsertion(at: location)
    }

    public func refreshOutline(_ text: String) {
        let text = text.nativeCopy()
        generation += 1
        let revision = generation
        outlineTask?.cancel()
        outlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let analysis = await Self.analyze(text)
            guard !Task.isCancelled, let self, self.generation == revision,
                  !self.isPreviewing, self.textView?.string.nativeCopy() == text else { return }
            self.analysis = analysis
            let headings = analysis.headings
            if self.headings != headings { self.headings = headings }
            if self.statistics != analysis.statistics { self.statistics = analysis.statistics }
            self.analysisRevision += 1
            (self.textView as? WritingTextView)?.applyAnalysis(analysis)
        }
    }

    private nonisolated static func analyze(_ text: String) async -> MarkdownDocument {
        MarkdownDocument(text)
    }

    public func selectionChanged() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        // Cada escritura en una propiedad observada invalida la pantalla.
        if cursorOffset != range.location { cursorOffset = range.location }
        let selectedText = range.length == 0 ? "" : (view.string as NSString).substring(with: range)
        var words = 0
        selectedText.enumerateSubstrings(in: selectedText.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let characters = selectedText.count
        if selectedCharacters != characters { selectedCharacters = characters }
        if selectedWords != words { selectedWords = words }
        (view as? WritingTextView)?.updateParagraphHighlight()
    }

    public func stop() {
        if isPreviewing { endPreview() }
        discardRewrite()
        voicePreviewActive = false
        onPreviewCommitted = nil
        outlineTask?.cancel()
        outlineTask = nil
        textView = nil
    }

    public func send(_ command: EditorCommand) {
        guard let view = textView else { return }
        if readingMode {
            if voicePreviewActive { cancelPreview(); voicePreviewActive = false }
            return
        }
        switch command {
        case .insertText(let text):
            edit(view) { $0.insertText(text, replacementRange: $0.selectedRange()) }
        case .replaceSelection(let text):
            // Solo con selección real: sin ella sería una inserción fantasma.
            guard view.selectedRange().length > 0 else { return }
            edit(view) { $0.insertText(text, replacementRange: $0.selectedRange()) }
        case .selectRange(let range):
            guard let valid = range.validated(in: view.string) else { return }
            view.setSelectedRange(valid)
            view.scrollRangeToVisible(valid)
        case .moveParagraph(let source, let target):
            guard !isPreviewing else { return }
            moveParagraph(from: source, to: target, in: view)
        case .selectAll: view.selectAll(nil)
        case .deleteBackward: view.deleteBackward(nil)
        case .deleteForward: view.deleteForward(nil)
        case .undo: view.undoManager?.undo()
        case .redo: view.undoManager?.redo()
        case .toggleBold: edit(view) { wrapSelection(in: "**", view: $0) }
        case .toggleItalic: edit(view) { wrapSelection(in: "*", view: $0) }
        case .toggleCode: edit(view) { wrapSelection(in: "`", view: $0) }
        case .toggleUnderline: edit(view) { toggleUnderline(view: $0) }
        case .heading(let level):
            guard (1...6).contains(level) else { return }
            edit(view) { prefixParagraph(String(repeating: "#", count: level) + " ", view: $0) }
        case .bulletList: edit(view) { prefixParagraph("- ", view: $0) }
        case .quote: edit(view) { prefixParagraph("> ", view: $0) }
        case .insertLink:
            edit(view) { v in
                let range = v.selectedRange()
                let selected = (v.string as NSString).substring(with: range)
                let label = selected.isEmpty ? "texto" : selected
                v.insertText("[\(label)](https://)", replacementRange: range)
                v.setSelectedRange(NSRange(location: range.location + label.utf16.count + 3, length: 8))
            }
        case .beginPreview(let range):
            if !voicePreviewActive { beginPreview(range) }
        case .showPreview(let option):
            if !voicePreviewActive { showPreview(option: option) }
        case .commitPreview:
            if !voicePreviewActive { commitPreview() }
        case .cancelPreview:
            if !voicePreviewActive { cancelPreview() }
        case .beginVoicePreview:
            guard !isPreviewing else { break }
            let range = view.selectedRange()
            beginPreview(EditorCore.TextRange(location: range.location, length: range.length))
            voicePreviewActive = isPreviewing
        case .showVoicePreview(let text):
            guard voicePreviewActive else { break }
            showPreview(option: Self.spacedDictation(text, after: view.string, at: previewLocation))
            voicePreviewActive = isPreviewing
        case .commitVoicePreview(let text):
            if voicePreviewActive {
                let span = NSRange(location: previewLocation, length: previewLength)
                let current = view.string as NSString
                let unchanged = NSMaxRange(span) <= current.length && current.substring(with: span) == previewCurrent
                cancelPreview()
                voicePreviewActive = false
                if unchanged {
                    edit(view) {
                        let range = $0.selectedRange()
                        $0.insertText(Self.spacedDictation(text, after: $0.string, at: range.location), replacementRange: range)
                    }
                }
            }
        case .cancelVoicePreview:
            if voicePreviewActive { cancelPreview(); voicePreviewActive = false }
        case .renameTitle:
            // Lo aplica EditorScreen (dueño del documento). Ver el caso en
            // EditorCommand: ignorar aquí evita el bug de insertar el título
            // como texto si algún consumidor reenvía al session.send.
            break
        case .findText(let query):
            findInText(query, view: view)
        case .selectText(let query):
            findInText(query, view: view)
        case .rewriteSelection:
            break // La voz prepara y confirma la propuesta por separado.
        case .saveDocument, .openDocument, .exportDocument:
            // Los aplica EditorScreen (documento y paneles). Ignorar aquí.
            break
        }
        view.window?.makeFirstResponder(view)
    }

    /// Una sola operación de Undo por comando de voz: aísla la mutación del
    /// tecleo adyacente (funciona con groupsByEvent true o false).
    /// Separa un dictado del texto que lo precede: sin esto, dos frases
    /// seguidas quedarían pegadas («Hola.Sigo»). No añade nada al inicio de
    /// una línea, tras un espacio o un signo de apertura, ni si el dictado
    /// empieza con un salto o con puntuación de cierre.
    static func spacedDictation(_ text: String, after document: String, at location: Int) -> String {
        let ns = document as NSString
        guard location > 0, location <= ns.length, let first = text.first,
              !first.isWhitespace, !",.;:?!…%)»".contains(first) else { return text }
        let before = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: location - 1))
        guard let previous = before.last, !previous.isWhitespace, !"(¿¡«\"'".contains(previous) else { return text }
        return " " + text
    }

    private func edit(_ view: NSTextView, _ body: (NSTextView) -> Void) {
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        body(view)
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
    }

    private func moveParagraph(from source: EditorCore.TextRange, to target: EditorCore.TextRange, in view: NSTextView) {
        let text = view.string as NSString
        guard let sourceRange = source.validated(in: view.string),
              let targetRange = target.validated(in: view.string),
              sourceRange != targetRange else { return }
        var paragraphs: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in
            if range.length > 0 { paragraphs.append(range) }
        }
        guard let sourceIndex = paragraphs.firstIndex(of: sourceRange),
              let targetIndex = paragraphs.firstIndex(of: targetRange) else { return }
        let lower = min(sourceIndex, targetIndex)
        let upper = max(sourceIndex, targetIndex)
        let affected = Array(paragraphs[lower...upper])
        var contents = affected.map { text.substring(with: $0) }
        let separators = zip(affected, affected.dropFirst()).map { left, right in
            text.substring(with: NSRange(location: NSMaxRange(left), length: right.location - NSMaxRange(left)))
        }
        let moved = contents.remove(at: sourceIndex - lower)
        contents.insert(moved, at: targetIndex - lower)
        var replacement = ""
        var selectionLocation = affected[0].location
        for index in contents.indices {
            if index == targetIndex - lower { selectionLocation += (replacement as NSString).length }
            replacement += contents[index]
            if index < separators.count { replacement += separators[index] }
        }
        let span = NSRange(location: affected[0].location,
                           length: NSMaxRange(affected[affected.count - 1]) - affected[0].location)
        edit(view) { $0.insertText(replacement, replacementRange: span) }
        let selection = NSRange(location: selectionLocation, length: (moved as NSString).length)
        view.setSelectedRange(selection)
        view.scrollRangeToVisible(selection)
    }

    private func prefixParagraph(_ prefix: String, view: NSTextView) {        let text = view.string as NSString
        let range = text.paragraphRange(for: view.selectedRange())
        let paragraph = text.substring(with: range)
        let replacement = paragraph.hasPrefix(prefix) ? String(paragraph.dropFirst(prefix.count)) : prefix + paragraph
        view.insertText(replacement, replacementRange: range)
    }

    private func wrapSelection(in marker: String, view: NSTextView) {
        let text = view.string as NSString
        let range = view.selectedRange()
        let selected = text.substring(with: range)
        let width = marker.utf16.count
        let hasOuterMarkers = range.location >= width && NSMaxRange(range) + width <= text.length
            && text.substring(with: NSRange(location: range.location - width, length: width)) == marker
            && text.substring(with: NSRange(location: NSMaxRange(range), length: width)) == marker
        // A second press removes the markers around the still-selected content.
        if hasOuterMarkers {
            view.insertText(selected, replacementRange: NSRange(location: range.location - width, length: range.length + width * 2))
            view.setSelectedRange(NSRange(location: range.location - width, length: range.length))
            return
        }
        let unwrap = selected.count >= marker.count * 2 && selected.hasPrefix(marker) && selected.hasSuffix(marker)
        let replacement = unwrap ? String(selected.dropFirst(marker.count).dropLast(marker.count)) : marker + selected + marker
        view.insertText(replacement, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + (unwrap ? 0 : width), length: unwrap ? replacement.utf16.count : range.length))
    }

    /// Subrayado con `<u>…</u>` (HTML inline válido en Markdown; el motor no
    /// tiene toggleUnderline nativo). Misma semántica de conmutación que
    /// `wrapSelection`: segunda aplicación lo retira.
    private func toggleUnderline(view: NSTextView) {
        let text = view.string as NSString
        let range = view.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        let selected = text.substring(with: range)
        let open = "<u>", close = "</u>"
        let ow = (open as NSString).length, cw = (close as NSString).length
        if range.location >= ow && NSMaxRange(range) + cw <= text.length
            && text.substring(with: NSRange(location: range.location - ow, length: ow)) == open
            && text.substring(with: NSRange(location: NSMaxRange(range), length: cw)) == close {
            view.insertText(selected, replacementRange: NSRange(location: range.location - ow, length: range.length + ow + cw))
            view.setSelectedRange(NSRange(location: range.location - ow, length: range.length))
            return
        }
        if selected.hasPrefix(open) && selected.hasSuffix(close) && selected.count >= open.count + close.count {
            let inner = String(selected.dropFirst(open.count).dropLast(close.count))
            view.insertText(inner, replacementRange: range)
            view.setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
            return
        }
        view.insertText(open + selected + close, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + ow, length: range.length))
    }

    /// Buscar por voz: coincidencia literal exacta primero, luego normalizada
    /// (insensible a mayúsculas y acentos). Sin fuzzy. Duplicados: primera
    /// coincidencia en o después del cursor, con wrap al inicio. Solo mueve
    /// selección/cursor; jamás modifica contenido. Sin coincidencia no toca nada.
    private func findInText(_ query: String, view: NSTextView) {
        guard !query.isEmpty else { return }
        let text = view.string
        let ns = text as NSString
        for options in [NSString.CompareOptions(), [.caseInsensitive, .diacriticInsensitive]] {
            var found: [NSRange] = []
            var at = NSRange(location: 0, length: ns.length)
            while at.location < ns.length {
                let r = ns.range(of: query, options: options, range: at)
                guard r.location != NSNotFound else { break }
                if Range(r, in: text) != nil { found.append(r) }
                let next = r.location + max(r.length, 1)
                if next >= ns.length { break }
                at = NSRange(location: next, length: ns.length - next)
            }
            if let match = found.first(where: { $0.location >= min(view.selectedRange().location, ns.length) }) ?? found.first {
                view.setSelectedRange(match)
                view.scrollRangeToVisible(match)
                return
            }
        }
    }

    // MARK: - Reescritura con IA (voz "hazlo más breve")

    /// Prepara una propuesta visible sin tocar el documento ni su undo.
    /// Lanza `ModelFailure` con la causa; si otra petición la reemplazó o
    /// quien espera canceló, lanza `CancellationError` (no es un fallo).
    public func prepareRewrite(instruction: String) async throws -> String {
        try Task.checkCancellation()
        discardRewrite()
        let requestID = rewriteRequestID
        guard !readingMode, !isPreviewing, let view = textView else { throw ModelFailure.notEditable }
        let range = view.selectedRange()
        let ns = view.string as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { throw ModelFailure.selectionMissing }
        let document = view.string
        let documentURL = (view as? WritingTextView)?.documentURL
        let original = ns.substring(with: range)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelFailure.selectionMissing }
        let rewritten = try await rewriteProvider.rewrite(original, instruction: instruction)
        guard !Task.isCancelled, requestID == rewriteRequestID else { throw CancellationError() }
        guard textView === view, !readingMode, !isPreviewing, view.string == document,
              (view as? WritingTextView)?.documentURL == documentURL,
              view.selectedRange() == range else { throw ModelFailure.selectionChanged }
        guard !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rewritten != original else { throw ModelFailure.invalidOutput }
        rewriteProposal = (view, document, documentURL, range, rewritten)
        return rewritten
    }

    /// Aplica exactamente la propuesta mostrada, si el documento y la selección siguen vigentes.
    @discardableResult public func acceptRewrite() -> Bool {
        guard let proposal = rewriteProposal else { return false }
        rewriteProposal = nil
        guard textView === proposal.view, !readingMode, !isPreviewing,
              proposal.view.string == proposal.document,
              (proposal.view as? WritingTextView)?.documentURL == proposal.documentURL,
              proposal.view.selectedRange() == proposal.range else { return false }
        edit(proposal.view) { $0.insertText(proposal.replacement, replacementRange: proposal.range) }
        let range = NSRange(location: proposal.range.location, length: (proposal.replacement as NSString).length)
        proposal.view.setSelectedRange(range)
        proposal.view.scrollRangeToVisible(range)
        proposal.view.window?.makeFirstResponder(proposal.view)
        return true
    }

    public func discardRewrite() {
        rewriteRequestID = UUID()
        rewriteProposal = nil
    }

    // MARK: - Previsualización atómica (gestos)

    /// Congela el undo y marca el span provisional. Vale para palabra y para
    /// párrafo: solo importa el rango afectado.
    private func beginPreview(_ range: EditorCore.TextRange) {
        guard !isPreviewing, !readingMode, let view = textView else { return }
        let ns = view.string as NSString
        let span = NSRange(location: range.location, length: range.length)
        guard range.location >= 0, range.length >= 0, NSMaxRange(span) <= ns.length else { return }
        previewLocation = span.location
        previewOriginal = ns.substring(with: span)
        previewCurrent = previewOriginal
        previewLength = span.length
        view.undoManager?.disableUndoRegistration()
        isPreviewing = true
        view.setSelectedRange(span)
        view.scrollRangeToVisible(span)
    }

    /// Muestra una opción reemplazando solo el span. Si el span ya no contiene
    /// lo esperado (el usuario tecleó durante la preview), cancela en vez de
    /// aplicar a ciegas.
    private func showPreview(option: String) {
        guard isPreviewing, let view = textView else { return }
        let ns = view.string as NSString
        let span = NSRange(location: previewLocation, length: previewLength)
        guard NSMaxRange(span) <= ns.length,
              ns.substring(with: span) == previewCurrent else {
            cancelPreview()
            return
        }
        applyPreviewSpan(option)
        let sel = previewOriginal.isEmpty
            ? NSRange(location: previewLocation + previewLength, length: 0)
            : NSRange(location: previewLocation, length: previewLength)
        view.setSelectedRange(sel)
        view.scrollRangeToVisible(sel)
    }

    /// Confirma con un único undo (o ninguno si el texto no cambió).
    /// Si el documento cambió por fuera, libera sin tocar nada.
    private func commitPreview() {
        guard isPreviewing, let view = textView else { return }
        let ns = view.string as NSString
        let span = NSRange(location: previewLocation, length: previewLength)
        guard NSMaxRange(span) <= ns.length,
              ns.substring(with: span) == previewCurrent else {
            endPreview()
            onPreviewCommitted?(view.string)
            return
        }
        let changed = previewCurrent != previewOriginal
        let committedRange = span
        let originalRange = NSRange(location: previewLocation, length: (previewOriginal as NSString).length)
        endPreview()
        view.setSelectedRange(committedRange)
        if changed, let um = view.undoManager {
            registerPreviewSwap(range: committedRange, newText: previewOriginal, newSelect: originalRange,
                                backRange: originalRange, backText: previewCurrent, backSelect: committedRange,
                                undoManager: um)
        }
        onPreviewCommitted?(view.string)
    }

    /// Cancela y restaura el original. Si el span está obsoleto (edición
    /// externa), libera la sesión sin tocar nada: el texto del usuario manda.
    private func cancelPreview() {
        guard isPreviewing, let view = textView else { return }
        let ns = view.string as NSString
        let span = NSRange(location: previewLocation, length: previewLength)
        if NSMaxRange(span) <= ns.length, ns.substring(with: span) == previewCurrent {
            applyPreviewSpan(previewOriginal)
        }
        endPreview()
        let full = NSRange(location: 0, length: (view.string as NSString).length)
        let sel = NSIntersectionRange(
            NSRange(location: previewLocation, length: (previewOriginal as NSString).length), full)
        view.setSelectedRange(sel.length > 0 ? sel : NSRange(location: min(previewLocation, full.length), length: 0))
        onPreviewCommitted?(view.string)
    }

    private func endPreview() {
        isPreviewing = false
        textView?.undoManager?.enableUndoRegistration()
    }

    /// Reemplazo crudo del span, sin undo ni sincronización (la hace quien llama).
    private func applyPreviewSpan(_ option: String) {
        guard let view = textView else { return }
        let span = NSRange(location: previewLocation, length: previewLength)
        view.shouldChangeText(in: span, replacementString: option)
        view.replaceCharacters(in: span, with: option)
        view.didChangeText() // El Coordinator lo ignora mientras isPreviewing.
        previewCurrent = option
        previewLength = (option as NSString).length
        if MarkdownImage(line: previewOriginal) != nil, let writing = view as? WritingTextView {
            writing.applyAnalysis(MarkdownDocument(view.string))
        }
    }

    /// Ping-pong undo/redo simétrico para el cambio confirmado.
    private func registerPreviewSwap(range: NSRange, newText: String, newSelect: NSRange,
                                     backRange: NSRange, backText: String, backSelect: NSRange,
                                     undoManager um: UndoManager) {
        guard let view = textView else { return }
        um.registerUndo(withTarget: view) { [weak self] target in
            self?.applyPreviewSwap(in: target, range: range, text: newText, select: newSelect)
            self?.registerPreviewSwap(range: backRange, newText: backText, newSelect: backSelect,
                                      backRange: newSelect, backText: newText, backSelect: newSelect,
                                      undoManager: um)
        }
    }

    private func applyPreviewSwap(in view: NSTextView, range: NSRange, text: String, select: NSRange) {
        guard NSMaxRange(range) <= (view.string as NSString).length else { return }
        view.shouldChangeText(in: range, replacementString: text)
        view.replaceCharacters(in: range, with: text)
        view.didChangeText()
        view.setSelectedRange(select)
    }
}
