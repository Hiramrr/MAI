import Foundation
import FoundationModels

/// Por qué una generación con IA no dio resultado. Viaja del proveedor a la
/// interfaz para decir qué pasó y qué puede hacer la persona. Nunca lleva el
/// texto del documento. Cancelar a propósito no es un fallo: llega como
/// `CancellationError` y `classify` devuelve nil.
public enum ModelFailure: Error, Equatable, Sendable {
    /// El modelo no respondió dentro del plazo.
    case deadline
    /// Apple Intelligence no está disponible; lleva el motivo legible.
    case unavailable(String)
    /// El texto no cabe en el contexto del modelo.
    case tooLong
    /// El modelo rechazó el texto por sus protecciones.
    case refused
    /// El modelo no admite el idioma del texto.
    case unsupportedLanguage
    /// El modelo atiende otra petición o alcanzó su límite.
    case busy
    /// Otro error de generación.
    case generation
    /// Respondió, pero vacío, igual al original o sin pasar la validación.
    case invalidOutput
    /// No hay texto seleccionado que reescribir.
    case selectionMissing
    /// La selección o el documento cambió mientras se generaba.
    case selectionChanged
    /// El editor está en lectura o mostrando otra vista previa.
    case notEditable

    /// Mensaje breve con la acción que puede intentar la persona.
    public var message: String {
        switch self {
        case .deadline:
            "Apple Intelligence tardó demasiado. Reintenta o usa un fragmento más corto."
        case .unavailable(let reason):
            reason
        case .tooLong:
            "El texto es demasiado largo para Apple Intelligence. Usa un fragmento más corto y reintenta."
        case .refused:
            "Apple Intelligence no quiso reescribir este texto. Prueba con otro fragmento."
        case .unsupportedLanguage:
            "Apple Intelligence no admite el idioma de este texto."
        case .busy:
            "Apple Intelligence está ocupada. Espera unos segundos y reintenta."
        case .generation:
            "Apple Intelligence no pudo generar una respuesta. Reintenta."
        case .invalidOutput:
            "La respuesta de la IA no sirve: vacía, igual al original o incompleta. Reintenta o cambia la instrucción."
        case .selectionMissing:
            "Selecciona el texto que quieres reescribir y repite la orden."
        case .selectionChanged:
            "La selección o el documento cambió mientras se generaba. Vuelve a seleccionar el texto y repite la orden."
        case .notEditable:
            "Sal del modo lectura o termina la vista previa y repite la orden."
        }
    }

    /// Traduce un error de generación. Devuelve nil para la cancelación.
    /// Casos tomados de la interfaz de FoundationModels del SDK (macOS 26 y 27).
    public static func classify(_ error: any Error) -> ModelFailure? {
        if error is CancellationError { return nil }
        if let failure = error as? ModelFailure { return failure }
        if error is ModelDeadlineExceeded { return .deadline }
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .tooLong
                case .rateLimited: return .busy
                case .guardrailViolation, .refusal: return .refused
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                case .timeout: return .deadline
                default: return .generation
                }
            }
            if error is SystemLanguageModel.Error {
                return .unavailable("Los recursos de Apple Intelligence no están disponibles ahora. Reintenta en unos minutos.")
            }
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests {
                return .busy
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .tooLong
            case .assetsUnavailable:
                return .unavailable("Los recursos de Apple Intelligence no están disponibles ahora. Reintenta en unos minutos.")
            case .guardrailViolation, .refusal: return .refused
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited, .concurrentRequests: return .busy
            default: return .generation
            }
        }
        return .generation
    }
}
