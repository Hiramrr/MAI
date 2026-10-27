import Foundation

/// Micrófono + reconocimiento local detrás de la pieza de voz.
///
/// El `VoiceModule` solo habla con este protocolo: en producción se inyecta
/// `AppleSpeechRecognizer`; en pruebas, un doble que devuelve texto fijo
/// sin pedir micrófono ni permisos.
public protocol VoiceSpeechRecognizer: AnyObject, Sendable {
    /// Transcripción parcial para mostrar mientras se dicta.
    var onPartial: (@Sendable (String) -> Void)? { get set }
    /// Nivel de entrada 0…1 para la barra del HUD.
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    /// ¿Detectó voz real en la sesión actual? (energía, no texto).
    /// Es acumulativo: no dice si hay voz ahora mismo.
    var hasSpeech: Bool { get }
    /// Nivel de `onLevel` a partir del cual un buffer cuenta como voz.
    var voiceThreshold: Float { get }
    /// Texto acumulado de la sesión actual (solo lectura). Si `stop()` falla,
    /// conserva lo reconocido hasta el fallo; `start()` y `cancel()` lo vacían.
    var liveTranscript: String { get }

    /// Pide permisos y abre el micrófono. Lanza con mensaje legible si falla.
    func start() async throws
    /// Cierra el micrófono y devuelve la transcripción final.
    func stop() async throws -> String
    /// Descarta la sesión sin devolver texto. No espera a un `start()` en
    /// curso: lo invalida, y si ese arranque termina después no abre el
    /// micrófono ni toca la sesión siguiente.
    func cancel() async
}
