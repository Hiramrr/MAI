import Foundation

/// Niveles de tono de una oración, de frío a cálido.
/// La pinza los recorre: mover a la izquierda enfría, a la derecha templa.
public enum ToneLevel: Int, CaseIterable, Sendable {
    case frio = 0
    case original = 1
    case calido = 2

    public var label: String {
        switch self {
        case .frio: "frío"
        case .original: "original"
        case .calido: "cálido"
        }
    }
}

/// Oraciones del documento (lógica pura, testeable).
/// Los rangos usan offsets UTF-16, las mismas unidades que TextKit y NSString.
public enum GestureSentences: Sendable {
    /// Marcas de bloque Markdown al inicio de línea: no son parte de la oración.
    private static let blockPrefix = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:#{1,6}[ \t]+|>[ \t]*|[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d+[.)][ \t]+)+"#)

    /// Rangos de cada oración, sin espacios alrededor ni marcas de bloque
    /// (`#`, `>`, viñetas). Se omiten imágenes, tablas, bloques de código y
    /// líneas sin letras: reescribirlas rompería el Markdown.
    public static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, paragraph, _, _ in
            let trimmed = (line ?? "").trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return
            }
            guard !inFence, !trimmed.hasPrefix("!["), !trimmed.hasPrefix("|") else { return }
            var body = paragraph
            if let prefix = blockPrefix?.firstMatch(in: text, options: .anchored, range: paragraph) {
                body = NSRange(location: NSMaxRange(prefix.range),
                               length: NSMaxRange(paragraph) - NSMaxRange(prefix.range))
            }
            guard body.length > 0 else { return }
            ns.enumerateSubstrings(in: body, options: [.bySentences, .substringNotRequired]) { _, sentence, _, _ in
                let range = trim(sentence, in: ns)
                if range.length > 0,
                   ns.rangeOfCharacter(from: .letters, options: [], range: range).location != NSNotFound {
                    out.append(range)
                }
            }
        }
        return out
    }

    private static func trim(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let blank = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = Unicode.Scalar(ns.character(at: start)), blank.contains(scalar) { start += 1 }
        while end > start, let scalar = Unicode.Scalar(ns.character(at: end - 1)), blank.contains(scalar) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}

/// Validación de las versiones de tono (lógica pura, testeable).
public enum GestureTone: Sendable {
    public static let minWords = 3

    /// Solo se cambia el tono de prosa: enlaces, imágenes y código no
    /// sobreviven a una reescritura.
    public static func canRewrite(_ sentence: String) -> Bool {
        sentence.split(whereSeparator: \.isWhitespace).count >= minWords
            && !["](", "![", "`", "://"].contains(where: sentence.contains)
    }

    /// Una versión de tono es otra forma de decir la misma oración: una sola
    /// línea, distinta del original, de tamaño comparable y con parte de su
    /// vocabulario distintivo.
    public static func isValid(_ candidate: String, original: String) -> Bool {
        let words = candidate.split(whereSeparator: \.isWhitespace).count
        let originalWords = original.split(whereSeparator: \.isWhitespace).count
        guard words >= 2, !candidate.contains("\n"),
              !candidate.hasSuffix("…"), !candidate.hasSuffix("..."),
              candidate.caseInsensitiveCompare(original) != .orderedSame,
              Double(words) >= Double(originalWords) * 0.4,
              words <= originalWords * 2 + 6 else { return false }
        let distinctive = GestureSynonyms.distinctiveWords(original)
        return distinctive.count < 2
            || !GestureSynonyms.distinctiveWords(candidate).isDisjoint(with: distinctive)
    }

    /// `[fría, cálida]`: ambas válidas y distintas entre sí.
    public static func areValid(_ variants: [String], original: String) -> Bool {
        variants.count == 2 && variants[0] != variants[1]
            && variants.allSatisfy { isValid($0, original: original) }
    }

    /// (fría, cálida) validadas por separado: cada una queda si es válida.
    /// Si salen iguales no se sabe cuál tono es, así que no queda ninguna.
    public static func validPair(_ cold: String, _ warm: String, original: String) -> VariantPair {
        let cold = cold.trimmingCharacters(in: .whitespacesAndNewlines)
        let warm = warm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cold != warm else { return VariantPair(nil, nil) }
        return VariantPair(isValid(cold, original: original) ? cold : nil,
                           isValid(warm, original: original) ? warm : nil)
    }
}
