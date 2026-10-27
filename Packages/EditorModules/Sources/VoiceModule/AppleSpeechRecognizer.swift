import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Reconocimiento local con `SpeechAnalyzer` + `DictationTranscriber`
/// (macOS 26+). Todo el audio se procesa en el dispositivo; Apple documenta
/// que el transcriptor de dictado solo admite modelos locales.
///
/// Adaptado de `SpeechRecognitionService` de LocalFlow
/// (`MiyuWisp/LocalFlow/LocalFlow/Speech/SpeechRecognitionService.swift`).
/// Recorte aplicado: sin WhisperKit, sin historial, sin atajos globales ni
/// inserción por Accesibilidad (el editor inserta vía `EditorCommand`).
/// Los parciales llegan por `onPartial`; el nivel por `onLevel`.
public final class AppleSpeechRecognizer: VoiceSpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _onPartial: (@Sendable (String) -> Void)?
    private nonisolated(unsafe) var _onLevel: (@Sendable (Float) -> Void)?
    private nonisolated(unsafe) var _finalSegments: [(start: Double, text: String)] = []
    private nonisolated(unsafe) var _volatileText = ""
    private nonisolated(unsafe) var _recognitionError: (any Error)?
    private nonisolated(unsafe) var _speechFrames = 0
    private nonisolated(unsafe) var _peakLevel: Float = 0

    /// Umbral de energía para considerar que hay voz (modo susurro lo baja).
    public var voiceThreshold: Float = 0.08
    /// Idioma del dictado, p. ej. `es-MX`.
    public var localeIdentifier: String = "es-MX"

    public var onPartial: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onPartial } }
        set { lock.withLock { _onPartial = newValue } }
    }

    public var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { _onLevel } }
        set { lock.withLock { _onLevel = newValue } }
    }

    public var hasSpeech: Bool {
        lock.withLock { _speechFrames > 0 }
    }

    public var liveTranscript: String {
        lock.withLock { Self.combined(finalSegments: _finalSegments, volatile: _volatileText) }
    }

    /// Motores de una sesión. Se sacan enteros bajo el candado para
    /// apagarlos fuera de él: así la limpieza de una sesión vieja nunca
    /// toca los de una nueva.
    private struct Session: @unchecked Sendable {
        var engine: AVAudioEngine?
        var analyzer: SpeechAnalyzer?
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var resultsTask: Task<Void, Never>?

        func shutdown() async {
            engine?.stop()
            engine?.inputNode.removeTap(onBus: 0)
            continuation?.finish()
            if let analyzer { await analyzer.cancelAndFinishNow() }
            resultsTask?.cancel()
            await resultsTask?.value
        }
    }

    /// Lo que el tap del micrófono necesita de su sesión.
    private final class TapContext: @unchecked Sendable {
        let converter: AVAudioConverter?
        let format: AVAudioFormat
        let continuation: AsyncStream<AnalyzerInput>.Continuation

        init(converter: AVAudioConverter?, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
            self.converter = converter
            self.format = format
            self.continuation = continuation
        }
    }

    /// Sesión vigente y su número, protegidos por `lock`. Cada `start()` y
    /// cada `cancel()` sube el número: un arranque que despierta tarde de un
    /// permiso o una descarga ve otro número y no abre el micrófono.
    private nonisolated(unsafe) var _session = Session()
    private nonisolated(unsafe) var _sessionID = 0
    /// Cubre "comprobar el número y encender el motor" frente a abrir o
    /// cancelar una sesión. Va aparte de `lock` porque el tap del micrófono
    /// toma `lock` y `engine.start()` no debe esperar al tap. Orden: este y
    /// después `lock`.
    private let startLock = NSLock()

    public init(localeIdentifier: String = "es-MX") {
        self.localeIdentifier = localeIdentifier
    }

    // MARK: - Permisos y recursos

    private func failure(_ message: String) -> NSError {
        NSError(domain: "EditorFinal.Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func requestSpeech() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    @available(macOS 26, *)
    private func supportedLocale() async -> Locale? {
        await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier))
    }

    @available(macOS 26, *)
    private func ensureAssets(_ id: Int) async throws {
        guard let locale = await supportedLocale() else {
            throw failure("El idioma seleccionado no tiene un modelo local compatible.")
        }
        try ensureCurrent(id)
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        for reserved in await AssetInventory.reservedLocales where reserved != locale {
            _ = await AssetInventory.release(reservedLocale: reserved)
        }
        _ = try await AssetInventory.reserve(locale: locale)
        try ensureCurrent(id)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try ensureCurrent(id)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw failure("El modelo local no está instalado. Conecta internet para descargarlo y vuelve a intentar.")
        }
    }

    // MARK: - Sesión

    /// Abre una sesión nueva: invalida cualquier arranque en curso, limpia
    /// el texto anterior y devuelve los motores viejos para apagarlos.
    private func openSession() -> (id: Int, previous: Session) {
        startLock.withLock { lock.withLock {
            _sessionID += 1
            let previous = _session
            _session = Session()
            _finalSegments = []
            _volatileText = ""
            _recognitionError = nil
            _speechFrames = 0
            _peakLevel = 0
            return (_sessionID, previous)
        } }
    }

    private func isCurrent(_ id: Int) -> Bool {
        lock.withLock { _sessionID == id }
    }

    /// Tras cada espera: si otra sesión o una cancelación tomó el relevo, se
    /// abandona el arranque sin tocar nada compartido.
    private func ensureCurrent(_ id: Int) throws {
        guard isCurrent(id), !Task.isCancelled else { throw CancellationError() }
    }

    /// Suelta los motores de `id` si sigue vigente; si no, no toca nada.
    private func releaseSession(_ id: Int) -> Session {
        lock.withLock {
            guard _sessionID == id else { return Session() }
            let current = _session
            _session = Session()
            return current
        }
    }

    // MARK: - Start / Stop

    public func start() async throws {
        if #available(macOS 26, *) {
            let (id, previous) = openSession()
            await previous.shutdown()
            guard await requestMicrophone() else {
                try ensureCurrent(id)
                throw failure("Autoriza el micrófono en Ajustes del Sistema > Privacidad y seguridad > Micrófono.")
            }
            try ensureCurrent(id)
            guard await requestSpeech() else {
                try ensureCurrent(id)
                throw failure("Autoriza Reconocimiento de voz en Ajustes del Sistema > Privacidad y seguridad.")
            }
            try ensureCurrent(id)
            do {
                try await start26(id)
            } catch {
                await releaseSession(id).shutdown()
                throw error
            }
        } else {
            throw failure("El dictado por voz requiere macOS 26 o posterior.")
        }
    }

    @available(macOS 26, *)
    private func start26(_ id: Int) async throws {
        try await ensureAssets(id)
        guard let locale = await supportedLocale() else { throw failure("Idioma no compatible.") }
        try ensureCurrent(id)
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try ensureCurrent(id)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw failure("No hay un micrófono disponible. Revisa la entrada de sonido de macOS.")
        }
        let tapFormat: AVAudioFormat = bestFormat ?? inputFormat
        var converter: AVAudioConverter?
        if let best = bestFormat, best != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: best)
            guard converter != nil else { throw failure("No se pudo convertir el formato del micrófono.") }
        }

        var contRef: AsyncStream<AnalyzerInput>.Continuation!
        // Cola acotada: si el reconocimiento se atrasa, avisa en vez de perder voz en silencio.
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingOldest(128)) { c in contRef = c }
        let continuation: AsyncStream<AnalyzerInput>.Continuation = contRef
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])

        let resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let isFinal = result.isFinal
                    let text = String(result.text.characters)
                    let startSec: Double = {
                        let seconds = result.range.start.seconds
                        return seconds.isFinite ? seconds : 0
                    }()
                    let callback: (@Sendable (String) -> Void)? = self.lock.withLock {
                        // Resultados de una sesión ya cancelada o reemplazada: se ignoran.
                        guard _sessionID == id else { return nil }
                        if isFinal {
                            _finalSegments.removeAll { abs($0.start - startSec) < 0.05 }
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                _finalSegments.append((startSec, text))
                            }
                            _volatileText = ""
                        } else {
                            _volatileText = text
                        }
                        return _onPartial
                    }
                    guard let callback else { continue }
                    callback(self.liveTranscript)
                }
            } catch {
                self.lock.withLock { if self._sessionID == id { self._recognitionError = error } }
            }
        }

        let tap = TapContext(converter: converter, format: tapFormat, continuation: continuation)
        do {
            // Revisar y encender bajo el mismo candado: un `cancel()` que llegue
            // ahora espera y después apaga este motor; nunca queda encendido.
            try startLock.withLock {
                try ensureCurrent(id)
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    let level = Self.rmsLevel(from: buffer)
                    let levelCallback: (@Sendable (Float) -> Void)?? = self.lock.withLock {
                        guard self._sessionID == id else { return .none }
                        if level > self.voiceThreshold { self._speechFrames += 1 }
                        self._peakLevel = max(self._peakLevel, level)
                        return .some(self._onLevel)
                    }
                    guard let levelCallback else { return }
                    levelCallback?(level)
                    do {
                        let output = try Self.prepareBuffer(buffer, converter: tap.converter, format: tap.format)
                        guard output.frameLength > 0 else { return }
                        if case .dropped = tap.continuation.yield(AnalyzerInput(buffer: output)) {
                            throw self.failure("El reconocimiento no pudo seguir el ritmo del audio. Intenta un dictado más corto.")
                        }
                    } catch {
                        self.lock.withLock { if self._sessionID == id { self._recognitionError = error } }
                        tap.continuation.finish()
                    }
                }
                engine.prepare()
                try engine.start()
                lock.withLock {
                    _session = Session(engine: engine, analyzer: analyzer, continuation: continuation, resultsTask: resultsTask)
                }
            }
        } catch {
            await Session(engine: engine, analyzer: analyzer, continuation: continuation, resultsTask: resultsTask).shutdown()
            throw error
        }
    }

    /// Nivel 0…1 a partir de un buffer PCM. La voz normal queda a mitad de
    /// barra y el silencio cerca de 0.
    static func rmsLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return 0 }
        var sum: Double = 0
        var count: Double = 0
        for ch in 0..<channelCount {
            let data = channels[ch]
            for i in 0..<frames {
                let sample = Double(data[i])
                sum += sample * sample
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let rms = sqrt(sum / count)
        guard rms > 0.00001 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }

    /// Copia propia de las muestras: AVAudioEngine reutiliza los buffers del tap.
    static func prepareBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(domain: "EditorFinal.Voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "No se pudo reservar memoria para el audio."])
        }
        if let converter {
            var supplied = false
            var convertError: NSError?
            let status = converter.convert(to: output, error: &convertError) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let convertError { throw convertError }
            if status == .error {
                throw NSError(domain: "EditorFinal.Voice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Falló la conversión del audio del micrófono."])
            }
        } else {
            output.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for (src, dst) in zip(source, destination) {
                if let from = src.mData, let to = dst.mData {
                    memcpy(to, from, Int(src.mDataByteSize))
                }
            }
        }
        return output
    }

    public func stop() async throws -> String {
        if #available(macOS 26, *) {
            return try await stop26()
        }
        return liveTranscript
    }

    @available(macOS 26, *)
    private func stop26() async throws -> String {
        let (id, current) = lock.withLock { (_sessionID, _session) }
        current.engine?.stop()
        current.engine?.inputNode.removeTap(onBus: 0)
        // Terminar la entrada antes de finalizar: el analizador espera el fin.
        current.continuation?.finish()
        if let analyzer = current.analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
                await current.resultsTask?.value
                _ = releaseSession(id)
                // El texto reconocido hasta aquí queda en `liveTranscript`
                // para que quien llama lo ofrezca sin perderlo.
                throw error
            }
        }
        await current.resultsTask?.value
        // Se conserva la transcripción para quien la pidió; solo se sueltan motores.
        _ = releaseSession(id)
        if let error = lock.withLock({ _recognitionError }) { throw error }
        return liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Descarta la sesión vigente y cualquier arranque en curso. No espera a
    /// permisos ni descargas: el arranque pendiente verá otro número de
    /// sesión al despertar y no abrirá el micrófono.
    public func cancel() async {
        let previous: Session = startLock.withLock { lock.withLock {
            _sessionID += 1
            let previous = _session
            _session = Session()
            _finalSegments = []
            _volatileText = ""
            _recognitionError = nil
            return previous
        } }
        await previous.shutdown()
    }

    private static func combined(finalSegments: [(start: Double, text: String)], volatile: String) -> String {
        let final = finalSegments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        if volatile.isEmpty { return final }
        return final.isEmpty ? volatile : final + " " + volatile
    }
}
