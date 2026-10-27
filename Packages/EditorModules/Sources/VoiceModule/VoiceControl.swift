import AppKit
import SwiftUI

/// Botón + HUD del dictado. Vive dentro de `VoiceModule` para que `EditorUI`
/// nunca importe voz: la app lo envuelve en `AnyView` y lo pasa a
/// `EditorScreen(voicePanel:)`. Si la pieza se quita, ese parámetro es `nil`.
public struct VoiceControl: View {
    @Bindable private var module: VoiceModule
    @State private var showHUD = false
    /// Los ejemplos se ven abiertos hasta que la persona los pliega.
    @AppStorage("voice.showExamples") private var showExamples = true
    @AppStorage("voice.showOptions") private var showOptions = false

    public init(module: VoiceModule) {
        self.module = module
    }

    /// Frases de muestra del panel. Las que no llevan «…» se comprueban en
    /// las pruebas contra el parser real, para no enseñar nada que no funcione.
    static let examples: [(title: String, phrases: [String])] = [
        ("Dictar", ["coma", "punto", "nueva línea", "nuevo párrafo"]),
        ("Buscar", ["Busca …", "Selecciona …"]),
        ("Editar", ["Ponlo en negritas", "Borra la selección", "Sustituye esto por …", "Hazlo más breve"]),
        ("Corregir", ["Deshacer", "Borra eso"]),
        ("Documento", ["Guarda el documento", "Cambia el título a …", "Abre …", "Exporta a PDF"]),
        ("Salir", ["Detener voz"]),
    ]

    public var body: some View {
        Button {
            if module.isListening || module.pendingAction == nil { Task { await module.toggle() } }
            showHUD = true
        } label: {
            Image(systemName: module.isListening ? symbol : module.pendingAction == nil ? symbol : "exclamationmark.bubble")
                .foregroundStyle(showHUD || module.isListening || module.pendingAction != nil ? .white : .primary)
                .frame(minWidth: 28, minHeight: 28)
                .background(showHUD || module.isListening || module.pendingAction != nil ? Color.accentColor : Color.clear, in: Circle())
        }
        .help(module.isListening ? "Detener escucha" : module.pendingAction != nil ? "Revisar propuesta de voz" : "Dictar con la voz · mantén ⌥Espacio o pulsa ⌃⌘V")
        .accessibilityLabel(module.isListening ? "Detener escucha" : module.pendingAction != nil ? "Revisar propuesta de voz" : "Iniciar dictado")
        .accessibilityHint("Mantén Opción Espacio para hablar y suelta para revisar, o pulsa para empezar y de nuevo para terminar.")
        .keyboardShortcut("v", modifiers: [.control, .command])
        .popover(isPresented: $showHUD, arrowEdge: .bottom) {
            hud
        }
        .onChange(of: isActive) { _, active in
            if active { showHUD = true }
        }
        .onChange(of: module.pendingAction) { previous, action in
            if action != nil { showHUD = true }
            else if previous != nil { showHUD = false }
        }
        .onChange(of: module.helpRequests) {
            showExamples = true
            showHUD = true
        }
    }

    private var isActive: Bool {
        switch module.state {
        case .idle: false
        case .listening, .processing, .failed: true
        }
    }

    private var symbol: String {
        switch module.state {
        case .listening: "mic.fill"
        case .processing: "ellipsis"
        case .failed: "mic.slash"
        case .idle: "mic"
        }
    }

    private var title: String {
        switch module.state {
        case .idle: "Voz"
        case .listening: module.microphoneReady ? "Escuchando" : "Preparando micrófono…"
        case .processing: "Procesando…"
        case .failed: "No pude escucharte"
        }
    }

    private var statusText: String {
        switch module.state {
        case .idle:
            if !module.lastCommandFeedback.isEmpty {
                module.lastCommandFeedback
            } else if module.lastInsertedText.isEmpty {
                "Pulsa Dictar y habla. Sirve para escribir y para dar órdenes."
            } else {
                "Insertado: \(module.lastInsertedText.prefix(80))"
            }
        case .listening:
            if !module.microphoneReady {
                "Un momento…"
            } else if module.partialTranscript.isEmpty {
                module.pushToTalkHeld ? "Habla y suelta ⌥Espacio al terminar." : "Habla ahora."
            } else {
                module.partialTranscript
            }
        case .processing:
            module.lastCommandFeedback.isEmpty ? "Un momento…" : module.lastCommandFeedback
        case .failed(let message):
            message
        }
    }

    /// Una sola línea que explica qué pasa al hablar en el modo elegido.
    private var modeHint: String {
        if module.pushToTalkHeld {
            "Al soltar ⌥Espacio verás el texto para revisarlo."
        } else if module.continuousListening {
            "Cada pausa escribe lo dictado. Los cambios piden tu confirmación."
        } else {
            "Al terminar verás el texto para revisarlo antes de insertarlo."
        }
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let action = module.pendingAction {
                proposal(action)
            } else {
                dictation
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Dictado

    @ViewBuilder private var dictation: some View {
        Label(title, systemImage: symbol).font(.headline)
        if !module.lastTranscript.isEmpty && module.state == .idle {
            Text("Escuché: \(module.lastTranscript)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Text(statusText)
            .font(.callout)
            .foregroundStyle(module.isListening && !module.partialTranscript.isEmpty ? .primary : .secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let recovered = module.recoveredTranscript {
            recovery(recovered)
        }
        if module.handsFreeActive && module.isListening && !module.lastCommandFeedback.isEmpty {
            Text(module.lastCommandFeedback)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if module.isListening {
            ProgressView(value: Double(module.inputLevel))
                .accessibilityLabel("Nivel del micrófono")
        }
        HStack {
            if module.isListening {
                Button("Terminar") { Task { await module.finish() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Cierra el micrófono y usa lo que dijiste")
                Button("Descartar", role: .cancel) { Task { await module.cancelDictation() } }
                    .help("Cierra el micrófono sin escribir nada")
            } else {
                Button(module.lastInsertedText.isEmpty && module.lastCommandFeedback.isEmpty ? "Dictar" : "Dictar de nuevo") {
                    Task { await module.toggle() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(module.state == .processing || module.recoveredTranscript != nil)
                if module.state == .processing {
                    Button("Cancelar", role: .cancel) { Task { await module.cancelDictation() } }
                        .help("Detiene lo que se está procesando sin cambiar el texto")
                }
                if case .failed = module.state {
                    Button("Cerrar") { showHUD = false }
                }
            }
        }
        Text(modeHint)
            .font(.caption)
            .foregroundStyle(.secondary)
        Divider()
        DisclosureGroup("Qué puedo decir", isExpanded: $showExamples) { examplesList }
            .font(.callout)
        DisclosureGroup("Opciones", isExpanded: $showOptions) { options }
            .font(.callout)
    }

    /// Texto que quedó tras un fallo del reconocedor. No se inserta ni se
    /// interpreta como orden sin una decisión explícita.
    @ViewBuilder private func recovery(_ text: String) -> some View {
        Text("Texto recuperado (puede estar incompleto)")
            .font(.callout.weight(.semibold))
        ScrollView {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
        HStack {
            Button("Copiar") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .help("Copia el texto recuperado sin cambiar el documento")
            Button("Insertar como texto incompleto") { Task { await module.insertRecoveredTranscript() } }
                .help("Escribe este texto tal cual en el cursor. No ejecuta órdenes.")
            Button("Descartar", role: .cancel) { module.discardRecoveredTranscript() }
                .help("Olvida el texto recuperado")
        }
    }

    private var examplesList: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Self.examples, id: \.title) { group in
                GridRow {
                    Text(group.title).foregroundStyle(.secondary)
                    Text(group.phrases.map { "«\($0)»" }.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Manos libres", isOn: $module.continuousListening)
                .help("Activado: un toque inicia y cada pausa escribe lo dictado. Desactivado: revisas cada frase antes de insertarla.")
            Toggle("Mantener ⌥Espacio para hablar", isOn: $module.pushToTalkEnabled)
                .help("Mantén la tecla mientras hablas y suéltala para revisar el texto.")
            Toggle("Mayúscula inicial y punto final", isOn: $module.formalStyle)
            Picker("Idioma", selection: $module.localeIdentifier) {
                Text("Español (México)").tag("es-MX")
                Text("Español (España)").tag("es-ES")
                Text("English (US)").tag("en-US")
            }
            .pickerStyle(.menu)
            .disabled(module.state != .idle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    // MARK: - Propuesta por confirmar

    @ViewBuilder private func proposal(_ action: PendingVoiceAction) -> some View {
        Text(action.isDictation ? "¿Insertar este texto?" : "¿Aplicar este cambio?").font(.headline)
        if let text = module.pendingDictationText {
            TextField("Texto a insertar", text: Binding(
                get: { module.pendingDictationText ?? text },
                set: { module.updatePendingDictation($0) }
            ), axis: .vertical)
            .lineLimit(2...5)
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                Task { await module.confirmPending() }
                return .handled
            }
        } else {
            ScrollView {
                Text(action.preview)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Text("Escuché: \(action.transcript)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        HStack {
            Button("Confirmar") { Task { await module.confirmPending() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Confirmar con Enter o diciendo «sí»")
                .disabled(module.pendingDictationText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
            Button("Descartar", role: .cancel) {
                module.cancelPending()
                if module.isListening && !module.continuousListening {
                    Task { await module.cancelDictation() }
                }
            }
            .keyboardShortcut(.cancelAction)
            .help("Descartar con Esc o diciendo «no»")
            Button("Repetir") {
                Task {
                    await module.repeatPending()
                    showHUD = true
                }
            }
            .help("Descarta la propuesta y vuelve a escuchar")
        }
        if !action.isDictation {
            Button("No era una orden: escribirlo como texto") { module.usePendingAsDictation() }
                .buttonStyle(.link)
                .font(.callout)
        }
        if module.isListening {
            Text(module.microphoneReady ? "Te escucho: di «sí», «no» o «repetir»." : "Preparando micrófono…")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(module.inputLevel))
                .accessibilityLabel("Nivel del micrófono")
            if !module.partialTranscript.isEmpty {
                Text("Escuchando: \(module.partialTranscript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if module.lastCommandFeedback == VoiceModule.decisionHint {
                Text("No entendí la respuesta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Responder por voz") { Task { await module.listenForPendingDecision() } }
                .disabled(module.state == .processing)
                .help("Abre el micrófono para decir «sí», «no» o «repetir»")
        }
    }
}
