import EditorCore
import Foundation

extension GestureModule {
    // MARK: - Sesión de tono (oración)

    /// Lecturas para la tarjeta de tono (observadas por SwiftUI).
    public var isToneSession: Bool { pinchSession?.isTone ?? false }
    public var toneLabels: [String] { ToneLevel.allCases.map(\.label) }
    public var toneOptions: [String] {
        guard let s = pinchSession, s.isTone else { return [] }
        if toneLoading { return ["Preparando tono frío…", s.word, "Preparando tono cálido…"] }
        return s.alternatives.indices.map { s.unavailable[$0] ?? s.alternatives[$0] }
    }
    /// Motivo por el que un tono no se puede usar (nil si se puede).
    public func toneUnavailableReason(at index: Int) -> String? {
        guard let s = pinchSession, s.isTone else { return nil }
        return s.unavailable[index]
    }

    /// Pone en la sesión los tonos válidos; los que faltan quedan bloqueados
    /// con su motivo. El original solo ocupa su hueco.
    func toneSession(_ session: PinchSession, with pair: VariantPair) -> PinchSession? {
        let pair = GestureTone.validPair(pair.first ?? "", pair.second ?? "", original: session.word)
        guard !pair.isEmpty else { return nil }
        var s = session
        s.alternatives = [pair.first ?? s.word, s.word, pair.second ?? s.word]
        s.unavailable = [:]
        if pair.first == nil { s.unavailable[ToneLevel.frio.rawValue] = "La IA no dio una versión fría válida para esta oración." }
        if pair.second == nil { s.unavailable[ToneLevel.calido.rawValue] = "La IA no dio una versión cálida válida para esta oración." }
        return s
    }

    private func toneReadyMessage(_ s: PinchSession, reused: Bool) -> String {
        let how = pinchManualControl
            ? "Elige en la tarjeta para confirmar."
            : "Izquierda enfría, derecha templa. Suelta para confirmar."
        let head = reused ? "Tonos listos (reusados)." : "Tonos listos."
        guard let missing = s.unavailable.keys.min(), let level = ToneLevel(rawValue: missing) else {
            return "\(head) \(how)"
        }
        return "Tono \(level.label) no disponible: la IA no dio uno válido. \(how)"
    }

    private func sentenceAtSelection() -> (text: String, range: NSRange)? {
        let ranges = currentSentenceRanges()
        let caret = cachedSelection.location
        guard let range = ranges.first(where: { NSLocationInRange(caret, $0) })
                ?? ranges.first(where: { NSMaxRange($0) == caret }) else { return nil }
        return ((cachedText as NSString).substring(with: range), range)
    }

    /// Abre la sesión sobre la oración seleccionada. La comparten la pinza
    /// (modo oraciones) y el botón del panel: mismo ciclo que los sinónimos,
    /// con niveles fijos [frío, original, cálido] generados en el Mac.
    func tryStartToneSession(x: Double, manual: Bool) async {
        // Con cámara, aviso una sola vez por pinza (al abrir la ventana de inicio).
        let announce = manual || pinchStreak == GestureTuning.pinchStartFrames
        guard let (text, range) = sentenceAtSelection() else {
            if announce {
                message = manual ? "Coloca el cursor en una oración primero."
                                 : "Señala una oración con la mano abierta y haz pinza."
            }
            return
        }
        guard GestureTone.canRewrite(text) else {
            if announce { message = "Esta oración no admite cambio de tono: es muy corta o tiene enlaces o código." }
            return
        }
        guard toneProvider.isAvailable else {
            message = "No se puede cambiar el tono. \(toneProvider.availabilityReason ?? "Modelo de IA no disponible.")"
            lengthToast = message
            lengthToastCanUndo = false
            if !manual { requiresRelease = true }
            return
        }
        await send(.beginPreview(TextRange(location: range.location, length: range.length)))
        await send(.selectRange(TextRange(location: range.location, length: range.length)))
        let session = PinchSession(id: UUID(), word: text, location: range.location,
                                   alternatives: [text, text, text],
                                   currentIndex: ToneLevel.original.rawValue,
                                   referenceX: x, isTone: true)
        sessionLastHandX = x
        sessionDelta = 0
        sessionUpgraded = false
        openStreak = 0
        pinchManualControl = manual
        if manual { pinchStreak = 0 }
        lengthToast = nil
        // Reuso instantáneo: la misma oración no regenera.
        if let cached = toneCache[text], let ready = toneSession(session, with: cached) {
            pinchSession = ready
            toneLoading = false
            message = toneReadyMessage(ready, reused: true)
            return
        }
        pinchSession = session
        toneLoading = true
        message = manual ? "Preparando tono frío y cálido…"
                         : "Preparando tono frío y cálido… mantén la pinza."
        // La misma oración aún generándose (sesión cerrada y reabierta): se
        // une a esa generación en vez de reiniciarla.
        guard toneJob?.key != text else { return }
        toneJob?.task.cancel()
        let id = UUID()
        toneJob = ModelJob(key: text, id: id, task: Task { [weak self] in
            guard let self else { return }
            let result: Result<VariantPair, ModelFailure>
            do {
                result = .success(try await toneProvider.variants(for: text))
            } catch {
                // Cancelada porque otra generación la reemplazó: no es un fallo.
                guard let failure = ModelFailure.classify(error) else { return }
                result = .failure(failure)
            }
            await applyToneVariants(result, text: text, id: id)
        })
    }

    private func applyToneVariants(_ result: Result<VariantPair, ModelFailure>, text: String, id: UUID) async {
        // Se guarda aunque la sesión ya cerrara, también si solo un tono es
        // válido: volver a pinzar es instantáneo. Los fallos no se guardan.
        if case .success(let pair) = result {
            let valid = GestureTone.validPair(pair.first ?? "", pair.second ?? "", original: text)
            if !valid.isEmpty {
                toneCache[text] = valid
                if toneCache.count > 30 {
                    toneCache.removeValue(forKey: toneCache.keys.first ?? "")
                }
            }
        }
        guard toneJob?.id == id else { return }
        toneJob = nil
        guard let s = pinchSession, s.isTone, s.word == text, toneLoading else { return }
        toneLoading = false
        let failure: ModelFailure
        switch result {
        case .success(let pair):
            if let ready = toneSession(s, with: pair) {
                pinchSession = ready
                message = toneReadyMessage(ready, reused: false)
                return
            }
            failure = .invalidOutput
        case .failure(let cause):
            failure = cause
        }
        await cancelSession(reason: "no se pudo cambiar el tono; \(failure.message)")
        lengthToast = "No se pudo cambiar el tono. \(failure.message)"
        lengthToastCanUndo = false
    }

    func updateToneSession(x: Double) async {
        guard var s = pinchSession, s.isTone else { return }
        sessionLastHandX = x
        let delta = x - s.referenceX
        sessionDelta = delta
        // Mientras carga no hay extremos que previsualizar.
        guard !toneLoading,
              let out = PinchStep.advance(current: s.currentIndex, count: s.alternatives.count,
                                          delta: delta, reference: s.referenceX,
                                          step: GestureTuning.toneStep) else { return }
        if let reason = s.unavailable[out.index] {
            message = "\(reason) Vuelve al centro o ve al otro lado."
            return
        }
        s.referenceX = out.reference
        if out.index != s.currentIndex {
            s.currentIndex = out.index
            pinchSession = s
            await send(.showPreview(s.option))
            message = "Tono · \(ToneLevel(rawValue: out.index)?.label ?? ""). Suelta para confirmar."
        } else {
            pinchSession = s
            message = out.index == 0
                ? "Tono más frío. Mueve a la derecha para templarlo."
                : "Tono más cálido. Mueve a la izquierda para enfriarlo."
        }
    }

    /// Abre la sesión de tono sin cámara (botón del panel), sobre la oración
    /// del cursor. Alternativa accesible a la pinza: clic confirma, ✕ cancela.
    public func startToneSessionManually() async {
        guard pinchSession == nil, lengthSession == nil, imageSizeSession == nil else {
            message = "Ya hay una sesión de gesto activa."
            return
        }
        await tryStartToneSession(x: 0, manual: true)
    }
}
