import EditorCore
import Foundation

extension GestureModule {
    // MARK: - Visión (MainActor)

    func handleVision(_ vision: GestureState, at uptime: TimeInterval) async {
        guard running else { return }
        state = vision
        if paused { return }
        updateFingerCursor(vision)
        // Calibrando: solo muestrear (la interacción queda congelada).
        if calibration != nil {
            sampleCalibration(vision, at: uptime)
            return
        }
        // Sesión manual (botón): la cámara solo decora, no decide.
        // La tarjeta confirma con clic y cancela con ✕.
        if pinchManualControl || imageManualControl {
            return
        }
        // Dos manos: el gesto de longitud tiene prioridad y suspende
        // la navegación y la pinza de una mano mientras está activo.
        if lengthSession != nil || imageSizeSession != nil || vision.hasTwoDistinctHands {
            if paragraphDragSource != nil {
                paragraphDragSource = nil
                paragraphDropTarget = nil
                requiresRelease = true
            }
            await handleLengthVision(vision, at: uptime)
            return
        }
        // Sin dos manos: rearmar el gesto (las detecciones viejas caducan solas).
        lengthRequiresRelease = false
        guard vision.landmarksValid else {
            await handleTrackingGap(at: uptime)
            return
        }
        resolveTrackingGap(vision)
        if pinchSession == nil, pointedImageRange != nil {
            navigationX = nil
            pinchStreak = 0
            lastRawPinch = false
            message = "Imagen bajo el dedo. Muestra la otra mano para cambiar su tamaño."
            return
        }
        // Antirrebote: la pinza efectiva exige 2 frames seguidos.
        // Solo retrasa el cierre (40 ms); la apertura sigue instantánea.
        let rawPinch = vision.pinch
        let effectivePinch = rawPinch && lastRawPinch
        lastRawPinch = rawPinch
        if effectivePinch {
            openStreak = 0
            navigationX = nil
            pinchStreak += 1
            if navigateByParagraph {
                if paragraphDragSource == nil { await tryStartSession(vision) }
                if paragraphDragSource != nil { await updateParagraphDropTarget() }
            } else if pinchSession == nil {
                // Pinza + barrido lateral amplio = deshacer/rehacer.
                // Se evalúa antes de abrir sinónimos: pinza quieta abre la
                // tarjeta, pinza que barre ejecuta (una vez por pinza; abrir
                // los dedos rearma, como en el prototipo).
                if !undoSwipeFired, !requiresRelease,
                   let x = vision.x, x.isFinite {
                    if undoSwipeAnchor == nil {
                        undoSwipeAnchor = x
                    } else if abs(x - undoSwipeAnchor!) > GestureTuning.undoSwipeDistance {
                        if x < undoSwipeAnchor! {
                            await send(.undo)
                            message = "Deshacer"
                        } else {
                            await send(.redo)
                            message = "Rehacer"
                        }
                        undoSwipeFired = true
                        requiresRelease = true
                        pinchStreak = 0
                    }
                }
                // La sesión abre tras varios frames sostenidos: un roce
                // no abre la tarjeta y el ancla excluye el gesto de cierre.
                if pinchStreak >= GestureTuning.pinchStartFrames {
                    await tryStartSession(vision)
                }
            } else {
                await updateSession(vision)
            }
        } else if !rawPinch {
            // Apertura verificada (el frame de transición se ignora).
            pinchStreak = 0
            requiresRelease = false
            undoSwipeAnchor = nil
            undoSwipeFired = false
            if paragraphDragSource != nil {
                await finishParagraphDrag()
            } else if pinchSession != nil {
                // Soltar confirma: al instante si es decidido, o tras
                // 3 frames sostenidos (un parpadeo no confirma solo).
                let clearRelease = vision.event == .ended
                    && (vision.distance ?? 0) > GestureThresholds.commit
                openStreak += 1
                if clearRelease || openStreak >= 3 { await commitSession() }
            } else {
                await navigateWords(vision)
            }
        }
    }

    private func updateFingerCursor(_ vision: GestureState) {
        // Se calcula en locales y se publica una vez: cada escritura en una
        // propiedad observada repinta la interfaz, y esto corre en cada frame.
        var point: CGPoint?
        var range: NSRange?
        if calibration == nil {
            for hand in [vision.landmarks, vision.secondaryLandmarks].compactMap({ $0 }) where hand.isValid {
                let candidate = CGPoint(x: 1 - hand.index.x, y: 1 - hand.index.y)
                let hit = imageHitTest?(candidate)
                if point == nil || hit != nil {
                    point = candidate
                    range = hit
                }
                if hit != nil { break }
            }
        }
        if point == nil { range = imageHitTest?(nil) }
        if cursorPoint != point { cursorPoint = point }
        if pointedImageRange != range { pointedImageRange = range }
    }

    func rangeUnderCursor(_ ranges: [NSRange]) -> NSRange? {
        guard let point = cursorPoint, let location = textHitTest?(point) else { return nil }
        return ranges.first(where: { NSLocationInRange(location, $0) })
            ?? ranges.last(where: { NSMaxRange($0) <= location })
            ?? ranges.first
    }

    private func updateParagraphDropTarget() async {
        let target = rangeUnderCursor(currentParagraphRanges())
        guard target != paragraphDropTarget else { return }
        paragraphDropTarget = target
        if let target {
            await send(.selectRange(TextRange(location: target.location, length: target.length)))
            message = target == paragraphDragSource
                ? "Párrafo en su lugar."
                : "Suelta para mover el párrafo aquí."
        }
    }

    private func finishParagraphDrag() async {
        await updateParagraphDropTarget()
        defer {
            paragraphDragSource = nil
            paragraphDropTarget = nil
            requiresRelease = true
        }
        guard let source = paragraphDragSource,
              let target = paragraphDropTarget, target != source else {
            if let source = paragraphDragSource {
                await send(.selectRange(TextRange(location: source.location, length: source.length)))
            }
            message = "Párrafo en su lugar."
            return
        }
        await send(.moveParagraph(from: TextRange(location: source.location, length: source.length),
                                  to: TextRange(location: target.location, length: target.length)))
        message = "Párrafo movido."
    }

    func handleVisionError(_ text: String) async {
        guard running else { return }
        message = text
    }

    // MARK: - Pérdida breve de seguimiento (0.3 s de gracia)

    private func handleTrackingGap(at uptime: TimeInterval) async {
        // Sin mano verificable no hay pinza verificable: cuenta como
        // dedos abiertos para no bloquear futuros pinch.
        requiresRelease = false
        navigationX = nil
        lastRawPinch = false
        undoSwipeAnchor = nil
        undoSwipeFired = false
        if paragraphDragSource != nil {
            paragraphDragSource = nil
            paragraphDropTarget = nil
            requiresRelease = true
            message = "Se perdió la mano; movimiento cancelado."
        }
        guard pinchSession != nil else { return }
        if trackingLostAt == nil {
            trackingLostAt = uptime
            message = "Sin seguimiento. Mantén la mano visible."
        } else if uptime - trackingLostAt! >= GestureTuning.trackingLossGrace {
            await cancelSession(reason: "Se perdió la mano")
        }
    }

    private func resolveTrackingGap(_ vision: GestureState) {
        guard trackingLostAt != nil else { return }
        defer { trackingLostAt = nil }
        // Vuelve con pinza: conserva lo avanzado pero excluye el salto no visto.
        if vision.pinch, let x = vision.x, var s = pinchSession {
            s.referenceX += x - sessionLastHandX
            pinchSession = s
            sessionLastHandX = x
            message = s.isTone
                ? "Tono · \(ToneLevel(rawValue: s.currentIndex)?.label ?? ""). Mueve para elegir, suelta para confirmar."
                : "Preview: \(s.option). Mueve para elegir, suelta para confirmar."
        }
    }

    // MARK: - Selección con mano abierta

    private func navigateWords(_ vision: GestureState) async {
        // Sin puerta de distancia: si el estado dice "no pinza", se navega.
        // La histéresis del reconocedor ya evita el aleteo en la frontera.
        guard vision.event != .ended,
              let hand = vision.landmarks, hand.isValid,
              let x = vision.x, x.isFinite, (0...1).contains(x) else {
            navigationX = nil
            return
        }
        let ranges = currentNavigationRanges()
        guard !ranges.isEmpty else {
            navigationX = nil
            return
        }
        if textHitTest != nil {
            guard let range = rangeUnderCursor(ranges) else { return }
            navigationX = nil
            guard range != cachedSelection else { return }
            cachedSelection = range
            await send(.selectRange(TextRange(location: range.location, length: range.length)))
            return
        }
        let selection = cachedSelection
        guard let out = WordNavigator.update(
            ranges: ranges, selection: selection,
            referenceX: navigationX, handX: x,
            step: navigationUnit.step
        ) else { return }
        navigationX = out.referenceX
        cachedSelection = out.select
        await send(.selectRange(TextRange(location: out.select.location, length: out.select.length)))
    }
}
