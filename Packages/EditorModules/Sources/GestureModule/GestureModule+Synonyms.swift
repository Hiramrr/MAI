import EditorCore
import Foundation

extension GestureModule {
    // MARK: - Sesión de sinónimos

    private func wordAtSelection() -> (word: String, range: NSRange)? {
        let full = cachedText
        guard !full.isEmpty else { return nil }
        let sel = cachedSelection
        let ranges = currentWordRanges()
        guard !ranges.isEmpty else { return nil }
        var target: NSRange?
        if sel.length > 0 {
            target = ranges.first(where: { $0 == sel })
                ?? ranges.first(where: { NSLocationInRange(sel.location, $0) })
        } else {
            target = ranges.first(where: { NSLocationInRange(sel.location, $0) })
        }
        // Sin coincidencia (caret en un espacio): la palabra más cercana.
        if target == nil {
            var bestDist = Int.max
            for r in ranges {
                let d = abs((r.location + r.length / 2) - sel.location)
                if d < bestDist { bestDist = d; target = r }
            }
            if bestDist > 20 { target = nil }
        }
        guard let r = target, let swiftRange = Range(r, in: full) else { return nil }
        let word = String(full[swiftRange])
        guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (word, r)
    }

    func tryStartSession(_ vision: GestureState) async {
        guard !requiresRelease, let x = vision.x, x.isFinite else { return }
        if navigateByParagraph {
            guard let range = rangeUnderCursor(currentParagraphRanges()),
                  range == cachedSelection else { return }
            paragraphDragSource = range
            paragraphDropTarget = range
            message = "Párrafo tomado. Muévelo y abre la pinza para soltarlo."
            return
        }
        if navigationUnit == .oracion {
            await tryStartToneSession(x: x, manual: false)
            return
        }
        guard let (word, range) = wordAtSelection() else {
            // Aviso una sola vez por pinza (al abrir la ventana de inicio).
            if pinchStreak == GestureTuning.pinchStartFrames {
                message = "Selecciona una palabra con la mano abierta y haz pinza."
            }
            return
        }
        // El markdown de imagen no son palabras: pinzar sobre `![alt](...)`
        // abría sinónimos para "alt", "width" o "align" y al confirmar
        // rompía la imagen. Se bloquea y se dirige al gesto de imagen.
        if wordIsInsideImage(range) {
            if pinchStreak == GestureTuning.pinchStartFrames {
                message = "Esto es una imagen: muestra las dos manos o usa el botón Imagen para su tamaño, no sinónimos."
            }
            return
        }
        let starter = PinchStep.starterOptions(word: word, local: GestureSynonyms.alternatives(for: word))
        // Reuso instantáneo: la misma palabra no regenera con la IA.
        let cachedFresh = self.cachedSynonyms(for: word)
        let opening = cachedFresh.map { PinchStep.mergedOptions(word: word, fresh: $0) } ?? starter
        // Sin locales ni caché solo se abre si la IA puede generar: son justo las
        // palabras que más la necesitan. Sin IA que las genere, decirlo en
        // vez de abrir una tarjeta con la palabra sola (control falso).
        guard opening.count > 1 || synonymProvider.isAvailable else {
            let reason = synonymProvider.availabilityReason.map { " \($0)" } ?? ""
            if pinchStreak == GestureTuning.pinchStartFrames {
                message = "Sin sinónimos locales para “\(word)”. Prueba con otra palabra.\(reason)"
            }
            return
        }
        await send(.beginPreview(TextRange(location: range.location, length: range.length)))
        // La palabra objetivo queda seleccionada: se ve qué va a cambiar.
        await send(.selectRange(TextRange(location: range.location, length: range.length)))
        pinchSession = PinchSession(id: UUID(), word: word, location: range.location,
                                    alternatives: opening,
                                    currentIndex: opening.firstIndex(of: word) ?? 0,
                                    referenceX: x)
        sessionLastHandX = x
        sessionDelta = 0
        sessionUpgraded = cachedFresh != nil
        synonymNotice = nil
        openStreak = 0
        if cachedFresh != nil {
            message = "Sinónimos listos (reusados). Mueve para elegir, suelta para confirmar."
            return
        }
        message = starter.count > 1
            ? "Pinza: mueve para elegir, suelta para confirmar."
            : "Buscando sinónimos con IA… mantén la pinza."
        fetchUpgrade(word: word)
    }

    func updateSession(_ vision: GestureState) async {
        guard var s = pinchSession, vision.event == .changed,
              let x = vision.x, x.isFinite else { return }
        if s.isTone {
            await updateToneSession(x: x)
            return
        }
        sessionLastHandX = x
        let delta = x - s.referenceX
        sessionDelta = delta
        guard let out = PinchStep.advance(current: s.currentIndex, count: s.alternatives.count,
                                          delta: delta, reference: s.referenceX) else { return }
        s.referenceX = out.reference
        if out.index != s.currentIndex {
            s.currentIndex = out.index
            pinchSession = s
            await send(.showPreview(s.option))
            message = "Preview: \(s.option)"
        } else {
            pinchSession = s
            message = out.index == 0
                ? "Primera opción. Mueve a la derecha para avanzar."
                : "Última opción. Mueve a la izquierda para volver."
        }
    }

    func commitSession() async {
        guard let s = pinchSession else { return }
        // Un nivel sin versión válida nunca se confirma (no debería estar elegido).
        if let reason = s.unavailable[s.currentIndex] {
            message = reason
            return
        }
        // El tono a medio generar no se cancela: termina y queda en caché.
        let stillLoading = toneLoading
        toneLoading = false
        pinchSession = nil
        pinchManualControl = false
        trackingLostAt = nil
        openStreak = 0
        sessionDelta = 0
        // Tras confirmar hay que reabrir los dedos para otra sesión
        // (evita que un clic en la tarjeta reabra la pinza sostenida).
        requiresRelease = true
        await send(.commitPreview)
        guard s.isTone else {
            message = (s.option == s.word) ? "Sin cambios" : "Confirmado: \(s.option)"
            return
        }
        if s.option != s.word {
            let level = ToneLevel(rawValue: s.currentIndex)?.label ?? ""
            message = "Confirmado · tono \(level). ⌘Z para deshacer."
            lengthToast = "Oración en tono \(level)"
            lengthToastCanUndo = true
        } else {
            message = stillLoading
                ? "Sin cambios: el tono aún se generaba. Vuelve a pinzar la oración."
                : "Sin cambios"
        }
    }

    /// Confirma directamente una opción de la tarjeta (clic).
    public func commitPinchSession(at index: Int) async {
        guard var s = pinchSession, s.alternatives.indices.contains(index) else { return }
        // Los tonos a medio generar aún no existen: solo el original confirma.
        if s.isTone, toneLoading, index != ToneLevel.original.rawValue { return }
        if let reason = s.unavailable[index] {
            message = reason
            return
        }
        s.currentIndex = index
        pinchSession = s
        await send(.showPreview(s.option))
        await commitSession()
    }

    func cancelSession(reason: String) async {
        pinchSession = nil
        toneLoading = false
        pinchManualControl = false
        trackingLostAt = nil
        openStreak = 0
        sessionDelta = 0
        requiresRelease = true
        await send(.cancelPreview)
        message = "Cancelado: \(reason). Abre los dedos antes de otro pinch."
    }

    /// Cancela la sesión (cambio de documento, cámara detenida).
    public func cancelPinchSession() {
        if pinchSession != nil {
            let pinch = pinchSession
            pinchSession = nil
            toneLoading = false
            pinchManualControl = false
            trackingLostAt = nil
            openStreak = 0
            sessionDelta = 0
            requiresRelease = true
            Task { await send(.cancelPreview) }
            _ = pinch
        }
        cancelLengthSession()
        lengthToast = nil
    }

    /// Abre la sesión de sinónimos sin cámara (botón o menú).
    /// Sirve para probar la lista aislando el gesto, y como
    /// alternativa accesible a la pinza. La tarjeta la dirige:
    /// clic confirma, ✕ cancela.
    public func startPinchSessionManually() async {
        guard pinchSession == nil, lengthSession == nil, imageSizeSession == nil else {
            message = "Ya hay una sesión de gesto activa."
            return
        }
        guard let (word, range) = wordAtSelection() else {
            message = "Coloca el cursor en una palabra primero."
            return
        }
        // Igual que con cámara: el markdown de imagen no admite sinónimos.
        // Confirmar aquí reemplazaría "alt", "width" o "align" y rompería la imagen.
        if wordIsInsideImage(range) {
            message = "El cursor está en una imagen: usa el botón Imagen para su tamaño, no sinónimos."
            return
        }
        let starter = PinchStep.starterOptions(word: word, local: GestureSynonyms.alternatives(for: word))
        let cachedFresh = self.cachedSynonyms(for: word)
        let opening = cachedFresh.map { PinchStep.mergedOptions(word: word, fresh: $0) } ?? starter
        guard opening.count > 1 || synonymProvider.isAvailable else {
            let reason = synonymProvider.availabilityReason.map { " \($0)" } ?? ""
            message = "Sin sinónimos locales para “\(word)”. Prueba con otra palabra.\(reason)"
            return
        }
        await send(.beginPreview(TextRange(location: range.location, length: range.length)))
        await send(.selectRange(TextRange(location: range.location, length: range.length)))
        pinchSession = PinchSession(id: UUID(), word: word, location: range.location,
                                    alternatives: opening,
                                    currentIndex: opening.firstIndex(of: word) ?? 0,
                                    referenceX: 0)
        sessionLastHandX = 0
        sessionDelta = 0
        sessionUpgraded = cachedFresh != nil
        synonymNotice = nil
        openStreak = 0
        pinchStreak = 0
        pinchManualControl = true
        if cachedFresh != nil {
            message = "Sinónimos listos (reusados). Elige en la tarjeta para confirmar, o ✕ para cancelar."
            return
        }
        message = starter.count > 1
            ? "Elige un sinónimo en la tarjeta para confirmar, o ✕ para cancelar."
            : "Buscando sinónimos con IA…"
        fetchUpgrade(word: word)
    }

    /// Sinónimos reales (IA on-device) que mejoran la lista local si llegan
    /// a tiempo. Con caché no se llama al modelo. Sin modelo disponible
    /// el proveedor devuelve vacío y la tarjeta conserva los locales
    /// diciendo que son locales.
    /// La generación sigue aunque la sesión cierre: el resultado queda en
    /// caché y reabrir la misma palabra se une a ella en vez de reiniciarla.
    private func fetchUpgrade(word: String) {
        let key = synonymCacheKey(word)
        if let cached = cachedSynonyms(for: word), !cached.isEmpty {
            Task { [weak self] in
                await self?.applyUpgrade(cached, word: word)
            }
            return
        }
        guard upgradeJob?.key != key else { return }
        // Otra palabra: la anterior ya no se espera y deja libre el modelo.
        upgradeJob?.task.cancel()
        let id = UUID()
        upgradeJob = ModelJob(key: key, id: id, task: Task { [weak self] in
            guard let self else { return }
            let result: Result<[String], ModelFailure>
            do {
                result = .success(try await synonymProvider.synonyms(for: word))
            } catch {
                // Cancelada porque otra palabra la reemplazó: no es un fallo.
                guard let failure = ModelFailure.classify(error) else { return }
                result = .failure(failure)
            }
            await finishUpgrade(result, word: word, id: id)
        })
    }

    private func finishUpgrade(_ result: Result<[String], ModelFailure>, word: String, id: UUID) async {
        if case .success(let fresh) = result { storeSynonyms(fresh, for: word) }
        guard upgradeJob?.id == id else { return }
        upgradeJob = nil
        switch result {
        case .success(let fresh):
            await applyUpgrade(fresh, word: word)
        case .failure(let failure):
            await reportUpgradeFailure(failure, word: word)
        }
    }

    /// La IA no mejoró la lista: se dice por qué. Con sinónimos locales la
    /// sesión sigue; con la palabra sola no hay nada que elegir y se cierra.
    private func reportUpgradeFailure(_ failure: ModelFailure, word: String) async {
        guard let s = pinchSession, !s.isTone,
              synonymCacheKey(s.word) == synonymCacheKey(word) else { return }
        if s.alternatives.count <= 1 {
            await cancelSession(reason: "sin sinónimos para “\(word)”. \(failure.message)")
        } else {
            synonymNotice = failure.message
            message = "Sinónimos locales. \(failure.message)"
        }
    }

    /// Clave insensible a mayúsculas: "Importante" y "importante" comparten caché.
    private func synonymCacheKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func cachedSynonyms(for word: String) -> [String]? {
        let hit = synonymCache[synonymCacheKey(word)]
        guard let hit, !hit.isEmpty else { return nil }
        return hit
    }

    private func storeSynonyms(_ fresh: [String], for word: String) {
        guard !fresh.isEmpty else { return }
        synonymCache[synonymCacheKey(word)] = fresh
        if synonymCache.count > 200 {
            synonymCache.removeValue(forKey: synonymCache.keys.first ?? "")
        }
    }

    /// Mejora con sinónimos frescos: se aplica aunque el usuario ya se
    /// moviera (se conserva su elección si sigue en la lista). Si no hay
    /// sesión de esa palabra, se descarta en silencio (ya quedó en caché).
    /// Si no llegó mejora y la lista era solo la palabra, se cierra con
    /// mensaje (con la pinza aún cerrada el `requiresRelease` evita que se
    /// reabra sola).
    private func applyUpgrade(_ fresh: [String], word: String) async {
        guard var s = pinchSession, !s.isTone,
              synonymCacheKey(s.word) == synonymCacheKey(word) else { return }
        if fresh.isEmpty {
            if s.alternatives.count <= 1 {
                await cancelSession(reason: "La IA no devolvió sinónimos para “\(word)”")
            }
            return
        }
        synonymNotice = nil
        let merged = PinchStep.mergedOptions(word: s.word, fresh: fresh)
        guard merged != s.alternatives else { return }
        let currentOption = s.option
        s.alternatives = merged
        s.currentIndex = merged.firstIndex(of: currentOption) ?? 0
        pinchSession = s
        sessionUpgraded = true
        message = "Sinónimos listos. Mueve para elegir, suelta para confirmar."
        // En orden con el resto de comandos: un envío suelto podía llegar
        // después de confirmar y pisar la preview de la siguiente sesión.
        await send(.showPreview(s.option))
    }
}
