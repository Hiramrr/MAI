import EditorCore
import Foundation

extension GestureModule {
    // MARK: - Sesión a dos manos (longitud del párrafo)

    /// Suavizado exponencial de la separación entre manos.
    /// Con la señal congelada (sin medida nueva) devuelve el último valor:
    /// durante pérdidas de seguimiento no se hereda ningún brinco.
    private func smoothedLengthSpan(raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return lengthSmoothedSpan }
        if let prev = lengthSmoothedSpan {
            lengthSmoothedSpan = prev + GestureTuning.lengthSmoothing * (raw - prev)
        } else {
            lengthSmoothedSpan = raw
        }
        return lengthSmoothedSpan
    }

    /// Puerta del gesto doble: exige varias detecciones con ambas manos
    /// dentro de una ventana corta (un cruce aislado o un parpadeo no abren
    /// ni reinician la cuenta). Mientras hay sesión, retirar UNA mano
    /// confirma; perder AMBAS manos restaura el párrafo (nunca confirma
    /// a ciegas: lo no visto no se aplica).
    /// Interna para pruebas (@testable): simulan detecciones sin cámara.
    func handleLengthVision(_ vision: GestureState, at uptime: TimeInterval) async {
        // Sesión manual (botón): la cámara solo decora, no decide.
        guard !lengthManualControl, !imageManualControl else { return }
        guard vision.landmarksValid else {
            await handleLengthTrackingGap(at: uptime)
            return
        }
        // Suavizar una sola vez por frame válido.
        let span = smoothedLengthSpan(raw: vision.handSpan)
        if lengthTrackingLostAt != nil {
            // Vuelve tras perder frames: conserva lo avanzado pero excluye
            // el salto no observado (igual que la pinza de una mano).
            lengthTrackingLostAt = nil
            if let span {
                if var s = lengthSession {
                    s.referenceSpan += span - lengthLastSpan
                    lengthSession = s
                } else if var s = imageSizeSession {
                    s.referenceSpan += span - lengthLastSpan
                    imageSizeSession = s
                }
                lengthLastSpan = span
            }
        }
        if vision.hasTwoDistinctHands {
            lengthTwoHandHits.append(uptime)
            lengthTwoHandHits.removeAll { uptime - $0 > GestureTuning.twoHandWindow }
            lengthOpenStreak = 0
        } else if lengthSession != nil || imageSizeSession != nil {
            // Sesión activa y solo una mano: contar hacia confirmar.
            lengthOpenStreak += 1
            if lengthOpenStreak >= GestureTuning.lengthCommitFrames {
                if imageSizeSession != nil { await commitImageSizeSession() }
                else { await commitLengthSession() }
            } else {
                message = "Retira una mano para confirmar (las dos cancela)."
            }
            return
        } else {
            return
        }
        let hits = min(lengthTwoHandHits.count, GestureTuning.twoHandStartFrames)
        let ready = lengthSession != nil || imageSizeSession != nil
            || (!lengthRequiresRelease && pinchSession == nil
                && lengthTwoHandHits.count >= GestureTuning.twoHandStartFrames)
        guard ready else {
            if pinchSession != nil {
                message = "Termina la pinza de una mano primero (suelta para confirmar)."
            } else if lengthRequiresRelease {
                message = "Separa las manos antes de otro gesto de dos manos."
            } else {
                message = "Dos manos \(hits)/\(GestureTuning.twoHandStartFrames)… mantén la posición."
            }
            return
        }
        if lengthSession == nil && imageSizeSession == nil {
            // Un gesto cada vez: la sesión de palabra sigue intacta.
            guard pinchSession == nil else { return }
            guard let span else { return }
            if let (image, range) = pointedImageRange.flatMap(imageAtRange) ?? imageAtSelection() {
                await startImageSizeSession(image: image, range: range, span: span, manual: false)
            } else {
                await tryStartLengthSession(span: span)
            }
        } else if imageSizeSession != nil {
            guard let span else { return }
            await updateImageSizeSession(span: span)
        } else {
            guard let span else { return }
            await updateLengthSession(span: span)
        }
    }

    private func handleLengthTrackingGap(at uptime: TimeInterval) async {
        lengthRequiresRelease = false
        lastRawPinch = false
        guard lengthSession != nil || imageSizeSession != nil else { return }
        // Mientras genera no se cancela por perder las manos: la IA sigue
        // en segundo plano y al volver la sesión sigue viva.
        if lengthLoading, lengthSession != nil {
            message = "Generando versiones… mantén ambas manos visibles, medio ya disponible."
            return
        }
        if lengthTrackingLostAt == nil {
            lengthTrackingLostAt = uptime
            message = "Sin seguimiento. Mantén ambas manos visibles."
        } else if uptime - lengthTrackingLostAt! >= GestureTuning.trackingLossGrace {
            // Manos perdidas del todo: se restaura el párrafo original.
            // Solo confirma lo que se ve: retirar UNA mano.
            if imageSizeSession != nil {
                await finishImageSizeSession(commit: false)
                message = "Se perdieron las manos; imagen restaurada."
            } else {
                await cancelLengthSession(reason: "Se perdieron las manos; párrafo restaurado")
            }
        }
    }

    /// Párrafo de prosa bajo el cursor o el motivo concreto por el que no
    /// se puede cambiar su longitud. Usa el mismo análisis Markdown del
    /// editor: el interior de un bloque de código cuenta como código aunque
    /// la línea no lleve comillas invertidas. En citas y listas solo se
    /// reescribe el texto tras la marca, que se conserva.
    nonisolated static func lengthTarget(in text: String, at caret: Int) -> LengthTarget {
        lengthTarget(in: MarkdownDocument(text), at: caret)
    }

    private nonisolated static func lengthTarget(in document: MarkdownDocument, at caret: Int) -> LengthTarget {
        guard let last = document.lines.last, NSMaxRange(last.range) > 0 else { return .none }
        let caret = min(max(caret, 0), NSMaxRange(last.range) - 1)
        var lower = 0
        var upper = document.lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(document.lines[middle].range) <= caret { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < document.lines.count else { return .none }
        let line = document.lines[lower]
        switch line.kind {
        case .code, .fence:
            return .refused("Este párrafo es código: la longitud solo cambia prosa.")
        case .tableRow, .tableDelimiter:
            return .refused("Esta línea es una fila de tabla: la longitud solo cambia prosa.")
        case .heading:
            return .refused("Esta línea es un título: la longitud solo cambia párrafos de prosa.")
        case .rule, .hidden:
            return .refused("Esta línea es una marca de Markdown, no prosa.")
        case .text, .quote, .list, .orderedList, .taskList:
            break
        }
        let body = line.content
        guard body.rangeOfCharacter(from: .letters) != nil else { return .none }
        // Una cita que contiene una lista (o al revés) sigue siendo estructura.
        guard MarkdownDocument(body).lines.first?.kind == .text else {
            return .refused("Este párrafo combina varias marcas de Markdown (cita, lista o título). Edítalo a mano.")
        }
        if ["](", "![", "][", "[^", "`", "://"].contains(where: body.contains)
            || body.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil {
            return .refused("Este párrafo tiene enlaces, imágenes, código o HTML: la IA podría romperlos. Edítalo a mano.")
        }
        if body.contains("*") || body.contains("_") || body.contains("~") {
            let refusal = LengthTarget.refused("Este párrafo tiene formato en línea. Edítalo a mano para conservarlo.")
            guard let parsed = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
                return refusal
            }
            if parsed.runs.contains(where: { run in
                guard let intent = run.inlinePresentationIntent else { return false }
                return intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) || intent.contains(.strikethrough)
            }) { return refusal }
        }
        return .prose(NSRange(location: line.range.location + line.prefixLength, length: (body as NSString).length))
    }

    func paragraphForLength() -> LengthTarget {
        guard imageAtSelection() == nil else { return .none }
        let document = lengthDocument ?? MarkdownDocument(cachedText)
        lengthDocument = document
        return Self.lengthTarget(in: document, at: cachedSelection.location)
    }

    /// Avisa por qué no se abre la sesión. Devuelve el párrafo si se puede.
    private func lengthParagraph(_ target: LengthTarget, noParagraph: String) -> (text: String, range: NSRange)? {
        switch target {
        case .prose(let range):
            return ((cachedText as NSString).substring(with: range), range)
        case .refused(let reason):
            message = reason
            lengthToast = reason
            lengthToastCanUndo = false
            return nil
        case .none:
            message = noParagraph
            return nil
        }
    }

    private func tryStartLengthSession(span: Double) async {
        guard !lengthRequiresRelease, span.isFinite else { return }
        let target = paragraphForLength()
        guard let (text, range) = lengthParagraph(target, noParagraph: "Coloca el cursor en un párrafo y muestra las dos manos.") else {
            // Un párrafo rechazado no se reintenta en cada frame.
            if case .refused = target { lengthRequiresRelease = true }
            return
        }
        guard lengthProvider.isAvailable else {
            message = "No se puede cambiar la longitud. \(lengthProvider.availabilityReason ?? "Modelo de IA no disponible.")"
            lengthToast = message
            lengthToastCanUndo = false
            lengthRequiresRelease = true
            return
        }
        await send(.beginPreview(TextRange(location: range.location, length: range.length)))
        await send(.selectRange(TextRange(location: range.location, length: range.length)))
        lengthSession = LengthSession(id: UUID(), originalText: text, originalLocation: range.location,
                                      alternatives: [text, text, text],
                                      currentIndex: LengthLevel.medio.rawValue,
                                      referenceSpan: span)
        lengthLastSpan = span
        lengthSessionDelta = 0
        lengthOpenStreak = 0
        lengthManualControl = false
        // La pinza de una mano queda desarmada: al volver a una mano se
        // confirma la longitud en vez de abrir sinónimos por accidente.
        pinchStreak = 0
        openStreak = 0
        lastRawPinch = false
        navigationX = nil
        lengthToast = nil
        // Reuso instantáneo: el mismo párrafo no regenera.
        if let cached = lengthCache[text], applyLengthPair(cached, text: text) {
            lengthLoading = false
            message = "\(lengthReadyMessage) (reusadas)"
            return
        }
        lengthLoading = true
        message = "Preparando versiones corta y larga… Puedes quedarte en medio mientras tanto."
        fetchLengthVariants(text: text)
    }

    /// Pone en la sesión las versiones válidas. Las que faltan quedan
    /// bloqueadas con su motivo: el original solo ocupa su hueco, nunca se
    /// ofrece como si fuera una versión generada.
    @discardableResult
    private func applyLengthPair(_ pair: VariantPair, text: String) -> Bool {
        let pair = GestureSynonyms.validLengthPair(pair.first ?? "", pair.second ?? "", original: text)
        guard !pair.isEmpty, var s = lengthSession, s.originalText == text else { return false }
        s.alternatives = [pair.first ?? text, text, pair.second ?? text]
        s.unavailable = [:]
        if pair.first == nil { s.unavailable[LengthLevel.corto.rawValue] = "La IA no dio una versión corta válida para este párrafo." }
        if pair.second == nil { s.unavailable[LengthLevel.largo.rawValue] = "La IA no dio una versión larga válida para este párrafo." }
        lengthSession = s
        return true
    }

    private var lengthReadyMessage: String {
        let how = lengthManualControl
            ? "Compara y confirma."
            : "Acerca para acortar, separa para ampliar. Retira una mano para confirmar."
        guard let missing = lengthSession?.unavailable.keys.min(),
              let level = LengthLevel(rawValue: missing) else { return "Versiones listas. \(how)" }
        return "Versión \(level.label) no disponible: la IA no dio una válida. \(how)"
    }

    /// La generación sigue aunque la sesión cierre: el resultado queda en
    /// caché y reabrir el mismo párrafo se une a ella en vez de reiniciarla.
    private func fetchLengthVariants(text: String) {
        guard lengthJob?.key != text else { return }
        lengthJob?.task.cancel()
        let id = UUID()
        lengthJob = ModelJob(key: text, id: id, task: Task { [weak self] in
            guard let self else { return }
            let result: Result<VariantPair, ModelFailure>
            do {
                result = .success(try await lengthProvider.variants(for: text))
            } catch {
                // Cancelada porque otra generación la reemplazó: no es un fallo.
                guard let failure = ModelFailure.classify(error) else { return }
                result = .failure(failure)
            }
            await applyLengthVariants(result, text: text, id: id)
        })
    }

    private func applyLengthVariants(_ result: Result<VariantPair, ModelFailure>, text: String, id: UUID) async {
        // Guarda para reuso, también si solo una versión es válida: reabrir
        // el mismo párrafo es instantáneo. Los fallos no se guardan para poder reintentar.
        if case .success(let pair) = result {
            let valid = GestureSynonyms.validLengthPair(pair.first ?? "", pair.second ?? "", original: text)
            if !valid.isEmpty {
                lengthCache[text] = valid
                if lengthCache.count > 30 {
                    lengthCache.removeValue(forKey: lengthCache.keys.first ?? "")
                }
            }
        }
        guard lengthJob?.id == id else { return }
        lengthJob = nil
        guard let s = lengthSession, s.originalText == text, lengthLoading else { return }
        let failure: ModelFailure
        switch result {
        case .success(let pair):
            if applyLengthPair(pair, text: text) {
                lengthLoading = false
                // Mientras cargaba solo se podía estar en medio: no hay preview que rehacer.
                message = lengthReadyMessage
                return
            }
            failure = .invalidOutput
        case .failure(let cause):
            failure = cause
        }
        await cancelLengthSession(reason: "no se pudieron crear versiones; \(failure.message)")
        lengthToast = "No se pudieron crear versiones. \(failure.message)"
        lengthToastCanUndo = false
    }

    private func updateLengthSession(span: Double) async {
        guard var s = lengthSession, span.isFinite else { return }
        lengthLastSpan = span
        let delta = span - s.referenceSpan
        lengthSessionDelta = delta
        guard let out = LengthSpanStep.advance(current: s.currentIndex, count: s.alternatives.count,
                                               delta: delta, reference: s.referenceSpan,
                                               maxSteps: 1) else { return }
        // Mientras carga solo se puede volver al medio (original): los
        // extremos aún no existen y no se previsualiza texto a medias.
        if lengthLoading, out.index != LengthLevel.medio.rawValue { return }
        if let reason = s.unavailable[out.index] {
            message = "\(reason) Quédate en medio o ve al otro extremo."
            return
        }
        s.referenceSpan = out.reference
        if out.index != s.currentIndex {
            s.currentIndex = out.index
            lengthSession = s
            await send(.showPreview(s.option))
            let level = LengthLevel(rawValue: out.index)?.label ?? ""
            message = lengthLoading
                ? "Longitud · \(level) (tu texto) mientras se generan las versiones."
                : "Longitud · \(level). Retira UNA mano para confirmar."
        } else {
            lengthSession = s
            message = out.index == 0
                ? "Versión más corta. Separa las manos para ampliar."
                : "Versión más larga. Acerca las manos para acortar."
        }
    }

    private func commitLengthSession() async {
        guard let s = lengthSession else { return }
        if let reason = s.unavailable[s.currentIndex] {
            message = reason
            return
        }
        if lengthLoading {
            // Confirmar el medio (original) no necesita esperar: no hay
            // cambio que generar. Otro nivel sí debe esperar.
            guard s.currentIndex == LengthLevel.medio.rawValue else {
                message = "Aún generando versiones… espera o elige medio para salir sin cambios."
                return
            }
        }
        lengthSession = nil
        lengthLoading = false
        lengthTrackingLostAt = nil
        lengthTwoHandHits = []
        lengthSmoothedSpan = nil
        lengthOpenStreak = 0
        lengthSessionDelta = 0
        lengthManualControl = false
        // Tras confirmar hay que separar las manos para otra sesión.
        lengthRequiresRelease = true
        pinchStreak = 0
        lastRawPinch = false
        // La mano restante puede seguir en pinza: no debe abrir sinónimos.
        requiresRelease = true
        await send(.commitPreview)
        if s.option != s.originalText {
            let level = LengthLevel(rawValue: s.currentIndex)?.label ?? ""
            message = "Confirmado · \(level). ⌘Z para deshacer."
            lengthToast = "Párrafo en versión \(level)"
            lengthToastCanUndo = true
        } else {
            message = "Sin cambios"
            let words = s.option.split(whereSeparator: \.isWhitespace).count
            let origWords = s.originalText.split(whereSeparator: \.isWhitespace).count
            lengthToast = "Sin cambios: \(LengthLevel(rawValue: s.currentIndex)?.label ?? "esa versión") tiene \(words) pal., igual que tu texto (\(origWords))"
            lengthToastCanUndo = false
        }
    }

    /// Confirma directamente un nivel de la tarjeta (clic).
    /// Sin silencios: si no se puede aplicar, se dice en voz alta (toast).
    /// El medio (original) confirma incluso mientras carga: no hay espera.
    public func commitLengthSession(at index: Int) async {
        guard var s = lengthSession else {
            lengthToast = "La sesión ya no está activa; vuelve a abrirla"
            lengthToastCanUndo = false
            return
        }
        guard s.alternatives.indices.contains(index) else { return }
        if lengthLoading, index != LengthLevel.medio.rawValue { return }
        if let reason = s.unavailable[index] {
            message = reason
            return
        }
        s.currentIndex = index
        lengthSession = s
        await send(.showPreview(s.option))
        await commitLengthSession()
    }

    /// Previsualiza un nivel sin confirmar: el usuario puede comparar
    /// corto/medio/largo antes de decidir. Confirmar es explícito
    /// (botón Confirmar o retirar una mano). No cierra la sesión.
    public func previewLengthOption(at index: Int) async {
        guard var s = lengthSession, s.alternatives.indices.contains(index) else { return }
        if lengthLoading, index != LengthLevel.medio.rawValue { return }
        if let reason = s.unavailable[index] {
            message = reason
            return
        }
        guard index != s.currentIndex else { return }
        s.currentIndex = index
        lengthSession = s
        await send(.showPreview(s.option))
        let level = LengthLevel(rawValue: index)?.label ?? ""
        message = "Longitud · \(level) en vista previa. Confirma o sigue comparando."
    }

    /// Confirmación explícita del nivel previsualizado (botón Confirmar).
    public func confirmLengthSession() async {
        await commitLengthSession()
    }

    func cancelLengthSession(reason: String) async {
        lengthSession = nil
        lengthLoading = false
        lengthTrackingLostAt = nil
        lengthOpenStreak = 0
        lengthTwoHandHits = []
        lengthSmoothedSpan = nil
        lengthSessionDelta = 0
        lengthManualControl = false
        lengthToast = nil
        lengthRequiresRelease = true
        requiresRelease = true
        await send(.cancelPreview)
        message = "Cancelado: \(reason). Separa las manos antes de otro gesto."
    }

    /// Cancela la sesión de longitud (cambio de documento, cámara detenida).
    public func cancelLengthSession() {
        if lengthSession != nil {
            lengthSession = nil
            lengthLoading = false
            lengthTrackingLostAt = nil
            lengthOpenStreak = 0
            lengthTwoHandHits = []
            lengthSmoothedSpan = nil
            lengthSessionDelta = 0
            lengthManualControl = false
            lengthRequiresRelease = true
            requiresRelease = true
            Task { await send(.cancelPreview) }
        }
    }

    /// Abre la sesión de longitud sin cámara (botón del panel).
    /// Sirve para probar la generación aislando el gesto, y como
    /// alternativa accesible al gesto a dos manos.
    public func startLengthSessionManually() async {
        guard lengthSession == nil, pinchSession == nil, imageSizeSession == nil else {
            message = "Ya hay una sesión de gesto activa."
            return
        }
        guard let (text, range) = lengthParagraph(paragraphForLength(), noParagraph: "Coloca el cursor en un párrafo primero.") else { return }
        guard lengthProvider.isAvailable else {
            message = "No se puede cambiar la longitud. \(lengthProvider.availabilityReason ?? "Modelo de IA no disponible.")"
            lengthToast = message
            lengthToastCanUndo = false
            return
        }
        await send(.beginPreview(TextRange(location: range.location, length: range.length)))
        await send(.selectRange(TextRange(location: range.location, length: range.length)))
        lengthSession = LengthSession(id: UUID(), originalText: text, originalLocation: range.location,
                                      alternatives: [text, text, text],
                                      currentIndex: LengthLevel.medio.rawValue,
                                      referenceSpan: state.handSpan ?? 0)
        lengthManualControl = true
        lengthSessionDelta = 0
        lengthSmoothedSpan = nil
        lengthToast = nil
        navigationX = nil
        if let cached = lengthCache[text], applyLengthPair(cached, text: text) {
            lengthLoading = false
            message = "\(lengthReadyMessage) (reusadas)"
            return
        }
        lengthLoading = true
        message = "Preparando versiones corta y larga… Puedes ver tu texto en medio mientras tanto."
        fetchLengthVariants(text: text)
    }

    /// Cierra el aviso de longitud confirmada (sin tocar el texto).
    public func dismissLengthToast() { lengthToast = nil }

    /// Revierte el último cambio de longitud confirmado con el gesto.
    public func undoLengthCommit() async {
        await send(.undo)
        lengthToast = nil
    }
}
