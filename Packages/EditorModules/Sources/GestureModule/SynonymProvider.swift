import EditorCore
import Foundation
import FoundationModels

/// Fuente de sinónimos para la sesión de pinza.
///
/// La lista local es instantánea y siempre está; la IA (si hay modelo en el
/// Mac) mejora la lista en segundo plano. Sin modelo no se finge nada: la
/// tarjeta dice "locales" y el panel explica el motivo.
public protocol SynonymProvider: Sendable {
    /// ¿Puede mejorar la lista local ahora mismo?
    var isAvailable: Bool { get }
    /// Motivo legible si no está disponible (nil si lo está).
    var availabilityReason: String? { get }
    /// Sinónimos frescos (máximo 3 útiles). Lanza `ModelFailure` con la
    /// causa, o `CancellationError` si se canceló; el módulo conserva la
    /// lista local y explica por qué no mejoró.
    func synonyms(for word: String) async throws -> [String]
    /// Prepara el modelo antes de usarlo (sin efecto si no hay modelo).
    func prewarm()
}

extension SynonymProvider {
    public func prewarm() {}
}

/// Lista local inmediata. Siempre disponible como base, pero nunca mejora:
/// `isAvailable` es falso para que el módulo sepa que no hay de dónde
/// generar más allá del diccionario.
public struct LocalSynonymProvider: SynonymProvider {
    public init() {}
    public var isAvailable: Bool { false }
    public var availabilityReason: String? { "Mejora con IA desactivada: solo listas locales." }
    public func synonyms(for word: String) async -> [String] {
        GestureSynonyms.alternatives(for: word)
    }
}

/// Sinónimos reales con Apple Foundation Models (on-device).
/// Sin modelo disponible lanza `.unavailable`: el módulo conserva los locales.
public struct FoundationModelsSynonymProvider: SynonymProvider {
    private static let instructions = "Eres un asistente de escritura en español. Respondes solo con el resultado pedido, sin preámbulos."

    public init() {}

    public var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public var availabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Este Mac no es compatible con Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Activa Apple Intelligence en Ajustes del Sistema para sinónimos con IA."
            case .modelNotReady:
                return "El modelo de IA se está descargando; reintenta en unos minutos."
            @unknown default:
                return "Modelo de IA no disponible ahora mismo."
            }
        }
    }

    /// Carga el modelo antes de la primera petición; las tres funciones de
    /// gestos comparten el mismo modelo del sistema.
    public func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    /// Un solo intento con plazo: un reintento duplicaba la espera máxima y
    /// la lista local ya está a la vista mientras tanto.
    public func synonyms(for word: String) async throws -> [String] {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ModelFailure.invalidOutput }
        guard isAvailable else {
            throw ModelFailure.unavailable(availabilityReason ?? "Modelo de IA no disponible ahora mismo.")
        }
        try Task.checkCancellation()
        let candidates: [String]
        do {
            candidates = try await withModelDeadline(.seconds(15)) {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(
                    to: """
                    Dame exactamente 3 sinónimos breves para la palabra "\(clean)".
                    Responde SIEMPRE en el mismo idioma de la palabra (español por defecto).
                    Ejemplo: para "rápido" responde veloz, pronto, ágil.
                    Devuelve solo los sinónimos, sin explicaciones ni numeración extra.
                    """,
                    generating: SynonymList.self
                )
                return response.content.synonyms
            }
        } catch {
            guard let failure = ModelFailure.classify(error) else { throw error }
            aiLogger.error("Sinónimos sin resultado: \(String(describing: error), privacy: .private)")
            throw failure
        }
        // Solo sustitutos reales: distintos, breves y sin duplicados.
        let maxWords = clean.split(separator: " ").count + 1
        var seen = Set<String>()
        let alts = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != clean.lowercased() }
            .filter { $0.split(separator: " ").count <= maxWords }
            .filter { seen.insert($0.lowercased()).inserted }
        guard !alts.isEmpty else { throw ModelFailure.invalidOutput }
        return Array(alts.prefix(3))
    }
}

/// Respuesta estructurada (Guided Generation): directa, sin preámbulos.
@Generable
struct SynonymList {
    @Guide(description: "Tres sinónimos breves en español, sin explicaciones")
    var synonyms: [String]
}
