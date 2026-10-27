import EditorCore
import Foundation
import FoundationModels
import OSLog

let aiLogger = Logger(subsystem: "com.hiram.EditorFinal", category: "ai")

/// Dos versiones pedidas en una sola llamada al modelo. Cada una es nil si
/// no pasó su validación: la otra se puede usar igual.
public struct VariantPair: Sendable, Equatable {
    public var first: String?
    public var second: String?

    public init(_ first: String?, _ second: String?) {
        self.first = first
        self.second = second
    }

    public var isEmpty: Bool { first == nil && second == nil }
}

public protocol LengthProvider: Sendable {
    var isAvailable: Bool { get }
    var availabilityReason: String? { get }
    /// Devuelve (corta, larga), cada una nil si no es válida. Lanza
    /// `ModelFailure` con la causa, o `CancellationError` si se canceló.
    func variants(for paragraph: String) async throws -> VariantPair
}

public struct FoundationModelsLengthProvider: LengthProvider {
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

    public func variants(for paragraph: String) async throws -> VariantPair {
        guard isAvailable else {
            throw ModelFailure.unavailable(availabilityReason ?? "Modelo de IA no disponible ahora mismo.")
        }
        try Task.checkCancellation()
        let result: [String]
        do {
            result = try await withModelDeadline(.seconds(20)) {
                let session = LanguageModelSession(instructions: "Eres editor de textos en español. Conserva los hechos, nombres, cifras y sentido del original. No inventes datos ni agregues información externa. Devuelve párrafos completos, sin puntos suspensivos ni comentarios.")
                let response = try await session.respond(
                    to: """
                    Reescribe este párrafo en dos versiones.
                    Corta: expresa su idea principal en una oración completa, con menos del 70 % de las palabras. No cortes una frase a la mitad.
                    Larga: explica con mayor claridad las ideas que ya están en el párrafo, con al menos 10 % más palabras. No agregues hechos nuevos ni repitas frases para rellenar.

                    Párrafo: \(paragraph)
                    """,
                    generating: LengthVariants.self
                )
                return [response.content.short, response.content.long]
            }
        } catch {
            guard let failure = ModelFailure.classify(error) else { throw error }
            aiLogger.error("Longitud sin resultado: \(String(describing: error), privacy: .private)")
            throw failure
        }
        let pair = GestureSynonyms.validLengthPair(result[0], result[1], original: paragraph)
        if pair.first == nil || pair.second == nil {
            aiLogger.notice("Longitud: versión no válida descartada")
        }
        return pair
    }
}

@Generable
struct LengthVariants {
    @Guide(description: "Una versión breve y completa del párrafo")
    var short: String
    @Guide(description: "Una versión más extensa que aclara sin inventar hechos")
    var long: String
}
