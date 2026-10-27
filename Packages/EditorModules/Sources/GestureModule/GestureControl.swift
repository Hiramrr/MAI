import AVFoundation
import SwiftUI

/// Botón + panel de gestos. Vive dentro de `GestureModule` para que `EditorUI`
/// nunca importe gestos: la app lo envuelve en `AnyView` y lo pasa a
/// `EditorScreen(gesturePanel:)`. Si la pieza se quita, ese parámetro es `nil`.
public struct GestureControl: View {
    @Bindable private var module: GestureModule
    @State private var showPanel = false

    public init(module: GestureModule) {
        self.module = module
    }

    public var body: some View {
        Button {
            showPanel = true
        } label: {
            Image(systemName: module.paused ? "pause.circle.fill" : module.running ? "hand.raised.fill" : "hand.raised")
        }
        .help("Gestos con la cámara")
        .accessibilityLabel("Gestos con la cámara")
        .accessibilityHint("Activa la cámara para elegir palabras, oraciones o párrafos con la mano y usar la pinza.")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            GesturePanel(module: module)
        }
        .onChange(of: module.hasPinchSession || module.hasLengthSession || module.hasImageSizeSession) { _, active in
            if active { showPanel = false }
        }
    }
}

/// Vista previa de la cámara, espejada para que funcione como espejo.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let isRunning: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        // La conexión no existe hasta que la entrada se configura;
        // isRunning fuerza a SwiftUI a actualizar tras arrancar.
        if isRunning, let connection = view.previewLayer.connection,
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        init() {
            super.init(frame: .zero)
            previewLayer.videoGravity = .resizeAspect
            wantsLayer = true
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}

/// Puntos de las manos (muñeca, pulgar, índice) sobre la vista previa.
/// Con dos manos dibuja la línea de separación: es lo que mueve la longitud.
struct HandOverlay: View {
    let landmarks: HandLandmarks?
    let secondaryLandmarks: HandLandmarks?

    var body: some View {
        Canvas { context, size in
            let hands = [landmarks, secondaryLandmarks].compactMap { $0 }
            if hands.count == 2 {
                var span = Path()
                span.move(to: hands[0].displayPoint(hands[0].index, in: size))
                span.addLine(to: hands[1].displayPoint(hands[1].index, in: size))
                context.stroke(span, with: .color(.white), lineWidth: 2)
            }
            for (handIndex, hand) in hands.enumerated() {
                for (name, joint) in [("muñeca", hand.wrist), ("pulgar", hand.thumb), ("índice", hand.index)] {
                    let point = hand.displayPoint(joint, in: size)
                    let circle = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                    context.fill(circle, with: .color(.white))
                    context.stroke(circle, with: .color(.black), lineWidth: 2)
                    let label = hands.count > 1 ? "\(handIndex + 1) \(name)" : name
                    let text = context.resolve(Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                    let textSize = text.measure(in: size)
                    let labelX = min(size.width - textSize.width - 8, max(4, point.x + 10))
                    let labelY = min(size.height - textSize.height - 8, max(4, point.y - 22))
                    let box = CGRect(x: labelX - 3, y: labelY - 2, width: textSize.width + 6, height: textSize.height + 4)
                    context.fill(Path(box), with: .color(.black.opacity(0.8)))
                    context.draw(text, at: CGPoint(x: labelX, y: labelY), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Contenido del popover de gestos: preview, diagnóstico en vivo y control.
public struct GesturePanel: View {
    @Bindable private var module: GestureModule
    @AppStorage(GestureThresholds.key) private var pinchActivation = GestureThresholds.default

    public init(module: GestureModule) {
        self.module = module
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gestos")
                    .font(.headline)
                Spacer()
                statusPill
            }

            ZStack(alignment: .topLeading) {
                Color.black
                if module.running {
                    CameraPreview(session: module.camera.session,
                                  isRunning: module.running)
                    HandOverlay(landmarks: module.state.landmarks,
                                secondaryLandmarks: module.state.secondaryLandmarks)
                } else {
                    VStack {
                        Spacer()
                        Text(module.starting ? "Iniciando cámara…" : "Cámara apagada")
                            .foregroundStyle(.white)
                            .font(.callout)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                detectionBadge
                    .padding(8)
            }
            .frame(width: 320, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Picker("Señalar", selection: $module.navigationUnit) {
                ForEach(GestureUnit.allCases, id: \.self) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Qué señala el dedo")
            .help("Lo que selecciona el dedo y sobre lo que actúa la pinza")

            Text(unitDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(module.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(module.running ? "Detener cámara" : "Activar cámara") {
                    if module.running {
                        module.deactivateCamera()
                    } else {
                        Task { await module.activateCamera() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(module.starting)
                if module.running {
                    Button(module.paused ? "Reanudar gestos" : "Pausar gestos") {
                        Task { await module.setGesturesPaused(!module.paused) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Mantiene la cámara encendida sin ejecutar acciones")
                }
                Spacer()
                Label("Local", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("El vídeo se procesa en este Mac y no se guarda.")
            }

            if module.running {
                Divider()
                DisclosureGroup("Calibración") {
                    diagnostics
                    calibrationSection
                        .padding(.top, 8)
                }
                .font(.callout)
            }

            Divider()
            manualTests
        }
        .padding(16)
        .frame(width: 352)
    }

    /// Qué hace la pinza con la unidad elegida; el gesto a dos manos es común.
    private var unitDescription: String {
        let pinch = switch module.navigationUnit {
        case .palabra: "Pinza sobre una palabra: sinónimos; mueve para elegir y suelta. Pinza con barrido lateral: deshacer o rehacer."
        case .oracion: "Pinza sobre una oración: tono; izquierda enfría, derecha templa, suelta para confirmar."
        case .parrafo: "Pinza sobre un párrafo: mantén, muévelo y suelta para reordenar."
        }
        return pinch + " Dos manos: longitud del párrafo o tamaño de una imagen."
    }

    /// Pruebas sin cámara: siempre visibles, con cámara o sin ella.
    /// Abren las mismas tarjetas que los gestos (clic confirma, ✕ cancela).
    private var manualTests: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Probar sin cámara")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Sinónimos") {
                    Task { await module.startPinchSessionManually() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(module.hasLengthSession || module.hasPinchSession || module.hasImageSizeSession)
                .help("Abre la tarjeta de sinónimos sobre la palabra actual")
                Button("Tono") {
                    Task { await module.startToneSessionManually() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(module.hasLengthSession || module.hasPinchSession || module.hasImageSizeSession)
                .help("Abre frío/original/cálido sobre la oración actual")
                Button("Longitud") {
                    Task { await module.startLengthSessionManually() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(module.hasLengthSession || module.hasPinchSession || module.hasImageSizeSession)
                .help("Abre corto/medio/largo sobre el párrafo actual")
                Button("Imagen") {
                    Task { await module.startImageSizeSessionManually() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(module.hasLengthSession || module.hasPinchSession || module.hasImageSizeSession)
                .help("Ajusta el ancho de la imagen bajo el cursor")
            }
            Text("Usa las tarjetas para comparar, confirmar o cancelar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // IA on-device para sinónimos: disponible o motivo honesto.
            Text(module.synonymProviderAvailable
                 ? "Sinónimos con IA en este Mac (mejoran la lista local)."
                 : (module.synonymProviderReason ?? "Sinónimos locales."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Estado en vivo

    private var statusPill: some View {
        let (text, color): (String, Color) = if module.running && module.paused {
            ("En pausa", .orange)
        } else if module.running {
            ("Detectando", .green)
        } else if module.starting {
            ("Iniciando…", .orange)
        } else {
            ("Apagada", .gray)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Insignia sobre el vídeo: qué ve el reconocedor ahora mismo.
    private var detectionBadge: some View {
        let text: String = if !module.running {
            ""
        } else if module.paused {
            "Gestos en pausa"
        } else if module.hasLengthSession {
            "Longitud: acerca ↔ separa"
        } else if module.hasImageSizeSession {
            "Imagen: acerca ↔ separa"
        } else if module.isDraggingParagraph {
            "Párrafo: mueve y suelta"
        } else if module.isToneSession {
            "Tono: frío ↔ cálido"
        } else if module.hasPinchSession {
            "Pinza: mueve ↔"
        } else if module.isPointingAtImage {
            "Imagen bajo el dedo: muestra la otra mano"
        } else if module.state.hasTwoDistinctHands {
            "Dos manos: mantén…"
        } else if !module.state.handDetected {
            "Buscando mano…"
        } else if module.state.pinch {
            "Pinza: mueve ↔"
        } else {
            module.navigationUnit.pointHint
        }
        return Group {
            if !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.65), in: Capsule())
            }
        }
    }

    /// Diagnóstico: mano, pinza y apertura en vivo.
    private var diagnostics: some View {
        let state = module.state
        let distance = state.distance ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label(state.handDetected ? "Mano: sí" : "Mano: no",
                      systemImage: state.handDetected ? "hand.raised.fill" : "hand.raised")
                    .foregroundStyle(state.handDetected ? .green : .secondary)
                Label(state.pinch ? "Pinza: cerrada" : "Pinza: abierta",
                      systemImage: state.pinch ? "circle.fill" : "circle")
                    .foregroundStyle(state.pinch ? .blue : .secondary)
            }
            .font(.caption)
            LabeledContent("Apertura \(String(format: "%.3f", distance))") {
                ProgressView(value: min(max(distance, 0), 0.12) / 0.12)
                    .frame(width: 120)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Distancia pulgar–índice en vivo. La pinza cierra por debajo del umbral.")
            if let span = state.handSpan {
                LabeledContent("Separación \(String(format: "%.3f", span))") {
                    ProgressView(value: min(max(span, 0), 0.8) / 0.8)
                        .frame(width: 120)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Distancia entre ambas manos en vivo. Acercar acorta, separar amplía.")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Umbral de pinza")
                    Spacer()
                    Text(String(format: "%.3f", pinchActivation))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Slider(value: $pinchActivation,
                       in: GestureThresholds.min...GestureThresholds.max,
                       step: 0.005)
                Text("Cierra la pinza y deja el umbral un poco por encima de tu apertura.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 8)
    }

    /// Calibración guiada: muestrea tu mano abierta y tu pinza, y coloca
    /// el umbral en medio.
    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calibrar a tu mano")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Mano abierta") {
                    module.startCalibration(phase: .openHand)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(module.calibration != nil)
                Button("Pinza") {
                    module.startCalibration(phase: .pinch)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(module.calibration != nil)
            }
            if module.calibration != nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(module.calibrationMessage ?? "Muestreando… quédate quieto")
                        .font(.caption)
                    Spacer()
                    Button("Cancelar") { module.cancelCalibration() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                Text("Quédate quieto 3 segundos en cada paso.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
