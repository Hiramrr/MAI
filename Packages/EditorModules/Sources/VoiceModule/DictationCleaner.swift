import Foundation

/// Limpieza local del dictado, sin red ni modelos externos.
///
/// Orden: muletillas fuera, puntuación y saltos dictados (`coma` → `,`,
/// `nuevo párrafo` → línea en blanco), correcciones del usuario y estilo
/// formal opcional (mayúscula inicial y punto final, como en documentos y
/// correo).
///
/// Versión recortada de `DictationNormalizer` de LocalFlow
/// (`MiyuWisp/LocalFlow/LocalFlow/Intelligence/DictationNormalizer.swift`).
/// Allí quedan backtrack, listas dictadas y vocabulario técnico; aquí solo
/// lo que el editor necesita para dictar prosa. Conservadora por diseño:
/// ante la duda, conserva el texto tal cual.
public struct DictationCleaner: Sendable {
    public init() {}

    /// Limpia un dictado.
    /// - Parameters:
    ///   - raw: transcripción tal cual la entrega el reconocedor.
    ///   - formal: mayúscula inicial y punto final.
    ///   - customCorrections: pares `(lo que oigo, lo que quiero)`; ganan a las reglas.
    public func clean(
        _ raw: String,
        formal: Bool = true,
        customCorrections: [(from: String, to: String)] = []
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"[^\S\r\n]+"#, with: " ", options: .regularExpression)
        text = removingFillers(text)
        text = applyingSpokenPunctuation(text)
        for correction in customCorrections where !correction.from.isEmpty && !correction.to.isEmpty {
            text = replacingWord(text, variant: correction.from, canonical: correction.to)
        }
        if formal {
            text = applyingFormalStyle(text)
        }
        return trimmingSpaces(text)
    }

    /// Quita espacios de los bordes y conserva los saltos de línea dictados.
    private func trimmingSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: #"^[^\S\r\n]+|[^\S\r\n]+$"#, with: "", options: .regularExpression)
    }

    // MARK: - Muletillas

    /// Quita relleno (`eh`, `um`, `ah`) y tartamudeos cortos (`yo yo`).
    /// Conserva palabras con significado (`este`, `pues`) y énfasis (`muy muy`).
    private func removingFillers(_ text: String) -> String {
        var out = text
        for filler in ["eh", "uh", "um", "ah", "mmm", "mm", "euh"] {
            let pattern = #"(?i)(?<![\p{L}\p{N}_])"# + filler + #"\b,?"#
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"(?i)\b([\p{L}]{1,2})\s+\1\b"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[^\S\r\n]+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.;:?!…])"#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Puntuación dictada

    /// Convierte palabras de puntuación en signos y los saltos dictados en
    /// saltos reales. `punto` y `nueva línea` no se tocan dentro de locuciones
    /// (`punto de encuentro`, `punto final`, `nueva línea de productos`).
    private func applyingSpokenPunctuation(_ text: String) -> String {
        var out = text
        let phrases: [(pattern: String, replacement: String)] = [
            (#"(?i)\bpunto y aparte\b"#, ".\n\n"),
            (#"(?i)\bpunto y seguido\b"#, "."),
            (#"(?i)\b(nuevo p[áa]rrafo|p[áa]rrafo nuevo)\b"#, "\n\n"),
            (#"(?i)\b(nueva l[íi]nea|salto de l[íi]nea)\b(?!\s+de\b|\s+del\b)"#, "\n"),
            (#"(?i)\babre (signo de )?interrogaci[óo]n\b"#, "¿"),
            (#"(?i)\bcierra (signo de )?interrogaci[óo]n\b"#, "?"),
            (#"(?i)\babre (signo de )?(exclamaci[óo]n|admiraci[óo]n)\b"#, "¡"),
            (#"(?i)\bcierra (signo de )?(exclamaci[óo]n|admiraci[óo]n)\b"#, "!"),
            (#"(?i)\bpunto y coma\b"#, ";"),
            (#"(?i)\bdos puntos\b"#, ":"),
            (#"(?i)\bpuntos suspensivos\b"#, "…"),
            (#"(?i)\bsigno de interrogaci[óo]n\b"#, "?"),
            (#"(?i)\bsigno de exclamaci[óo]n\b"#, "!"),
            (#"(?i)\bpor ciento\b"#, "%"),
            (#"(?i)\barroba\b"#, "@"),
            (#"(?i)\bcoma\b"#, ","),
            (#"(?i)\bpunto\b(?!\s+de\b|\s+del\b|\s+final\b|\s+muerto\b)"#, "."),
        ]
        for (pattern, replacement) in phrases {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"[^\S\r\n]+([,.;:?!…%])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([¿¡])[^\S\r\n]+"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s*@\s*"#, with: "@", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[^\S\r\n]+"#, with: " ", options: .regularExpression)
        // Sin espacios colgando alrededor de un salto ni más de una línea en blanco.
        out = out.replacingOccurrences(of: #"[^\S\r\n]*\n[^\S\r\n]*"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return trimmingSpaces(out)
    }

    // MARK: - Estilo

    /// Mayúscula al empezar, tras fin de oración y en cada línea nueva; punto
    /// al final de cada línea que termine en letra o número.
    private func applyingFormalStyle(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        var capitalize = true
        var sentenceEnded = false
        for char in text {
            if char == "\n" {
                capitalize = true
                sentenceEnded = false
            } else if char.isWhitespace {
                if sentenceEnded { capitalize = true }
                sentenceEnded = false
            } else if ".?!…".contains(char) {
                capitalize = false
                sentenceEnded = true
            } else if char.isLetter {
                out += capitalize ? String(char).uppercased() : String(char)
                capitalize = false
                sentenceEnded = false
                continue
            } else if !"¿¡\"«(".contains(char) {
                capitalize = false
                sentenceEnded = false
            }
            out.append(char)
        }
        return out.replacingOccurrences(of: #"(?<=[\p{L}\p{N}])(?=\n|\z)"#, with: ".", options: .regularExpression)
    }

    private func replacingWord(_ text: String, variant: String, canonical: String) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: variant) + #"(?![\p{L}\p{N}_])"#
        return text.replacingOccurrences(of: pattern, with: canonical, options: .regularExpression)
    }
}
