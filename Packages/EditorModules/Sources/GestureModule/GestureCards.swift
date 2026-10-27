import SwiftUI

public struct GestureCursor: View {
    @Bindable private var module: GestureModule

    public init(module: GestureModule) { self.module = module }

    public var body: some View {
        GeometryReader { geometry in
            if module.running, let point = module.cursorPoint {
                Circle()
                    .fill(module.isDraggingParagraph ? Color.orange : Color.accentColor)
                    .frame(width: module.isDraggingParagraph ? 20 : 14,
                           height: module.isDraggingParagraph ? 20 : 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: point.x * geometry.size.width,
                              y: point.y * geometry.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Tarjetas flotantes de las sesiones de gesto. Las envuelve la app en
/// `AnyView` para `EditorScreen(gestureCards:)`; sin la pieza, `nil`.
///
/// Nada cambia a ciegas: la opción actual se resalta y el documento la
/// previsualiza. Clic en una opción la confirma directamente; ✕ cancela y
/// restaura.
public struct GestureCards: View {
    @Bindable private var module: GestureModule

    public init(module: GestureModule) {
        self.module = module
    }

    public var body: some View {
        VStack(spacing: 10) {
            if module.isToneSession {
                ToneOptionsCard(module: module)
            } else if module.hasPinchSession {
                PinchOptionsCard(module: module)
            }
            if module.hasLengthSession {
                LengthOptionsCard(module: module)
            }
            if module.hasImageSizeSession {
                ImageSizeCard(module: module)
            }
            if let toast = module.lengthToast, !module.hasLengthSession {
                LengthToast(module: module, text: toast)
            }
        }
    }
}

struct ImageSizeCard: View {
    @Bindable var module: GestureModule

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo")
            Text("Imagen · ancho \(module.imageWidth)")
                .monospacedDigit()
            Button("Reducir") { Task { await module.setImageWidth(module.imageWidth - 40) } }
                .disabled(module.imageWidth <= 80)
            Button("Ampliar") { Task { await module.setImageWidth(module.imageWidth + 40) } }
                .disabled(module.imageWidth >= 1200)
            Button("Confirmar") { Task { await module.confirmImageSizeSession() } }
            Button("Cancelar") { module.cancelImageSizeSession() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

/// Opciones de la sesión de pinza: tarjeta flotante sobre la palabra,
/// con las opciones en tira horizontal para que el movimiento de la mano
/// (izquierda ↔ derecha) mapee directo a la pantalla.
struct PinchOptionsCard: View {
    @Bindable var module: GestureModule

    var body: some View {
        let options = module.sessionOptions
        let current = module.sessionIndex
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(module.isPinchManual ? "Sinónimos · prueba" : "Sinónimos · pinza")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(min(current + 1, max(options.count, 1))) de \(options.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    module.cancelPinchSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancelar y restaurar la palabra")
            }

            // Opción actual en grande: es lo que el documento previsualiza.
            HStack(spacing: 6) {
                Text(currentOption(options: options, current: current))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                // Guía de dirección: cuánto falta para cambiar de opción.
                directionHint
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            Button {
                                Task { await module.commitPinchSession(at: index) }
                            } label: {
                                Text(option)
                                    .font(.callout)
                                    .fontWeight(index == current ? .semibold : .regular)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        index == current
                                            ? Color.accentColor
                                            : Color(nsColor: .controlBackgroundColor).opacity(0.7),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(index == current ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .help("Confirmar “\(option)”")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: current) { _, new in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            HStack {
                Text(module.sessionUpgraded ? "Sugerencias de IA"
                     : module.synonymNotice.map { "Sugerencias locales · \($0)" } ?? "Sugerencias locales…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                Spacer()
                Text(module.isPinchManual ? "Clic para confirmar" : "Suelta para confirmar · abre para cancelar")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private func currentOption(options: [String], current: Int) -> String {
        guard options.indices.contains(current) else { return "" }
        return options[current]
    }

    /// Flechas que se encienden según hacia dónde (y cuánto falta para) cambiar.
    private var directionHint: some View {
        let delta = module.sessionDelta
        let threshold = GestureTuning.optionStep
        let progress = min(abs(delta) / threshold, 1)
        let leftStrength = delta < -0.008 ? 0.35 + 0.65 * progress : 0.18
        let rightStrength = delta > 0.008 ? 0.35 + 0.65 * progress : 0.18
        return HStack(spacing: 10) {
            Image(systemName: "arrow.left")
                .font(.caption)
                .foregroundStyle(.blue)
                .opacity(leftStrength)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.blue)
                .opacity(rightStrength)
        }
    }
}

/// Tono de la oración mientras la pinza está activa: izquierda enfría,
/// derecha templa y el documento previsualiza cada nivel. Clic en un nivel
/// lo confirma; ✕ cancela.
struct ToneOptionsCard: View {
    @Bindable var module: GestureModule

    private static let tints: [Color] = [.blue, .secondary, .orange]

    var body: some View {
        let options = module.toneOptions
        let labels = module.toneLabels
        let current = module.sessionIndex
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(tint(current))
                Text(module.isPinchManual ? "Tono · prueba" : "Tono · pinza")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(labels.indices.contains(current) ? labels[current] : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    module.cancelPinchSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancelar y restaurar la oración")
                .accessibilityLabel("Cancelar")
            }

            scale(current: current, count: options.count)

            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let waiting = module.toneLoading && index != ToneLevel.original.rawValue
                let missing = module.toneUnavailableReason(at: index)
                Button {
                    Task { await module.commitPinchSession(at: index) }
                } label: {
                    HStack(alignment: .top) {
                        Text(index == ToneLevel.original.rawValue ? "tu texto"
                             : labels.indices.contains(index) ? labels[index] : "")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint(index))
                            .frame(width: 52, alignment: .leading)
                        Text(option)
                            .font(.system(size: 13))
                            .fontWeight(index == current ? .semibold : .regular)
                            .foregroundStyle(waiting || missing != nil ? .secondary : .primary)
                            .lineLimit(4)
                        Spacer()
                        if index == current {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(tint(index))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        index == current
                            ? tint(index).opacity(0.16)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(waiting || missing != nil)
                .help(waiting ? "Aún generando esta versión…" : missing ?? "Confirmar: \(option)")
            }

            HStack {
                Text(module.toneLoading ? "Generando con Apple Intelligence…" : "Generadas en este Mac")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(module.isPinchManual ? "Clic para confirmar" : "Mueve ↔ · suelta para confirmar")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private func tint(_ index: Int) -> Color {
        Self.tints.indices.contains(index) ? Self.tints[index] : .secondary
    }

    /// Escala frío → cálido con la posición actual: la mano se mueve sobre
    /// el mismo eje que se ve en pantalla.
    private func scale(current: Int, count: Int) -> some View {
        let fraction = count > 1 ? Double(current) / Double(count - 1) : 0.5
        return HStack(spacing: 8) {
            Image(systemName: "snowflake")
                .font(.caption2)
                .foregroundStyle(.blue)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.blue, .gray.opacity(0.5), .orange],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 14, height: 14)
                        .offset(x: (geometry.size.width - 14) * fraction)
                        .animation(.easeOut(duration: 0.15), value: current)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Image(systemName: "sun.max.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        .accessibilityHidden(true)
    }
}

/// Niveles de longitud del párrafo, visibles mientras el gesto a dos
/// manos está activo. Acercar acorta, separar amplía; el documento
/// previsualiza cada nivel. Clic en un nivel lo confirma; ✕ cancela.
struct LengthOptionsCard: View {
    @Bindable var module: GestureModule

    var body: some View {
        let options = module.lengthOptions
        let labels = module.lengthLabels
        let current = module.lengthIndex
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hands.clap.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(module.isLengthManual ? "Longitud · prueba" : "Longitud · dos manos")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(currentLabel(labels: labels, current: current))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    module.cancelLengthSession()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancelar y restaurar el párrafo")
            }

            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    Task { await module.previewLengthOption(at: index) }
                } label: {
                    levelRow(index: index, text: option, labels: labels, current: current)
                }
                .buttonStyle(.plain)
                .disabled(module.lengthLoading && index != LengthLevel.medio.rawValue
                          || module.lengthUnavailableReason(at: index) != nil)
                .help(index != LengthLevel.medio.rawValue && module.lengthLoading
                      ? "Aún generando esta versión…"
                      : module.lengthUnavailableReason(at: index)
                        ?? "\(index < labels.count ? labels[index].capitalized : "Versión") en vista previa: \(option)")
            }

            HStack(spacing: 8) {
                Button("Confirmar") { Task { await module.confirmLengthSession() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(module.lengthLoading && module.lengthIndex != LengthLevel.medio.rawValue)
                    .help("Aplica la versión previsualizada")
                Button("Cancelar") { module.cancelLengthSession() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Cancela y restaura el párrafo")
                Spacer()
            }

            HStack {
                Text(module.lengthLoading ? "Generando con Apple Intelligence… medio ya disponible" : "Generadas en este Mac")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                // Acercar (juntar) acorta · separar amplía.
                directionHint
                Spacer()
                Text(module.isLengthManual ? "Clic previsualiza · Confirma abajo" : "Retira UNA mano para confirmar")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private func currentLabel(labels: [String], current: Int) -> String {
        guard labels.indices.contains(current) else { return "" }
        return "\(labels[current]) · \(current + 1) de \(labels.count)"
    }

    private func levelRow(index: Int, text: String, labels: [String], current: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(index < labels.count ? labels[index] : "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(module.lengthLoading && index != LengthLevel.medio.rawValue
                     || module.lengthUnavailableReason(at: index) != nil
                     ? ""
                     : "\(text.split(whereSeparator: \.isWhitespace).count) pal.\(text == module.lengthOriginalText ? " · tu texto" : "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(width: 52, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                .fontWeight(index == current ? .semibold : .regular)
                .foregroundStyle(module.lengthUnavailableReason(at: index) != nil ? .secondary : .primary)
                .lineLimit(6)
            Spacer()
            if index == current {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            index == current
                ? Color.accentColor.opacity(0.14)
                : Color(nsColor: .controlBackgroundColor).opacity(0.6),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    /// ← se enciende al acercar (hacia corto), → al separar (hacia largo).
    private var directionHint: some View {
        let delta = module.lengthSessionDelta
        let threshold = GestureTuning.lengthSpanStep
        let progress = min(abs(delta) / threshold, 1)
        let leftStrength = delta < -0.008 ? 0.35 + 0.65 * progress : 0.18
        let rightStrength = delta > 0.008 ? 0.35 + 0.65 * progress : 0.18
        return HStack(spacing: 6) {
            Image(systemName: "arrow.left")
                .font(.caption)
                .foregroundStyle(.green)
                .opacity(leftStrength)
            Text("acercar · separar")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.green)
                .opacity(rightStrength)
        }
    }
}

/// Confirmación visible tras aplicar un nivel, con Deshacer en un clic.
/// Tranquilidad ante el gesto: si el párrafo cambió sin querer, se revierte aquí.
struct LengthToast: View {
    @Bindable var module: GestureModule
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.callout)
            Spacer()
            if module.lengthToastCanUndo {
                Button("Deshacer") {
                    Task { await module.undoLengthCommit() }
                }
                .buttonStyle(.link)
            }
            Button {
                module.dismissLengthToast()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cerrar aviso")
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }
}
