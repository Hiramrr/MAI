import Foundation

/// Alternativas locales de sinónimos y validación de versiones de longitud.
public enum GestureSynonyms: Sendable {
    public static let synonyms: [String: [String]] = [
        "enfoque": ["perspectiva", "planteamiento", "aproximación"],
        "utilidad": ["valor", "provecho", "aplicabilidad"],
        "usabilidad": ["facilidad de uso", "manejabilidad", "accesibilidad"],
        "estudio": ["investigación", "trabajo", "análisis"],
        "participantes": ["colaboradores", "intervinientes", "sujetos"],
        "metodología": ["método", "procedimiento", "enfoque metódico"],
        "evaluación": ["valoración", "análisis", "revisión"],
        "análisis": ["estudio", "examen", "revisión"],
        "datos": ["información", "resultados", "registros"],
        "resultados": ["hallazgos", "conclusiones", "datos"],
        "importante": ["relevante", "significativo", "esencial"],
        "proceso": ["procedimiento", "desarrollo", "mecanismo"],
        "desarrollo": ["evolución", "avance", "progreso"],
        "investigación": ["estudio", "indagación", "análisis"],
        "texto": ["escrito", "documento", "redacción"],
        "idea": ["noción", "concepto", "propuesta"],
        "forma": ["manera", "modo", "vía"],
        "manera": ["forma", "modo", "vía"],
        "grande": ["amplio", "extenso", "considerable"],
        "nuevo": ["reciente", "actual", "innovador"],
        "hacer": ["realizar", "llevar a cabo", "efectuar"],
        "usar": ["utilizar", "emplear", "aplicar"],
        "mostrar": ["exhibir", "presentar", "revelar"],
        "obtener": ["conseguir", "lograr", "alcanzar"],
        "permitir": ["posibilitar", "facilitar", "autorizar"],
        "analizar": ["examinar", "estudiar", "evaluar"],
        "evaluar": ["valorar", "analizar", "medir"],
        "mejorar": ["optimizar", "perfeccionar", "reforzar"],
        "reducir": ["disminuir", "rebajar", "limitar"],
        "mantener": ["conservar", "sostener", "preservar"],
        "carga": ["peso", "volumen", "exigencia"],
        "estrategia": ["táctica", "plan", "enfoque"],
        "herramienta": ["instrumento", "recurso", "medio"],
        "experiencia": ["vivencia", "práctica", "trayectoria"],
        "casa": ["hogar", "vivienda", "residencia"],
        "trabajo": ["empleo", "labor", "ocupación"],
        "tiempo": ["momento", "rato", "época"],
        "vida": ["existencia", "trayectoria", "vivencia"],
        "persona": ["individuo", "sujeto", "ser humano"],
        "mundo": ["planeta", "tierra", "universo"],
        "país": ["nación", "patria", "estado"],
        "ciudad": ["urbe", "localidad", "metrópoli"],
        "libro": ["volumen", "obra", "ejemplar"],
        "escuela": ["colegio", "instituto", "academia"],
        "amigo": ["compañero", "colega", "camarada"],
        "amor": ["cariño", "afecto", "ternura"],
        "problema": ["dificultad", "inconveniente", "obstáculo"],
        "pregunta": ["interrogante", "cuestión", "duda"],
        "respuesta": ["contestación", "solución", "reacción"],
        "ayuda": ["apoyo", "auxilio", "colaboración"],
        "ejemplo": ["muestra", "caso", "modelo"],
        "cosa": ["objeto", "asunto", "tema"],
        "agua": ["líquido", "fluido"],
        "comida": ["alimento", "platillo", "manjar"],
        "dinero": ["efectivo", "fondos", "recursos"],
        "día": ["jornada", "fecha"],
        "noche": ["velada", "madrugada", "oscuridad"],
        "luz": ["claridad", "iluminación", "brillo"],
        "camino": ["ruta", "sendero", "vía"],
        "viaje": ["travesía", "recorrido", "excursión"],
        "fiesta": ["celebración", "festejo", "reunión"],
        "música": ["melodía", "canción", "armonía"],
        "historia": ["relato", "narración", "crónica"],
        "verdad": ["realidad", "certeza", "hecho"],
        "mentira": ["engaño", "falsedad", "trampa"],
        "sueño": ["ensueño", "anhelo", "ilusión"],
        "miedo": ["temor", "terror", "pánico"],
        "alegría": ["felicidad", "gozo", "júbilo"],
        "tristeza": ["pena", "melancolía", "aflicción"],
        "fuerza": ["potencia", "energía", "vigor"],
        "paz": ["tranquilidad", "calma", "armonía"],
        "guerra": ["conflicto", "combate", "batalla"],
        "salud": ["bienestar", "sanidad", "vigor"],
        "enfermedad": ["padecimiento", "dolencia", "mal"],
        "éxito": ["triunfo", "logro", "victoria"],
        "fracaso": ["fallo", "derrota", "revés"],
        "inicio": ["comienzo", "principio", "arranque"],
        "final": ["término", "conclusión", "cierre"],
        "cambio": ["modificación", "transformación", "variación"],
        "oportunidad": ["ocasión", "chance", "posibilidad"],
        "peligro": ["riesgo", "amenaza", "acechanza"],
        "belleza": ["hermosura", "encanto", "atractivo"],
        "inteligente": ["listo", "brillante", "capaz"],
        "rápido": ["veloz", "pronto", "ágil"],
        "lento": ["pausado", "tardío", "despacio"],
        "feliz": ["contento", "dichoso", "alegre"],
        "triste": ["apenado", "melancólico", "afligido"],
        "bueno": ["bondadoso", "excelente", "favorable"],
        "malo": ["perverso", "adverso", "deficiente"],
        "difícil": ["complicado", "arduo", "complejo"],
        "fácil": ["sencillo", "simple", "accesible"],
        "pensar": ["reflexionar", "meditar", "considerar"],
        "hablar": ["conversar", "dialogar", "expresar"],
        "escuchar": ["oír", "atender", "prestar atención"],
        "mirar": ["observar", "contemplar", "ver"],
        "caminar": ["andar", "pasear", "avanzar"],
        "correr": ["trotar", "apresurarse", "acelerar"],
        "comer": ["alimentarse", "degustar", "probar"],
        "dormir": ["descansar", "reposar", "pernoctar"],
        "trabajar": ["laborar", "emplearse", "producir"],
        "estudiar": ["aprender", "formarse", "prepararse"],
        "enseñar": ["instruir", "educar", "mostrar"],
        "preguntar": ["interrogar", "consultar", "indagar"],
        "responder": ["contestar", "replicar", "resolver"],
        "ayudar": ["apoyar", "auxiliar", "colaborar"],
        "intentar": ["probar", "tratar", "procurar"],
        "lograr": ["conseguir", "alcanzar", "obtener"],
        "empezar": ["comenzar", "iniciar", "arrancar"],
        "terminar": ["concluir", "finalizar", "acabar"],
        "crear": ["producir", "generar", "elaborar"],
        "destruir": ["demoler", "arruinar", "aniquilar"],
        "comprar": ["adquirir", "obtener", "conseguir"],
        "vender": ["ofertar", "comercializar", "traspasar"],
    ]

    public static func alternatives(for selection: String) -> [String] {
        let key = selection.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = synonyms[key] { return exact }
        var out: [String] = []
        let words = selection.split(separator: " ").map(String.init)
        if words.count > 1 {
            for i in 0..<min(3, words.count) {
                var copy = words
                let w = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
                if let syn = synonyms[w]?.first {
                    copy[i] = syn
                    out.append(copy.joined(separator: " "))
                }
            }
        }
        if out.isEmpty {
            out = [
                selection,
                selection.replacingOccurrences(of: "muy ", with: ""),
                selection,
            ]
        }
        return Array(out.prefix(3))
    }

    /// Mínimos para aceptar una versión corta.
    public static let minShortChars = 12
    public static let minShortWords = 3

    /// Palabras distintivas (vocabulario técnico): las largas en minúsculas.
    public static func distinctiveWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(separator: " ").map {
            String($0.trimmingCharacters(in: .punctuationCharacters))
        }.filter { $0.count >= 7 })
    }

    /// La candidata conserva el vocabulario del original en proporción a su
    /// tamaño: si dice lo mismo con menos palabras, retiene al menos la mitad
    /// de las distintivas esperables.
    public static func keepsVocabulary(_ s: String, original: String) -> Bool {
        let oDistinct = distinctiveWords(original)
        guard oDistinct.count >= 2 else { return true }
        let sWords = s.split(separator: " ").count
        let oWords = original.split(separator: " ").count
        guard sWords > 0, oWords > 0 else { return false }
        let kept = distinctiveWords(s).intersection(oDistinct).count
        return Double(kept) >= 0.5 * Double(sWords) / Double(oWords) * Double(oDistinct.count)
    }

    /// La corta debe ser una versión real: legible, más breve que el original
    /// en caracteres Y en palabras (como máximo el 70 %).
    public static func isValidShort(_ s: String, original: String) -> Bool {
        let sWords = s.split(separator: " ").count
        let oWords = original.split(separator: " ").count
        return s.count >= minShortChars
            && sWords >= minShortWords
            && s.last.map { ".!?".contains($0) } == true
            && s != original && s.count < original.count
            && oWords > 0 && Double(sWords) <= Double(oWords) * 0.7
            && keepsVocabulary(s, original: original)
    }

    /// (corta, larga) validadas por separado: cada una queda si es válida.
    public static func validLengthPair(_ short: String, _ long: String, original: String) -> VariantPair {
        let short = short.trimmingCharacters(in: .whitespacesAndNewlines)
        let long = long.trimmingCharacters(in: .whitespacesAndNewlines)
        return VariantPair(isValidShort(short, original: original) ? short : nil,
                           isValidLong(long, original: original) ? long : nil)
    }

    /// La larga debe aportar texto respecto al original: más palabras y más
    /// caracteres, con el vocabulario del original.
    public static func isValidLong(_ s: String, original: String) -> Bool {
        let sWords = s.split(separator: " ").count
        let oWords = original.split(separator: " ").count
        let charGain = s.count - original.count
        return !s.isEmpty && s != original && charGain > 0 && sWords > oWords
            && sWords >= minShortWords
            && (oWords > 0 && Double(sWords) >= Double(oWords) * 1.08 || charGain >= 40)
            && keepsVocabulary(s, original: original)
    }
}
