import Foundation

// Pieza Lego: Gestos. Lógica pura del reconocedor, portada de EditorTDAH
// (`Enfoque/Gestures/GestureRecognizer.swift`). Sin IA, cámara ni AppKit:
// solo matemática de gestos, testeable sin permisos.
//
// Para QUITAR los gestos del programa:
//   1. Borra el bloque "Pieza Lego: Gestos" de `App/EditorApp.swift`.
//   2. Quita el target `GestureModule` de `Packages/EditorModules/Package.swift`
//      y su producto de `EditorFinal.xcodeproj`.
//   3. Listo: `EditorScreen` compila igual con `gesturePanel == nil` y muestra
//      "Módulo no disponible" en Ajustes > Multimodalidad.
//
// Para PONERLOS de nuevo basta revertir esos pasos: el motor no se toca
// (la preview atómica ya vive en `EditorSession` y está inerte sin la pieza).

/// Ajuste del reconocedor de pinza (pulgar + índice).
/// Distancias en unidades de ancho de imagen, con corrección de aspecto.
/// La activación la pone el usuario (ver `GestureThresholds`); la histéresis
/// es ancha a propósito: mantener la pinza cerrada mientras se mueve la
/// mano debe ser fácil; soltar debe ser deliberado.
public enum GestureTuning: Sendable {
    /// Confianza mínima de Vision para aceptar pulgar e índice.
    public static let minimumConfidence: Float = 0.35
    /// Paso horizontal para cambiar de opción dentro de la sesión de pinza.
    public static let optionStep = 0.05
    /// Paso horizontal para caminar la selección palabra por palabra.
    public static let wordStep = 0.07
    /// Paso horizontal entre niveles de tono (frío · original · cálido).
    /// Más ancho que el de sinónimos: cada nivel reescribe la oración entera.
    public static let toneStep = 0.08
    /// Las oraciones requieren un movimiento intermedio entre palabra y párrafo.
    public static let sentenceStep = 0.11
    /// Los párrafos requieren un movimiento más amplio que las palabras.
    public static let paragraphStep = 0.16
    /// Frames seguidos de pinza antes de abrir la sesión (evita roces).
    public static let pinchStartFrames = 4
    /// Barrido lateral con pinza para deshacer/rehacer.
    /// Muy superior al paso de opciones: solo un barrido deliberado lo cruza.
    public static let undoSwipeDistance = 0.14
    /// Gracia ante pérdida breve de seguimiento dentro de una sesión.
    public static let trackingLossGrace = 0.3
    /// Fotogramas por segundo analizados (el resto se descarta).
    public static let analysisFPS = 24.0
    /// Si un frame tarda más que esto, se ignora por obsoleto.
    public static let staleFrameTimeout = 0.5
    // MARK: - Gesto a dos manos (longitud del párrafo)
    /// Separación mínima entre ambas manos para contar como gesto doble.
    public static let minimumHandSpan = 0.08
    /// Detecciones con dos manos dentro de la ventana para abrir la sesión.
    /// Por ventana temporal (no frames consecutivos): tolera parpadeos de Vision.
    public static let twoHandStartFrames = 3
    /// Ventana en segundos donde deben caer esas detecciones.
    public static let twoHandWindow = 0.6
    /// Cambio de separación entre manos para pasar de un nivel a otro.
    /// 0.10 con suavizado: el temblor (±0.04) no cambia de nivel solo.
    public static let lengthSpanStep = 0.10
    /// Frames seguidos con una sola mano para confirmar la longitud.
    /// 5 (~0.2 s): un parpadeo no confirma solo, retirar se siente directo.
    public static let lengthCommitFrames = 5
    /// Suavizado de la separación (media móvil exponencial): responde
    /// en ~3 frames y absorbe el temblor sin retardo perceptible.
    public static let lengthSmoothing = 0.35
}

/// Umbral de pinza ajustable por el usuario (persiste en UserDefaults).
/// La lectura de "Apertura" del panel muestra la distancia en vivo:
/// cierra la pinza y deja el umbral un poco por encima de ese valor.
///
/// Clave propia de este programa (no se comparte con Enfoque): cada mano y
/// cada cámara calibran distinto.
public enum GestureThresholds: Sendable {
    public static let key = "editor.pinchActivation"
    public static let `default` = 0.05
    public static let min = 0.005
    public static let max = 0.09

    public static var activation: Double {
        get {
            let v = UserDefaults.standard.double(forKey: key)
            return v > 0 ? Swift.min(Swift.max(v, min), max) : `default`
        }
        set {
            UserDefaults.standard.set(Swift.min(Swift.max(newValue, min), max), forKey: key)
        }
    }

    /// Soltar exige abrir claramente por encima de la activación.
    public static var release: Double { activation + 0.03 }
    /// Apertura que cuenta como "soltar decidido" (confirma al instante).
    public static var commit: Double { activation + 0.05 }
}
