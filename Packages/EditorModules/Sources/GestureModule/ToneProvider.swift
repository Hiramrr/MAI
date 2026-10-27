import EditorCore
import Foundation
import FoundationModels

public protocol ToneProvider: Sendable {
    var isAvailable: Bool { get }
    var availabilityReason: String? { get }
    /// Devuelve (fría, cálida), cada una nil si no es válida. Lanza
    /// `ModelFailure` con la causa, o `CancellationError` si se canceló.
    func variants(for sentence: String) async throws -> VariantPair
}

public struct FoundationModelsToneProvider: ToneProvider {
    public init() {}

    public var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public var availabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: "Este Mac no es compatible con Apple Intelligence."
            case .appleIntelligenceNotEnabled: "Activa Apple Intelligence en Ajustes del Sistema."
            case .modelNotReady: "El modelo de IA se está descargando; reintenta en unos minutos."
            @unknown default: "Modelo de IA no disponible ahora mismo."
            }
        }
    }

    public func variants(for sentence: String) async throws -> VariantPair {
        guard isAvailable else {
            throw ModelFailure.unavailable(availabilityReason ?? "Modelo de IA no disponible ahora mismo.")
        }
        try Task.checkCancellation()
        let result: [String]
        do {
            result = try await withModelDeadline(.seconds(15)) {
                let session = LanguageModelSession(instructions: "Eres editor de textos en español. Cambias el tono sin cambiar lo que se dice: conserva los hechos, nombres, cifras y las marcas de Markdown del original. No inventes datos. Devuelve una sola oración completa por versión, sin comentarios ni emojis.")
                let response = try await session.respond(
                    to: """
                    Reescribe esta oración en dos tonos.
                    Fría: distante, neutra e impersonal; sin adjetivos afectivos ni exclamaciones.
                    Cálida: cercana, amable y humana, sin exagerar.

                    Oración: \(sentence)
                    """,
                    generating: ToneVariants.self
                )
                return [response.content.cold, response.content.warm]
            }
        } catch {
            guard let failure = ModelFailure.classify(error) else { throw error }
            aiLogger.error("Tono sin resultado: \(String(describing: error), privacy: .private)")
            throw failure
        }
        let pair = GestureTone.validPair(result[0], result[1], original: sentence)
        if pair.first == nil || pair.second == nil {
            aiLogger.notice("Tono: versión no válida descartada")
        }
        return pair
    }
}

@Generable
struct ToneVariants {
    @Guide(description: "La misma oración en tono frío, distante e impersonal")
    var cold: String
    @Guide(description: "La misma oración en tono cálido, cercano y amable")
    var warm: String
}
