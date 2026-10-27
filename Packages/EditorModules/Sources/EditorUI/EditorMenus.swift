import SwiftUI
import EditorEngine
import ExportFeature

private struct SessionKey: FocusedValueKey { typealias Value = EditorSession }
private struct TitleKey: FocusedValueKey { typealias Value = String }
private struct NewDocumentKey: FocusedValueKey { typealias Value = () -> Void }
private struct NavigationVisibleKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct InspectorVisibleKey: FocusedValueKey { typealias Value = Binding<Bool> }
extension FocusedValues {
    var writingSession: EditorSession? {
        get { self[SessionKey.self] }
        set { self[SessionKey.self] = newValue }
    }
    var writingTitle: String? {
        get { self[TitleKey.self] }
        set { self[TitleKey.self] = newValue }
    }
    var newDocument: (() -> Void)? {
        get { self[NewDocumentKey.self] }
        set { self[NewDocumentKey.self] = newValue }
    }
    var navigationVisible: Binding<Bool>? {
        get { self[NavigationVisibleKey.self] }
        set { self[NavigationVisibleKey.self] = newValue }
    }
    var inspectorVisible: Binding<Bool>? {
        get { self[InspectorVisibleKey.self] }
        set { self[InspectorVisibleKey.self] = newValue }
    }
}

/// Lado de la barra de navegación; el inspector ocupa el contrario.
public enum SidebarSide: String, CaseIterable, Sendable {
    case leading, trailing
    public static let storageKey = "editor.sidebarSide"
}

public struct EditorMenus: Commands {
    @FocusedValue(\.writingSession) private var session
    @FocusedValue(\.writingTitle) private var title
    @FocusedValue(\.newDocument) private var newDocument
    @FocusedValue(\.navigationVisible) private var navigationVisible
    @FocusedValue(\.inspectorVisible) private var inspectorVisible
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nuevo escrito") { newDocument?() }
                .keyboardShortcut("n")
                .disabled(newDocument == nil)
        }
        CommandMenu("Formato") {
            Group {
            Button("Negrita") { session?.send(.toggleBold) }.keyboardShortcut("b")
            Button("Cursiva") { session?.send(.toggleItalic) }.keyboardShortcut("i")
            Button("Código") { session?.send(.toggleCode) }.keyboardShortcut("e")
            Divider()
            Button("Título") { session?.send(.heading(1)) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Subtítulo") { session?.send(.heading(2)) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Lista") { session?.send(.bulletList) }
            Button("Cita") { session?.send(.quote) }
            Button("Enlace…") { session?.send(.insertLink) }.keyboardShortcut("k")
            }.disabled(session == nil || session?.readingMode == true)
        }
        CommandGroup(replacing: .sidebar) {
            Button(navigationVisible?.wrappedValue == true ? "Ocultar navegación" : "Mostrar navegación") {
                navigationVisible?.wrappedValue.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(navigationVisible == nil)
            Button(inspectorVisible?.wrappedValue == true ? "Ocultar inspector" : "Mostrar inspector") {
                inspectorVisible?.wrappedValue.toggle()
            }
            .keyboardShortcut("0", modifiers: [.option, .command])
            .disabled(inspectorVisible == nil)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button(session?.focusMode == true ? "Salir de concentración" : "Concentración") { session?.focusMode.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(session?.readingMode == true ? "Volver a escribir" : "Vista de lectura") { session?.readingMode.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(session?.paragraphFocus == true ? "Desactivar foco de párrafo" : "Foco de párrafo") { session?.paragraphFocus.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button(session?.typewriterMode == true ? "Desactivar máquina de escribir" : "Máquina de escribir") { session?.typewriterMode.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .printItem) {
            Button("Imprimir o guardar PDF…") {
                guard let view = session?.textView else { return }
                PrintDocument.run(text: view.string, title: title ?? "Sin título", window: view.window, documentURL: NSDocumentController.shared.currentDocument?.fileURL)
            }.keyboardShortcut("p").disabled(session == nil)
        }
    }
}
