import Foundation

/// Unidad que señala el índice. Cada una tiene su gesto de pinza:
/// sinónimos (palabra), tono (oración) y mover (párrafo).
public enum GestureUnit: String, CaseIterable, Sendable {
    case palabra, oracion, parrafo

    static let key = "editor.gestureNavigationUnit"

    /// Preferencia guardada. Sin ella se respeta el interruptor anterior
    /// (palabras o párrafos).
    static var stored: GestureUnit {
        let defaults = UserDefaults.standard
        if let unit = defaults.string(forKey: key).flatMap(GestureUnit.init) { return unit }
        return defaults.bool(forKey: "editor.gestureParagraphNavigation") ? .parrafo : .palabra
    }

    public var title: String {
        switch self {
        case .palabra: "Palabras"
        case .oracion: "Oraciones"
        case .parrafo: "Párrafos"
        }
    }

    public var pointHint: String {
        switch self {
        case .palabra: "Señala una palabra"
        case .oracion: "Señala una oración"
        case .parrafo: "Señala un párrafo"
        }
    }

    var startMessage: String {
        switch self {
        case .palabra: "Señala una palabra; la pinza muestra sinónimos."
        case .oracion: "Señala una oración; la pinza cambia su tono."
        case .parrafo: "Señala un párrafo y usa la pinza para moverlo."
        }
    }

    /// Paso horizontal al caminar la selección sin cursor sobre el texto.
    var step: Double {
        switch self {
        case .palabra: GestureTuning.wordStep
        case .oracion: GestureTuning.sentenceStep
        case .parrafo: GestureTuning.paragraphStep
        }
    }
}

/// Navegación palabra por palabra con la mano abierta.
/// Lógica pura (testeable). Portada de EditorTDAH.
///
/// - Sin referencia (`referenceX == nil`): ancla sobre la palabra actual.
/// - Con referencia: cada `wordStep` de desplazamiento horizontal mueve una palabra.
/// - En los bordes se queda en el extremo y re-ancla (no se acumula deriva).
///
/// Los rangos usan offsets UTF-16, las mismas unidades que TextKit y NSString.
public struct WordNavigator: Sendable {
    public static var step: Double { GestureTuning.wordStep }

    public init() {}

    public static func update(
        ranges: [NSRange],
        selection: NSRange,
        referenceX: Double?,
        handX: Double,
        step: Double = GestureTuning.wordStep
    ) -> (select: NSRange, referenceX: Double)? {
        guard !ranges.isEmpty, handX.isFinite, (0...1).contains(handX), step > 0 else { return nil }
        let index = ranges.firstIndex(where: { NSLocationInRange(selection.location, $0) })
            ?? ranges.firstIndex(where: { $0.location >= selection.location })
            ?? (ranges.count - 1)
        guard let reference = referenceX else {
            return (ranges[index], handX)
        }
        let steps = Int((handX - reference) / step)
        guard steps != 0 else { return nil }
        let requested = index + steps
        let next = min(ranges.count - 1, max(0, requested))
        let newReference = requested == next
            ? reference + Double(steps) * step
            : handX
        return (ranges[next], newReference)
    }
}

/// Avance de opción dentro de la sesión de pinza (lógica pura, testeable).
/// Cada `optionStep` de desplazamiento horizontal mueve una opción
/// (`toneStep` en la sesión de tono); en los bordes se queda en el extremo
/// y re-ancla con el dedo.
public struct PinchStep: Sendable {
    public static var threshold: Double { GestureTuning.optionStep }

    public init() {}

    /// - Returns: `(índice, nueva referencia)` o `nil` si no hay que moverse.
    public static func advance(current: Int, count: Int, delta: Double, reference: Double,
                               step: Double = threshold) -> (index: Int, reference: Double)? {
        guard count > 0, step > 0 else { return nil }
        let steps = Int(delta / step)
        guard steps != 0 else { return nil }
        let requested = current + steps
        let next = min(count - 1, max(0, requested))
        let newReference = requested == next
            ? reference + Double(steps) * step
            : reference + delta
        return (next, newReference)
    }

    /// Lista inicial de opciones: la palabra primero + alternativas locales.
    /// Se ignoran las alternativas vacías (nunca se muestra una opción en blanco).
    public static func starterOptions(word: String, local: [String], maxCount: Int = 5) -> [String] {
        var opts = [word]
        for alt in local {
            let clean = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean != word, !opts.contains(clean) else { continue }
            opts.append(clean)
            if opts.count >= maxCount { break }
        }
        return opts
    }

    /// Mejora con sinónimos frescos: la palabra sigue primera.
    /// (Aquí la lista local es final: no hay IA en este programa.)
    public static func mergedOptions(word: String, fresh: [String], maxCount: Int = 5) -> [String] {
        starterOptions(word: word, local: fresh, maxCount: maxCount)
    }
}

/// Niveles de longitud del párrafo, de menor a mayor.
/// El gesto a dos manos los recorre: acercar acorta, separar amplía.
public enum LengthLevel: Int, CaseIterable, Sendable {
    case corto = 0
    case medio = 1
    case largo = 2

    public var label: String {
        switch self {
        case .corto: "corto"
        case .medio: "medio"
        case .largo: "largo"
        }
    }
}

/// Avance de nivel por separación entre manos (lógica pura, testeable).
/// Cada `lengthSpanStep` de separación mueve un nivel; acercar (delta
/// negativo) acorta y separar (delta positivo) amplía. En los bordes se
/// queda en el extremo y re-ancla con las manos (sin deriva acumulada).
/// Con `maxSteps = 1` el gesto recorre un nivel por frame: un brinco de
/// la señal muestra cada versión intermedia en vez de saltar de corto
/// a largo sin ver el medio.
public struct LengthSpanStep: Sendable {
    public static var threshold: Double { GestureTuning.lengthSpanStep }

    public init() {}

    /// - Returns: `(nivel, nueva referencia)` o `nil` si no hay que moverse.
    public static func advance(current: Int, count: Int, delta: Double, reference: Double, maxSteps: Int = .max) -> (index: Int, reference: Double)? {
        guard count > 0, maxSteps > 0 else { return nil }
        let rawSteps = Int(delta / threshold)
        let steps = max(-maxSteps, min(maxSteps, rawSteps))
        guard steps != 0 else { return nil }
        let requested = current + steps
        let next = min(count - 1, max(0, requested))
        let newReference = requested == next
            ? reference + Double(steps) * threshold
            : reference + delta
        return (next, newReference)
    }
}
