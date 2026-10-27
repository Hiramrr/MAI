import XCTest
import AppKit
import CommandGrammar
import FoundationModels
@testable import EditorCore
@testable import EditorEngine
@testable import EditorUI
@testable import ModuleKit
@testable import VoiceModule

/// Doble sin micrófono: devuelve texto fijo en `stop()`.
final class MockSpeechRecognizer: VoiceSpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _started = false
    var nextTranscript = ""
    var didStart: Bool { lock.withLock { _started } }

    var onPartial: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    // Sin voz real si el texto es vacío o solo espacios (como el VAD de energía).
    var hasSpeech: Bool { !nextTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var voiceThreshold: Float { 0.08 }
    var liveTranscript: String { nextTranscript }

    func start() async throws {
        lock.withLock { _started = true }
    }

    func stop() async throws -> String { nextTranscript }
    func cancel() async { lock.withLock { _started = false } }
}

private final class DelayedSpeechRecognizer: VoiceSpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var stoppedBeforeStart = false
    var onStart: (@Sendable () -> Void)?
    var onPartial: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var hasSpeech: Bool { true }
    var voiceThreshold: Float { 0.08 }
    var liveTranscript: String { "hola" }
    var didStopBeforeStart: Bool { lock.withLock { stoppedBeforeStart } }

    func start() async throws {
        await withCheckedContinuation { continuation in
            lock.withLock { startContinuation = continuation }
            onStart?()
        }
        lock.withLock { started = true }
    }

    func completeStart() {
        lock.withLock {
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func stop() async throws -> String {
        lock.withLock { stoppedBeforeStart = !started }
        return "hola"
    }

    func cancel() async {}
}

final class VoiceCommandParserTests: XCTestCase {
    func testCommands() {
        let parser = VoiceCommandParser()
        XCTAssertEqual(parser.parse("cancelar"), .cancel)
        XCTAssertEqual(parser.parse("Borra eso."), .deleteLastInsertion)
        XCTAssertEqual(parser.parse("deshacer"), .undo)
        XCTAssertEqual(parser.parse("corrige eso"), .undo)
        XCTAssertEqual(parser.parse("nueva línea"), .newline)
        XCTAssertEqual(parser.parse("nuevo párrafo"), .paragraph)
    }

    func testDictationIsNotACommand() {
        let parser = VoiceCommandParser()
        XCTAssertNil(parser.parse("hola mundo"))
        // Comando mezclado en frase larga: no dispara.
        XCTAssertNil(parser.parse("quiero decir que borra eso por favor y sigue escribiendo mucho más"))
        XCTAssertNil(parser.parse(""))
    }

    @MainActor func testRenameTitleViaGrammar() {
        // El rename ahora lo resuelve la gramática probada (fuente única),
        // no el parser legacy: mismo resultado, bestemado en 447 tests.
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertEqual(module.process(rawTranscript: "Cambia el título a prueba."), .command(.renameTitle("prueba")))
        XCTAssertEqual(module.process(rawTranscript: "Cambia el titulo a Metodología"), .command(.renameTitle("Metodología")))
        XCTAssertEqual(module.process(rawTranscript: "Pon como título IHC 2026."), .command(.renameTitle("IHC 2026")))
        XCTAssertEqual(module.process(rawTranscript: "Ponle de título TDAH"), .command(.renameTitle("TDAH")))
        XCTAssertEqual(module.process(rawTranscript: "Titula Informe final"), .command(.renameTitle("Informe final")))
        XCTAssertEqual(module.process(rawTranscript: "Renombra a Borrador 2"), .command(.renameTitle("Borrador 2")))
        // El argumento va verbatim: si el STT confunde ("de usabilidad" por
        // ", sensibilidad"), el título refleja el transcript tal cual.
        XCTAssertEqual(
            module.process(rawTranscript: "Cambia el titulo a prueba, sensibilidad."),
            .command(.renameTitle("prueba, sensibilidad"))
        )
    }

    func testRenameTitleGuards() {
        let parser = VoiceCommandParser()
        // Sin argumento, vacío efectivo o frase larga: no es comando (dictado).
        XCTAssertNil(parser.parse("Cambia el título a."))
        XCTAssertNil(parser.parse("Cambia el título a "))
        XCTAssertNil(parser.parse("Titula"))
        XCTAssertNil(parser.parse("quiero que cambies el título a otro porque este no me gusta nada"))
        XCTAssertNil(parser.parse("hola mundo"))
    }

    @MainActor func testFullGrammarCommands() {
        // La gramática probada (fuente única) resuelve los 12 comandos.
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertEqual(module.process(rawTranscript: "Cambia el título a prueba."), .command(.renameTitle("prueba")))
        XCTAssertEqual(module.process(rawTranscript: "Busca TDAH."), .command(.findText("TDAH")))
        XCTAssertEqual(module.process(rawTranscript: "Selecciona IHC."), .command(.selectText("IHC")))
        XCTAssertEqual(module.process(rawTranscript: "Ponlo en negritas."), .command(.formatSelection(.bold)))
        XCTAssertEqual(module.process(rawTranscript: "Borra la selección."), .command(.deleteSelection))
        XCTAssertEqual(module.process(rawTranscript: "Sustituye esto por diseño."), .command(.replaceSelection("diseño")))
        XCTAssertEqual(module.process(rawTranscript: "Deshaz el cambio."), .command(.undo))
        XCTAssertEqual(module.process(rawTranscript: "Rehaz el cambio."), .command(.redo))
        XCTAssertEqual(module.process(rawTranscript: "Guarda el documento."), .command(.saveDocument))
        XCTAssertEqual(module.process(rawTranscript: "Exporta a pdf."), .command(.exportDocument(.pdf)))
        XCTAssertEqual(module.process(rawTranscript: "Hazlo más breve."), .command(.rewriteSelection("más breve")))
    }

    @MainActor func testTitleDeAdaptation() {
        // El STT confunde a/de: segundo intento con "a", sin tocar Grammar.
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertEqual(module.process(rawTranscript: "Cambia el título de prueba."), .command(.renameTitle("prueba")))
        XCTAssertEqual(VoiceModule.adaptTitleDe("Cambia el título de prueba."), "Cambia el título a prueba.")
        XCTAssertNil(VoiceModule.adaptTitleDe("Cambia el título a prueba."))
        XCTAssertNil(VoiceModule.adaptTitleDe("hola mundo"))
    }

    @MainActor func testLegacyWinsAndFallbackIsDictation() {
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        // "Borra eso" sigue siendo undo (legacy), no deleteSelection.
        XCTAssertEqual(module.process(rawTranscript: "borra eso"), .deleteLastInsertion)
        // Lo no accionable (unsupported/unknown/múltiple) cae a dictado.
        if case .dictation = module.process(rawTranscript: "Imprime el documento.") { } else {
            XCTFail("unsupported debe caer a dictado")
        }
        if case .dictation = module.process(rawTranscript: "klmn xyz wq") { } else {
            XCTFail("unknown debe caer a dictado")
        }
        if case .dictation = module.process(rawTranscript: "hola coma mundo") { } else {
            XCTFail("dictado normal intacto")
        }
    }

    @MainActor func testCommandMapping() {
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertEqual(module.editorCommands(for: .renameTitle("X")), [.renameTitle("X")])
        XCTAssertEqual(module.editorCommands(for: .deleteSelection), [.replaceSelection("")])
        XCTAssertEqual(module.editorCommands(for: .replaceSelection("diseño")), [.replaceSelection("diseño")])
        XCTAssertEqual(module.editorCommands(for: .formatSelection(.bold)), [.toggleBold])
        XCTAssertEqual(module.editorCommands(for: .formatSelection(.italic)), [.toggleItalic])
        XCTAssertEqual(module.editorCommands(for: .formatSelection(.underline)), [.toggleUnderline])
        XCTAssertEqual(module.editorCommands(for: VoiceIntent.undo), [.undo])
        XCTAssertEqual(module.editorCommands(for: .redo), [.redo])
        XCTAssertEqual(module.editorCommands(for: .findText("a")), [.findText("a")])
        XCTAssertEqual(module.editorCommands(for: .selectText("b")), [.selectText("b")])
        XCTAssertEqual(module.editorCommands(for: .saveDocument), [.saveDocument])
        XCTAssertEqual(module.editorCommands(for: .openDocument("x")), [.openDocument("x")])
        XCTAssertEqual(module.editorCommands(for: .exportDocument(.pdf)), [.exportDocument("pdf")])
        XCTAssertEqual(module.editorCommands(for: .exportDocument(.plainText)), [.exportDocument("txt")])
        XCTAssertEqual(module.editorCommands(for: .exportDocument(.richText)), [.exportDocument("rtf")])
        // Rewrite y word emiten comandos reales (IA on-device y .docx).
        XCTAssertEqual(module.editorCommands(for: .rewriteSelection("x")), [.rewriteSelection("x")])
        XCTAssertEqual(module.editorCommands(for: .rewriteSelection("  ")), [])
        XCTAssertEqual(module.editorCommands(for: .exportDocument(.word)), [.exportDocument("word")])
        XCTAssertEqual(module.editorCommands(for: .unsupported("z")), [])
        XCTAssertEqual(module.editorCommands(for: .unknown), [])
        XCTAssertEqual(module.editorCommands(for: .multipleActions), [])
    }

    @MainActor func testCommandFeedback() {
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertFalse(module.feedback(for: .saveDocument).isEmpty)
        XCTAssertFalse(module.feedback(for: .renameTitle("X")).isEmpty)
        XCTAssertTrue(module.feedback(for: .exportDocument(.word)).contains("Word"))
        XCTAssertTrue(module.feedback(for: .rewriteSelection("x")).contains("Reescrib"))
    }

    func testEndpointReached() {
        XCTAssertTrue(VoiceModule.endpointReached(partial: "hola", unchangedFor: 2.0, quietFor: 2.0, timeout: 1.6))
        XCTAssertFalse(VoiceModule.endpointReached(partial: "hola", unchangedFor: 0.5, quietFor: 2.0, timeout: 1.6))
        // Parcial quieto pero todavía hay voz: Speech va atrasado, no se corta.
        XCTAssertFalse(VoiceModule.endpointReached(partial: "hola", unchangedFor: 9.0, quietFor: 0.2, timeout: 1.6))
        XCTAssertFalse(VoiceModule.endpointReached(partial: "   ", unchangedFor: 9.0, quietFor: 9.0, timeout: 1.6))
        XCTAssertFalse(VoiceModule.endpointReached(partial: "", unchangedFor: 9.0, quietFor: 9.0, timeout: 1.6))
    }

    func testPushToTalkHotkeyDetection() {
        func keyEvent(type: NSEvent.EventType, flags: NSEvent.ModifierFlags, keyCode: UInt16, repeat repeatFlag: Bool = false) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatFlag, keyCode: keyCode)
        }
        XCTAssertNotNil(keyEvent(type: .keyDown, flags: .option, keyCode: 49))
        if let down = keyEvent(type: .keyDown, flags: .option, keyCode: 49) {
            XCTAssertTrue(VoicePushToTalk.isHotkeyDown(down))
        }
        // Con comando o control ya no es el hotkey de voz.
        if let cmd = keyEvent(type: .keyDown, flags: [.option, .command], keyCode: 49) {
            XCTAssertFalse(VoicePushToTalk.isHotkeyDown(cmd))
        }
        if let ctrl = keyEvent(type: .keyDown, flags: [.option, .control], keyCode: 49) {
            XCTAssertFalse(VoicePushToTalk.isHotkeyDown(ctrl))
        }
        // Otra tecla con opción no dispara.
        if let other = keyEvent(type: .keyDown, flags: .option, keyCode: 8) {
            XCTAssertFalse(VoicePushToTalk.isHotkeyDown(other))
        }
        // KeyUp nunca es "down".
        if let up = keyEvent(type: .keyUp, flags: .option, keyCode: 49) {
            XCTAssertFalse(VoicePushToTalk.isHotkeyDown(up))
        }
    }
}

final class VoicePushToTalkTests: XCTestCase {
    @MainActor func testReleaseWaitsForMicrophoneStartup() async throws {
        let recognizer = DelayedSpeechRecognizer()
        let started = expectation(description: "El micrófono empezó a prepararse")
        recognizer.onStart = { started.fulfill() }
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        module.pushToTalkEnabled = true
        let press = Task { await module.beginPushToTalk() }
        await fulfillment(of: [started], timeout: 2)
        let release = Task { await module.endPushToTalk() }
        await Task.yield()
        XCTAssertFalse(recognizer.didStopBeforeStart)
        recognizer.completeStart()
        await press.value
        await release.value
        XCTAssertFalse(recognizer.didStopBeforeStart)
        XCTAssertEqual(module.pendingDictationText, "Hola.")
    }

    @MainActor func testPushToTalkDictationFlow() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "hola coma mundo"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.pushToTalkEnabled = true
        try await module.start(context: EditorModuleContext(commandBus: bus))
        XCTAssertTrue(module.canBeginPushToTalk)
        let stream = await bus.commands()
        await module.beginPushToTalk()
        XCTAssertTrue(module.pushToTalkHeld)
        XCTAssertTrue(module.isListening)
        // Segunda pulsación mientras se mantiene: no hace nada.
        XCTAssertFalse(module.canBeginPushToTalk)
        await module.endPushToTalk()
        XCTAssertFalse(module.pushToTalkHeld)
        XCTAssertFalse(module.isListening)
        XCTAssertEqual(module.pendingAction?.preview, "Insertar: \"Hola, mundo.\"")
        await module.confirmPending()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.insertText("Hola, mundo.")])
    }

    @MainActor func testPushToTalkKeepsCommandMode() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Guarda el documento"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.pushToTalkEnabled = true
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.beginPushToTalk()
        await module.endPushToTalk()
        // El comando pasa por propuesta (igual que por toques), no se inserta texto.
        XCTAssertEqual(module.pendingAction?.intent, .command(.saveDocument))
        await module.confirmPending()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.saveDocument])
    }

    @MainActor func testPendingCommandAcceptsOneVoiceAnswerWithoutHandsFree() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.continuousListening = false
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()

        mock.nextTranscript = "Guarda el documento"
        await module.begin()
        await module.finish()
        XCTAssertEqual(module.pendingAction?.intent, .command(.saveDocument))

        await module.listenForPendingDecision()
        XCTAssertTrue(module.isListening)
        mock.nextTranscript = "confirmar"
        await module.autoFinish()
        XCTAssertNil(module.pendingAction)
        XCTAssertFalse(module.isListening)

        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.saveDocument])
    }

    @MainActor func testPushToTalkImmediateCommand() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Busca TDAH"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.pushToTalkEnabled = true
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.beginPushToTalk()
        await module.endPushToTalk()
        XCTAssertNil(module.pendingAction)
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.findText("TDAH")])
    }

    @MainActor func testPushToTalkBlockedWhilePending() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "hola"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.pushToTalkEnabled = true
        try await module.start(context: EditorModuleContext(commandBus: bus))
        await module.beginPushToTalk()
        await module.endPushToTalk()
        XCTAssertNotNil(module.pendingAction)
        XCTAssertFalse(module.canBeginPushToTalk)
        await module.beginPushToTalk()
        XCTAssertFalse(module.pushToTalkHeld, "con propuesta pendiente no se rearma")
        XCTAssertFalse(module.isListening)
        module.cancelPending()
        await bus.finish()
    }

    @MainActor func testPushToTalkDisabledNeverStarts() async throws {
        let bus = EditorCommandBus()
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        module.pushToTalkEnabled = false
        try await module.start(context: EditorModuleContext(commandBus: bus))
        XCTAssertFalse(module.canBeginPushToTalk)
        await module.beginPushToTalk()
        XCTAssertFalse(module.pushToTalkHeld)
        XCTAssertFalse(module.isListening)
        module.pushToTalkEnabled = true
        await bus.finish()
    }
}

final class DictationCleanerTests: XCTestCase {
    func testFillersAndPunctuation() {
        let cleaner = DictationCleaner()
        // "eh" fuera, "coma" a signo, formal con punto final.
        XCTAssertEqual(cleaner.clean("eh hola coma mundo"), "Hola, mundo.")
    }

    func testLocutionsArePreserved() {
        let cleaner = DictationCleaner()
        XCTAssertEqual(cleaner.clean("punto de encuentro", formal: false), "punto de encuentro")
    }

    func testSpokenLineBreaks() {
        let cleaner = DictationCleaner()
        XCTAssertEqual(cleaner.clean("primera frase nueva línea segunda frase"), "Primera frase.\nSegunda frase.")
        XCTAssertEqual(cleaner.clean("hola punto y aparte adiós"), "Hola.\n\nAdiós.")
        XCTAssertEqual(cleaner.clean("hola mundo nuevo párrafo"), "Hola mundo.\n\n")
        XCTAssertEqual(cleaner.clean("hola nueva línea adiós", formal: false), "hola\nadiós")
        // Dentro de una locución sigue siendo texto.
        XCTAssertEqual(cleaner.clean("una nueva línea de productos", formal: false), "una nueva línea de productos")
    }

    func testOpeningPunctuationAndCapitals() {
        let cleaner = DictationCleaner()
        XCTAssertEqual(cleaner.clean("abre interrogación cómo estás cierra interrogación"), "¿Cómo estás?")
        XCTAssertEqual(cleaner.clean("listo. seguimos mañana"), "Listo. Seguimos mañana.")
        // Un punto sin espacio detrás no es fin de oración.
        XCTAssertEqual(cleaner.clean("visita ejemplo.com hoy"), "Visita ejemplo.com hoy.")
    }

    func testCustomCorrectionsWin() {
        let cleaner = DictationCleaner()
        let out = cleaner.clean("miyu wisp es bueno", formal: false, customCorrections: [(from: "miyu wisp", to: "MiyuWisp")])
        XCTAssertEqual(out, "MiyuWisp es bueno")
    }
}

final class VoiceBusRegistryTests: XCTestCase {
    func testBusDeliversCommand() async {
        let bus = EditorCommandBus()
        let stream = await bus.commands()
        await bus.send(.insertText("hola"))
        var received: EditorCommand?
        for await command in stream {
            received = command
            break
        }
        XCTAssertEqual(received, .insertText("hola"))
        await bus.finish()
    }

    @MainActor func testRegistry() {
        let registry = ModuleRegistry()
        XCTAssertFalse(registry.isRegistered(identifier: "voice.dictation"))
        registry.register(VoiceModule.descriptor)
        XCTAssertTrue(registry.isRegistered(identifier: "voice.dictation"))
        registry.unregister(identifier: "voice.dictation")
        XCTAssertFalse(registry.isRegistered(identifier: "voice.dictation"))
    }
}

final class VoiceModuleTests: XCTestCase {
    @MainActor func testHandsFreeDictationAfterConfirmingCommandInHUD() async throws {
        let (window, view, session) = voiceTestSession(text: "base ")
        defer { session.stop(); window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        for _ in 0..<50 { await Task.yield() }

        await module.toggle()
        mock.nextTranscript = "guarda el documento"
        await module.autoFinish()
        XCTAssertNotNil(module.pendingAction)
        XCTAssertTrue(module.isListening)
        await module.confirmPending()
        mock.nextTranscript = "siguiente frase"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base Siguiente frase.")
        XCTAssertEqual(module.lastInsertedText, "Siguiente frase.")

        await module.stop()
        await bus.finish()
    }

    @MainActor func testHandsFreeShowsDictationAndAcceptsNextCommandByVoice() async throws {
        let (window, view, session) = voiceTestSession(text: "base ")
        defer { session.stop(); window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        for _ in 0..<50 { await Task.yield() }

        await module.toggle()
        mock.onPartial?("probando")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base probando")
        XCTAssertTrue(session.isPreviewing)

        mock.nextTranscript = "hola"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base Hola.")
        XCTAssertTrue(session.isPreviewing, "la siguiente frase ya está preparada")
        XCTAssertTrue(module.isListening)

        mock.nextTranscript = "deshacer"
        await module.autoFinish()
        XCTAssertNotNil(module.pendingAction)
        XCTAssertTrue(module.isListening)
        mock.nextTranscript = "confirmar"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base ")
        XCTAssertNil(module.pendingAction)
        XCTAssertTrue(module.isListening)

        mock.onPartial?("provisional")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base provisional")
        mock.nextTranscript = "detener voz"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base ")
        XCTAssertFalse(session.isPreviewing)
        XCTAssertFalse(module.isListening)
        await module.stop()
        await bus.finish()
    }

    @MainActor func testHandsFreeSeparatesSentencesAndInsertsBreaks() async throws {
        let (window, view, session) = voiceTestSession(text: "")
        defer { session.stop(); window.orderOut(nil) }
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        for _ in 0..<50 { await Task.yield() }

        await module.toggle()
        mock.nextTranscript = "hola"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        mock.onPartial?("sigo")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "Hola. sigo", "la preview ya separa las frases")
        mock.nextTranscript = "sigo"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "Hola. Sigo.")

        // Un salto dictado es dictado: no pide confirmación en Manos libres.
        mock.nextTranscript = "nuevo párrafo"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(module.pendingAction)
        XCTAssertEqual(view.string, "Hola. Sigo.\n\n")
        mock.nextTranscript = "otra idea"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "Hola. Sigo.\n\nOtra idea.")

        // «No» sin propuesta es una palabra más del dictado.
        mock.nextTranscript = "no"
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "Hola. Sigo.\n\nOtra idea. No.")

        await module.stop()
        await bus.finish()
    }

    @MainActor func testSpacedDictation() {
        XCTAssertEqual(EditorSession.spacedDictation("Sigo.", after: "Hola.", at: 5), " Sigo.")
        XCTAssertEqual(EditorSession.spacedDictation("Sigo.", after: "Hola. ", at: 6), "Sigo.")
        XCTAssertEqual(EditorSession.spacedDictation("Sigo.", after: "Hola.\n", at: 6), "Sigo.")
        XCTAssertEqual(EditorSession.spacedDictation("Sigo.", after: "", at: 0), "Sigo.")
        XCTAssertEqual(EditorSession.spacedDictation("\n", after: "Hola.", at: 5), "\n")
        XCTAssertEqual(EditorSession.spacedDictation(", claro", after: "Hola", at: 4), ", claro")
        XCTAssertEqual(EditorSession.spacedDictation("cómo", after: "Dime ¿", at: 6), "cómo")
        XCTAssertEqual(EditorSession.spacedDictation("Sigo.", after: "Hola 🧠", at: 7), " Sigo.")
        XCTAssertEqual(EditorSession.spacedDictation("Sigo.", after: "Hola.", at: 99), "Sigo.")
    }

    @MainActor func testShortAnswersDecideOnlyPendingProposals() async throws {
        for (answer, expected) in [("Sí.", [EditorCommand.saveDocument]), ("dale", [.saveDocument]), ("No", []), ("mejor no", [])] {
            let bus = EditorCommandBus()
            let mock = MockSpeechRecognizer()
            let module = VoiceModule(recognizer: mock, preferences: nil)
            module.continuousListening = false
            try await module.start(context: EditorModuleContext(commandBus: bus))
            let stream = await bus.commands()
            mock.nextTranscript = "Guarda el documento"
            await module.begin()
            await module.finish()
            XCTAssertNotNil(module.pendingAction)
            await module.listenForPendingDecision()
            mock.nextTranscript = answer
            await module.autoFinish()
            XCTAssertNil(module.pendingAction, "«\(answer)» debe decidir la propuesta")
            await bus.finish()
            var received: [EditorCommand] = []
            for await command in stream { received.append(command) }
            XCTAssertEqual(received, expected, answer)
        }
    }

    @MainActor func testUnclearAnswerKeepsProposal() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.toggle()
        mock.nextTranscript = "Guarda el documento"
        await module.autoFinish()
        mock.nextTranscript = "bueno no sé"
        await module.autoFinish()
        XCTAssertNotNil(module.pendingAction)
        XCTAssertEqual(module.lastCommandFeedback, VoiceModule.decisionHint)
        await module.stop()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        // Manos libres abre y cierra su preview; nada más llega al editor.
        XCTAssertEqual(received, [.beginVoicePreview, .cancelVoicePreview])
    }

    @MainActor func testHelpPhraseOpensExamplesWithoutEditing() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "¿Qué puedo decir?"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertEqual(module.helpRequests, 1)
        XCTAssertNil(module.pendingAction)
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor func testPanelExamplesAreUnderstood() {
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        for group in VoiceControl.examples where group.title != "Dictar" && group.title != "Salir" {
            for phrase in group.phrases {
                let spoken = phrase.replacingOccurrences(of: "…", with: "prueba")
                if case .dictation = module.process(rawTranscript: spoken) {
                    XCTFail("«\(spoken)» se enseña en el panel pero cae a dictado")
                }
            }
        }
        XCTAssertEqual(module.process(rawTranscript: "nueva línea"), .newline)
        XCTAssertEqual(module.process(rawTranscript: "nuevo párrafo"), .paragraph)
        XCTAssertEqual(module.process(rawTranscript: "eh nuevo párrafo"), .paragraph)
    }

    @MainActor func testOptionsAreRemembered() throws {
        let suite = "voice.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: defaults)
        XCTAssertTrue(first.continuousListening)
        XCTAssertTrue(first.formalStyle)
        XCTAssertEqual(first.localeIdentifier, "es-MX")
        first.continuousListening = false
        first.formalStyle = false
        first.pushToTalkEnabled = false
        first.localeIdentifier = "en-US"
        let second = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: defaults)
        XCTAssertFalse(second.continuousListening)
        XCTAssertFalse(second.formalStyle)
        XCTAssertFalse(second.pushToTalkEnabled)
        XCTAssertEqual(second.localeIdentifier, "en-US")
    }

    @MainActor func testIntentMapping() {
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertEqual(module.editorCommands(for: .dictation("Hola.")), [.insertText("Hola.")])
        XCTAssertEqual(module.editorCommands(for: .newline), [.insertText("\n")])
        XCTAssertEqual(module.editorCommands(for: .paragraph), [.insertText("\n\n")])
        XCTAssertEqual(module.editorCommands(for: VoiceIntent.undo), [.undo])
        // "Borra eso" usa el UndoManager del editor: equivale a undo.
        XCTAssertEqual(module.editorCommands(for: .deleteLastInsertion), [.undo])
        XCTAssertEqual(module.editorCommands(for: .cancel), [])
        XCTAssertEqual(module.editorCommands(for: .dictation("")), [])
    }

    @MainActor func testProcessPrefersCommands() {
        let module = VoiceModule(recognizer: MockSpeechRecognizer(), preferences: nil)
        XCTAssertEqual(module.process(rawTranscript: "borra eso"), .deleteLastInsertion)
        if case .dictation(let text) = module.process(rawTranscript: "hola coma mundo") {
            XCTAssertEqual(text, "Hola, mundo.")
        } else {
            XCTFail("Se esperaba dictado limpio")
        }
    }

    @MainActor func testToggleInsertsThroughBus() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "hola coma mundo"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        XCTAssertTrue(mock.didStart)
        await module.finish()
        XCTAssertEqual(module.pendingAction?.transcript, "hola coma mundo")
        XCTAssertEqual(module.pendingAction?.preview, "Insertar: \"Hola, mundo.\"")
        await module.confirmPending()
        var received: EditorCommand?
        for await command in stream {
            received = command
            break
        }
        XCTAssertEqual(received, .insertText("Hola, mundo."))
        await bus.finish()
    }

    @MainActor func testVoiceCommandTravelsAsUndo() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "deshacer"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertNotNil(module.pendingAction)
        await module.confirmPending()
        var received: EditorCommand?
        for await command in stream {
            received = command
            break
        }
        XCTAssertEqual(received, .undo)
        await bus.finish()
    }

    @MainActor func testCorrectedDictationIsInsertedOnce() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "ola mundo"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        module.updatePendingDictation("Hola mundo.")
        XCTAssertEqual(module.pendingAction?.transcript, "ola mundo")
        XCTAssertEqual(module.pendingDictationText, "Hola mundo.")
        module.updatePendingDictation("   ")
        await module.confirmPending()
        XCTAssertNotNil(module.pendingAction)
        module.updatePendingDictation("Hola mundo.")
        await module.confirmPending()
        await module.confirmPending()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.insertText("Hola mundo.")])
    }

    @MainActor func testRenameTitleTravelsAsRenameNotInsert() async throws {
        // Regresión del reporte: "Cambia el título a prueba." insertaba texto.
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Cambia el título a prueba."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertEqual(module.pendingAction?.transcript, "Cambia el título a prueba.")
        XCTAssertEqual(module.lastTranscript, "Cambia el título a prueba.")
        await module.confirmPending()
        await module.confirmPending()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.renameTitle("prueba")])
    }

    @MainActor func testCancelNeverEmits() async throws {
        for spoken in ["Titula bien tus ideas", "Cambia el título a prueba"] {
            let bus = EditorCommandBus()
            let mock = MockSpeechRecognizer()
            mock.nextTranscript = spoken
            let module = VoiceModule(recognizer: mock, preferences: nil)
            try await module.start(context: EditorModuleContext(commandBus: bus))
            let stream = await bus.commands()
            await module.begin()
            await module.finish()
            XCTAssertNotNil(module.pendingAction)
            module.cancelPending()
            await bus.finish()
            var received: [EditorCommand] = []
            for await command in stream { received.append(command) }
            XCTAssertTrue(received.isEmpty, "\(spoken) se envió antes de confirmar")
        }
    }

    @MainActor func testAmbiguousCommandCanBeUsedAsDictation() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Titula bien tus ideas"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertEqual(module.pendingAction?.intent, .command(.renameTitle("bien tus ideas")))
        module.usePendingAsDictation()
        XCTAssertEqual(module.pendingAction?.intent, .dictation("Titula bien tus ideas."))
        await module.confirmPending()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.insertText("Titula bien tus ideas.")])
    }

    @MainActor func testNavigationIsImmediate() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Busca TDAH"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertNil(module.pendingAction)
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.findText("TDAH")])
    }

    @MainActor func testRepeatDropsProposalAndListensAgain() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Guarda el documento"
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertNotNil(module.pendingAction)
        await module.repeatPending()
        XCTAssertNil(module.pendingAction)
        XCTAssertTrue(module.isListening)
        await module.cancelDictation()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor func testOpenByNameRequiresUniqueMatch() {
        let acta = URL(fileURLWithPath: "/tmp/acta vieja.md")
        let other = URL(fileURLWithPath: "/tmp/notas.md")
        XCTAssertEqual(EditorScreen.matchVoiceDocument("el acta vieja", in: [acta, other]), acta)
        XCTAssertNil(EditorScreen.matchVoiceDocument("acta", in: [acta, URL(fileURLWithPath: "/tmp/acta nueva.md")]))
        XCTAssertNil(EditorScreen.matchVoiceDocument("desconocido", in: [acta, other]))
    }

    @MainActor func testSilenceDoesNotInsert() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "   "
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        await module.begin()
        await module.finish()
        if case .failed(let message) = module.state {
            XCTAssertTrue(message.lowercased().contains("silencio"))
        } else {
            XCTFail("Se esperaba estado de silencio, fue \(module.state)")
        }
        await bus.finish()
    }

    @MainActor func testSessionNeverInsertsTitleAsText() {
        // texto, la selección y el historial quedan intactos.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = true
        window.contentView = view
        window.makeFirstResponder(view)
        view.string = "texto intacto"
        view.undoManager?.removeAllActions()
        let session = EditorSession()
        session.textView = view
        session.send(.renameTitle("prueba"))
        XCTAssertEqual(view.string, "texto intacto")
        XCTAssertFalse(view.undoManager?.canUndo ?? true)
        window.orderOut(nil)
    }

    @MainActor func testSessionFindSelect() {
        let (window, view, session) = voiceTestSession(text: "TDAH y accesibilidad con 🧠 y metodología.")
        session.send(.findText("metodologia"))
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "metodología")
        let before = view.string
        session.send(.selectText("🧠"))
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "🧠")
        XCTAssertEqual(view.string, before, "find/select jamás mutan contenido")
        XCTAssertFalse(view.undoManager?.canUndo ?? true, "navegación no toca historial")
        session.send(.findText("zzz-sin-match"))
        XCTAssertEqual(view.string, before)
        window.orderOut(nil)
    }

    @MainActor func testSessionUnderline() {
        let (window, view, session) = voiceTestSession(text: "texto claro aquí")
        voiceTestSelect(view, "claro")
        let before = view.string
        session.send(.toggleUnderline)
        XCTAssertTrue(view.string.contains("<u>claro</u>"))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, before)
        window.orderOut(nil)
    }

    @MainActor func testSessionReplaceDeleteGuards() {
        let (window, view, session) = voiceTestSession(text: "borra esto por favor")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        session.send(.replaceSelection("X"))
        XCTAssertEqual(view.string, "borra esto por favor", "replace sin selección no inserta")
        voiceTestSelect(view, "esto")
        session.send(.replaceSelection(""))
        XCTAssertEqual(view.string, "borra  por favor", "delete = replace vacío con selección")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "borra esto por favor", "un undo restaura")
        window.orderOut(nil)
    }

    @MainActor func testRewriteVoiceShowsProposalBeforeConfirming() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let (window, view, session) = voiceTestSession(
            text: "texto original aquí", rewrite: MockRewriteProvider(result: "nuevo"))
        defer { window.orderOut(nil) }
        voiceTestSelect(view, "original")
        module.prepareRewrite = { instruction in try await session.prepareRewrite(instruction: instruction) }
        module.acceptRewrite = { session.acceptRewrite() }
        module.discardRewrite = { session.discardRewrite() }
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertEqual(module.pendingAction?.intent, .command(.rewriteSelection("más breve")))
        XCTAssertTrue(module.pendingAction?.preview.contains("Propuesta:\nnuevo") == true)
        XCTAssertEqual(view.string, "texto original aquí")
        await module.confirmPending()
        XCTAssertEqual(view.string, "texto nuevo aquí")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "texto original aquí")
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor func testStoppingVoiceDiscardsLateRewrite() async throws {
        let provider = SuspendedRewriteProvider()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.prepareRewrite = { instruction in
            try await provider.rewrite("original", instruction: instruction)
        }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        let finishing = Task { await module.finish() }
        await provider.waitUntilStarted()
        await module.stop()
        await provider.finish("nuevo")
        await finishing.value
        XCTAssertNil(module.pendingAction)
        XCTAssertEqual(module.state, .idle)
    }

    @MainActor func testStoppingVoiceInvalidatesReadyRewrite() async throws {
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let (window, view, session) = voiceTestSession(
            text: "texto original aquí", rewrite: MockRewriteProvider(result: "nuevo"))
        defer { window.orderOut(nil) }
        voiceTestSelect(view, "original")
        module.prepareRewrite = { instruction in try await session.prepareRewrite(instruction: instruction) }
        module.discardRewrite = { session.discardRewrite() }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        await module.finish()
        XCTAssertNotNil(module.pendingAction)
        await module.stop()
        XCTAssertNil(module.pendingAction)
        XCTAssertFalse(session.acceptRewrite())
        XCTAssertEqual(view.string, "texto original aquí")
    }

    @MainActor func testWordTravelsAsWordExport() async throws {
        let bus = EditorCommandBus()
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Exporta a Word."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertNotNil(module.pendingAction, "word requiere confirmación")
        await module.confirmPending()
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.exportDocument("word")])
    }

    @MainActor func testSessionRewriteApplies() async {
        let (window, view, session) = voiceTestSession(
            text: "texto original aquí",
            rewrite: MockRewriteProvider(result: "nuevo"))
        voiceTestSelect(view, "original")
        let proposal = try? await session.prepareRewrite(instruction: "más breve")
        XCTAssertEqual(proposal, "nuevo")
        XCTAssertEqual(view.string, "texto original aquí")
        XCTAssertFalse(view.undoManager?.canUndo == true)
        XCTAssertTrue(session.acceptRewrite())
        XCTAssertEqual(view.string, "texto nuevo aquí")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "texto original aquí", "un undo restaura")
        XCTAssertFalse(view.undoManager?.canUndo == true, "aceptar registra un único undo")
        window.orderOut(nil)
    }

    func testRewriteKeepsSelectedBoundaryWhitespace() {
        XCTAssertEqual(
            FoundationModelsRewriteProvider.preservingBoundaryWhitespace(
                "nuevo", from: " \n original \n "),
            " \n nuevo \n "
        )
    }

    @MainActor func testSessionRewriteKeepsParagraphBreaks() async {
        let (window, view, session) = voiceTestSession(
            text: "antes \n original \n después",
            rewrite: MockRewriteProvider(result: " \n nuevo \n "))
        defer { window.orderOut(nil) }
        voiceTestSelect(view, " \n original \n ")
        let proposal = try? await session.prepareRewrite(instruction: "más breve")
        XCTAssertEqual(proposal, " \n nuevo \n ")
        XCTAssertTrue(session.acceptRewrite())
        XCTAssertEqual(view.string, "antes \n nuevo \n después")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "antes \n original \n después")
    }

    @MainActor func testSessionRewriteRequiresSelection() async {
        let (window, view, session) = voiceTestSession(
            text: "texto intacto",
            rewrite: MockRewriteProvider(result: "X"))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let proposal = try? await session.prepareRewrite(instruction: "más breve")
        XCTAssertNil(proposal)
        XCTAssertFalse(session.acceptRewrite())
        XCTAssertEqual(view.string, "texto intacto", "sin selección no reescribe")
        window.orderOut(nil)
    }

    @MainActor func testSessionRewriteFailureKeepsText() async {
        let (window, view, session) = voiceTestSession(
            text: "texto intacto",
            rewrite: MockRewriteProvider(result: nil))
        voiceTestSelect(view, "intacto")
        let proposal = try? await session.prepareRewrite(instruction: "más breve")
        XCTAssertNil(proposal)
        XCTAssertEqual(view.string, "texto intacto", "si la IA falla no toca nada")
        window.orderOut(nil)
    }

    @MainActor func testSessionRewriteStaleDoesNotApplyBlindly() async {
        let (window, view, session) = voiceTestSession(
            text: "texto original aquí",
            rewrite: MockRewriteProvider(result: "TARDÍO"))
        voiceTestSelect(view, "original")
        let proposal = try? await session.prepareRewrite(instruction: "más breve")
        XCTAssertEqual(proposal, "TARDÍO")
        // El usuario edita después de ver la propuesta: no se puede aceptar.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        session.send(.insertText("¡Hola! "))
        XCTAssertFalse(session.acceptRewrite())
        XCTAssertTrue(view.string.hasPrefix("¡Hola! "), "la edición del usuario manda")
        XCTAssertFalse(view.string.contains("TARDÍO"), "nunca aplica a ciegas")
        window.orderOut(nil)
    }

    @MainActor func testSessionRewriteDiscardKeepsDocumentAndUndo() async {
        let (window, view, session) = voiceTestSession(
            text: "texto original aquí", rewrite: MockRewriteProvider(result: "nuevo"))
        voiceTestSelect(view, "original")
        let proposal = try? await session.prepareRewrite(instruction: "más formal")
        XCTAssertEqual(proposal, "nuevo")
        session.discardRewrite()
        XCTAssertFalse(session.acceptRewrite())
        XCTAssertEqual(view.string, "texto original aquí")
        XCTAssertFalse(view.undoManager?.canUndo == true)
        window.orderOut(nil)
    }
}

private struct MockRewriteProvider: RewriteProvider {
    var result: String?
    var delay: Duration = .zero
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func rewrite(_ text: String, instruction: String) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let result else { throw ModelFailure.generation }
        return result
    }
}

private actor SuspendedRewriteProvider: RewriteProvider {
    nonisolated let isAvailable = true
    nonisolated let availabilityReason: String? = nil
    private var result: CheckedContinuation<String, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func rewrite(_ text: String, instruction: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ text: String) {
        result?.resume(returning: text)
        result = nil
    }
}

@MainActor private func voiceTestSession(text: String, rewrite: (any RewriteProvider)? = nil) -> (NSWindow, NSTextView, EditorSession) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = NSTextView(usingTextLayoutManager: true)
    view.isRichText = false
    view.allowsUndo = true
    window.contentView = view
    window.makeFirstResponder(view)
    view.undoManager?.groupsByEvent = false
    view.string = text
    view.breakUndoCoalescing()
    view.undoManager?.removeAllActions()
    let session = EditorSession(rewriteProvider: rewrite)
    session.textView = view
    return (window, view, session)
}

@MainActor private func voiceTestSelect(_ view: NSTextView, _ query: String) {
    let r = (view.string as NSString).range(of: query)
    guard r.location != NSNotFound else { return }
    view.setSelectedRange(r)
}

// MARK: - Cierre por pausa con actividad del audio

/// Reloj manual: el cierre por pausa se prueba sin esperar segundos reales.
@MainActor private final class ManualClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

final class VoiceEndpointActivityTests: XCTestCase {
    @MainActor private func pump() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @MainActor private func handsFreeModule() async throws -> (VoiceModule, MockSpeechRecognizer, ManualClock) {
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let clock = ManualClock()
        module.now = { clock.date }
        module.continuousListening = true
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.toggle()
        XCTAssertTrue(module.isListening)
        XCTAssertTrue(module.handsFreeActive)
        return (module, mock, clock)
    }

    /// Speech se atrasa: el parcial no cambia, pero el micrófono sigue con voz.
    @MainActor func testActiveAudioKeepsListeningWithStalledPartial() async throws {
        let (module, mock, clock) = try await handsFreeModule()
        defer { Task { await module.stop() } }
        mock.onPartial?("hola")
        await pump()
        XCTAssertFalse(module.autoFinishDue(), "el primer vistazo anota el cambio")
        for _ in 0..<120 {
            clock.advance(4096.0 / 48_000)
            module.noteInputLevel(0.6)
            if module.autoFinishDue() { return XCTFail("no se corta mientras hay voz sostenida") }
        }
        XCTAssertTrue(module.isListening)
    }

    /// Tras la voz, el silencio real cierra; el cierre rearma la escucha
    /// con sus propios relojes.
    @MainActor func testSilenceAfterSpeechFinishesAndRearms() async throws {
        let (module, mock, clock) = try await handsFreeModule()
        defer { Task { await module.stop() } }
        mock.onPartial?("hola")
        await pump()
        XCTAssertFalse(module.autoFinishDue())
        for _ in 0..<5 {
            clock.advance(0.2)
            module.noteInputLevel(0.6)
        }
        // Silencio: el nivel cae al ruido de fondo.
        for _ in 0..<7 {
            clock.advance(0.2)
            module.noteInputLevel(0.02)
            XCTAssertFalse(module.autoFinishDue(), "aún no pasa la pausa completa")
        }
        clock.advance(0.3)
        XCTAssertTrue(module.autoFinishDue())
        mock.nextTranscript = "hola"
        await module.autoFinish()
        XCTAssertTrue(module.isListening, "Manos libres vuelve a escuchar")

        // Nueva frase: sus relojes empiezan de cero, no heredan la pausa anterior.
        XCTAssertFalse(module.autoFinishDue(), "sin parcial no cierra")
        mock.onPartial?("sigo")
        await pump()
        XCTAssertFalse(module.autoFinishDue())
        clock.advance(0.5)
        module.noteInputLevel(0.6)
        clock.advance(1.2)
        XCTAssertFalse(module.autoFinishDue(), "hubo voz hace 1.2 s")
        clock.advance(0.5)
        XCTAssertTrue(module.autoFinishDue())
    }

    /// El nivel por sí solo no permite distinguir voz sostenida de ruido.
    @MainActor func testConstantAudioAboveThresholdDoesNotBecomeSilence() async throws {
        let (module, mock, clock) = try await handsFreeModule()
        defer { Task { await module.stop() } }
        mock.onPartial?("hola")
        await pump()
        XCTAssertFalse(module.autoFinishDue())
        for _ in 0..<120 {
            clock.advance(0.1)
            module.noteInputLevel(0.3)
            if module.autoFinishDue() { return XCTFail("un nivel sostenido no demuestra que haya silencio") }
        }
    }

    @MainActor func testQuietVoiceAboveRecognizerThresholdKeepsListening() async throws {
        let (module, mock, clock) = try await handsFreeModule()
        defer { Task { await module.stop() } }
        mock.onPartial?("hola")
        await pump()
        _ = module.autoFinishDue()
        for _ in 0..<120 {
            clock.advance(0.1)
            module.noteInputLevel(mock.voiceThreshold + 0.01)
            if module.autoFinishDue() { return XCTFail("el cierre debe respetar el umbral del reconocedor") }
        }
    }

    /// Push-to-talk no cierra por pausa: cierra al soltar.
    @MainActor func testPushToTalkNeverAutoFinishes() async throws {
        let mock = MockSpeechRecognizer()
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let clock = ManualClock()
        module.now = { clock.date }
        module.pushToTalkEnabled = true
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.beginPushToTalk()
        mock.onPartial?("hola")
        await pump()
        _ = module.autoFinishDue()
        clock.advance(10)
        XCTAssertFalse(module.autoFinishDue())
        await module.endPushToTalk()
    }
}

// MARK: - Recuperar texto tras un error del reconocedor

private struct RecognitionBroke: LocalizedError {
    var errorDescription: String? { "El reconocimiento se interrumpió." }
}

/// Doble cuyo `stop()` falla dejando parte del texto en `liveTranscript`.
private final class FailingStopRecognizer: VoiceSpeechRecognizer, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var hasSpeech: Bool { true }
    var voiceThreshold: Float { 0.08 }
    var partial = ""
    var failStop = true
    var liveTranscript: String { partial }
    func start() async throws {}
    func stop() async throws -> String {
        if failStop { throw RecognitionBroke() }
        return partial
    }
    func cancel() async { partial = "" }
}

final class VoiceRecoveryTests: XCTestCase {
    @MainActor private func collect(_ bus: EditorCommandBus, _ stream: AsyncStream<EditorCommand>) async -> [EditorCommand] {
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        return received
    }

    /// El texto parcial se conserva, el error sigue visible y nada se ejecuta
    /// aunque lo recuperado parezca una orden.
    @MainActor func testFailedStopKeepsPartialTextWithoutRunningCommands() async throws {
        let bus = EditorCommandBus()
        let recognizer = FailingStopRecognizer()
        recognizer.partial = "guarda el documento"
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        module.continuousListening = false
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        XCTAssertEqual(module.recoveredTranscript, "guarda el documento")
        XCTAssertNil(module.pendingAction)
        guard case .failed(let message) = module.state else { return XCTFail("debe seguir el error") }
        XCTAssertTrue(message.contains("se interrumpió"))
        XCTAssertTrue(message.contains("recuperó"))
        // Mientras no decide, no empieza otra grabación que lo borre.
        await module.begin()
        XCTAssertFalse(module.isListening)
        XCTAssertEqual(module.recoveredTranscript, "guarda el documento")
        let received = await collect(bus, stream)
        XCTAssertTrue(received.isEmpty, "ni orden ni inserción sin decisión")
    }

    @MainActor func testFailedStopWithoutTextShowsErrorOnly() async throws {
        let recognizer = FailingStopRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        await module.finish()
        XCTAssertNil(module.recoveredTranscript)
        XCTAssertEqual(module.state, .failed("El reconocimiento se interrumpió."))
    }

    @MainActor func testDiscardRecoveredTextKeepsDocument() async throws {
        let bus = EditorCommandBus()
        let recognizer = FailingStopRecognizer()
        recognizer.partial = "texto a medias"
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        await module.begin()
        await module.finish()
        module.discardRecoveredTranscript()
        XCTAssertNil(module.recoveredTranscript)
        XCTAssertEqual(module.state, .idle)
        await module.insertRecoveredTranscript()
        let received = await collect(bus, stream)
        XCTAssertTrue(received.isEmpty)
    }

    /// Con Manos libres la preview en vivo se retira; insertar es explícito,
    /// ocurre una sola vez y se deshace con un undo.
    @MainActor func testRecoveredTextInsertsOnceOnRequest() async throws {
        let (window, view, session) = voiceTestSession(text: "base ")
        defer { session.stop(); window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let bus = EditorCommandBus()
        let recognizer = FailingStopRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        module.continuousListening = true
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let consumer = Task { @MainActor in
            for await command in await bus.commands() { session.send(command) }
        }
        defer { consumer.cancel() }
        for _ in 0..<50 { await Task.yield() }

        await module.toggle()
        recognizer.partial = "texto a medias"
        recognizer.onPartial?("texto a medias")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base texto a medias", "preview en vivo")
        await module.autoFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base ", "el documento vuelve al original")
        XCTAssertFalse(session.isPreviewing)
        XCTAssertFalse(module.isListening, "tras el error no se rearma")
        XCTAssertEqual(module.recoveredTranscript, "texto a medias")

        await module.insertRecoveredTranscript()
        await module.insertRecoveredTranscript()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(view.string, "base texto a medias")
        XCTAssertNil(module.recoveredTranscript)
        XCTAssertEqual(module.state, .idle)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "base ")
        await module.stop()
    }

    /// El parcial de una sesión cancelada no se cuela como texto recuperado.
    @MainActor func testRecoveryIgnoresPreviousSessionPartial() async throws {
        let recognizer = FailingStopRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        recognizer.onPartial?("viejo")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(module.partialTranscript, "viejo")
        await module.cancelDictation()
        await module.begin()
        await module.finish()
        XCTAssertNil(module.recoveredTranscript)
    }
}

// MARK: - Cancelar mientras se prepara el micrófono

/// Doble con el contrato de `VoiceSpeechRecognizer.cancel()`: cada arranque
/// queda suspendido hasta `resolve`; si lo cancelaron antes, no enciende el
/// micrófono.
private final class ControlledStartRecognizer: VoiceSpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var session = 0
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _micOn = false
    var onPartial: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var hasSpeech: Bool { true }
    var voiceThreshold: Float { 0.08 }
    var liveTranscript: String { "hola" }
    var micOn: Bool { lock.withLock { _micOn } }

    func start() async throws {
        let id = lock.withLock { session += 1; return session }
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock {
                pending[id] = continuation
                defer { waiters = [] }
                return waiters
            }
            ready.forEach { $0.resume() }
        }
        try lock.withLock {
            guard session == id else { throw CancellationError() }
            _micOn = true
        }
    }

    /// Espera a que haya `count` arranques pendientes en total.
    func waitForStarts(_ count: Int) async {
        while lock.withLock({ pending.count }) < count {
            await withCheckedContinuation { continuation in
                let now = lock.withLock {
                    if pending.count >= count { return true }
                    waiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
    }

    /// Termina el arranque número `index` (1, 2…), con éxito o con error.
    func resolve(_ index: Int, error: (any Error)? = nil) {
        let ids = lock.withLock { pending.keys.sorted() }
        guard ids.indices.contains(index - 1),
              let continuation = lock.withLock({ pending.removeValue(forKey: ids[index - 1]) }) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func stop() async throws -> String {
        lock.withLock { _micOn = false }
        return "hola"
    }

    func cancel() async {
        lock.withLock {
            session += 1
            _micOn = false
        }
    }
}

final class VoiceStartCancellationTests: XCTestCase {
    @MainActor private func pump() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Cancelar no espera al arranque; si después termina, no enciende nada
    /// ni cambia el estado ni deja preview.
    @MainActor func testCancelDuringStartReturnsAndIgnoresLateSuccess() async throws {
        let bus = EditorCommandBus()
        let recognizer = ControlledStartRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        module.continuousListening = true
        try await module.start(context: EditorModuleContext(commandBus: bus))
        let stream = await bus.commands()
        let beginning = Task { await module.toggle() }
        await recognizer.waitForStarts(1)
        XCTAssertTrue(module.isListening)
        XCTAssertFalse(module.microphoneReady)
        await module.cancelDictation()
        XCTAssertEqual(module.state, .idle)
        recognizer.resolve(1)
        await beginning.value
        await pump()
        XCTAssertEqual(module.state, .idle)
        XCTAssertFalse(module.microphoneReady)
        XCTAssertFalse(recognizer.micOn)
        await bus.finish()
        var received: [EditorCommand] = []
        for await command in stream { received.append(command) }
        XCTAssertEqual(received, [.beginVoicePreview, .cancelVoicePreview], "la preview se abre y se retira una vez")
    }

    @MainActor func testLateStartFailureAfterCancelShowsNoError() async throws {
        let recognizer = ControlledStartRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        let beginning = Task { await module.begin() }
        await recognizer.waitForStarts(1)
        await module.cancelDictation()
        recognizer.resolve(1, error: RecognitionBroke())
        await beginning.value
        XCTAssertEqual(module.state, .idle)
    }

    /// Una grabación nueva no se ve afectada por la respuesta tardía de la anterior.
    @MainActor func testLateStartDoesNotTouchNewSession() async throws {
        let recognizer = ControlledStartRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        module.continuousListening = false
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        let first = Task { await module.begin() }
        await recognizer.waitForStarts(1)
        await module.cancelDictation()
        let second = Task { await module.begin() }
        await recognizer.waitForStarts(2)
        recognizer.resolve(1)
        await first.value
        await pump()
        XCTAssertTrue(module.isListening, "la sesión nueva sigue preparándose")
        XCTAssertFalse(module.microphoneReady)
        XCTAssertFalse(recognizer.micOn, "el arranque viejo no abre el micrófono")
        recognizer.resolve(1)
        await second.value
        XCTAssertTrue(module.microphoneReady)
        XCTAssertTrue(recognizer.micOn)
        await module.finish()
        XCTAssertEqual(module.pendingDictationText, "Hola.")
    }

    /// Detener la pieza tampoco espera al arranque pendiente.
    @MainActor func testModuleStopDoesNotWaitForStart() async throws {
        let recognizer = ControlledStartRecognizer()
        let module = VoiceModule(recognizer: recognizer, preferences: nil)
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        let beginning = Task { await module.begin() }
        await recognizer.waitForStarts(1)
        await module.stop()
        XCTAssertEqual(module.state, .idle)
        recognizer.resolve(1)
        await beginning.value
        XCTAssertEqual(module.state, .idle)
        XCTAssertFalse(recognizer.micOn)
    }
}

// MARK: - Causa del fallo de IA en la voz

private struct FailingRewriteProvider: RewriteProvider {
    let failure: ModelFailure
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func rewrite(_ text: String, instruction: String) async throws -> String { throw failure }
}

final class VoiceRewriteFailureTests: XCTestCase {
    @MainActor private func feedback(for failure: ModelFailure) async throws -> (String, String) {
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let (window, view, session) = voiceTestSession(text: "texto original aquí", rewrite: FailingRewriteProvider(failure: failure))
        defer { window.orderOut(nil) }
        voiceTestSelect(view, "original")
        module.prepareRewrite = { try await session.prepareRewrite(instruction: $0) }
        module.discardRewrite = { session.discardRewrite() }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        await module.finish()
        XCTAssertNil(module.pendingAction)
        return (module.lastCommandFeedback, view.string)
    }

    @MainActor func testEachCauseReachesThePanel() async throws {
        let cases: [(ModelFailure, String)] = [
            (.deadline, "tardó demasiado"),
            (.unavailable("Activa Apple Intelligence en Ajustes del Sistema."), "Activa Apple Intelligence"),
            (.tooLong, "más corto"),
            (.invalidOutput, "no sirve"),
        ]
        for (failure, expected) in cases {
            let (message, text) = try await feedback(for: failure)
            XCTAssertTrue(message.contains(expected), "\(failure): \(message)")
            XCTAssertEqual(text, "texto original aquí", "el original se conserva")
        }
    }

    @MainActor func testMissingSelectionIsExplained() async throws {
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let (window, view, session) = voiceTestSession(text: "texto", rewrite: MockRewriteProvider(result: "nuevo"))
        defer { window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        module.prepareRewrite = { try await session.prepareRewrite(instruction: $0) }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        await module.finish()
        XCTAssertTrue(module.lastCommandFeedback.contains("Selecciona el texto"), module.lastCommandFeedback)
    }

    /// La selección cambia mientras genera: se dice, no se aplica nada.
    @MainActor func testSelectionChangedDuringGenerationIsExplained() async throws {
        let provider = SuspendedRewriteProvider()
        let (window, view, session) = voiceTestSession(text: "texto original aquí", rewrite: provider)
        defer { window.orderOut(nil) }
        voiceTestSelect(view, "original")
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.prepareRewrite = { try await session.prepareRewrite(instruction: $0) }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        let finishing = Task { await module.finish() }
        await provider.waitUntilStarted()
        view.setSelectedRange(NSRange(location: 0, length: 5))
        await provider.finish("nuevo")
        await finishing.value
        XCTAssertNil(module.pendingAction)
        XCTAssertTrue(module.lastCommandFeedback.contains("cambió"), module.lastCommandFeedback)
        XCTAssertEqual(view.string, "texto original aquí")
        XCTAssertFalse(session.acceptRewrite())
    }

    @MainActor func testSessionReportsCauses() async {
        let (window, view, session) = voiceTestSession(text: "texto original", rewrite: MockRewriteProvider(result: "original"))
        defer { window.orderOut(nil) }
        voiceTestSelect(view, "original")
        do {
            _ = try await session.prepareRewrite(instruction: "igual")
            XCTFail("una salida igual al original no es propuesta")
        } catch {
            XCTAssertEqual(error as? ModelFailure, .invalidOutput)
        }
    }
}

final class ModelFailureTests: XCTestCase {
    func testClassifiesKnownErrors() {
        XCTAssertNil(ModelFailure.classify(CancellationError()), "cancelar no es un fallo")
        XCTAssertEqual(ModelFailure.classify(ModelDeadlineExceeded()), .deadline)
        XCTAssertEqual(ModelFailure.classify(ModelFailure.busy), .busy)
        XCTAssertEqual(ModelFailure.classify(RecognitionBroke()), .generation)
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "prueba")
        XCTAssertEqual(ModelFailure.classify(LanguageModelSession.GenerationError.exceededContextWindowSize(context)), .tooLong)
        XCTAssertEqual(ModelFailure.classify(LanguageModelSession.GenerationError.guardrailViolation(context)), .refused)
        XCTAssertEqual(ModelFailure.classify(LanguageModelSession.GenerationError.rateLimited(context)), .busy)
        XCTAssertEqual(ModelFailure.classify(LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)), .unsupportedLanguage)
        if case .unavailable = ModelFailure.classify(LanguageModelSession.GenerationError.assetsUnavailable(context)) {} else {
            XCTFail("sin recursos del modelo es no disponible")
        }
    }

    func testMessagesNameAnAction() {
        XCTAssertTrue(ModelFailure.deadline.message.contains("Reintenta"))
        XCTAssertTrue(ModelFailure.tooLong.message.contains("más corto"))
        XCTAssertTrue(ModelFailure.selectionChanged.message.contains("Vuelve a seleccionar"))
    }
}
