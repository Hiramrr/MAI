import XCTest
@testable import GestureModule

final class GestureRecognizerTests: XCTestCase {
    private func landmarks(distance: Double) -> HandLandmarks {
        // Pulgar fijo en (0.5, 0.5); índice desplazado en X para la distancia.
        HandLandmarks(wrist: CGPoint(x: 0.5, y: 0.2),
                      thumb: CGPoint(x: 0.5, y: 0.5),
                      index: CGPoint(x: 0.5 + distance, y: 0.5),
                      imageSize: CGSize(width: 640, height: 480))
    }

    func testHysteresis() {
        let saved = GestureThresholds.activation
        GestureThresholds.activation = 0.05
        defer { GestureThresholds.activation = saved }
        var recognizer = GestureRecognizer()
        // Abierta: sin pinza.
        var state = recognizer.update(handDetected: true, landmarks: landmarks(distance: 0.09))
        XCTAssertFalse(state.pinch)
        XCTAssertEqual(state.event, .none)
        // Cierra por debajo de la activación: empieza.
        state = recognizer.update(handDetected: true, landmarks: landmarks(distance: 0.04))
        XCTAssertTrue(state.pinch)
        XCTAssertEqual(state.event, .started)
        // Pequeña apertura dentro de la histéresis: sigue cerrada.
        state = recognizer.update(handDetected: true, landmarks: landmarks(distance: 0.06))
        XCTAssertTrue(state.pinch)
        XCTAssertEqual(state.event, .changed)
        // Apertura clara por encima de release (0.08): termina.
        state = recognizer.update(handDetected: true, landmarks: landmarks(distance: 0.10))
        XCTAssertFalse(state.pinch)
        XCTAssertEqual(state.event, .ended)
    }

    func testTrackingLost() {
        var recognizer = GestureRecognizer()
        _ = recognizer.update(handDetected: true, landmarks: landmarks(distance: 0.01))
        let state = recognizer.update(handDetected: false, landmarks: nil)
        XCTAssertEqual(state.event, .trackingLost)
        XCTAssertFalse(state.pinch)
    }

    func testTwoHandsSpan() {
        var recognizer = GestureRecognizer()
        let first = landmarks(distance: 0.02)
        var second = landmarks(distance: 0.02)
        second = HandLandmarks(wrist: second.wrist,
                               thumb: CGPoint(x: 0.1, y: 0.5),
                               index: CGPoint(x: 0.12, y: 0.5),
                               imageSize: second.imageSize)
        let state = recognizer.update(handDetected: true, landmarks: first, secondaryLandmarks: second)
        XCTAssertNotNil(state.handSpan)
        XCTAssertTrue(state.hasTwoDistinctHands)
    }
}

final class GestureCalibrationTests: XCTestCase {
    func testMedian() {
        XCTAssertEqual(GestureCalibrationMath.median([0.3, 0.1, 0.2]), 0.2)
        XCTAssertEqual(GestureCalibrationMath.median([0.4, 0.1, 0.3, 0.2]), 0.25)
        XCTAssertNil(GestureCalibrationMath.median([]))
    }

    func testSuggestedThreshold() {
        let result = GestureCalibrationMath.suggestedThreshold(open: 0.09, pinch: 0.03)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.value ?? 0, 0.06, accuracy: 0.0001)
        XCTAssertFalse(result?.gapWarning ?? true)
        // Muestras solapadas: no calibrable.
        XCTAssertNil(GestureCalibrationMath.suggestedThreshold(open: 0.03, pinch: 0.05))
        // Poca separación relativa: avisa.
        let tight = GestureCalibrationMath.suggestedThreshold(open: 0.05, pinch: 0.045)
        XCTAssertEqual(tight?.gapWarning, true)
    }
}

final class GestureNavigationTests: XCTestCase {
    private var ranges: [NSRange] {
        [NSRange(location: 0, length: 4), NSRange(location: 5, length: 5), NSRange(location: 11, length: 6)]
    }

    func testAnchorsWithoutReference() {
        let out = WordNavigator.update(ranges: ranges,
                                       selection: NSRange(location: 6, length: 0),
                                       referenceX: nil, handX: 0.5)
        XCTAssertEqual(out?.select, NSRange(location: 5, length: 5))
        XCTAssertEqual(out?.referenceX ?? 0, 0.5, accuracy: 0.0001)
    }

    func testStepMovesOneWord() {
        let first = WordNavigator.update(ranges: ranges,
                                         selection: NSRange(location: 0, length: 0),
                                         referenceX: 0.5, handX: 0.5 + GestureTuning.wordStep)
        XCTAssertEqual(first?.select, NSRange(location: 5, length: 5))
        XCTAssertNil(WordNavigator.update(ranges: ranges,
                                          selection: NSRange(location: 5, length: 0),
                                          referenceX: first?.referenceX, handX: 0.5 + GestureTuning.wordStep + 0.01))
    }

    func testWiderStepForParagraphs() {
        XCTAssertNil(WordNavigator.update(ranges: ranges,
                                          selection: ranges[0], referenceX: 0.5, handX: 0.6,
                                          step: GestureTuning.paragraphStep))
        let moved = WordNavigator.update(ranges: ranges,
                                         selection: ranges[0], referenceX: 0.5, handX: 0.67,
                                         step: GestureTuning.paragraphStep)
        XCTAssertEqual(moved?.select, ranges[1])
    }

    func testClampsAtEdges() {
        let out = WordNavigator.update(ranges: ranges,
                                       selection: NSRange(location: 11, length: 0),
                                       referenceX: 0.5, handX: 0.9)
        XCTAssertEqual(out?.select, NSRange(location: 11, length: 6))
    }

    func testPinchStep() {
        let out = PinchStep.advance(current: 0, count: 3, delta: GestureTuning.optionStep, reference: 0.5)
        XCTAssertEqual(out?.index, 1)
        XCTAssertNil(PinchStep.advance(current: 1, count: 3, delta: 0.01, reference: 0.5))
        // En el borde se queda y re-ancla con el dedo.
        let edge = PinchStep.advance(current: 2, count: 3, delta: GestureTuning.optionStep * 2, reference: 0.5)
        XCTAssertEqual(edge?.index, 2)
    }

    func testLengthSpanStepOneLevelPerFrame() {
        let out = LengthSpanStep.advance(current: 1, count: 3,
                                         delta: GestureTuning.lengthSpanStep * 3,
                                         reference: 0.5, maxSteps: 1)
        XCTAssertEqual(out?.index, 2)
        let back = LengthSpanStep.advance(current: 1, count: 3,
                                          delta: -GestureTuning.lengthSpanStep,
                                          reference: 0.5, maxSteps: 1)
        XCTAssertEqual(back?.index, 0)
    }

    func testStarterOptions() {
        let opts = PinchStep.starterOptions(word: "datos", local: ["información", "datos"])
        XCTAssertEqual(opts.first, "datos")
        XCTAssertTrue(opts.contains("información"))
        XCTAssertEqual(
            PinchStep.starterOptions(word: "x", local: []).count, 1)
        // Las alternativas vacías jamás llegan a la tarjeta.
        XCTAssertEqual(PinchStep.starterOptions(word: "x", local: ["", "  "]), ["x"])
    }
}

final class GestureSynonymsTests: XCTestCase {
    func testKnownWord() {
        XCTAssertTrue(GestureSynonyms.alternatives(for: "datos").contains("información"))
    }

    func testUnknownWordFallsBackHonestly() {
        // Sin entrada: variantes genéricas, la palabra siempre primera.
        let alts = GestureSynonyms.alternatives(for: "zxq")
        XCTAssertEqual(alts.first, "zxq")
    }

    func testLengthRejectsCopiedAndIncompleteVersions() {
        let paragraph = "Primera oración completa. Segunda oración con desarrollo importante y metodología clara."
        XCTAssertFalse(GestureSynonyms.isValidShort(paragraph, original: paragraph))
        XCTAssertFalse(GestureSynonyms.isValidLong(paragraph, original: paragraph))
        XCTAssertFalse(GestureSynonyms.isValidShort("Primera oración completa…", original: paragraph))
        XCTAssertTrue(GestureSynonyms.isValidShort("Primera oración completa.", original: paragraph))
    }
}

final class GestureToneTests: XCTestCase {
    func testSentenceRangesSkipMarkdownMarks() {
        let text = "# Título del texto\n\nPrimera oración. ¿Segunda oración?\n- Punto de lista.\n![foto](a.png)\n```\ncódigo aquí.\n```\n---"
        let sentences = GestureSentences.ranges(in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(sentences, ["Título del texto", "Primera oración.", "¿Segunda oración?", "Punto de lista."])
    }

    func testToneStepIsWiderThanOptions() {
        XCTAssertNil(PinchStep.advance(current: 1, count: 3, delta: GestureTuning.optionStep,
                                       reference: 0.5, step: GestureTuning.toneStep))
        let warm = PinchStep.advance(current: 1, count: 3, delta: GestureTuning.toneStep,
                                     reference: 0.5, step: GestureTuning.toneStep)
        XCTAssertEqual(warm?.index, ToneLevel.calido.rawValue)
        let cold = PinchStep.advance(current: 1, count: 3, delta: -GestureTuning.toneStep,
                                     reference: 0.5, step: GestureTuning.toneStep)
        XCTAssertEqual(cold?.index, ToneLevel.frio.rawValue)
    }

    func testToneRejectsCopiesAndUnrelatedText() {
        let sentence = "Necesito el informe mañana sin falta."
        XCTAssertTrue(GestureTone.canRewrite(sentence))
        XCTAssertFalse(GestureTone.canRewrite("Hola equipo."))
        XCTAssertFalse(GestureTone.canRewrite("Lee [la guía](https://ejemplo.com) antes de empezar."))
        XCTAssertTrue(GestureTone.isValid("Se requiere el informe mañana.", original: sentence))
        XCTAssertFalse(GestureTone.isValid("necesito el informe mañana sin falta.", original: sentence))
        XCTAssertFalse(GestureTone.isValid("Se requiere el informe…", original: sentence))
        XCTAssertFalse(GestureTone.isValid("El clima estará soleado todo el fin de semana.", original: sentence))
        XCTAssertFalse(GestureTone.areValid(["Se requiere el informe mañana.", "Se requiere el informe mañana."],
                                            original: sentence))
    }
}
