import CommandGrammar
import EditorCore
import Foundation
import ModuleKit
import OSLog

/// Estado visible del dictado. Nunca se registra el texto dictado en el log.
public enum VoiceState: Sendable, Equatable {
    case idle
    case listening
    case processing
    case failed(String)
}

public struct PendingVoiceAction: Equatable, Sendable {
    public let transcript: String
    public let intent: VoiceIntent
    public let preview: String

    public var isDictation: Bool {
        if case .dictation = intent { return true }
        return false
    }
}

// MARK: - Pieza Lego: Voz
//
// Para QUITAR la voz del programa:
//   1. Borra el bloque "Pieza Lego: Voz" de `App/EditorApp.swift`.
//   2. Quita `VoiceModule` (y `ModuleKit` si nada más lo usa) de
//      `EditorFinal.xcodeproj` y de `Package.swift`.
//   3. Listo: `EditorScreen` compila igual con `voicePanel == nil` y muestra
//      "Módulo no disponible" en Ajustes > Voz.
//
// Para PONERLA de nuevo basta revertir esos pasos: el motor de texto no se toca.

/// Dictado local estilo Wispr Flow como pieza extraíble.
///
/// Flujo: micrófono → reconocedor → dictado o comando → propuesta si cambia
/// estado → `EditorCommandBus` → `EditorSession`.
///
/// El módulo nunca toca `NSTextView`: si el editor está en lectura, sus
/// comandos se ignoran solos (`EditorSession.send` no escribe en lectura).
/// Deshacer usa el `UndoManager` del editor: "borra eso" equivale a undo.
@MainActor @Observable
public final class VoiceModule: EditorInputModule {
    public nonisolated let identifier = "voice.dictation"
    public nonisolated let displayName = "Voz"

    public static var descriptor: ModuleDescriptor {
        ModuleDescriptor(identifier: "voice.dictation", displayName: "Voz")
    }

    public private(set) var state: VoiceState = .idle
    public private(set) var microphoneReady = false
    /// Último parcial del reconocedor, para mostrar mientras se dicta.
    public private(set) var partialTranscript = ""
    /// Nivel de entrada 0…1 para la barra del HUD.
    public private(set) var inputLevel: Float = 0
    /// Último texto insertado (para confirmar sin reabrir el documento).
    public private(set) var lastInsertedText = ""
    /// La transcripción cruda acompaña al resultado para detectar errores de voz.
    public private(set) var lastTranscript = ""
    public private(set) var pendingAction: PendingVoiceAction?
    /// El editor aporta la selección y conserva la propuesta hasta decidir.
    /// Lanza `ModelFailure` con la causa, o `CancellationError` si se canceló.
    public var prepareRewrite: (@MainActor (String) async throws -> String)?
    public var acceptRewrite: (@MainActor () -> Bool)?
    public var discardRewrite: (@MainActor () -> Void)?
    public var pendingDictationText: String? {
        guard case .dictation(let text) = pendingAction?.intent else { return nil }
        return text
    }
    /// Qué hizo el último comando ("Guardado", "Título: X"…).
    public private(set) var lastCommandFeedback = ""
    /// Escucha continua: un toque inicia; cada pausa procesa un enunciado y
    /// vuelve a escuchar, incluso si hay una propuesta por confirmar.
    public var continuousListening = true {
        didSet { preferences?.set(continuousListening, forKey: Self.continuousDefaultsKey) }
    }
    public private(set) var handsFreeActive = false
    /// Push-to-talk con `⌥Espacio`: mantener habla, soltar cierra. Comparte el
    /// mismo `process` que el modo por toques, así los comandos
    /// ("guarda", "busca…", "cambia el título a…") siguen funcionando.
    public var pushToTalkEnabled = true {
        didSet {
            preferences?.set(pushToTalkEnabled, forKey: Self.pushToTalkDefaultsKey)
            pushToTalk?.isEnabled = pushToTalkEnabled
        }
    }
    /// Hay una pulsación de push-to-talk en curso (para el HUD y para
    /// suspender el cierre automático mientras se mantiene la tecla).
    public private(set) var pushToTalkHeld = false
    private var pushToTalk: VoicePushToTalk?
    private static let pushToTalkDefaultsKey = "voice.pushToTalkEnabled"
    private static let continuousDefaultsKey = "voice.continuousListening"
    private static let formalDefaultsKey = "voice.formalStyle"
    private static let localeDefaultsKey = "voice.localeIdentifier"
    /// Dónde se recuerdan las opciones del panel; `nil` en pruebas.
    private let preferences: UserDefaults?
    /// Sube cuando se pide «qué puedo decir»: el panel abre sus ejemplos.
    public private(set) var helpRequests = 0
    /// Aviso cuando la respuesta a una propuesta no se entendió.
    public static let decisionHint = "Di «sí», «no» o «repetir»"
    /// Pausa (s) sin cambios en el parcial y sin voz en el micrófono para
    /// cerrar el enunciado solo.
    public var autoEndpointSilence: TimeInterval = 1.6
    /// Texto reconocido antes de que fallara el reconocedor. Espera a que la
    /// persona lo copie, lo inserte como texto incompleto o lo descarte;
    /// nunca se interpreta como orden.
    public private(set) var recoveredTranscript: String?
    private var monitorTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    /// Propuesta de reescritura en curso; cancelar el dictado la detiene.
    private var rewriteTask: Task<String, any Error>?
    private var voicePreviewStarted = false
    private var recognitionGeneration = 0
    private var lastSeenPartial = ""
    private var lastPartialChange = Date()
    /// Último buffer por encima del umbral del reconocedor.
    private var lastVoiceActivity = Date()
    /// Reloj del cierre por pausa; las pruebas lo sustituyen para no esperar.
    var now: @MainActor () -> Date = { Date() }
    /// Idioma del dictado (`es-MX`, `es-ES`, `en-US`).
    public var localeIdentifier = "es-MX" {
        didSet {
            preferences?.set(localeIdentifier, forKey: Self.localeDefaultsKey)
            if let apple = recognizer as? AppleSpeechRecognizer {
                apple.localeIdentifier = localeIdentifier
            }
        }
    }
    /// Estilo formal: mayúscula inicial y punto final (recomendado en documentos).
    public var formalStyle = true {
        didSet { preferences?.set(formalStyle, forKey: Self.formalDefaultsKey) }
    }

    private let recognizer: any VoiceSpeechRecognizer
    private let parser = VoiceCommandParser()
    private let cleaner = DictationCleaner()
    private var context: EditorModuleContext?
    private let logger = Logger(subsystem: "com.hiram.EditorFinal", category: "voice")

    /// - Parameters:
    ///   - recognizer: en producción se omite (usa el de Apple); en pruebas
    ///     se inyecta un doble sin micrófono.
    ///   - localeIdentifier: fuerza el idioma; si se omite, usa el recordado.
    ///   - preferences: almacén de las opciones del panel. Las pruebas pasan
    ///     `nil` para no leer ni escribir preferencias reales.
    public init(recognizer: (any VoiceSpeechRecognizer)? = nil, localeIdentifier: String? = nil, preferences: UserDefaults? = .standard) {
        let locale = localeIdentifier ?? preferences?.string(forKey: Self.localeDefaultsKey) ?? "es-MX"
        self.preferences = preferences
        self.localeIdentifier = locale
        self.pushToTalkEnabled = preferences?.object(forKey: Self.pushToTalkDefaultsKey) as? Bool ?? true
        self.continuousListening = preferences?.object(forKey: Self.continuousDefaultsKey) as? Bool ?? true
        self.formalStyle = preferences?.object(forKey: Self.formalDefaultsKey) as? Bool ?? true
        if let recognizer {
            self.recognizer = recognizer
        } else {
            self.recognizer = AppleSpeechRecognizer(localeIdentifier: locale)
        }
    }

    // MARK: - EditorInputModule (ciclo de vida)

    public func start(context: EditorModuleContext) async throws {
        self.context = context
    }

    public func stop() async {
        disablePushToTalk()
        stopMonitor()
        rewriteTask?.cancel()
        rewriteTask = nil
        recognitionGeneration += 1
        discardRewrite?()
        handsFreeActive = false
        microphoneReady = false
        pushToTalkHeld = false
        recognizer.onPartial = nil
        recognizer.onLevel = nil
        recoveredTranscript = nil
        startTask?.cancel()
        startTask = nil
        await recognizer.cancel()
        await cancelLivePreview()
        context = nil
        state = .idle
        partialTranscript = ""
        pendingAction = nil
    }

    // MARK: - Dictado (pulsar para hablar)

    public var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    /// Alterna dictado: empieza si está en reposo, termina si escucha.
    public func toggle() async {
        if pendingAction != nil && isListening {
            await cancelDictation()
        } else if isListening {
            await finish()
        } else if state == .processing {
            handsFreeActive = false
        } else {
            handsFreeActive = continuousListening
            await begin()
        }
    }

    /// Abre el micrófono. Pide permiso de micrófono y voz solo aquí,
    /// nunca al arrancar el editor. Arranca el monitor de cierre automático.
    public func begin() async {
        guard state == .idle || isFailed,
              pendingAction == nil || handsFreeActive else { return }
        guard recoveredTranscript == nil else {
            handsFreeActive = false
            lastCommandFeedback = "Decide primero qué hacer con el texto recuperado."
            return
        }
        state = .listening
        microphoneReady = false
        partialTranscript = ""
        inputLevel = 0
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognizer.onPartial = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self, self.isListening, self.recognitionGeneration == generation else { return }
                self.partialTranscript = text
                if self.voicePreviewStarted {
                    await self.context?.commandBus.send(.showVoicePreview(text))
                }
            }
        }
        recognizer.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == generation else { return }
                self.inputLevel = level
                self.noteInputLevel(level)
            }
        }
        let bus = context?.commandBus
        let showsPreview = handsFreeActive && pendingAction == nil
        voicePreviewStarted = showsPreview
        let task = Task {
            if showsPreview {
                try Task.checkCancellation()
                await bus?.send(.beginVoicePreview)
            }
            try await recognizer.start()
        }
        startTask = task
        defer { if startTask == task { startTask = nil } }
        do {
            try await task.value
            // Un arranque que termina tras cancelar no toca el estado ni la sesión nueva.
            guard recognitionGeneration == generation, isListening else { return }
            microphoneReady = true
            startMonitor()
        } catch {
            guard recognitionGeneration == generation else { return }
            await cancelLivePreview()
            handsFreeActive = false
            microphoneReady = false
            state = .failed(error.localizedDescription)
            logger.error("Voice begin failed")
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Cierra el micrófono y procesa el texto. Una mutación espera confirmación.
    /// Uso manual (botón "Terminar" o segundo toque): no rearma.
    public func finish() async {
        let commitDictation = handsFreeActive
        handsFreeActive = false
        await stopAndEmit(commitDictation: commitDictation)
    }

    /// Cierre automático por pausa. Conserva la escucha para responder a la propuesta.
    func autoFinish() async {
        await stopAndEmit(commitDictation: true)
        if continuousListening, handsFreeActive, state == .idle {
            await begin()
        } else {
            handsFreeActive = false
        }
    }

    /// Escucha la respuesta a una propuesta con o sin Manos libres.
    public func listenForPendingDecision() async {
        guard pendingAction != nil, !isListening else { return }
        handsFreeActive = true
        await begin()
    }

    // MARK: - Push-to-talk (`⌥Espacio`: mantener para hablar, soltar para cerrar)

    /// ¿Puede empezar una pulsación ahora? Síncrono para el monitor de teclas.
    var canBeginPushToTalk: Bool {
        pushToTalkEnabled && !pushToTalkHeld && (state == .idle || isFailed)
            && pendingAction == nil && recoveredTranscript == nil
    }

    /// Instala el hotkey global/local. La app real lo llama una vez tras
    /// `start`; las pruebas no lo llaman (sin monitores de teclas).
    public func enablePushToTalk() {
        if let existing = pushToTalk {
            existing.isEnabled = pushToTalkEnabled
            return
        }
        let monitor = VoicePushToTalk(
            onPress: { [weak self] in Task { @MainActor [weak self] in _ = self?.handlePushToTalkPress() } },
            onRelease: { [weak self] in Task { @MainActor [weak self] in self?.handlePushToTalkRelease() } }
        )
        monitor.isEnabled = pushToTalkEnabled
        monitor.start()
        pushToTalk = monitor
    }

    public func disablePushToTalk() {
        pushToTalk?.stop()
        pushToTalk = nil
    }

    /// Entrada del hotkey (síncrona): reserva `held` y arranca el micrófono en
    /// segundo plano. Devuelve si se consumió la pulsación.
    @discardableResult
    func handlePushToTalkPress() -> Bool {
        guard canBeginPushToTalk else { return false }
        pushToTalkHeld = true
        Task {
            await self.begin()
            if !self.isListening { self.pushToTalkHeld = false }
        }
        return true
    }

    /// Soltada del hotkey: cierra el enunciado por el camino normal
    /// (`stopAndEmit` → `process`), así dictado y comandos se conservan.
    func handlePushToTalkRelease() {
        guard pushToTalkHeld else { return }
        pushToTalkHeld = false
        Task { await self.finish() }
    }

    /// Atajos async para pruebas y para la UI sin teclas.
    public func beginPushToTalk() async {
        guard canBeginPushToTalk else { return }
        pushToTalkHeld = true
        await begin()
        if !isListening { pushToTalkHeld = false }
    }

    public func endPushToTalk() async {
        guard pushToTalkHeld else { return }
        pushToTalkHeld = false
        await finish()
    }

    private func stopAndEmit(commitDictation: Bool) async {
        guard isListening else { return }
        // Un arranque que falla o se cancela ya lo resuelve `begin`.
        if let startTask, (try? await startTask.value) == nil { return }
        guard isListening else { return }
        state = .processing
        microphoneReady = false
        recognitionGeneration += 1
        let generation = recognitionGeneration
        stopMonitor()
        recognizer.onPartial = nil
        recognizer.onLevel = nil
        do {
            let raw = try await recognizer.stop()
            guard recognitionGeneration == generation else { return }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await cancelLivePreview()
                if recognizer.hasSpeech {
                    state = .idle
                } else {
                    state = .failed("Silencio: revisa el micrófono y vuelve a intentarlo.")
                }
                return
            }
            if Self.isStopPhrase(raw) {
                await cancelLivePreview()
                handsFreeActive = false
                lastCommandFeedback = "Escucha detenida"
            } else if Self.isHelpPhrase(raw) {
                await cancelLivePreview()
                helpRequests += 1
                lastCommandFeedback = "Abrí los ejemplos en el panel de voz"
            } else if pendingAction != nil {
                await handlePendingSpeech(raw)
            } else if Self.decision(for: raw, pending: false) != nil {
                await cancelLivePreview()
                lastCommandFeedback = "No hay propuesta pendiente"
            } else {
                let intent = process(rawTranscript: raw)
                if commitDictation, Self.insertedText(for: intent) != nil {
                    lastTranscript = raw
                    let hadLivePreview = voicePreviewStarted
                    voicePreviewStarted = false
                    await emit(intent, livePreview: hadLivePreview)
                } else {
                    await cancelLivePreview()
                    await receive(intent, transcript: raw, generation: generation)
                }
            }
            if recognitionGeneration == generation && state == .processing { state = .idle }
        } catch {
            guard recognitionGeneration == generation else { return }
            await cancelLivePreview()
            handsFreeActive = false
            // Lo reconocido de esta sesión se guarda aparte: el documento no
            // cambia y nada se ejecuta hasta que la persona decida.
            let partial = recognizer.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let best = partial.isEmpty ? partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines) : partial
            partialTranscript = ""
            // Una respuesta a una propuesta («sí», «no») no es texto que recuperar.
            if best.isEmpty || pendingAction != nil {
                state = .failed(error.localizedDescription)
            } else {
                recoveredTranscript = best
                state = .failed("\(error.localizedDescription) Se recuperó parte del texto: revísalo antes de usarlo.")
            }
            logger.error("Voice finish failed")
        }
    }

    // MARK: - Texto recuperado tras un error

    /// Inserta el texto recuperado tal cual, como texto incompleto. Solo por
    /// decisión explícita; nunca se interpreta como orden.
    public func insertRecoveredTranscript() async {
        guard let text = recoveredTranscript else { return }
        guard let bus = context?.commandBus else {
            state = .failed("Voz sin conectar al editor. Reinicia la app.")
            return
        }
        recoveredTranscript = nil
        state = .idle
        lastTranscript = text
        lastInsertedText = text
        lastCommandFeedback = "Texto incompleto insertado. «Deshacer» lo revierte."
        await bus.send(.insertText(text))
    }

    /// Descarta el texto recuperado sin tocar el documento.
    public func discardRecoveredTranscript() {
        guard recoveredTranscript != nil else { return }
        recoveredTranscript = nil
        state = .idle
        lastCommandFeedback = "Texto recuperado descartado"
    }

    // MARK: - Cierre automático por pausa (sin botón de terminar)

    private func startMonitor() {
        stopMonitor()
        lastSeenPartial = ""
        lastPartialChange = now()
        lastVoiceActivity = now()
        monitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                self.checkAutoFinish()
            }
        }
    }

    private func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func checkAutoFinish() {
        guard autoFinishDue() else { return }
        Task { await self.autoFinish() }
    }

    /// ¿Toca cerrar el enunciado por pausa? Anota cambios del parcial.
    /// Push-to-talk nunca cierra por pausa: cierra al soltar la tecla.
    /// Interna para pruebas (@testable), con el reloj `now`.
    func autoFinishDue() -> Bool {
        guard isListening, handsFreeActive, !pushToTalkHeld else { return false }
        let current = partialTranscript
        let time = now()
        if current != lastSeenPartial {
            lastSeenPartial = current
            lastPartialChange = time
            return false
        }
        return Self.endpointReached(partial: current,
                                    unchangedFor: time.timeIntervalSince(lastPartialChange),
                                    quietFor: time.timeIntervalSince(lastVoiceActivity),
                                    timeout: autoEndpointSilence)
    }

    /// Un nivel sostenido puede ser voz: no se aprende como ruido ni se
    /// eleva el umbral mientras se habla. Interna para pruebas.
    func noteInputLevel(_ level: Float) {
        guard isListening else { return }
        if level > recognizer.voiceThreshold {
            lastVoiceActivity = now()
        }
    }

    /// Decisión pura del endpoint: parcial no vacío, estable por `timeout` y
    /// sin voz en el micrófono por `timeout`. Si Speech se atrasa mientras se
    /// sigue hablando, el audio activo impide cortar. El silencio total
    /// (parcial vacío) nunca cierra solo: el usuario detiene.
    nonisolated static func endpointReached(partial: String, unchangedFor: TimeInterval,
                                            quietFor: TimeInterval, timeout: TimeInterval) -> Bool {
        !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && unchangedFor >= timeout && quietFor >= timeout
    }

    /// Descarta la grabación sin insertar nada. "Cancelar" por voz hace lo mismo.
    public func cancelDictation() async {
        stopMonitor()
        if let task = rewriteTask {
            rewriteTask = nil
            task.cancel()
            discardRewrite?()
            lastCommandFeedback = "Reescritura cancelada"
        }
        recognitionGeneration += 1
        handsFreeActive = false
        microphoneReady = false
        recognizer.onPartial = nil
        recognizer.onLevel = nil
        // Sin esperar permisos ni descargas: el reconocedor invalida el
        // arranque pendiente y `begin` ignora su respuesta tardía.
        startTask?.cancel()
        startTask = nil
        await recognizer.cancel()
        await cancelLivePreview()
        state = .idle
        partialTranscript = ""
    }

    // MARK: - Intención → comandos

    /// Convierte una transcripción cruda en su intención final.
    /// Orden: legacy (frases exactas cortas) → gramática completa probada →
    /// dictado. Lo no accionable (unsupported/unknown/múltiple) cae a dictado,
    /// jamás se inserta como comando.
    func process(rawTranscript raw: String) -> VoiceIntent {
        if let legacy = parser.parse(raw) {
            return legacy
        }
        if let cmd = fullCommand(raw) {
            return .command(cmd)
        }
        let cleaned = cleaner.clean(raw, formal: formalStyle)
        // Un dictado que solo deja saltos («eh, nueva línea») es ese salto.
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if cleaned.contains("\n\n") { return .paragraph }
            return cleaned.contains("\n") ? .newline : .cancel
        }
        return .dictation(cleaned)
    }

    /// Gramática probada (`CommandGrammar`, fuente única). Si el raw no da una
    /// acción, se reintenta con la adaptación "cambia el título de X" → "a X"
    /// (el STT confunde a/de); `Grammar.swift` no se toca.
    func fullCommand(_ raw: String) -> ParsedCommand? {
        let first = parseCommand(raw: raw)
        if Self.isActionable(first) { return first }
        if let adapted = Self.adaptTitleDe(raw) {
            let second = parseCommand(raw: adapted)
            if Self.isActionable(second) { return second }
        }
        return nil
    }

    static func isActionable(_ cmd: ParsedCommand) -> Bool {
        switch cmd {
        case .unsupported, .unknown, .multipleActions: return false
        default: return true
        }
    }

    /// "Cambia el título de X" → "Cambia el título a X" (mismo largo en
    /// caracteres: el folding no expande estos prefijos). Solo para parsear;
    /// el dictado usa siempre el raw original.
    static func adaptTitleDe(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es_MX"))
        let prefix = "cambia el titulo de "
        guard folded.hasPrefix(prefix), folded.count > prefix.count else { return nil }
        return "Cambia el título a " + String(trimmed.dropFirst(prefix.count))
    }

    /// Texto que la intención escribe tal cual (dictado y saltos de línea).
    /// En Manos libres se inserta al cerrar la pausa, igual que el dictado.
    static func insertedText(for intent: VoiceIntent) -> String? {
        switch intent {
        case .dictation(let text): return text.isEmpty ? nil : text
        case .newline: return "\n"
        case .paragraph: return "\n\n"
        default: return nil
        }
    }

    /// Traduce una intención a comandos del editor.
    /// `deleteLastInsertion` es undo: borra la última inserción del editor.
    func editorCommands(for intent: VoiceIntent) -> [EditorCommand] {
        switch intent {
        case .dictation(let text):
            return text.isEmpty ? [] : [.insertText(text)]
        case .newline:
            return [.insertText("\n")]
        case .paragraph:
            return [.insertText("\n\n")]
        case .undo, .deleteLastInsertion:
            return [.undo]
        case .command(let cmd):
            return editorCommands(for: cmd)
        case .cancel:
            return []
        }
    }

    /// Gramática probada → `EditorCommand`. Reglas:
    /// - find/select: inmediatos, solo mueven selección (la sesión no muta).
    /// - delete sin selección: no-op en sesión (nunca inserta ni borra de más).
    /// - rewrite: la sesión genera antes de confirmar; la aceptación aplica el texto visible.
    /// - unsupported/unknown/múltiple: 0 comandos (el dictado ya los cubrió
    ///   como fallback en `process`; aquí nunca llegan, pero se blindan).
    func editorCommands(for command: ParsedCommand) -> [EditorCommand] {
        switch command {
        case .renameTitle(let t):
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.renameTitle(t)]
        case .deleteSelection:
            return [.replaceSelection("")]
        case .replaceSelection(let t):
            return [.replaceSelection(t)]
        case .rewriteSelection(let instruction):
            return instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [.rewriteSelection(instruction)]
        case .formatSelection(let style):
            switch style {
            case .bold: return [.toggleBold]
            case .italic: return [.toggleItalic]
            case .underline: return [.toggleUnderline]
            }
        case .undo:
            return [.undo]
        case .redo:
            return [.redo]
        case .selectText(let q):
            return q.isEmpty ? [] : [.selectText(q)]
        case .findText(let q):
            return q.isEmpty ? [] : [.findText(q)]
        case .saveDocument:
            return [.saveDocument]
        case .openDocument(let name):
            return [.openDocument(name)]
        case .exportDocument(let format):
            switch format {
            case .pdf: return [.exportDocument("pdf")]
            case .plainText: return [.exportDocument("txt")]
            case .richText: return [.exportDocument("rtf")]
            case .word: return [.exportDocument("word")]
            }
        case .unsupported, .unknown, .multipleActions:
            return []
        }
    }

    /// Texto del HUD tras ejecutar ("Guardado", "Título: X"…). Sin esto los
    /// comandos automáticos serían invisibles.
    func feedback(for command: ParsedCommand) -> String {
        switch command {
        case .renameTitle(let t): return "Título: \(t)"
        case .deleteSelection: return "Selección eliminada — «deshacer» revierte"
        case .replaceSelection(let t): return "Reemplazado por «\(t)» — «deshacer» revierte"
        case .rewriteSelection: return "Reescribí la selección. «Deshacer» revierte el cambio."
        case .formatSelection(let s):
            let name: String
            switch s {
            case .bold: name = "negritas"
            case .italic: name = "cursiva"
            case .underline: name = "subrayado"
            }
            return "Formato: \(name) — «deshacer» revierte"
        case .undo: return "Deshecho"
        case .redo: return "Rehecho"
        case .selectText(let q): return "Seleccionado: «\(q)»"
        case .findText(let q): return "Buscado: «\(q)»"
        case .saveDocument: return "Documento guardado"
        case .openDocument: return "Abriendo documento…"
        case .exportDocument(let f):
            switch f {
            case .pdf: return "Exportando PDF…"
            case .plainText: return "Exportando texto…"
            case .richText: return "Exportando RTF…"
            case .word: return "Exportando Word…"
            }
        case .unsupported: return "Ese comando no está disponible"
        case .unknown: return "No entendí el comando"
        case .multipleActions: return "Una acción a la vez, por favor"
        }
    }

    private func receive(_ intent: VoiceIntent, transcript: String, generation: Int) async {
        lastTranscript = transcript
        if intent == .cancel {
            partialTranscript = ""
            return
        }
        let commands = editorCommands(for: intent)
        guard !commands.isEmpty else {
            if case .command(let command) = intent { lastCommandFeedback = feedback(for: command) }
            partialTranscript = ""
            return
        }
        if case .command(.rewriteSelection(let instruction)) = intent {
            lastCommandFeedback = "Preparando la propuesta con IA…"
            let prepare = prepareRewrite
            let task = Task<String, any Error> {
                try Task.checkCancellation()
                guard let prepare else { throw ModelFailure.notEditable }
                return try await prepare(instruction)
            }
            rewriteTask = task
            let result = await task.result
            guard rewriteTask == task else { return }
            rewriteTask = nil
            guard recognitionGeneration == generation, context != nil else { return }
            let proposal: String
            switch result {
            case .success(let text):
                proposal = text
            case .failure(let error):
                // Cancelar o reemplazar la petición no es un fallo: no se avisa.
                if let failure = ModelFailure.classify(error) {
                    lastCommandFeedback = "No se pudo preparar la propuesta. \(failure.message)"
                }
                partialTranscript = ""
                return
            }
            pendingAction = PendingVoiceAction(
                transcript: transcript, intent: intent,
                preview: "Reescribir selección: «\(instruction)»\n\nPropuesta:\n\(proposal)"
            )
            lastCommandFeedback = ""
            partialTranscript = ""
        } else if case .command(.findText) = intent {
            await emit(intent)
        } else if case .command(.selectText) = intent {
            await emit(intent)
        } else {
            pendingAction = PendingVoiceAction(transcript: transcript, intent: intent, preview: preview(for: intent))
            lastCommandFeedback = ""
            partialTranscript = ""
        }
    }

    private func handlePendingSpeech(_ raw: String) async {
        switch Self.decision(for: raw, pending: true) {
        case .confirm:
            await confirmPending()
        case .discard:
            cancelPending()
        case .repeatAction:
            discardRewrite?()
            pendingAction = nil
            lastCommandFeedback = "Repite la frase"
        case .asText:
            usePendingAsDictation()
        default:
            lastCommandFeedback = Self.decisionHint
        }
        partialTranscript = ""
    }

    private static func spokenAction(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_MX"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isStopPhrase(_ raw: String) -> Bool {
        ["detener voz", "deten la voz", "deten voz", "apaga la voz", "apaga el microfono",
         "termina el dictado", "terminar dictado", "detener dictado", "deja de escuchar"]
            .contains(spokenAction(raw))
    }

    private static func isHelpPhrase(_ raw: String) -> Bool {
        ["que puedo decir", "ayuda de voz", "comandos de voz", "muestra los comandos"]
            .contains(spokenAction(raw))
    }

    private func cancelLivePreview() async {
        guard voicePreviewStarted else { return }
        voicePreviewStarted = false
        await context?.commandBus.send(.cancelVoicePreview)
    }

    private enum SpokenDecision { case confirm, discard, repeatAction, asText }

    /// Respuesta hablada a una propuesta. Las formas cortas («sí», «no»,
    /// «otra vez»…) solo valen con una propuesta a la vista: sin ella son
    /// palabras normales de un dictado.
    private static func decision(for raw: String, pending: Bool) -> SpokenDecision? {
        let spoken = spokenAction(raw)
        switch spoken {
        case "confirmar", "confirma", "aceptar", "acepta", "confirmar la propuesta": return .confirm
        case "descartar", "descarta", "cancelar", "cancela": return .discard
        case "repetir", "repite", "intentar de nuevo": return .repeatAction
        case "usar como texto": return .asText
        default: break
        }
        guard pending else { return nil }
        switch spoken {
        case "si", "ok", "okay", "vale", "dale", "adelante", "hazlo", "correcto", "de acuerdo", "listo":
            return .confirm
        case "no", "mejor no", "olvidalo", "dejalo":
            return .discard
        case "otra vez", "de nuevo", "repite la frase":
            return .repeatAction
        case "es texto", "era texto", "como texto", "usalo como texto", "escribelo":
            return .asText
        default:
            return nil
        }
    }

    private func preview(for intent: VoiceIntent) -> String {
        switch intent {
        case .dictation(let text): return "Insertar: \"\(text)\""
        case .newline: return "Insertar salto de línea"
        case .paragraph: return "Insertar párrafo"
        case .undo, .deleteLastInsertion: return "Deshacer último cambio"
        case .command(let command):
            switch command {
            case .renameTitle(let title): return "Cambiar título a: \"\(title)\""
            case .replaceSelection(let text): return "Reemplazar selección por: \"\(text)\""
            case .rewriteSelection(let instruction): return "Reescribir selección: «\(instruction)»"
            case .deleteSelection: return "Eliminar selección"
            case .formatSelection(let style): return "Aplicar formato: \(style.rawValue)"
            case .undo: return "Deshacer último cambio"
            case .redo: return "Rehacer último cambio"
            case .saveDocument: return "Guardar documento"
            case .openDocument(let name): return "Abrir: \(name ?? "elegir documento")"
            case .exportDocument(let format): return "Exportar: \(format.rawValue)"
            default: return feedback(for: command)
            }
        case .cancel: return ""
        }
    }

    public func confirmPending() async {
        guard let action = pendingAction else { return }
        if case .dictation(let text) = action.intent,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        pendingAction = nil
        if isListening && !continuousListening { await cancelDictation() }
        if case .command(.rewriteSelection) = action.intent {
            lastCommandFeedback = acceptRewrite?() == true
                ? "Selección reescrita — «deshacer» revierte"
                : "La propuesta caducó porque cambió la selección o el documento."
            return
        }
        await emit(action.intent)
    }

    public func updatePendingDictation(_ text: String) {
        guard let action = pendingAction, action.isDictation else { return }
        let intent = VoiceIntent.dictation(text)
        pendingAction = PendingVoiceAction(transcript: action.transcript, intent: intent, preview: preview(for: intent))
    }

    public func cancelPending() {
        guard pendingAction != nil else { return }
        discardRewrite?()
        pendingAction = nil
        lastCommandFeedback = "Propuesta descartada"
    }

    /// Si una frase era dictado, conserva el transcript y cambia la propuesta.
    public func usePendingAsDictation() {
        guard let action = pendingAction else { return }
        if case .dictation = action.intent { return }
        let text = cleaner.clean(action.transcript, formal: formalStyle)
        guard !text.isEmpty else { return }
        discardRewrite?()
        let intent = VoiceIntent.dictation(text)
        pendingAction = PendingVoiceAction(transcript: action.transcript, intent: intent, preview: preview(for: intent))
    }

    public func repeatPending() async {
        guard pendingAction != nil else { return }
        discardRewrite?()
        pendingAction = nil
        lastCommandFeedback = ""
        if isListening && !continuousListening { await cancelDictation() }
        await begin()
    }

    private func emit(_ intent: VoiceIntent, livePreview: Bool = false) async {
        guard let bus = context?.commandBus else {
            state = .failed("Voz sin conectar al editor. Reinicia la app.")
            return
        }
        let commands: [EditorCommand]
        if livePreview, let text = Self.insertedText(for: intent) {
            commands = [.commitVoicePreview(text)]
        } else {
            commands = editorCommands(for: intent)
        }
        switch intent {
        case .dictation(let text):
            lastInsertedText = text
            lastCommandFeedback = ""
        case .command(let cmd):
            lastInsertedText = ""
            lastCommandFeedback = feedback(for: cmd)
        case .undo, .deleteLastInsertion:
            lastInsertedText = ""
            lastCommandFeedback = "Deshecho"
        case .newline:
            lastInsertedText = ""
            lastCommandFeedback = "Nueva línea"
        case .paragraph:
            lastInsertedText = ""
            lastCommandFeedback = "Nuevo párrafo"
        default:
            lastInsertedText = ""
            lastCommandFeedback = ""
        }
        for command in commands {
            await bus.send(command)
        }
        partialTranscript = ""
    }
}
