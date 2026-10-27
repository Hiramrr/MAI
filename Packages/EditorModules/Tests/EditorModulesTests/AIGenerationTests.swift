import XCTest
import AppKit
@testable import EditorCore
@testable import EditorEngine
@testable import ModuleKit
@testable import GestureModule
@testable import VoiceModule

/// Plazos y ciclo de vida de las generaciones con IA, con dobles sin modelo.
final class ModelDeadlineTests: XCTestCase {
    func testReturnsValueBeforeDeadline() async throws {
        let value = try await withModelDeadline(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await withModelDeadline(.seconds(5)) { () async throws -> Int in throw Boom() }
            XCTFail("debía lanzar")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    /// Una operación que ignora la cancelación no alarga la espera más allá del plazo.
    func testDeadlineDoesNotWaitForUncooperativeOperation() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withModelDeadline(.milliseconds(50)) { await uncooperativeWait(seconds: 2); return 1 }
            XCTFail("debía vencer el plazo")
        } catch {
            XCTAssertTrue(error is ModelDeadlineExceeded)
        }
        XCTAssertLessThan(clock.now - start, .seconds(1))
    }

    /// Cancelar a quien espera devuelve en el acto, aunque la operación siga.
    func testCallerCancellationReturnsPromptly() async {
        let clock = ContinuousClock()
        let start = clock.now
        let waiting = Task {
            try await withModelDeadline(.seconds(30)) { await uncooperativeWait(seconds: 2); return 1 }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        let result = await waiting.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(clock.now - start, .seconds(1))
    }
}

/// Espera que no atiende la cancelación, como una generación que no la revisa.
private func uncooperativeWait(seconds: Double) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// Retiene cada petición hasta `release()` y cuenta las llamadas al modelo.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func pass() async {
        lock.withLock { _calls += 1 }
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if open { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            open = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private struct GatedToneProvider: ToneProvider {
    let gate = Gate()
    let results = ["Se requiere el informe mañana.", "Me ayudaría mucho tener el informe mañana, por favor."]
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func variants(for sentence: String) async throws -> VariantPair {
        await gate.pass()
        return VariantPair(results[0], results[1])
    }
}

private struct GatedSynonymProvider: SynonymProvider {
    let gate = Gate()
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func synonyms(for word: String) async throws -> [String] {
        await gate.pass()
        return ["trascendental", "clave"]
    }
}

private struct GatedLengthProvider: LengthProvider {
    let gate = Gate()
    let results = [
        "Primera oración completa.",
        "Primera oración completa. La segunda oración desarrolla la idea con una metodología clara e importante."
    ]
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func variants(for paragraph: String) async throws -> VariantPair {
        await gate.pass()
        return VariantPair(results[0], results[1])
    }
}

final class GestureGenerationLifecycleTests: XCTestCase {
    @MainActor private func pump(times: Int = 50) async {
        for _ in 0..<times { await Task.yield() }
    }

    /// Cerrar la tarjeta mientras genera no tira la generación; reabrir la
    /// misma oración se une a ella en vez de pedirla otra vez.
    @MainActor func testReopeningToneJoinsRunningGeneration() async {
        let provider = GatedToneProvider()
        let module = GestureModule(toneProvider: provider)
        let text = "Hola equipo. Necesito el informe mañana sin falta. Gracias."
        module.updateDocument(text: text, selection: NSRange(location: 20, length: 0))
        await module.startToneSessionManually()
        await pump()
        XCTAssertTrue(module.toneLoading)
        module.cancelPinchSession()
        await module.startToneSessionManually()
        await pump()
        XCTAssertTrue(module.toneLoading)
        provider.gate.release()
        await pump()
        XCTAssertFalse(module.toneLoading)
        XCTAssertEqual(module.toneOptions, [provider.results[0], "Necesito el informe mañana sin falta.", provider.results[1]])
        XCTAssertEqual(provider.gate.calls, 1)
    }

    /// Sinónimos que llegan tras cerrar la sesión quedan en caché.
    @MainActor func testSynonymsArrivingAfterCloseAreReused() async {
        let provider = GatedSynonymProvider()
        let module = GestureModule(synonymProvider: provider)
        module.updateDocument(text: "dato importante", selection: NSRange(location: 7, length: 0))
        await module.startPinchSessionManually()
        await pump()
        XCTAssertFalse(module.sessionUpgraded)
        module.cancelPinchSession()
        provider.gate.release()
        await pump()
        XCTAssertFalse(module.hasPinchSession)
        await module.startPinchSessionManually()
        XCTAssertTrue(module.sessionUpgraded)
        XCTAssertTrue(module.sessionOptions.contains("trascendental"))
        XCTAssertEqual(provider.gate.calls, 1)
    }

    /// Confirmar el medio mientras genera no descarta las versiones.
    @MainActor func testLengthVersionsArrivingAfterCommitAreReused() async {
        let provider = GatedLengthProvider()
        let module = GestureModule(lengthProvider: provider)
        let paragraph = "Primera oración completa. Segunda oración con desarrollo importante y metodología clara."
        module.updateDocument(text: paragraph, selection: NSRange(location: 5, length: 0))
        await module.startLengthSessionManually()
        await pump()
        XCTAssertTrue(module.lengthLoading)
        await module.commitLengthSession(at: LengthLevel.medio.rawValue)
        XCTAssertFalse(module.hasLengthSession)
        XCTAssertFalse(module.lengthLoading)
        provider.gate.release()
        await pump()
        await module.startLengthSessionManually()
        XCTAssertFalse(module.lengthLoading)
        XCTAssertEqual(module.lengthOptions, [provider.results[0], paragraph, provider.results[1]])
        XCTAssertEqual(provider.gate.calls, 1)
    }
}

/// Doble de reescritura que espera hasta que lo cancelen.
private struct CancellableRewriteProvider: RewriteProvider {
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func rewrite(_ text: String, instruction: String) async throws -> String {
        try await Task.sleep(for: .seconds(30))
        return "nuevo"
    }
}

private struct LateRewriteProvider: RewriteProvider {
    let gate: Gate
    let onStart: @Sendable () -> Void
    var isAvailable: Bool { true }
    var availabilityReason: String? { nil }
    func rewrite(_ text: String, instruction: String) async throws -> String {
        if instruction == "más breve" {
            onStart()
            await gate.pass()
            return "viejo"
        }
        return "nuevo"
    }
}

final class VoiceRewriteCancellationTests: XCTestCase {
    @MainActor func testCancelledRewriteCannotDiscardNewerProposal() async throws {
        let started = expectation(description: "primera reescritura iniciada")
        let gate = Gate()
        let session = EditorSession(rewriteProvider: LateRewriteProvider(gate: gate, onStart: { started.fulfill() }))
        let view = NSTextView(frame: .zero)
        view.string = "original"
        view.setSelectedRange(NSRange(location: 0, length: 8))
        session.textView = view
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        module.prepareRewrite = { try await session.prepareRewrite(instruction: $0) }
        module.discardRewrite = { session.discardRewrite() }
        module.acceptRewrite = { session.acceptRewrite() }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        let first = Task { await module.finish() }
        await fulfillment(of: [started], timeout: 2)
        await module.cancelDictation()

        mock.nextTranscript = "Hazlo más formal."
        await module.begin()
        await module.finish()
        XCTAssertTrue(module.pendingAction?.preview.contains("nuevo") == true)
        gate.release()
        await first.value
        await module.confirmPending()
        XCTAssertEqual(view.string, "nuevo")
    }

    /// Cancelar mientras se prepara la propuesta corta la espera y no deja propuesta.
    @MainActor func testCancelDuringRewriteStopsWaiting() async throws {
        let mock = MockSpeechRecognizer()
        mock.nextTranscript = "Hazlo más breve."
        let module = VoiceModule(recognizer: mock, preferences: nil)
        let provider = CancellableRewriteProvider()
        module.prepareRewrite = { instruction in try await provider.rewrite("original", instruction: instruction) }
        try await module.start(context: EditorModuleContext(commandBus: EditorCommandBus()))
        await module.begin()
        let finishing = Task { await module.finish() }
        for _ in 0..<50 where module.lastCommandFeedback.isEmpty { await Task.yield() }
        XCTAssertEqual(module.state, .processing)
        XCTAssertEqual(module.lastCommandFeedback, "Preparando la propuesta con IA…")
        let clock = ContinuousClock()
        let start = clock.now
        await module.cancelDictation()
        await finishing.value
        XCTAssertLessThan(clock.now - start, .seconds(5))
        XCTAssertNil(module.pendingAction)
        XCTAssertEqual(module.state, .idle)
        XCTAssertEqual(module.lastCommandFeedback, "Reescritura cancelada")
    }
}
