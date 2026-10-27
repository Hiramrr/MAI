import XCTest
import AppKit
@testable import EditorCore
@testable import EditorEngine
@testable import ModuleKit
@testable import GestureModule

/// Flujo completo gesto → bus → sesión, sin cámara.
final class GestureIntegrationTests: XCTestCase {
    @MainActor
    private func makeHarness(text: String, lengthProvider: (any LengthProvider)? = nil,
                             toneProvider: (any ToneProvider)? = nil) -> (GestureModule, EditorSession, NSTextView, NSWindow, EditorCommandBus) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = true
        view.string = text
        window.contentView = view
        window.makeFirstResponder(view)
        let session = EditorSession()
        session.textView = view
        session.onPreviewCommitted = { _ in }
        let bus = EditorCommandBus()
        let module = GestureModule(lengthProvider: lengthProvider, toneProvider: toneProvider)
        return (module, session, view, window, bus)
    }

    @MainActor
    private func pump(times: Int = 50) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }

    @MainActor func testManualSynonymSessionEndToEnd() async throws {
        let (module, session, view, window, bus) = makeHarness(text: "hola mundo importante")
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        // Consumidor como el de EditorScreen.
        let consumer = Task { @MainActor in
            for await command in await bus.commands() {
                session.send(command)
            }
        }
        defer { consumer.cancel() }
        // Dejar que el consumidor registre su continuación antes de enviar.
        await pump()
        module.updateDocument(text: "hola mundo importante",
                              selection: NSRange(location: 18, length: 0))
        await module.startPinchSessionManually()
        await pump()
        XCTAssertTrue(module.hasPinchSession, "mensaje: \(module.message)")
        XCTAssertGreaterThan(module.sessionOptions.count, 1)
        // La palabra objetivo queda seleccionada.
        XCTAssertEqual(view.selectedRange().length, ("importante" as NSString).length)
        // Confirmar la segunda opción la aplica con un solo undo.
        await module.commitPinchSession(at: 1)
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(session.isPreviewing)
        let applied = view.string
        XCTAssertNotEqual(applied, "hola mundo importante")
        XCTAssertTrue(applied.hasPrefix("hola mundo "))
        // Un solo undo revierte lo confirmado.
        session.send(.undo)
        XCTAssertEqual(view.string, "hola mundo importante")
        session.send(.redo)
        XCTAssertEqual(view.string, applied)
    }

    @MainActor func testBeginPreviewDirectlyThroughBus() async throws {
        let (module, session, view, window, bus) = makeHarness(text: "hola mundo importante")
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() {
                session.send(command)
            }
        }
        defer { consumer.cancel() }
        // Dejar que el consumidor registre su continuación antes de enviar.
        await pump()
        await bus.send(.beginPreview(TextRange(location: 11, length: 10)))
        await pump()
        XCTAssertTrue(session.isPreviewing)
        await bus.send(.showPreview("relevante"))
        await pump()
        XCTAssertEqual(view.string, "hola mundo relevante")
        await bus.send(.commitPreview)
        await pump()
        XCTAssertFalse(session.isPreviewing)
        XCTAssertEqual(view.string, "hola mundo relevante")
    }

    @MainActor func testManualLengthSessionEndToEnd() async throws {
        let paragraph = "Primera oración completa. Segunda oración con desarrollo importante y metodología clara."
        let (module, session, view, window, bus) = makeHarness(text: paragraph, lengthProvider: StubLengthProvider())
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() {
                session.send(command)
            }
        }
        defer { consumer.cancel() }
        // Dejar que el consumidor registre su continuación antes de enviar.
        await pump()
        module.updateDocument(text: paragraph, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertTrue(module.hasLengthSession, "mensaje: \(module.message)")
        XCTAssertEqual(module.lengthOptions.count, 3)
        await module.commitLengthSession(at: 2)
        await pump()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertEqual(view.string, StubLengthProvider().results[1])
        XCTAssertNotNil(module.lengthToast)
    }

    @MainActor func testFailedLengthGenerationKeepsParagraph() async throws {
        let paragraph = "Primera oración completa. Segunda oración con desarrollo importante y metodología clara."
        let (module, session, view, window, bus) = makeHarness(text: paragraph, lengthProvider: StubLengthProvider(results: []))
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: paragraph, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertEqual(view.string, paragraph)
        XCTAssertFalse(module.lengthToastCanUndo)
    }

    @MainActor func testUnknownWordOpensNoSession() async {
        // Sin sinónimos locales y sin IA que genere: no se abre tarjeta con
        // la palabra sola (el proveedor local nunca mejora).
        let module = GestureModule(synonymProvider: LocalSynonymProvider())
        module.updateDocument(text: "hola zxq", selection: NSRange(location: 6, length: 0))
        await module.startPinchSessionManually()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertTrue(module.message.contains("zxq"))
    }

    @MainActor func testKnownWordOpensSession() async {
        let module = GestureModule(synonymProvider: LocalSynonymProvider())
        module.updateDocument(text: "hola mundo", selection: NSRange(location: 6, length: 0))
        await module.startPinchSessionManually()
        XCTAssertTrue(module.hasPinchSession)
        XCTAssertGreaterThan(module.sessionOptions.count, 1)
        XCTAssertEqual(module.sessionOptions.first, "mundo")
    }

    @MainActor func testPinchOnImageOpensNoSynonyms() async {
        // El markdown de imagen no son palabras: pinzar sobre `![...]` no debe
        // abrir sinónimos (antes ofrecía "foto"/"width"/"align" y al confirmar rompía la imagen).
        let image = "![foto](images/foto.png \"width=320;align=center\")"
        for location in [4, 15, 30, 40] {
            let module = GestureModule(synonymProvider: LocalSynonymProvider())
            module.updateDocument(text: image, selection: NSRange(location: location, length: 0))
            await module.startPinchSessionManually()
            XCTAssertFalse(module.hasPinchSession, "loc \(location) abrió sinónimos en imagen")
            XCTAssertTrue(module.message.lowercased().contains("imagen"), "loc \(location): \(module.message)")
        }
    }

    // MARK: - Gesto a dos manos (detecciones sintéticas, sin cámara)

    private func validLandmarks(x: Double) -> HandLandmarks {
        HandLandmarks(wrist: CGPoint(x: x, y: 0.2), thumb: CGPoint(x: x, y: 0.5),
                      index: CGPoint(x: x + 0.02, y: 0.5), imageSize: CGSize(width: 640, height: 480))
    }

    private func twoHands(span: Double) -> GestureState {
        var state = GestureState()
        state.handDetected = true
        state.landmarks = validLandmarks(x: 0.6)
        state.secondaryLandmarks = validLandmarks(x: 0.3)
        state.handSpan = span
        state.pinch = false
        return state
    }

    private func oneHand() -> GestureState {
        var state = GestureState()
        state.handDetected = true
        state.landmarks = validLandmarks(x: 0.5)
        state.pinch = false
        return state
    }

    @MainActor func testTwoHandLengthFlow() async throws {
        let paragraph = "Primera oración completa. Segunda oración con desarrollo importante y metodología clara."
        let short = StubLengthProvider().results[0]
        XCTAssertNotEqual(short, paragraph)
        let (module, session, view, window, bus) = makeHarness(text: paragraph, lengthProvider: StubLengthProvider())
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() {
                session.send(command)
            }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: paragraph, selection: NSRange(location: 5, length: 0))
        // Tres detecciones con dos manos abren la sesión en nivel medio.
        await module.handleLengthVision(twoHands(span: 0.40), at: 0.0)
        await module.handleLengthVision(twoHands(span: 0.41), at: 0.05)
        await module.handleLengthVision(twoHands(span: 0.42), at: 0.10)
        await pump()
        XCTAssertTrue(module.hasLengthSession, "mensaje: \(module.message)")
        XCTAssertEqual(module.lengthIndex, LengthLevel.medio.rawValue)
        // Separar las manos amplía un nivel por frame.
        await module.handleLengthVision(twoHands(span: 0.75), at: 0.15)
        await pump()
        XCTAssertEqual(module.lengthIndex, LengthLevel.largo.rawValue)
        XCTAssertEqual(view.string, StubLengthProvider().results[1])
        // Acercar reduce un nivel por frame hasta la versión corta, que previsualiza.
        await module.handleLengthVision(twoHands(span: 0.30), at: 0.20)
        await module.handleLengthVision(twoHands(span: 0.22), at: 0.25)
        await module.handleLengthVision(twoHands(span: 0.15), at: 0.30)
        await pump()
        XCTAssertEqual(module.lengthIndex, LengthLevel.corto.rawValue)
        XCTAssertEqual(view.string, short)
        // Retirar una mano confirma con aviso y Deshacer.
        await module.handleLengthVision(oneHand(), at: 0.35)
        await module.handleLengthVision(oneHand(), at: 0.40)
        await module.handleLengthVision(oneHand(), at: 0.45)
        await module.handleLengthVision(oneHand(), at: 0.50)
        await module.handleLengthVision(oneHand(), at: 0.55)
        await pump()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertEqual(view.string, short)
        XCTAssertNotNil(module.lengthToast)
        XCTAssertTrue(module.lengthToastCanUndo)
        session.send(.undo)
        XCTAssertEqual(view.string, paragraph)
    }

    @MainActor func testTwoHandImageSizeAndUndo() async throws {
        let image = "![foto](images/foto.png \"width=320;align=center\")"
        let (module, session, view, window, bus) = makeHarness(text: image)
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: image, selection: NSRange(location: 4, length: 0))
        await module.handleLengthVision(twoHands(span: 0.40), at: 0)
        await module.handleLengthVision(twoHands(span: 0.41), at: 0.05)
        await module.handleLengthVision(twoHands(span: 0.42), at: 0.10)
        XCTAssertTrue(module.hasImageSizeSession)
        XCTAssertFalse(module.hasLengthSession)
        await module.handleLengthVision(twoHands(span: 0.75), at: 0.15)
        await pump()
        XCTAssertGreaterThan(module.imageWidth, 320)
        XCTAssertEqual(MarkdownImage(line: view.string)?.width, module.imageWidth)
        for step in 0..<GestureTuning.lengthCommitFrames {
            await module.handleLengthVision(oneHand(), at: 0.20 + Double(step) * 0.05)
        }
        await pump()
        XCTAssertFalse(module.hasImageSizeSession)
        XCTAssertGreaterThan(MarkdownImage(line: view.string)?.width ?? 0, 320)
        XCTAssertTrue(module.lengthToastCanUndo)
        session.send(.undo)
        XCTAssertEqual(view.string, image)
    }

    @MainActor func testFingerTargetsImageWithoutTextCursor() async throws {
        let image = "![foto](images/foto.png \"width=320;align=center\")"
        let text = "Texto\n" + image
        let imageRange = (text as NSString).range(of: image)
        let (module, session, view, window, bus) = makeHarness(text: text)
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: text, selection: NSRange(location: 2, length: 0))
        module.imageHitTest = { point in
            guard let point, (0.35...0.45).contains(point.x), (0.45...0.55).contains(point.y) else { return nil }
            return imageRange
        }
        module.running = true
        await module.handleVision(twoHands(span: 0.40), at: 0)
        await module.handleVision(twoHands(span: 0.41), at: 0.05)
        await module.handleVision(twoHands(span: 0.42), at: 0.10)
        await pump()
        XCTAssertTrue(module.isPointingAtImage)
        XCTAssertNotNil(module.cursorPoint)
        XCTAssertTrue(module.hasImageSizeSession)
        XCTAssertEqual(view.selectedRange(), imageRange)
    }

    @MainActor func testManualImageSizeCancelRestoresOriginal() async throws {
        let image = "![foto](images/foto.png)"
        let (module, session, view, window, bus) = makeHarness(text: image)
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: image, selection: NSRange(location: 4, length: 0))
        await module.startImageSizeSessionManually()
        await module.setImageWidth(240)
        await pump()
        XCTAssertEqual(MarkdownImage(line: view.string)?.width, 240)
        module.cancelImageSizeSession()
        await pump()
        XCTAssertEqual(view.string, image)
    }

    @MainActor func testCursorSelectsAndPinchMovesParagraph() async throws {
        let text = "primer párrafo\nsegundo párrafo\ntercer párrafo"
        let (module, session, view, window, bus) = makeHarness(text: text)
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: text, selection: NSRange(location: 0, length: 0))
        let previousMode = module.navigateByParagraph
        module.navigateByParagraph = true
        defer { module.navigateByParagraph = previousMode }
        module.textHitTest = { point in
            point.x > 0.6 ? 1 : point.x > 0.4 ? 17 : 33
        }
        module.running = true
        var hand = oneHand()
        hand.x = 0.5
        await module.handleVision(hand, at: 0)
        await pump()
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "segundo párrafo")
        hand.pinch = true
        hand.event = .changed
        for frame in 0..<2 {
            await module.handleVision(hand, at: 0.05 + Double(frame) * 0.05)
        }
        XCTAssertTrue(module.isDraggingParagraph)
        hand.landmarks = validLandmarks(x: 0.7)
        hand.x = 0.7
        await module.handleVision(hand, at: 0.35)
        await pump()
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "tercer párrafo")
        hand.pinch = false
        for frame in 0..<3 {
            await module.handleVision(hand, at: 0.4 + Double(frame) * 0.05)
        }
        await pump()
        XCTAssertEqual(view.string, "primer párrafo\ntercer párrafo\nsegundo párrafo")
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(module.isDraggingParagraph)
        session.send(.undo)
        XCTAssertEqual(view.string, text)
        module.navigateByParagraph = false
        module.textHitTest = { _ in 2 }
        var pointing = oneHand()
        pointing.x = 0.5
        await module.handleVision(pointing, at: 0.6)
        await pump()
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "primer")
    }

    // MARK: - Tono de la oración

    private static let toneText = "Hola equipo. Necesito el informe mañana sin falta. Gracias."
    private static let toneSentence = "Necesito el informe mañana sin falta."

    @MainActor func testManualToneSessionEndToEnd() async throws {
        let text = Self.toneText
        let (module, session, view, window, bus) = makeHarness(text: text, toneProvider: StubToneProvider())
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        await pump()
        XCTAssertTrue(module.isToneSession, "mensaje: \(module.message)")
        XCTAssertFalse(module.toneLoading)
        XCTAssertEqual(module.toneOptions, [StubToneProvider().results[0], Self.toneSentence, StubToneProvider().results[1]])
        // La oración objetivo queda seleccionada, sin tocar las vecinas.
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), Self.toneSentence)
        await module.commitPinchSession(at: ToneLevel.frio.rawValue)
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(session.isPreviewing)
        XCTAssertEqual(view.string, "Hola equipo. \(StubToneProvider().results[0]) Gracias.")
        XCTAssertTrue(module.lengthToastCanUndo)
        session.send(.undo)
        XCTAssertEqual(view.string, text)
    }

    @MainActor func testPinchOnSentenceShiftsToneAndReleaseCommits() async throws {
        let text = Self.toneText
        let (module, session, view, window, bus) = makeHarness(text: text, toneProvider: StubToneProvider())
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        let previousUnit = module.navigationUnit
        module.navigationUnit = .oracion
        defer { module.navigationUnit = previousUnit }
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        module.running = true
        var hand = oneHand()
        hand.x = 0.5
        hand.pinch = true
        hand.event = .changed
        // La pinza sostenida abre la sesión en el nivel original.
        for frame in 0...GestureTuning.pinchStartFrames {
            await module.handleVision(hand, at: Double(frame) * 0.05)
        }
        await pump()
        XCTAssertTrue(module.isToneSession, "mensaje: \(module.message)")
        XCTAssertEqual(module.sessionIndex, ToneLevel.original.rawValue)
        XCTAssertEqual(view.string, text)
        // Mover a la derecha templa: el documento previsualiza la versión cálida.
        hand.x = 0.5 + GestureTuning.toneStep + 0.01
        await module.handleVision(hand, at: 0.5)
        await pump()
        XCTAssertEqual(module.sessionIndex, ToneLevel.calido.rawValue)
        let warm = "Hola equipo. \(StubToneProvider().results[1]) Gracias."
        XCTAssertEqual(view.string, warm)
        XCTAssertTrue(session.isPreviewing)
        // Soltar confirma con un solo undo.
        hand.pinch = false
        hand.event = .none
        for frame in 0..<3 {
            await module.handleVision(hand, at: 0.6 + Double(frame) * 0.05)
        }
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(session.isPreviewing)
        XCTAssertEqual(view.string, warm)
        session.send(.undo)
        XCTAssertEqual(view.string, text)
    }

    @MainActor func testFailedToneGenerationKeepsSentence() async throws {
        let text = Self.toneText
        let (module, session, view, window, bus) = makeHarness(text: text, toneProvider: StubToneProvider(results: []))
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(session.isPreviewing)
        XCTAssertEqual(view.string, text)
        XCTAssertFalse(module.lengthToastCanUndo)
    }

    @MainActor func testToneNeedsProseSentence() async {
        let module = GestureModule(toneProvider: StubToneProvider())
        module.updateDocument(text: "Hola equipo. Gracias.", selection: NSRange(location: 2, length: 0))
        await module.startToneSessionManually()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertTrue(module.message.contains("tono"), module.message)
    }

    @MainActor func testPausingCancelsPreviewAndIgnoresHand() async throws {
        let text = "mundo importante"
        let (module, session, view, window, bus) = makeHarness(text: text)
        defer { session.stop(); window.orderOut(nil) }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        await pump()
        module.updateDocument(text: text, selection: NSRange(location: 1, length: 0))
        module.running = true
        await module.startPinchSessionManually()
        await pump()
        XCTAssertTrue(session.isPreviewing)
        await module.setGesturesPaused(true)
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(session.isPreviewing)
        let selection = view.selectedRange()
        var hand = oneHand()
        hand.x = 0.9
        await module.handleVision(hand, at: 0)
        await pump()
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.string, text)
    }
}

private struct StubLengthProvider: LengthProvider {
    let results: [String]
    init(results: [String] = [
        "Primera oración completa.",
        "Primera oración completa. La segunda oración desarrolla la idea con una metodología clara e importante."
    ]) { self.results = results }
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func variants(for paragraph: String) async throws -> VariantPair {
        results.count == 2 ? VariantPair(results[0], results[1]) : VariantPair(nil, nil)
    }
}

private struct StubToneProvider: ToneProvider {
    let results: [String]
    init(results: [String] = [
        "Se requiere el informe mañana.",
        "Me ayudaría mucho tener el informe mañana, por favor."
    ]) { self.results = results }
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func variants(for sentence: String) async throws -> VariantPair {
        results.count == 2 ? VariantPair(results[0], results[1]) : VariantPair(nil, nil)
    }
}

/// Doble sin modelo: devuelve lista fija sin Apple Intelligence.
struct StubSynonymProvider: SynonymProvider {
    let fresh: [String]
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func synonyms(for word: String) async throws -> [String] { fresh }
}

final class SynonymUpgradeTests: XCTestCase {
    @MainActor
    private func pump(times: Int = 50) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }

    @MainActor func testUpgradeMergesFreshSynonyms() async {
        let module = GestureModule(synonymProvider: StubSynonymProvider(fresh: ["trascendental", "clave"]))
        module.updateDocument(text: "dato importante", selection: NSRange(location: 7, length: 0))
        await module.startPinchSessionManually()
        await pump()
        XCTAssertTrue(module.hasPinchSession)
        XCTAssertTrue(module.sessionUpgraded)
        // La palabra sigue primera; los frescos entran después.
        XCTAssertEqual(module.sessionOptions.first, "importante")
        XCTAssertTrue(module.sessionOptions.contains("trascendental"))
        XCTAssertTrue(module.sessionOptions.contains("clave"))
    }

    @MainActor func testEmptyUpgradeKeepsLocal() async {
        let module = GestureModule(synonymProvider: StubSynonymProvider(fresh: []))
        module.updateDocument(text: "dato importante", selection: NSRange(location: 7, length: 0))
        await module.startPinchSessionManually()
        await pump()
        XCTAssertTrue(module.hasPinchSession)
        XCTAssertFalse(module.sessionUpgraded)
        XCTAssertEqual(module.sessionOptions.first, "importante")
    }

    @MainActor func testStaleUpgradeDiscarded() async {
        let module = GestureModule(synonymProvider: StubSynonymProvider(fresh: ["trascendental"]))
        module.updateDocument(text: "dato importante", selection: NSRange(location: 7, length: 0))
        await module.startPinchSessionManually()
        // Cierra antes de que llegue la mejora: no debe reabrir ni aplicar nada.
        module.cancelPinchSession()
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertFalse(module.sessionUpgraded)
    }

    @MainActor func testSingleOptionOpensWhenIAAvailable() async {
        // Sin locales pero con IA: la sesión abre con la palabra y mejora al llegar.
        let module = GestureModule(synonymProvider: StubSynonymProvider(fresh: ["extraño", "raro"]))
        module.updateDocument(text: "hola zxq", selection: NSRange(location: 6, length: 0))
        await module.startPinchSessionManually()
        XCTAssertTrue(module.hasPinchSession)
        XCTAssertEqual(module.sessionOptions, ["zxq"])
        await pump()
        XCTAssertTrue(module.sessionUpgraded)
        XCTAssertEqual(module.sessionOptions.first, "zxq")
        XCTAssertTrue(module.sessionOptions.contains("extraño"))
    }

    @MainActor func testSingleOptionClosesWhenIAFails() async {
        // Sin locales y la IA sin respuesta: se cierra con mensaje, sin tarjeta vacía.
        let module = GestureModule(synonymProvider: StubSynonymProvider(fresh: []))
        module.updateDocument(text: "hola zxq", selection: NSRange(location: 6, length: 0))
        await module.startPinchSessionManually()
        XCTAssertTrue(module.hasPinchSession)
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertTrue(module.message.contains("zxq"))
    }
}

// MARK: - Markdown protegido, causas de fallo y versiones parciales

/// Cuenta llamadas y devuelve un par fijo o lanza una causa.
private final class ScriptedLengthProvider: LengthProvider, @unchecked Sendable {
    let outcome: Result<VariantPair, ModelFailure>
    private(set) var calls = 0
    init(_ outcome: Result<VariantPair, ModelFailure>) { self.outcome = outcome }
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func variants(for paragraph: String) async throws -> VariantPair {
        calls += 1
        return try outcome.get()
    }
}

private final class ScriptedToneProvider: ToneProvider, @unchecked Sendable {
    let outcome: Result<VariantPair, ModelFailure>
    private(set) var calls = 0
    init(_ outcome: Result<VariantPair, ModelFailure>) { self.outcome = outcome }
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func variants(for sentence: String) async throws -> VariantPair {
        calls += 1
        return try outcome.get()
    }
}

private struct FailingSynonymProvider: SynonymProvider {
    let failure: ModelFailure
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func synonyms(for word: String) async throws -> [String] { throw failure }
}

extension GestureIntegrationTests {
    private static let lengthParagraph = "Primera oración completa. Segunda oración con desarrollo importante y metodología clara."
    private static let validShort = "Primera oración completa."
    private static let validLong = "Primera oración completa. La segunda oración desarrolla la idea con una metodología clara e importante."

    @MainActor private func connected(_ module: GestureModule, _ session: EditorSession, _ bus: EditorCommandBus) async throws -> Task<Void, Never> {
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        await pump()
        return consumer
    }

    // MARK: Markdown

    func testLengthTargetAcceptsOnlyProse() {
        func target(_ text: String, at needle: String) -> LengthTarget {
            GestureModule.lengthTarget(in: text, at: (text as NSString).range(of: needle).location)
        }
        let fenced = "Intro de prosa.\n\n```\nlet total = suma de varias cosas aquí\n```\n"
        guard case .refused(let code) = target(fenced, at: "total") else { return XCTFail("interior de bloque de código") }
        XCTAssertTrue(code.contains("código"))
        let indented = "Intro de prosa.\n\n    codigo con sangría y varias palabras\n"
        guard case .refused = target(indented, at: "sangría") else { return XCTFail("código con sangría") }
        let table = "| Tema | Nota |\n| --- | --- |\n| uno dos tres | cuatro |\n"
        guard case .refused(let row) = target(table, at: "dos") else { return XCTFail("fila de tabla") }
        XCTAssertTrue(row.contains("tabla"))
        let link = "Lee [la guía](https://ejemplo.com) antes de empezar el trabajo."
        guard case .refused(let links) = target(link, at: "antes") else { return XCTFail("enlace") }
        XCTAssertTrue(links.contains("enlaces"))
        guard case .refused = target("# Un título largo del documento", at: "título") else { return XCTFail("título") }

        let prose = "Antes.\n\(Self.lengthParagraph)\nDespués."
        XCTAssertEqual(target(prose, at: "desarrollo"), .prose((prose as NSString).range(of: Self.lengthParagraph)))
        let item = "- \(Self.lengthParagraph)"
        XCTAssertEqual(target(item, at: "desarrollo"), .prose(NSRange(location: 2, length: (Self.lengthParagraph as NSString).length)),
                       "en una lista solo cambia el texto, la viñeta se conserva")
    }

    @MainActor func testManualLengthRefusesCodeWithoutCallingModel() async throws {
        let text = "Intro de prosa.\n\n```\nlet total = suma de varias cosas aquí\n```\n"
        let provider = ScriptedLengthProvider(.success(VariantPair(Self.validShort, Self.validLong)))
        let module = GestureModule(lengthProvider: provider)
        module.updateDocument(text: text, selection: NSRange(location: (text as NSString).range(of: "total").location, length: 0))
        await module.startLengthSessionManually()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertTrue(module.message.contains("código"), module.message)
        XCTAssertNotNil(module.lengthToast)
        XCTAssertEqual(provider.calls, 0)
    }

    @MainActor func testTwoHandLengthRefusesTableRow() async throws {
        let text = "| Tema | Nota |\n| --- | --- |\n| uno dos tres | cuatro |\n"
        let provider = ScriptedLengthProvider(.success(VariantPair(Self.validShort, Self.validLong)))
        let (module, session, view, window, bus) = makeHarness(text: text, lengthProvider: provider)
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: (text as NSString).range(of: "dos").location, length: 0))
        await module.handleLengthVision(twoHands(span: 0.40), at: 0.0)
        await module.handleLengthVision(twoHands(span: 0.41), at: 0.05)
        await module.handleLengthVision(twoHands(span: 0.42), at: 0.10)
        await pump()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertTrue(module.message.contains("tabla"), module.message)
        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(view.string, text)
    }

    @MainActor func testLengthOnListItemKeepsBullet() async throws {
        let text = "- \(Self.lengthParagraph)"
        let (module, session, view, window, bus) = makeHarness(text: text, lengthProvider: StubLengthProvider())
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 10, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertEqual(module.lengthOriginalText, Self.lengthParagraph)
        await module.commitLengthSession(at: LengthLevel.corto.rawValue)
        await pump()
        XCTAssertEqual(view.string, "- \(Self.validShort)")
        session.send(.undo)
        XCTAssertEqual(view.string, text)
    }

    // MARK: Causas

    @MainActor func testLengthFailureCauseReachesToast() async throws {
        let text = Self.lengthParagraph
        let (module, session, view, window, bus) = makeHarness(text: text, lengthProvider: ScriptedLengthProvider(.failure(.deadline)))
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertTrue(module.lengthToast?.contains("tardó demasiado") == true, module.lengthToast ?? "")
        XCTAssertEqual(view.string, text)
    }

    @MainActor func testToneFailureCauseReachesToast() async throws {
        let text = Self.toneText
        let (module, session, view, window, bus) = makeHarness(
            text: text, toneProvider: ScriptedToneProvider(.failure(.unavailable("Activa Apple Intelligence en Ajustes del Sistema."))))
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        XCTAssertTrue(module.lengthToast?.contains("Activa Apple Intelligence") == true, module.lengthToast ?? "")
        XCTAssertEqual(view.string, text)
    }

    @MainActor func testSynonymFailureKeepsLocalsAndSaysWhy() async {
        let module = GestureModule(synonymProvider: FailingSynonymProvider(failure: .busy))
        module.updateDocument(text: "dato importante", selection: NSRange(location: 7, length: 0))
        await module.startPinchSessionManually()
        await pump()
        XCTAssertTrue(module.hasPinchSession, "los locales siguen disponibles")
        XCTAssertEqual(module.synonymNotice, ModelFailure.busy.message)
        XCTAssertTrue(module.message.contains("ocupada"), module.message)
    }

    // MARK: Versiones parciales

    @MainActor func testShortValidLongInvalidUsesShortOnly() async throws {
        let text = Self.lengthParagraph
        let provider = ScriptedLengthProvider(.success(VariantPair(Self.validShort, "Corto.")))
        let (module, session, view, window, bus) = makeHarness(text: text, lengthProvider: provider)
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertTrue(module.hasLengthSession, module.message)
        XCTAssertFalse(module.lengthLoading)
        XCTAssertNil(module.lengthUnavailableReason(at: LengthLevel.corto.rawValue))
        let reason = try XCTUnwrap(module.lengthUnavailableReason(at: LengthLevel.largo.rawValue))
        XCTAssertEqual(module.lengthOptions, [Self.validShort, text, reason], "el original no se ofrece como versión larga")
        XCTAssertTrue(module.message.contains("largo"), module.message)

        // Ni preview ni confirmación del nivel que falta.
        await module.previewLengthOption(at: LengthLevel.largo.rawValue)
        await module.commitLengthSession(at: LengthLevel.largo.rawValue)
        await pump()
        XCTAssertTrue(module.hasLengthSession)
        XCTAssertEqual(module.lengthIndex, LengthLevel.medio.rawValue)
        XCTAssertEqual(view.string, text)
        XCTAssertFalse(view.undoManager?.canUndo == true)

        await module.commitLengthSession(at: LengthLevel.corto.rawValue)
        await pump()
        XCTAssertEqual(view.string, Self.validShort)
        session.send(.undo)
        XCTAssertEqual(view.string, text, "un solo undo")
        XCTAssertEqual(provider.calls, 1)
    }

    @MainActor func testSpreadingHandsSkipsMissingLongVersion() async throws {
        let text = Self.lengthParagraph
        let (module, session, view, window, bus) = makeHarness(
            text: text, lengthProvider: ScriptedLengthProvider(.success(VariantPair(Self.validShort, nil))))
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 5, length: 0))
        await module.handleLengthVision(twoHands(span: 0.40), at: 0.0)
        await module.handleLengthVision(twoHands(span: 0.41), at: 0.05)
        await module.handleLengthVision(twoHands(span: 0.42), at: 0.10)
        await pump()
        XCTAssertTrue(module.hasLengthSession, module.message)
        await module.handleLengthVision(twoHands(span: 0.75), at: 0.15)
        await pump()
        XCTAssertEqual(module.lengthIndex, LengthLevel.medio.rawValue, "separar no lleva a una versión que no existe")
        XCTAssertEqual(view.string, text)
        // La separación va suavizada: acercar toma varios frames.
        for (frame, span) in [0.30, 0.22, 0.15, 0.10].enumerated() {
            await module.handleLengthVision(twoHands(span: span), at: 0.20 + Double(frame) * 0.05)
        }
        await pump()
        XCTAssertEqual(module.lengthIndex, LengthLevel.corto.rawValue)
        XCTAssertEqual(view.string, Self.validShort)
    }

    @MainActor func testNoValidLengthVersionClosesWithReason() async throws {
        let text = Self.lengthParagraph
        let (module, session, view, window, bus) = makeHarness(
            text: text, lengthProvider: ScriptedLengthProvider(.success(VariantPair("Corto.", text))))
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertTrue(module.lengthToast?.contains("no sirve") == true, module.lengthToast ?? "")
        XCTAssertEqual(view.string, text)
        XCTAssertFalse(session.isPreviewing)
    }

    @MainActor func testPartialLengthCacheIsReused() async throws {
        let text = Self.lengthParagraph
        let provider = ScriptedLengthProvider(.success(VariantPair(nil, Self.validLong)))
        let module = GestureModule(lengthProvider: provider)
        module.updateDocument(text: text, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertNotNil(module.lengthUnavailableReason(at: LengthLevel.corto.rawValue))
        module.cancelLengthSession()
        await module.startLengthSessionManually()
        XCTAssertFalse(module.lengthLoading, "reusa sin esperar")
        XCTAssertNotNil(module.lengthUnavailableReason(at: LengthLevel.corto.rawValue))
        XCTAssertEqual(module.lengthOptions[2], Self.validLong)
        XCTAssertEqual(provider.calls, 1, "sin llamada extra al modelo")
    }

    @MainActor func testColdInvalidWarmValidUsesWarmOnly() async throws {
        let text = Self.toneText
        let warm = "Me ayudaría mucho tener el informe mañana, por favor."
        let provider = ScriptedToneProvider(.success(VariantPair("Ok", warm)))
        let (module, session, view, window, bus) = makeHarness(text: text, toneProvider: provider)
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        await pump()
        XCTAssertTrue(module.isToneSession, module.message)
        let reason = try XCTUnwrap(module.toneUnavailableReason(at: ToneLevel.frio.rawValue))
        XCTAssertEqual(module.toneOptions, [reason, Self.toneSentence, warm])
        await module.commitPinchSession(at: ToneLevel.frio.rawValue)
        await pump()
        XCTAssertTrue(module.isToneSession, "el tono frío no existe: no se confirma")
        XCTAssertEqual(view.string, text)
        await module.commitPinchSession(at: ToneLevel.calido.rawValue)
        await pump()
        XCTAssertEqual(view.string, "Hola equipo. \(warm) Gracias.")
        session.send(.undo)
        XCTAssertEqual(view.string, text)

        // Reabrir la oración reusa el tono parcial sin volver al modelo.
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        XCTAssertFalse(module.toneLoading)
        XCTAssertNotNil(module.toneUnavailableReason(at: ToneLevel.frio.rawValue))
        XCTAssertEqual(provider.calls, 1)
    }

    @MainActor func testPinchMovesOnlyToAvailableTone() async throws {
        let text = Self.toneText
        let cold = "Se requiere el informe mañana."
        let (module, session, view, window, bus) = makeHarness(
            text: text, toneProvider: ScriptedToneProvider(.success(VariantPair(cold, nil))))
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        let previousUnit = module.navigationUnit
        module.navigationUnit = .oracion
        defer { module.navigationUnit = previousUnit }
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        module.running = true
        var hand = oneHand()
        hand.x = 0.5
        hand.pinch = true
        hand.event = .changed
        for frame in 0...GestureTuning.pinchStartFrames {
            await module.handleVision(hand, at: Double(frame) * 0.05)
        }
        await pump()
        XCTAssertTrue(module.isToneSession, module.message)
        hand.x = 0.5 + GestureTuning.toneStep + 0.01
        await module.handleVision(hand, at: 0.5)
        await pump()
        XCTAssertEqual(module.sessionIndex, ToneLevel.original.rawValue, "no hay tono cálido")
        XCTAssertEqual(view.string, text)
        hand.x = 0.5 - GestureTuning.toneStep - 0.01
        await module.handleVision(hand, at: 0.55)
        await pump()
        XCTAssertEqual(module.sessionIndex, ToneLevel.frio.rawValue)
        XCTAssertEqual(view.string, "Hola equipo. \(cold) Gracias.")
    }

    @MainActor func testNoValidToneClosesWithReason() async throws {
        let text = Self.toneText
        let same = "Se requiere el informe mañana."
        let (module, session, view, window, bus) = makeHarness(
            text: text, toneProvider: ScriptedToneProvider(.success(VariantPair(same, same))))
        defer { session.stop(); window.orderOut(nil) }
        let consumer = try await connected(module, session, bus)
        defer { consumer.cancel() }
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        await pump()
        XCTAssertFalse(module.hasPinchSession, "dos tonos iguales no dicen cuál es cuál")
        XCTAssertTrue(module.lengthToast?.contains("no sirve") == true, module.lengthToast ?? "")
        XCTAssertEqual(view.string, text)
    }
}
