import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DocumentKit
import EditorUI
import ModuleKit
// Pieza Lego: Voz. Borra este import y el bloque marcado más abajo para
// compilar sin voz; el editor sigue funcionando completo.
import VoiceModule
// Pieza Lego: Gestos. Borra este import y el bloque marcado más abajo para
// compilar sin gestos; el editor sigue funcionando completo y sin cámara.
import GestureModule

extension UTType {
    static let editorMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct TextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.editorMarkdown, .plainText, .utf8PlainText]
    static let writableContentTypes: [UTType] = [.editorMarkdown, .plainText]
    var text = ""

    init() {}
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = try UTF8Document.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: UTF8Document.encode(text))
    }
}

// MARK: - Ventana única

/// Todo se abre en la misma ventana. Nunca se crea una ventana nueva para
/// abrir un documento: se lee el archivo y se le pide a la ventana existente
/// que lo cargue en su propio `Binding` y reubique su `NSDocument`.
@MainActor
func writableSingleWindowURL(for requestedURL: URL) -> URL {
    guard requestedURL.path.hasPrefix(Bundle.main.bundleURL.path) else { return requestedURL }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Samples", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(requestedURL.lastPathComponent)
    if !FileManager.default.fileExists(atPath: destination.path) {
        try? FileManager.default.copyItem(at: requestedURL, to: destination)
    }
    return destination
}

@MainActor
func requestSameWindowOpen(_ requestedURL: URL) {
    let url = writableSingleWindowURL(for: requestedURL)
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
        let data = try Data(contentsOf: url)
        let text = try UTF8Document.decode(data)
        SingleWindowCoordinator.shared.requestOpen(url: url, text: text)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSDocumentController.shared.documents.first?.windowControllers.first?.window {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
    } catch {
        NSApplication.shared.presentError(error)
    }
}

// NOTA: no se subclasea NSDocumentController. SwiftUI DocumentGroup instala su
// propio PlatformDocumentController en applicationWillFinishLaunching; instanciar
// una subclase propia antes provoca crash en createDocumentClassIfNeeded
// (swift_isUniquelyReferenced con puntero nulo). La ventana única se logra con
// SingleWindowCoordinator + mergeExtraWindowIfNeeded + Nuevo focused (EditorMenus).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // La primera ventana la crea `EditorApp.init`; el sistema no debe duplicarla.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = NSDocumentController.shared.documents.first?.windowControllers.first?.window {
            window.makeKeyAndOrderFront(nil)
        } else if NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
        }
        return false
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        guard !NSDocumentController.shared.documents.isEmpty else { return false }
        requestSameWindowOpen(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard !NSDocumentController.shared.documents.isEmpty else {
            // Arranque en frío con varios archivos: una sola primera ventana.
            guard let first = filenames.first else { return }
            NSDocumentController.shared.openDocument(
                withContentsOf: URL(fileURLWithPath: first),
                display: true
            ) { _, _, error in
                if let error { NSApplication.shared.presentError(error) }
            }
            for name in filenames.dropFirst() {
                NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: name))
            }
            return
        }
        guard let first = filenames.first else { return }
        requestSameWindowOpen(URL(fileURLWithPath: first))
        for name in filenames.dropFirst() {
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: name))
        }
    }
}

@MainActor
@main
struct EditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // MARK: - Composition root (dependencias explícitas, sin singletons)
    private let commandBus = EditorCommandBus()
    private let moduleRegistry = ModuleRegistry()

    // MARK: - Pieza Lego: Voz (quitar para compilar sin voz)
    // Borra estas dos líneas, el `import VoiceModule` de arriba, el uso de
    // `voicePanel` en DocumentGroup y `EditorSettings(modules:)` vuelve a
    // `EditorSettings()`. Nada más cambia: el editor no depende de voz.
    private let voiceModule = VoiceModule()
    private var voicePanel: AnyView { AnyView(VoiceControl(module: voiceModule)) }

    // MARK: - Pieza Lego: Gestos (quitar para compilar sin gestos)
    // Borra estas líneas, el `import GestureModule` de arriba y los parámetros
    // `gesture*`/`onGesture*` en DocumentGroup. Nada más cambia: el editor no
    // depende de gestos y jamás pide permiso de cámara.
    private let gestureModule = GestureModule()
    private var gesturePanel: AnyView { AnyView(GestureControl(module: gestureModule)) }
    private var gestureCards: AnyView { AnyView(GestureCards(module: gestureModule)) }
    private var gestureCursor: AnyView { AnyView(GestureCursor(module: gestureModule)) }

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let bus = commandBus
        let voice = voiceModule
        let gestures = gestureModule
        let registry = moduleRegistry
        registry.register(VoiceModule.descriptor)
        registry.register(GestureModule.descriptor)
        Task { @MainActor in
            try? await voice.start(context: EditorModuleContext(commandBus: bus))
            voice.enablePushToTalk()
            try? await gestures.start(context: EditorModuleContext(commandBus: bus))
        }
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }

    private func openFileInCurrentWindow(_ requestedURL: URL) {
        requestSameWindowOpen(requestedURL)
    }

    var body: some Scene {
        DocumentGroup(newDocument: TextDocument()) { configuration in
            EditorScreen(
                text: configuration.$document.text,
                title: configuration.fileURL?.deletingPathExtension().lastPathComponent ?? "Sin título",
                currentURL: configuration.fileURL,
                recentURLs: NSDocumentController.shared.recentDocumentURLs,
                openFile: openFileInCurrentWindow,
                startOnHome: true,
                commandBus: commandBus,
                voicePanel: voicePanel,
                modules: moduleRegistry,
                gesturePanel: gesturePanel,
                gestureCards: gestureCards,
                gestureCursor: gestureCursor,
                onGestureDocument: { [gestures = gestureModule] text, selection in
                    gestures.updateDocument(text: text, selection: selection)
                },
                onEditorReady: { [gestures = gestureModule, voice = voiceModule] session in
                    gestures.imageHitTest = { [weak session] point in
                        session?.imageRange(atNormalizedPoint: point)
                    }
                    gestures.textHitTest = { [weak session] point in
                        session?.textLocation(atNormalizedPoint: point)
                    }
                    voice.prepareRewrite = { [weak session] instruction in
                        guard let session else { throw CancellationError() }
                        return try await session.prepareRewrite(instruction: instruction)
                    }
                    voice.acceptRewrite = { [weak session] in session?.acceptRewrite() == true }
                    voice.discardRewrite = { [weak session] in session?.discardRewrite() }
                }
            )
        }
        .defaultSize(width: 1440, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            EditorMenus()
            CommandGroup(after: .textEditing) {
                Button("Buscar…") {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }.keyboardShortcut("f")
            }
        }
        Settings { EditorSettings(modules: moduleRegistry) }
    }
}
