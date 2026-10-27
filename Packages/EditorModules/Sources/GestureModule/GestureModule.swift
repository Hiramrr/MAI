import EditorCore
import Foundation
import ModuleKit
import Observation

/// Sesión de pinza sobre una palabra: pinzar abre las opciones,
/// mover cambia el preview en el documento, soltar confirma.
///
/// Todo el cómputo es local. El preview no toca undo ni el guardado
/// hasta confirmar (entonces queda un único undo, como escribir).
struct PinchSession: Sendable {
    let id: UUID
    let word: String
    let location: Int
    var alternatives: [String]
    var currentIndex: Int
    var referenceX: Double
    /// Sesión de tono: `word` es la oración completa y las alternativas son
    /// fijas, [fría, original, cálida].
    var isTone = false
    /// Niveles de tono sin versión válida, con su motivo. No se pueden
    /// previsualizar ni confirmar.
    var unavailable: [Int: String] = [:]

    var option: String { alternatives[currentIndex] }
}

/// Sesión a dos manos sobre un párrafo: mostrar ambas manos abre las
/// versiones de longitud, acercar/separar cambia el preview en el
/// documento, retirar una mano confirma.
///
/// Las versiones se generan en este Mac. Mientras llegan, el gesto espera
/// sin aplicar texto incompleto.
struct LengthSession: Sendable {
    let id: UUID
    let originalText: String
    let originalLocation: Int
    /// Orden fijo: [corta, media (= original), larga].
    var alternatives: [String]
    var currentIndex: Int
    var referenceSpan: Double
    /// Niveles sin versión válida, con su motivo. No se pueden previsualizar
    /// ni confirmar; su hueco en `alternatives` guarda el original.
    var unavailable: [Int: String] = [:]

    var option: String { alternatives[currentIndex] }
}

/// Qué párrafo admite el cambio de longitud.
enum LengthTarget: Equatable {
    /// Rango UTF-16 del texto de prosa (sin marcas de cita o lista).
    case prose(NSRange)
    /// Hay algo bajo el cursor, pero no es prosa; lleva la explicación.
    case refused(String)
    /// No hay párrafo bajo el cursor.
    case none
}

/// Generación con IA en curso. `key` es el texto que genera; `id` distingue
/// la tarea vigente de una reemplazada que genera el mismo texto.
struct ModelJob {
    let key: String
    let id: UUID
    let task: Task<Void, Never>
}

struct ImageSizeSession {
    let original: MarkdownImage
    let originalText: String
    let location: Int
    var width: Int
    var referenceSpan: Double

    var markdown: String {
        MarkdownImage(alt: original.alt, path: original.path, width: width,
                      alignment: original.alignment).markdown
    }
}

/// Entrada por gestos con la cámara local, como pieza extraíble.
///
/// - El índice señala y selecciona la palabra, la oración o el párrafo bajo el cursor.
/// - Pinza sobre una palabra → muestra sinónimos locales; mover elige, soltar confirma.
/// - En modo oración, la pinza cambia el tono (frío ↔ cálido, generado en el Mac);
///   mover elige, soltar confirma.
/// - En modo párrafo, la pinza toma el párrafo; mover y soltar lo reordena.
/// - Perder la mano → cancela y restaura el texto.
/// - Pinza + barrido lateral amplio → deshacer/rehacer (una vez por pinza).
/// - Dos manos + acercar/separar → cambia la longitud del párrafo
///   (corto/medio/largo generados en el Mac); retirar UNA mano confirma, perder AMBAS
///   restaura (nunca se confirma a ciegas).
/// - Si el cursor está sobre una imagen, el mismo gesto ajusta su ancho.
///
/// El módulo nunca toca `NSTextView` ni el motor de texto:
/// - Navegación y deshacer/rehacer viajan como `EditorCommand` por el bus
///   (en orden FIFO; la sesión los valida contra el texto vigente).
/// - Las previews viajan como comandos atómicos
///   (`beginPreview`/`showPreview`/`commitPreview`/`cancelPreview`) que
///   `EditorSession` aplica sin ensuciar undo ni guardado.
/// - El documento llega por `updateDocument(text:selection:)` (instantánea
///   de valores, sin referencias a vistas). Si el texto cambia por fuera
///   durante una sesión, se cancela, no se aplica a ciegas.
@MainActor @Observable
public final class GestureModule: EditorInputModule {
    public nonisolated let identifier = "gestures.hand"
    public nonisolated let displayName = "Gestos"

    public static var descriptor: ModuleDescriptor {
        ModuleDescriptor(identifier: "gestures.hand", displayName: "Gestos")
    }

    public var running = false
    public var starting = false
    public private(set) var paused = false
    public var message = "Cámara apagada"
    public var state = GestureState()
    /// Qué señala el índice: palabras, oraciones o párrafos.
    public var navigationUnit = GestureUnit.stored {
        didSet {
            navigationX = nil
            if paragraphDragSource != nil { requiresRelease = true }
            paragraphDragSource = nil
            paragraphDropTarget = nil
            UserDefaults.standard.set(navigationUnit.rawValue, forKey: GestureUnit.key)
        }
    }
    public var navigateByParagraph: Bool {
        get { navigationUnit == .parrafo }
        set {
            if newValue {
                navigationUnit = .parrafo
            } else if navigationUnit == .parrafo {
                navigationUnit = .palabra
            }
        }
    }

    private var commandBus: EditorCommandBus?
    @ObservationIgnored public var imageHitTest: ((CGPoint?) -> NSRange?)?
    @ObservationIgnored public var textHitTest: ((CGPoint) -> Int?)?
    public internal(set) var cursorPoint: CGPoint?
    var pointedImageRange: NSRange?
    public var isPointingAtImage: Bool { pointedImageRange != nil }
    /// Mejora de sinónimos con IA (on-device). Por defecto Foundation Models
    /// con fallback local; en pruebas se inyecta un doble sin modelo.
    let synonymProvider: any SynonymProvider
    let lengthProvider: any LengthProvider
    let toneProvider: any ToneProvider

    // @Observable no admite `lazy`: inicialización explícita a demanda.
    // La cámara solo existe si el usuario la activa: sin la pieza (o sin
    // activarla) el programa jamás pide permiso de cámara.
    private var _camera: CameraManager?
    public var camera: CameraManager {
        if let _camera { return _camera }
        let manager = CameraManager { [weak self] message in
            Task { @MainActor [weak self] in
                self?.cameraDidFail(message)
            }
        }
        _camera = manager
        return manager
    }

    private var task: Task<Void, Never>?

    // Instantánea del documento (la empuja la app, sin vistas de por medio).
    var cachedText = ""
    var cachedSelection = NSRange(location: 0, length: 0)
    private var rangedText = ""
    private var cachedWordRanges: [NSRange] = []
    private var paragraphText = ""
    private var cachedParagraphRanges: [NSRange] = []
    private var sentenceText = ""
    private var cachedSentenceRanges: [NSRange] = []
    var navigationX: Double?
    var paragraphDragSource: NSRange?
    var paragraphDropTarget: NSRange?
    public var isDraggingParagraph: Bool { paragraphDragSource != nil }

    // Sesión de pinza. Interna para pruebas (@testable): simulan el avance
    // del preview sin cámara.
    var pinchSession: PinchSession?
    var sessionLastHandX = 0.0
    /// Ancla del barrido deshacer/rehacer: posición X al cerrar la pinza.
    /// Si la mano barre más de `undoSwipeDistance` antes de que abra la
    /// sesión de sinónimos, el gesto es deshacer/rehacer (una vez por pinza).
    var undoSwipeAnchor: Double?
    var undoSwipeFired = false
    /// Pinza sostenida: la sesión abre tras varios frames (evita roces).
    var pinchStreak = 0
    /// Pinza del frame anterior: la pinza efectiva exige 2 frames seguidos
    /// (un parpadeo aislado no interrumpe la navegación ni abre sesiones).
    var lastRawPinch = false
    var requiresRelease = false
    var trackingLostAt: TimeInterval?
    /// Frames válidos seguidos con la mano abierta y sesión activa.
    /// Confirma al llegar a 3: el evento .ended aislado se pierde con parpadeos.
    var openStreak = 0
    /// Desplazamiento actual respecto a la referencia (para guiar en la UI).
    public internal(set) var sessionDelta = 0.0
    /// La lista actual ya incluye sinónimos de IA (si no, locales).
    public internal(set) var sessionUpgraded = false
    /// Por qué la IA no mejoró la lista de la sesión actual (nil si no falló).
    public internal(set) var synonymNotice: String?
    var upgradeJob: ModelJob?
    /// Caché de sinónimos de IA por palabra (minúsculas): reabrir la misma
    /// palabra reusa al instante sin regenerar con el modelo.
    /// Solo se guardan respuestas no vacías; los fallos no se cachean
    /// para poder reintentar.
    var synonymCache: [String: [String]] = [:]
    /// Estado de la IA para la UI (panel y ajustes).
    public var synonymProviderAvailable: Bool { synonymProvider.isAvailable }
    public var synonymProviderReason: String? { synonymProvider.availabilityReason }

    /// Sesión de tono: generando las versiones fría y cálida.
    public internal(set) var toneLoading = false
    var toneJob: ModelJob?
    /// Caché de tonos por oración original; valor: (fría, cálida), con nil
    /// en la que no salió válida.
    var toneCache: [String: VariantPair] = [:]

    /// Sesión iniciada desde un botón (sin cámara): solo la tarjeta la mueve.
    var pinchManualControl = false
    public var isPinchManual: Bool { pinchManualControl }

    /// Calibración guiada a la mano del usuario.
    public internal(set) var calibration: GestureCalibrationRun?
    public internal(set) var calibrationMessage: String?
    public internal(set) var openMedian: Double?
    public internal(set) var pinchMedian: Double?

    /// Lecturas para la tarjeta de opciones (observadas por SwiftUI).
    public var hasPinchSession: Bool { pinchSession != nil }
    public var sessionOptions: [String] { pinchSession?.alternatives ?? [] }
    public var sessionIndex: Int { pinchSession?.currentIndex ?? 0 }
    /// Offset de la palabra en sesión.
    public var sessionLocation: Int? { pinchSession?.location }

    // MARK: - Sesión a dos manos (longitud del párrafo)

    var lengthSession: LengthSession?
    var imageSizeSession: ImageSizeSession?
    var imageManualControl = false
    public var hasImageSizeSession: Bool { imageSizeSession != nil }
    public var imageWidth: Int { imageSizeSession?.width ?? 0 }
    public var isImageSizeManual: Bool { imageManualControl }
    var lengthJob: ModelJob?
    public internal(set) var lengthLoading = false
    /// Caché de variantes por párrafo original: reabrir el mismo párrafo
    /// (p. ej. tras Deshacer) no regenera con la IA, reusa al instante.
    /// Clave: texto original; valor: (corta, larga), con nil en la que no
    /// salió válida.
    var lengthCache: [String: VariantPair] = [:]
    var lengthLastSpan = 0.0
    /// Separación suavizada (media móvil exponencial). Congelada durante
    /// pérdidas de seguimiento: al volver, el re-anclaje excluye el salto.
    var lengthSmoothedSpan: Double?
    /// Momentos (uptime) de detecciones recientes con dos manos.
    /// Abrir exige varias dentro de una ventana corta: tolera parpadeos.
    var lengthTwoHandHits: [TimeInterval] = []
    /// Frames seguidos con una sola mano y sesión activa (confirma).
    var lengthOpenStreak = 0
    /// Tras confirmar/cancelar hay que separar las manos para otra sesión.
    var lengthRequiresRelease = false
    /// Sesión iniciada desde el botón (sin cámara): solo la tarjeta la mueve.
    var lengthManualControl = false
    var lengthTrackingLostAt: TimeInterval?
    /// Desplazamiento actual de la separación (para guiar en la UI).
    public internal(set) var lengthSessionDelta = 0.0

    /// Lecturas para la tarjeta de longitud (observadas por SwiftUI).
    public var hasLengthSession: Bool { lengthSession != nil }
    public var lengthOptions: [String] {
        guard let s = lengthSession else { return [] }
        if lengthLoading { return ["Preparando versión corta…", s.alternatives[1], "Preparando versión larga…"] }
        return s.alternatives.indices.map { s.unavailable[$0] ?? s.alternatives[$0] }
    }
    /// Motivo por el que un nivel no se puede usar (nil si se puede).
    public func lengthUnavailableReason(at index: Int) -> String? {
        lengthSession?.unavailable[index]
    }
    public var lengthIndex: Int { lengthSession?.currentIndex ?? LengthLevel.medio.rawValue }
    public var lengthLabels: [String] { LengthLevel.allCases.map(\.label) }
    public var isLengthManual: Bool { lengthManualControl }
    /// Texto original del párrafo en sesión (para marcar filas idénticas).
    public var lengthOriginalText: String { lengthSession?.originalText ?? "" }
    /// Confirmación visible tras aplicar un nivel, con Deshacer en un clic.
    public internal(set) var lengthToast: String?
    /// Si el toast confirma un cambio real (con "Sin cambios" no hay nada que deshacer).
    public internal(set) var lengthToastCanUndo = true

    public init(synonymProvider: (any SynonymProvider)? = nil,
                lengthProvider: (any LengthProvider)? = nil,
                toneProvider: (any ToneProvider)? = nil) {
        // Sin inyección (producción): IA on-device si hay modelo, locales si no.
        self.synonymProvider = synonymProvider ?? FoundationModelsSynonymProvider()
        self.lengthProvider = lengthProvider ?? FoundationModelsLengthProvider()
        self.toneProvider = toneProvider ?? FoundationModelsToneProvider()
    }

    // MARK: - EditorInputModule

    public func start(context: EditorModuleContext) async throws {
        commandBus = context.commandBus
    }

    public func stop() async {
        deactivateCamera()
        commandBus = nil
    }

    // MARK: - Instantánea del documento

    /// La app empuja texto+selección (valores, sin vistas). Barato: los rangos
    /// de palabra se recalculan bajo demanda, no en cada pulsación.
    public func updateDocument(text: String, selection: NSRange) {
        if paragraphDragSource != nil, text != cachedText {
            paragraphDragSource = nil
            paragraphDropTarget = nil
            requiresRelease = true
        }
        cachedText = text
        cachedSelection = selection
        guard commandBus != nil else { return }
        reconcileSessions(with: text)
    }

    func currentWordRanges() -> [NSRange] {
        if cachedText != rangedText {
            rangedText = cachedText
            cachedWordRanges = Self.wordRanges(in: cachedText)
            navigationX = nil
        }
        return cachedWordRanges
    }

    func currentParagraphRanges() -> [NSRange] {
        if cachedText != paragraphText {
            paragraphText = cachedText
            cachedParagraphRanges = []
            let ns = cachedText as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
                if range.length > 0 { self.cachedParagraphRanges.append(range) }
            }
            navigationX = nil
        }
        return cachedParagraphRanges
    }

    func currentSentenceRanges() -> [NSRange] {
        if cachedText != sentenceText {
            sentenceText = cachedText
            cachedSentenceRanges = GestureSentences.ranges(in: cachedText)
            navigationX = nil
        }
        return cachedSentenceRanges
    }

    func currentNavigationRanges() -> [NSRange] {
        switch navigationUnit {
        case .palabra: currentWordRanges()
        case .oracion: currentSentenceRanges()
        case .parrafo: currentParagraphRanges()
        }
    }

    private static func wordRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in
            out.append(range)
        }
        return out
    }

    /// Si el texto cambió por fuera durante una sesión, se cancela la sesión
    /// (nunca se confirma a ciegas). Durante la propia preview el binding no
    /// cambia, así que la base sigue intacta y no hay cancelaciones falsas.
    /// Si algún eco de la preview llegara igual, se acepta la opción actual
    /// como intacta: solo lo ajeno a palabra Y opción cancela.
    private func reconcileSessions(with text: String) {
        let ns = text as NSString
        if let s = pinchSession {
            if !spanMatches(s.location, length: (s.word as NSString).length, text: s.word, in: ns)
                && !spanMatches(s.location, length: (s.option as NSString).length, text: s.option, in: ns) {
                cancelPinchSession()
            }
        }
        if let s = lengthSession {
            if !spanMatches(s.originalLocation, length: (s.originalText as NSString).length, text: s.originalText, in: ns)
                && !spanMatches(s.originalLocation, length: (s.option as NSString).length, text: s.option, in: ns) {
                cancelLengthSession()
            }
        }
        if let s = imageSizeSession {
            if !spanMatches(s.location, length: (s.originalText as NSString).length,
                            text: s.originalText, in: ns)
                && !spanMatches(s.location, length: (s.markdown as NSString).length,
                                text: s.markdown, in: ns) {
                cancelImageSizeSession()
            }
        }
    }

    private func spanMatches(_ location: Int, length: Int, text: String, in ns: NSString) -> Bool {
        let span = NSRange(location: location, length: length)
        return NSMaxRange(span) <= ns.length && ns.substring(with: span) == text
    }

    func send(_ command: EditorCommand) async {
        await commandBus?.send(command)
    }

    // MARK: - Cámara

    /// Abre la cámara. Pide permiso de cámara solo aquí, nunca al arrancar.
    public func activateCamera() async {
        guard !starting, !running else { return }
        starting = true
        defer { starting = false }
        do {
            _ = try await camera.start()
            running = true
            paused = false
            navigationX = nil
            trackingLostAt = nil
            lastRawPinch = false
            message = navigationUnit.startMessage
            // Con la cámara encendida es probable pedir sinónimos, tono o
            // longitud: cargar el modelo ahora acorta la primera respuesta.
            synonymProvider.prewarm()
            // Un único consumidor del AsyncStream durante toda la vida del
            // objeto: crearlo por arranque dividía la entrega de frames.
            ensureConsumer()
        } catch {
            message = error.localizedDescription
        }
    }

    public func deactivateCamera() {
        // No se cancela el consumidor: aparcado sin frames, se reutiliza
        // al arrancar de nuevo.
        cancelPinchSession()
        paragraphDragSource = nil
        paragraphDropTarget = nil
        cancelImageSizeSession()
        cursorPoint = nil
        pointedImageRange = imageHitTest?(nil)
        _camera?.stop()
        running = false
        paused = false
        navigationX = nil
        trackingLostAt = nil
        lengthTrackingLostAt = nil
        lengthTwoHandHits = []
        lengthSmoothedSpan = nil
        lengthToast = nil
        lengthOpenStreak = 0
        lengthRequiresRelease = false
        lengthManualControl = false
        lengthSessionDelta = 0
        openStreak = 0
        pinchStreak = 0
        lastRawPinch = false
        undoSwipeAnchor = nil
        undoSwipeFired = false
        sessionDelta = 0
        calibration = nil
        calibrationMessage = nil
        state = GestureState()
        message = "Cámara apagada"
    }

    /// Detiene las acciones sin cerrar la cámara. Toda vista previa activa se
    /// restaura antes de aceptar otro gesto.
    public func setGesturesPaused(_ shouldPause: Bool) async {
        guard running, paused != shouldPause else { return }
        paused = shouldPause
        if shouldPause {
            paragraphDragSource = nil
            paragraphDropTarget = nil
            if pinchSession != nil { await cancelSession(reason: "gestos en pausa") }
            if lengthSession != nil { await cancelLengthSession(reason: "gestos en pausa") }
            if imageSizeSession != nil { await finishImageSizeSession(commit: false) }
            calibration = nil
            calibrationMessage = nil
            cursorPoint = nil
            pointedImageRange = imageHitTest?(nil)
            navigationX = nil
            pinchStreak = 0
            lastRawPinch = false
            undoSwipeAnchor = nil
            undoSwipeFired = false
            lengthTwoHandHits = []
            requiresRelease = true
            lengthRequiresRelease = true
        }
        message = shouldPause ? "Gestos en pausa. La cámara sigue encendida." : "Gestos activos. Muestra una mano para navegar."
    }

    private func ensureConsumer() {
        guard task == nil else { return }
        let frames = camera.frames
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let detector = HandPoseDetector()
            var recognizer = GestureRecognizer()
            for await frame in frames {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard ProcessInfo.processInfo.systemUptime - frame.uptime
                        < GestureTuning.staleFrameTimeout else { continue }
                do {
                    let detection = try await detector.detect(frame)
                    let next = recognizer.update(handDetected: detection.handDetected,
                                                 landmarks: detection.landmarks,
                                                 secondaryLandmarks: detection.secondaryLandmarks)
                    await self.handleVision(next, at: frame.uptime)
                } catch {
                    await self.handleVisionError(error.localizedDescription)
                }
            }
        }
    }

    private func cameraDidFail(_ message: String) {
        self.message = message
        deactivateCamera()
    }
}
