import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditorCore
import EditorEngine
import DesignSystem
import ExportFeature
import ModuleKit
import DocumentKit

public struct EditorScreen: View {
    private struct LibraryRequest: Hashable {
        let folders: [URL]
        let revision: Int
    }

    /// Una pantalla visitada: la biblioteca de `destination` (lista de notas)
    /// o la nota abierta. Con esto el botón Volver regresa al sitio exacto.
    private struct ScreenSnapshot: Equatable {
        let destination: LibraryDestination
        let inNote: Bool
    }

    private enum LibraryDestination: Hashable {
        case home, recents, favorites, archived, drafts, trash
        case folder(URL)

        var title: String {
            switch self {
            case .home: "Inicio"
            case .recents: "Recientes"
            case .favorites: "Favoritos"
            case .archived: "Archivado"
            case .drafts: "Sin título"
            case .trash: "Papelera de EditorFinal"
            case .folder(let url): url.lastPathComponent
            }
        }
    }

    @Binding private var text: String
    @State private var documentTitle: String
    private let currentURL: URL?
    private let recentURLs: [URL]
    private let openFile: (URL) -> Void
    private let startOnHome: Bool
    // Pieza Lego: Voz. `commandBus` recibe los comandos de cualquier módulo
    // de entrada; `voicePanel` es la vista del módulo (`AnyView` para no
    // depender de VoiceModule) o `nil` si la pieza está quitada.
    private let commandBus: EditorCommandBus
    private let voicePanel: AnyView?
    private let modules: ModuleRegistry
    // Pieza Lego: Gestos. `gesturePanel` es el botón+popover de la cámara y
    // `gestureCards` las tarjetas flotantes de sesión (`AnyView` para no
    // depender de GestureModule). `onGestureDocument` empuja texto+selección
    // al módulo; `nil` sin la pieza.
    private let gesturePanel: AnyView?
    private let gestureCards: AnyView?
    private let gestureCursor: AnyView?
    private let onGestureDocument: ((String, NSRange) -> Void)?
    private let onEditorReady: ((EditorSession) -> Void)?
    @State private var session = EditorSession()
    @State private var showSidebar = true
    @State private var showOutline = false
    @State private var showHome: Bool
    @State private var hasAppeared = false
    @State private var launchHome: Bool
    @State private var hasChosenDocument = false
    @State private var destination = LibraryDestination.home
    @State private var search = ""
    @State private var showReadingControls = false
    @State private var showInspector = true
    @AppStorage("editor.fontSize") private var fontSize = 18.0
    @AppStorage("editor.fontFamily") private var family = "system"
    @AppStorage("editor.fontWeight") private var fontWeight = "regular"
    @AppStorage("editor.lineSpacing") private var spacing = 6.0
    @AppStorage("editor.paragraphSpacing") private var paragraph = 0.0
    @AppStorage("editor.tracking") private var tracking = 0.0
    @AppStorage("editor.alignment") private var alignment = "natural"
    @AppStorage("editor.textColor") private var lightTextHex = "auto"
    @AppStorage("editor.backgroundColor") private var lightBackgroundHex = "auto"
    @AppStorage("editor.accentColor") private var lightAccentHex = "auto"
    @AppStorage("editor.textColorDark") private var darkTextHex = "auto"
    @AppStorage("editor.backgroundColorDark") private var darkBackgroundHex = "auto"
    @AppStorage("editor.accentColorDark") private var darkAccentHex = "auto"
    @AppStorage("editor.readingWidth") private var width = 760.0
    @AppStorage("editor.syntax") private var syntax = true
    @AppStorage("editor.statistics") private var statistics = true
    @AppStorage("editor.appearance") private var appearance = "system"
    @AppStorage(SidebarSide.storageKey) private var sidebarSide = SidebarSide.leading.rawValue
    @AppStorage("editor.customFolders") private var customFolderPaths = ""
    @AppStorage("editor.favorites") private var favoritePaths = ""
    @AppStorage("editor.archived") private var archivedPaths = ""
    @AppStorage("editor.trashed") private var trashedPaths = ""
    @AppStorage(CloudDocuments.enabledKey) private var saveToICloud = false
    @AppStorage(CloudDocuments.pathKey) private var cloudFolderPath = ""
    @State private var autosaveWorkItem: DispatchWorkItem?
    @State private var openingDocument = false
    @State private var folderDocuments: [URL] = []
    @State private var libraryRevision = 0
    @State private var imageAccessAsked: Set<String> = []
    @State private var imageAccessRevision = 0
    /// Carpeta temporal de las imágenes de un documento sin guardar; se vacía al guardarlo.
    @State private var draftImagesURL = DraftImages.makeDocumentURL()
    // Pantallas anteriores, de la más reciente a la más antigua, para volver.
    @State private var screenHistory: [ScreenSnapshot] = []
    @State private var singleWindow = SingleWindowCoordinator.shared

    public init(text: Binding<String>, title: String, currentURL: URL?, recentURLs: [URL], openFile: @escaping (URL) -> Void, startOnHome: Bool = false, commandBus: EditorCommandBus = EditorCommandBus(), voicePanel: AnyView? = nil, modules: ModuleRegistry = ModuleRegistry(), gesturePanel: AnyView? = nil, gestureCards: AnyView? = nil, gestureCursor: AnyView? = nil, onGestureDocument: ((String, NSRange) -> Void)? = nil, onEditorReady: ((EditorSession) -> Void)? = nil) {
        _text = text
        _documentTitle = State(initialValue: title)
        self.currentURL = currentURL
        self.recentURLs = recentURLs
        self.openFile = openFile
        self.startOnHome = startOnHome
        self.commandBus = commandBus
        self.voicePanel = voicePanel
        self.modules = modules
        self.gesturePanel = gesturePanel
        self.gestureCards = gestureCards
        self.gestureCursor = gestureCursor
        self.onGestureDocument = onGestureDocument
        self.onEditorReady = onEditorReady
        _showHome = State(initialValue: startOnHome || (currentURL == nil && text.wrappedValue.isEmpty))
        _launchHome = State(initialValue: startOnHome)
    }

    private var style: WritingStyle {
        WritingStyle(
            size: fontSize, family: family, spacing: spacing, paragraph: paragraph,
            syntax: syntax, tracking: tracking, alignment: alignment, weight: fontWeight,
            textHex: resolvedTextHex, backgroundHex: resolvedBackgroundHex, accentHex: resolvedAccentHex
        )
    }

    @Environment(\.colorScheme) private var systemScheme

    /// Con Tema en Sistema se sigue al Mac; con Claro/Oscuro se fuerza el modo.
    private var resolvedIsDark: Bool {
        if appearance == "dark" { return true }
        if appearance == "light" { return false }
        return systemScheme == .dark
    }

    private var resolvedTextHex: String { resolvedIsDark ? darkTextHex : lightTextHex }
    private var resolvedBackgroundHex: String { resolvedIsDark ? darkBackgroundHex : lightBackgroundHex }
    private var resolvedAccentHex: String { resolvedIsDark ? darkAccentHex : lightAccentHex }

    /// El popover siempre edita los colores del modo que se está viendo.
    private var popoverText: Binding<String> {
        Binding(
            get: { resolvedIsDark ? darkTextHex : lightTextHex },
            set: { if resolvedIsDark { darkTextHex = $0 } else { lightTextHex = $0 } }
        )
    }

    private var popoverBackground: Binding<String> {
        Binding(
            get: { resolvedIsDark ? darkBackgroundHex : lightBackgroundHex },
            set: { if resolvedIsDark { darkBackgroundHex = $0 } else { lightBackgroundHex = $0 } }
        )
    }

    private var popoverAccent: Binding<String> {
        Binding(
            get: { resolvedIsDark ? darkAccentHex : lightAccentHex },
            set: { if resolvedIsDark { darkAccentHex = $0 } else { lightAccentHex = $0 } }
        )
    }

    // MARK: - Cromado con el tema (texto/fondo/acento personalizados)
    private var chromePrimary: Color {
        style.usesCustomText ? Color(nsColor: style.effectiveTextColor) : .primary
    }
    private var chromeSecondary: Color {
        style.usesCustomText ? Color(nsColor: style.secondaryTextColor) : .secondary
    }
    private var chromeTertiary: Color {
        style.usesCustomText ? Color(nsColor: style.tertiaryTextColor) : Color(nsColor: .tertiaryLabelColor)
    }
    private var themeAccent: Color {
        style.usesCustomAccent ? Color(nsColor: style.effectiveAccentColor) : .accentColor
    }
    private var homeBackground: Color {
        style.usesCustomBackground ? Color(nsColor: style.effectiveBackgroundColor) : Color(nsColor: .textBackgroundColor)
    }
    private var cardBackground: Color {
        style.usesCustomBackground ? Color(nsColor: style.chromeCard) : Color(nsColor: .controlBackgroundColor)
    }
    private var cardBorder: Color {
        style.usesCustomBackground ? Color(nsColor: style.chromeCardBorder) : Color.primary.opacity(0.10)
    }
    private var isShowingHome: Bool { showHome || (startOnHome && !hasChosenDocument) }
    /// Pantalla que se está viendo ahora (biblioteca o nota abierta).
    private var currentScreen: ScreenSnapshot {
        ScreenSnapshot(destination: destination, inNote: !isShowingHome)
    }
    /// Documento contra el que se resuelven las imágenes: el archivo o, sin guardar, la carpeta temporal.
    private var imageDocumentURL: URL {
        activeDocument?.fileURL ?? currentURL ?? draftImagesURL
    }
    private var activeDocument: NSDocument? {
        NSDocumentController.shared.currentDocument ?? NSDocumentController.shared.documents.first
    }
    /// Documento propio de esta ventana (no el global "current", que puede ser
    /// de otra ventana cuando hay una secundaria). Se usa para no cerrar la
    /// ventana equivocada al imponer ventana única.
    private var ownDocument: NSDocument? {
        if let window = session.textView?.window {
            let controller = NSDocumentController.shared
            if let mine = controller.documents.first(where: { document in
                document.windowControllers.contains(where: { $0.window == window })
            }) {
                return mine
            }
        }
        return activeDocument
    }
    private var activeHeading: Int? { session.headings.last(where: { $0.offset <= session.cursorOffset })?.id }
    private var savedFolders: [URL] {
        StoredPaths.decode(customFolderPaths).sorted().map { URL(fileURLWithPath: $0) }
    }
    private var sampleFolder: URL? {
        Bundle.main.url(forResource: "Samples", withExtension: nil)
    }
    private var savedSampleFolder: URL? {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Samples", isDirectory: true)
        return folder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    /// Carpeta de iCloud Drive autorizada, si el guardado en iCloud está activo.
    private var cloudFolder: URL? {
        guard saveToICloud, !cloudFolderPath.isEmpty else { return nil }
        return CloudDocuments.folder
    }
    private var folders: [URL] {
        let candidates = Array(Set((sampleFolder.map { [$0] } ?? []) + (savedSampleFolder.map { [$0] } ?? []) + (cloudFolder.map { [$0] } ?? []) + savedFolders + recentURLs.compactMap { url in
            guard url.isFileURL else { return nil }
            return url.deletingLastPathComponent().standardizedFileURL
        } + (currentURL.map { [$0.deletingLastPathComponent().standardizedFileURL] } ?? [])))
        let writableNames = Set(candidates.filter { !$0.path.hasPrefix(Bundle.main.bundleURL.path) }.map(\.lastPathComponent))
        return candidates.filter { !$0.path.hasPrefix(Bundle.main.bundleURL.path) || !writableNames.contains($0.lastPathComponent) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private var availableURLs: [URL] {
        let urls = Array(Set(recentURLs + folderDocuments + (currentURL.map { [$0] } ?? [])))
        let writableNames = Set(urls.filter { !$0.path.hasPrefix(Bundle.main.bundleURL.path) }.map(\.lastPathComponent))
        return urls.filter { !$0.path.hasPrefix(Bundle.main.bundleURL.path) || !writableNames.contains($0.lastPathComponent) }
    }
    private var favoriteKeys: Set<String> { StoredPaths.decode(favoritePaths) }
    private var archivedKeys: Set<String> { StoredPaths.decode(archivedPaths) }
    private var trashedKeys: Set<String> { StoredPaths.decode(trashedPaths) }
    private func storageKey(for url: URL) -> String { url.standardizedFileURL.path }
    private func isFavorite(_ url: URL) -> Bool { favoriteKeys.contains(storageKey(for: url)) }
    private func isArchived(_ url: URL) -> Bool { archivedKeys.contains(storageKey(for: url)) }
    private func isTrashed(_ url: URL) -> Bool { trashedKeys.contains(storageKey(for: url)) }
    /// Tras renombrar, las marcas de biblioteca siguen al documento.
    private func moveStoredMarks(from oldURL: URL, to newURL: URL) {
        let old = storageKey(for: oldURL), new = storageKey(for: newURL)
        favoritePaths = StoredPaths.renaming(favoritePaths, from: old, to: new)
        archivedPaths = StoredPaths.renaming(archivedPaths, from: old, to: new)
        trashedPaths = StoredPaths.renaming(trashedPaths, from: old, to: new)
    }
    private var activeURLs: [URL] {
        let excluded = trashedKeys.union(archivedKeys)
        return availableURLs.filter { !excluded.contains(storageKey(for: $0)) }
    }
    private var orderedRecentURLs: [URL] {
        DocumentLibrary.orderedRecents(
            (currentURL.map { [$0] } ?? []) + recentURLs,
            available: availableURLs,
            excluding: trashedKeys.union(archivedKeys)
        )
    }
    private var draftURLs: [URL] {
        activeURLs.filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("Sin título") }
    }
    private func baseURLs(for dest: LibraryDestination) -> [URL] {
        switch dest {
        case .home:
            return activeURLs
        case .recents:
            return orderedRecentURLs
        case .favorites:
            let keys = favoriteKeys
            return activeURLs.filter { keys.contains(storageKey(for: $0)) }
        case .archived:
            let included = archivedKeys.subtracting(trashedKeys)
            return availableURLs.filter { included.contains(storageKey(for: $0)) }
        case .drafts:
            return draftURLs
        case .trash:
            let keys = trashedKeys
            return availableURLs.filter { keys.contains(storageKey(for: $0)) }
        case .folder(let folder):
            let trashed = trashedKeys
            return availableURLs.filter {
                $0.deletingLastPathComponent().standardizedFileURL == folder && !trashed.contains(storageKey(for: $0))
            }
        }
    }
    private var homeURLs: [URL] {
        let base = baseURLs(for: destination)
        let filtered = base.filter { search.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedStandardContains(search) }
        if destination == .recents && search.isEmpty {
            return filtered
        }
        return filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private func count(for dest: LibraryDestination) -> Int {
        if dest == .drafts && currentURL == nil && !text.isEmpty { return baseURLs(for: dest).count + 1 }
        return baseURLs(for: dest).count
    }
    private func toggleFavorite(_ url: URL) {
        favoritePaths = StoredPaths.toggling(favoritePaths, path: storageKey(for: url))
    }
    private func setArchived(_ url: URL, archived: Bool) {
        archivedPaths = StoredPaths.setting(archivedPaths, path: storageKey(for: url), present: archived)
    }
    private func setTrashed(_ url: URL, trashed: Bool) {
        trashedPaths = StoredPaths.setting(trashedPaths, path: storageKey(for: url), present: trashed)
    }
    private func restore(_ url: URL) {
        trashedPaths = StoredPaths.setting(trashedPaths, path: storageKey(for: url), present: false)
        archivedPaths = StoredPaths.setting(archivedPaths, path: storageKey(for: url), present: false)
    }
    private func moveToSystemTrash(_ url: URL) {
        let key = storageKey(for: url)
        if currentURL?.standardizedFileURL.path == key {
            NSApplication.shared.presentError(NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "No se puede enviar a la papelera del Mac el documento abierto. Ciérralo primero."]
            ))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        } catch {
            NSApplication.shared.presentError(error)
            return
        }
        favoritePaths = StoredPaths.setting(favoritePaths, path: key, present: false)
        archivedPaths = StoredPaths.setting(archivedPaths, path: key, present: false)
        trashedPaths = StoredPaths.setting(trashedPaths, path: key, present: false)
        libraryRevision += 1
    }
    private func emptyTrash() {
        for url in baseURLs(for: .trash) {
            moveToSystemTrash(url)
        }
    }
    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public var body: some View {
        // Navegación e inspector son columnas fijas: con `.inspector` el panel
        // flotaba sobre el texto al estrechar la ventana. Cada uno ocupa el
        // lado contrario del otro según `editor.sidebarSide`.
        HSplitView {
            if navigationOnTrailing { inspectorColumn } else { navigationColumn }
            if isShowingHome {
                home
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if showOutline && !session.focusMode && !session.headings.isEmpty {
                    documentOutline
                        .frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
                }
                writingCanvas
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: style.effectiveBackgroundColor))
            }
            if navigationOnTrailing { navigationColumn } else { inspectorColumn }
        }
        .background(Color(nsColor: style.effectiveBackgroundColor))
        // La barra superior (titlebar) no hereda el fondo del contenido y se
        // veía blanca con temas personalizados: se tiñe igual que el lienzo.
        // En "auto" se conserva la barra nativa del sistema.
        .toolbarBackground(Color(nsColor: style.effectiveBackgroundColor), for: .windowToolbar)
        .toolbarBackgroundVisibility(style.usesCustomBackground ? .visible : .automatic, for: .windowToolbar)
        .frame(minWidth: 780, minHeight: 480)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .focusedSceneValue(\.writingSession, session)
        .focusedSceneValue(\.writingTitle, documentTitle)
        .focusedSceneValue(\.newDocument, createDocument)
        .focusedSceneValue(\.navigationVisible, panelBinding($showSidebar))
        .focusedSceneValue(\.inspectorVisible, isShowingHome ? nil : panelBinding($showInspector))
        .onChange(of: currentURL) { oldURL, newURL in
            if oldURL == nil, let newURL { adoptDraftImages(into: newURL) }
            libraryRevision += 1
            documentTitle = newURL?.deletingPathExtension().lastPathComponent ?? "Sin título"
            if hasAppeared && !launchHome { showHome = newURL == nil && text.isEmpty }
        }
        .onChange(of: session.readingMode) { _, reading in
            if !reading { focusEditor() }
        }
        .onChange(of: text) { _, newText in
            scheduleAutosave()
            // Pieza Lego: Gestos. El módulo trabaja sobre instantáneas; sin
            // este empuje no vería cambios programáticos (abrir documento).
            if let push = onGestureDocument {
                let sel = session.textView?.selectedRange()
                    ?? NSRange(location: min(session.cursorOffset, max(newText.utf16.count - 1, 0)), length: 0)
                push(newText, sel)
            }
        }
        .onChange(of: singleWindow.pendingOpen) { _, request in
            guard let request else { return }
            applySameWindowOpen(url: request.url, text: request.text)
        }
        .onChange(of: singleWindow.newDocumentRevision) { _, _ in
            createDocument()
        }
        .task(id: LibraryRequest(folders: folders, revision: libraryRevision)) {
            let documents = await DocumentLibrary.documents(in: folders)
            guard !Task.isCancelled else { return }
            folderDocuments = documents
        }
        .onChange(of: isShowingHome) { _, showing in
            if showing { libraryRevision += 1 }
        }
        // Cada cambio de pantalla guarda la anterior: así el botón Volver
        // regresa a la última pantalla en la que se estaba.
        .onChange(of: currentScreen) { previous, _ in
            guard previous != currentScreen else { return }
            screenHistory.append(previous)
            if screenHistory.count > 50 {
                screenHistory.removeFirst(screenHistory.count - 50)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            libraryRevision += 1
        }
        // Los módulos (voz, gestos) publican intenciones aquí; el editor las
        // aplica a la sesión activa sin saber de qué pieza vinieron.
        // renameTitle lo aplica la pantalla (dueña del documento), no la
        // sesión: cambiar el título renombra el archivo, no el texto.
        .task { @MainActor in
            for await command in await commandBus.commands() {
                switch command {
                case .renameTitle(let title):
                    applyVoiceRename(title)
                case .saveDocument:
                    applyVoiceSave()
                case .openDocument(let name):
                    applyVoiceOpen(name: name)
                case .exportDocument(let format):
                    applyVoiceExport(format)
                default:
                    session.send(command)
                }
            }
        }
        .onAppear {
            hasAppeared = true
            onEditorReady?(session)
            if startOnHome { launchHome = true; showHome = true }
            if currentURL == nil && text.isEmpty { showHome = true }
            mergeExtraWindowIfNeeded()
            // Pieza Lego: Gestos. Instantánea inicial para sesiones manuales
            // antes de la primera pulsación.
            if let push = onGestureDocument {
                let sel = session.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
                push(text, sel)
            }
        }
        .toolbar { toolbar }
    }

    private var writingCanvas: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if statistics && !session.focusMode {
                    HStack {
                        Spacer()
                        Text(session.selectedCharacters > 0
                             ? "\(session.selectedCharacters.formatted()) caracteres · \(session.selectedWords.formatted()) palabras seleccionadas"
                             : "\(session.statistics.words.formatted()) palabras")
                            .font(.caption).foregroundStyle(Color(nsColor: style.secondaryTextColor)).monospacedDigit()
                    }.padding(.horizontal, 32).padding(.top, 16)
                }
                HStack(alignment: .firstTextBaseline) {
                    TextField("Título", text: $documentTitle, onCommit: commitTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Color(nsColor: style.effectiveTextColor))
                        .lineLimit(2)
                        .accessibilityLabel("Título del documento")
                    Spacer(minLength: 12)
                    if session.readingMode {
                        Button("Editar") { session.readingMode = false }.buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 32).padding(.top, session.focusMode ? 20 : 28).padding(.bottom, 8)
                ZStack(alignment: .topLeading) {
                    NativeTextEditor(text: $text, session: session, style: style, documentURL: imageDocumentURL, isOpeningDocument: openingDocument, onTextActivity: onGestureDocument)
                        .opacity(session.readingMode ? 0 : 1)
                        .allowsHitTesting(!session.readingMode)
                        .accessibilityHidden(session.readingMode)
                    if let gestureCursor, !session.readingMode {
                        gestureCursor
                    }
                    if text.isEmpty && !session.readingMode {
                        Text("Escribe aquí…")
                            .font(.system(size: fontSize)).foregroundStyle(Color(nsColor: style.tertiaryTextColor))
                            .padding(.leading, 33).padding(.top, 25).allowsHitTesting(false)
                    }
                    if session.readingMode {
                        MarkdownReader(text: text, style: style, documentURL: imageDocumentURL)
                            .id(imageAccessRevision)
                    }
                    // Pieza Lego: Gestos. Las tarjetas se pintan solas solo
                    // cuando hay sesión o aviso; sin la pieza no hay nada.
                    if let gestureCards {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                gestureCards
                                Spacer()
                            }
                        }
                        .padding(.bottom, 24)
                        .allowsHitTesting(true)
                    }
                }
            }
            .frame(maxWidth: max(480, width))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(Color(nsColor: style.effectiveBackgroundColor))
        .onAppear { requestImageAccessIfNeeded() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Volver: regresa a la última pantalla vista (lista de notas o nota).
        ToolbarItem(placement: .navigation) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }
                .help("Volver a la pantalla anterior · ⌘[")
                .accessibilityLabel("Volver a la pantalla anterior")
                .keyboardShortcut("[", modifiers: .command)
                .disabled(screenHistory.isEmpty && isShowingHome)
        }
        if navigationOnTrailing {
            if !isShowingHome {
                ToolbarItem(placement: .navigation) { inspectorToggle }
            }
        } else {
            ToolbarItem(placement: .navigation) { navigationToggle }
        }
        if !isShowingHome && !session.focusMode && !session.headings.isEmpty {
            ToolbarItem(placement: .navigation) {
                Button { showOutline.toggle() } label: { Image(systemName: "list.bullet") }
                    .help(showOutline ? "Ocultar índice · ⌥⌘1" : "Mostrar índice · ⌥⌘1")
                    .accessibilityLabel(showOutline ? "Ocultar índice" : "Mostrar índice")
                    .keyboardShortcut("1", modifiers: [.option, .command])
            }
        }
        ToolbarItem(placement: .navigation) {
            Button { createDocument() } label: { Image(systemName: "plus") }
                .help("Nuevo documento · ⌘N").accessibilityLabel("Nuevo documento")
        }
        if !isShowingHome {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session.send(.toggleBold) } label: { Image(systemName: "bold") }
                    .help("Negrita · ⌘B").accessibilityLabel("Negrita").disabled(session.readingMode)
                Button { session.send(.toggleItalic) } label: { Image(systemName: "italic") }
                    .help("Cursiva · ⌘I").accessibilityLabel("Cursiva").disabled(session.readingMode)
                Button { session.send(.insertLink) } label: { Image(systemName: "link") }
                    .help("Insertar enlace · ⌘K").accessibilityLabel("Insertar enlace").disabled(session.readingMode)
                Button { insertImage() } label: { Image(systemName: "photo") }
                    .help("Insertar imagen · ⇧⌘I").accessibilityLabel("Insertar imagen")
                    .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(session.readingMode)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                if let url = currentURL {
                    Button { toggleFavorite(url) } label: { Image(systemName: isFavorite(url) ? "star.fill" : "star") }
                        .help(isFavorite(url) ? "Quitar de favoritos" : "Añadir a favoritos")
                        .accessibilityLabel(isFavorite(url) ? "Quitar de favoritos" : "Añadir a favoritos")
                        .foregroundStyle(isFavorite(url) ? .yellow : chromePrimary)
                } else {
                    Button {} label: { Image(systemName: "star") }
                        .disabled(true)
                        .accessibilityLabel("Añadir a favoritos")
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session.readingMode.toggle() } label: { Image(systemName: session.readingMode ? "square.and.pencil" : "book") }
                    .help(session.readingMode ? "Volver a escribir · ⇧⌘R" : "Vista de lectura · ⇧⌘R")
                    .accessibilityLabel(session.readingMode ? "Volver a escribir" : "Vista de lectura")
                Button { session.focusMode.toggle() } label: { Image(systemName: session.focusMode ? "eye.slash" : "eye") }
                    .help(session.focusMode ? "Salir de concentración · ⇧⌘F" : "Concentración · ⇧⌘F")
                    .accessibilityLabel(session.focusMode ? "Salir de concentración" : "Concentración")
                Button { showReadingControls.toggle() } label: { Image(systemName: "textformat.size") }
                    .help("Lectura y concentración").accessibilityLabel("Lectura y concentración")
                    .popover(isPresented: $showReadingControls, arrowEdge: .bottom) { readingControls }
            }
            if !navigationOnTrailing {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { inspectorToggle }
            }
            // Pieza Lego: Voz. Sin módulo no se muestra ningún control falso.
            if let voicePanel {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    voicePanel
                }
            }
            // Pieza Lego: Gestos. Sin módulo no se muestra ningún control falso
            // y el editor jamás pide permiso de cámara.
            if let gesturePanel {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    gesturePanel
                }
            }
        }
        if navigationOnTrailing {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { navigationToggle }
        }
    }

    private var navigationOnTrailing: Bool { sidebarSide == SidebarSide.trailing.rawValue }
    private var navigationSymbol: String { navigationOnTrailing ? "sidebar.right" : "sidebar.left" }
    private var inspectorSymbol: String { navigationOnTrailing ? "sidebar.left" : "sidebar.right" }

    /// Los atajos ⌃⌘S y ⌥⌘0 viven en el menú Visualización (`EditorMenus`)
    /// para que funcionen aunque la barra mande estos botones al desborde.
    private var navigationToggle: some View {
        Button { showSidebar.toggle() } label: { Image(systemName: navigationSymbol) }
            .help(showSidebar ? "Ocultar navegación · ⌃⌘S" : "Mostrar navegación · ⌃⌘S")
            .accessibilityLabel(showSidebar ? "Ocultar navegación" : "Mostrar navegación")
            .disabled(session.focusMode)
    }

    private var inspectorToggle: some View {
        Button { showInspector.toggle() } label: { Image(systemName: inspectorSymbol) }
            .help(showInspector ? "Ocultar inspector · ⌥⌘0" : "Mostrar inspector · ⌥⌘0")
            .accessibilityLabel(showInspector ? "Ocultar inspector" : "Mostrar inspector")
            .disabled(session.focusMode)
    }

    /// En concentración los paneles no se muestran ni se alternan.
    private func panelBinding(_ visible: Binding<Bool>) -> Binding<Bool>? {
        session.focusMode ? nil : visible
    }

    @ViewBuilder private var navigationColumn: some View {
        if showSidebar && !session.focusMode {
            sidebar
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
        }
    }

    @ViewBuilder private var inspectorColumn: some View {
        if showInspector && !session.focusMode && !isShowingHome {
            inspector
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
        }
    }

    private func hidePanelButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chromeSecondary)
        .help(label)
        .accessibilityLabel(label)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(chromeSecondary)
                TextField("Buscar escritos", text: $search).textFieldStyle(.plain)
                    .foregroundStyle(chromePrimary)
                    .accessibilityLabel("Buscar escritos por nombre")
                    .help("Filtra escritos por nombre. Para buscar en la nota, usa ⌘F.")
                    .onChange(of: search) { _, value in
                        if !value.isEmpty { launchHome = false; showHome = true }
                    }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(chromeSecondary).accessibilityLabel("Borrar búsqueda")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(style.usesCustomBackground ? Color(nsColor: style.chromeSearchFill) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("General").font(.headline).foregroundStyle(chromeSecondary)
                            .padding(.leading, 8).padding(.bottom, 6)
                        navigationButton("Inicio", symbol: "house", destination: .home)
                        navigationButton("Recientes", symbol: "clock", destination: .recents)
                        navigationButton("Favoritos", symbol: "star", destination: .favorites)
                        navigationButton("Archivado", symbol: "archivebox", destination: .archived)
                        navigationButton("Sin título", symbol: "doc.text", destination: .drafts)
                        navigationButton("Papelera de EditorFinal", symbol: "trash", destination: .trash)
                    }
                    if !folders.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Carpetas").font(.headline).foregroundStyle(chromeSecondary)
                                Spacer()
                                Button { createFolder() } label: {
                                    Image(systemName: "folder.badge.plus")
                                        .frame(minWidth: 32, minHeight: 32)
                                        .contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(chromeSecondary)
                                    .accessibilityLabel("Crear carpeta")
                            }
                            .padding(.leading, 8).padding(.bottom, 6)
                            ForEach(folders, id: \.self) { folder in
                                navigationButton(folder.lastPathComponent, symbol: folder == cloudFolder ? "icloud" : "folder", destination: .folder(folder))
                                    .help(folder.path)
                            }
                        }
                    }
                    if folders.isEmpty {
                        Button { createFolder() } label: {
                            Label("Crear carpeta", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            HStack {
                Button { NSDocumentController.shared.openDocument(nil) } label: {
                    Label("Abrir archivo…", systemImage: "folder.badge.plus")
                        .padding(.vertical, 8).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                }
                    .accessibilityLabel("Configuración")
                hidePanelButton("Ocultar navegación · ⌃⌘S", symbol: navigationSymbol) { showSidebar = false }
            }.buttonStyle(.plain).font(.callout).foregroundStyle(chromeSecondary).padding(.horizontal, 8).padding(.vertical, 4)
        }
        .padding(12).padding(.top, 14).padding(.bottom, 8)
        .frame(maxHeight: .infinity)
        .foregroundStyle(chromePrimary)
        .background {
            if style.usesCustomBackground {
                Color(nsColor: style.chromeSidebar)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
    }

    private func navigationButton(_ name: String, symbol: String, destination newDestination: LibraryDestination) -> some View {
        let selected = destination == newDestination
        let badge = count(for: newDestination)
        return Button {
            destination = newDestination
            launchHome = false
            showHome = true
        } label: {
            HStack(spacing: 10) {
                Label {
                    Text(name).lineLimit(1).foregroundStyle(chromePrimary)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(themeAccent)
                }
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(chromeSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(chromePrimary.opacity(0.08), in: Capsule())
                        .accessibilityLabel("\(badge) documentos")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11).padding(.horizontal, 12)
            .background(selected ? themeAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func outlineRow(for heading: DocumentHeading, active activeHeading: Int?) -> some View {
        Button { navigate(to: heading) } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(activeHeading == heading.id ? themeAccent : .clear).frame(width: 2)
                Text(heading.title.isEmpty ? "Sin título" : heading.title)
                    .font(.system(size: 14, weight: activeHeading == heading.id ? .semibold : .regular))
                    .foregroundStyle(activeHeading == heading.id ? chromePrimary : chromeSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10).padding(.trailing, 8).padding(.leading, CGFloat(max(0, heading.level - 1)) * 6)
            .background(activeHeading == heading.id ? chromePrimary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(activeHeading == heading.id ? [.isSelected] : [])
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Documento", systemImage: "slider.horizontal.3")
                    .font(.headline).foregroundStyle(chromePrimary)
                Spacer()
                hidePanelButton("Ocultar inspector · ⌥⌘0", symbol: inspectorSymbol) { showInspector = false }
            }
            .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 14)
            Divider()
            if statistics {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Estadísticas").font(.caption).foregroundStyle(chromeSecondary)
                    Grid(alignment: .leading, verticalSpacing: 10) {
                        GridRow {
                            Text("Caracteres")
                            Text(session.statistics.characters.formatted())
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .gridColumnAlignment(.trailing)
                        }
                        GridRow {
                            Text("Palabras")
                            Text(session.statistics.words.formatted())
                        }
                        GridRow {
                            Text("Párrafos")
                            Text(session.statistics.paragraphs.formatted())
                        }
                        GridRow {
                            Text("Lectura")
                            Text("\(session.statistics.readingMinutes) min")
                        }
                        if session.selectedCharacters > 0 {
                            GridRow {
                                Text("Selección")
                                Text(session.selectedCharacters.formatted())
                            }
                        }
                    }

                }.font(.callout).monospacedDigit().foregroundStyle(chromePrimary).padding(20)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background {
            if style.usesCustomBackground {
                Color(nsColor: style.chromeSidebar)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
    }

    private var readingControls: some View {
        @Bindable var settings = session
        return VStack(alignment: .leading, spacing: 18) {
            Text("Lectura y concentración").font(.headline)
            Picker("Tipografía", selection: $family) {
                Section("Estilos rápidos") {
                    ForEach(WritingStyle.availableFamilies, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                Section("Fuentes del sistema") {
                    ForEach(WritingStyle.systemFontFamilies, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }.pickerStyle(.menu)
            Picker("Grosor", selection: $fontWeight) {
                ForEach(WritingStyle.availableWeights, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }.pickerStyle(.menu)
            Picker("Alineación", selection: $alignment) {
                ForEach(WritingStyle.availableAlignments, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }.pickerStyle(.menu)
            HStack {
                Text("Tamaño del texto")
                Spacer()
                Button { fontSize = max(12, fontSize - 1) } label: { Image(systemName: "minus") }.accessibilityLabel("Reducir texto")
                Text("\(Int(fontSize))").monospacedDigit().frame(width: 26)
                Button { fontSize = min(32, fontSize + 1) } label: { Image(systemName: "plus") }.accessibilityLabel("Aumentar texto")
            }
            Picker("Ancho", selection: $width) {
                Text("Estrecho").tag(600.0)
                Text("Medio").tag(760.0)
                Text("Amplio").tag(920.0)
            }
            HStack {
                Text("Colores del modo \(resolvedIsDark ? "oscuro" : "claro")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Label("Editar…", systemImage: "gearshape").font(.caption) }
            }
            HStack {
                Text("Texto")
                Spacer()
                MiniHexPicker(hex: popoverText)
                Text("Fondo")
                MiniHexPicker(hex: popoverBackground)
                Text("Acento")
                MiniHexPicker(hex: popoverAccent)
            }
            .font(.callout)
            Divider()
            Toggle("Resaltar el párrafo actual", isOn: $settings.paragraphFocus)
            Toggle("Modo máquina de escribir", isOn: $settings.typewriterMode)
            Text("Mantiene el cursor a una altura estable mientras escribes.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Imprimir o guardar PDF…") {
                showReadingControls = false
                PrintDocument.run(text: text, title: documentTitle, window: session.textView?.window, documentURL: imageDocumentURL)
            }
        }.padding(22).frame(width: 340)
    }

    private var documentOutline: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(documentTitle.isEmpty ? "Sin título" : documentTitle)
                    .font(.headline).foregroundStyle(chromePrimary).lineLimit(2)
                Text(session.headings.isEmpty ? "Sin secciones" : "\(session.headings.count) secciones")
                    .font(.caption).foregroundStyle(chromeSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.headings.isEmpty {
                        Text("Escribe # antes de un título para organizar el documento.")
                            .font(.callout).foregroundStyle(chromeSecondary)
                            .padding(14)
                    }
                    let active = activeHeading
                    ForEach(session.headings) { heading in
                        outlineRow(for: heading, active: active)
                    }
                }.padding(10)
            }
        }
        .background(style.usesCustomBackground ? Color(nsColor: style.chromeOutline) : Color(nsColor: .controlBackgroundColor))
    }

    private var destinationSubtitle: String {
        switch destination {
        case .home: "Elige un escrito o empieza uno nuevo."
        case .recents: "Tus documentos abiertos recientemente."
        case .favorites: "Tus escritos marcados con estrella."
        case .archived: "Documentos guardados fuera de Inicio."
        case .drafts: "Archivos «Sin título» y documento actual sin guardar."
        case .trash: "Los archivos siguen en su carpeta hasta enviarlos a la papelera del Mac."
        case .folder(let url): "Documentos en \(url.lastPathComponent)."
        }
    }
    private var destinationSymbol: String {
        switch destination {
        case .home: "house"
        case .recents: "clock"
        case .favorites: "star"
        case .archived: "archivebox"
        case .drafts: "doc.text"
        case .trash: "trash"
        case .folder: "folder"
        }
    }
    private var showsNewCard: Bool {
        switch destination {
        case .home, .drafts, .folder: true
        case .recents, .favorites, .archived, .trash: false
        }
    }
    private var emptyTitle: String {
        if !search.isEmpty { return "Sin coincidencias" }
        switch destination {
        case .home: return "No hay documentos"
        case .recents: return "Sin recientes"
        case .favorites: return "Sin favoritos"
        case .archived: return "Nada archivado"
        case .drafts: return "No hay escritos sin título"
        case .trash: return "Papelera vacía"
        case .folder: return "Carpeta vacía"
        }
    }
    private var emptyMessage: String {
        if !search.isEmpty { return "Prueba con otro texto." }
        switch destination {
        case .home: return "Crea tu primer escrito con Nuevo escrito."
        case .recents: return "Abre un documento y aparecerá aquí."
        case .favorites: return "Marca un escrito con estrella para verlo aquí."
        case .archived: return "Archiva un documento para limpiar Inicio sin borrarlo."
        case .drafts: return "Crea un escrito nuevo para verlo aquí hasta que le pongas un nombre."
        case .trash: return "Mueve un escrito a la papelera de EditorFinal para verlo aquí."
        case .folder: return "No hay escritos en esta carpeta."
        }
    }
    private var hasVirtualDraft: Bool { currentURL == nil && !text.isEmpty }
    private var showsVirtualDraft: Bool {
        hasVirtualDraft && (destination == .home || destination == .drafts)
            && (search.isEmpty || documentTitle.localizedStandardContains(search))
    }
    private func open(url: URL) {
        if url == currentURL {
            hasChosenDocument = true
            launchHome = false
            showHome = false
            focusEditor()
        } else {
            hasChosenDocument = true
            launchHome = false
            openFile(url)
        }
    }
    private func documentCard(for url: URL) -> some View {
        Button { open(url: url) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(chromePrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if isFavorite(url) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorito")
                    }
                }
                Spacer(minLength: 8)
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .font(.callout).foregroundStyle(chromeSecondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(url.pathExtension.isEmpty ? "Escrito" : url.pathExtension.uppercased())
                    if isArchived(url) && destination != .archived {
                        Text("Archivado")
                    }
                }
                .font(.caption).foregroundStyle(chromeSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .padding(22)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(cardBorder))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            if destination == .trash {
                Button("Restaurar") { restore(url) }
                Button("Enviar a la papelera del Mac", role: .destructive) { moveToSystemTrash(url) }
            } else {
                Button(isFavorite(url) ? "Quitar de favoritos" : "Añadir a favoritos") { toggleFavorite(url) }
                Button(isArchived(url) ? "Desarchivar" : "Archivar") { setArchived(url, archived: !isArchived(url)) }
                Button("Mover a la papelera de EditorFinal", role: .destructive) { setTrashed(url, trashed: true) }
            }
            Button("Mostrar en el Finder") { revealInFinder(url) }
        }
    }
    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(destination.title).font(.system(size: 30, weight: .semibold)).foregroundStyle(chromePrimary)
                    Text(destinationSubtitle)
                        .font(.callout).foregroundStyle(chromeSecondary)
                    Text("\(homeURLs.count) escritos")
                        .font(.caption).foregroundStyle(chromeSecondary).monospacedDigit()
                }
                Spacer()
                if destination == .trash {
                    if !baseURLs(for: .trash).isEmpty {
                        Button("Enviar todo a la papelera del Mac", systemImage: "trash", role: .destructive, action: emptyTrash)
                            .buttonStyle(.bordered)
                    }
                } else if showsNewCard {
                    Button("Nuevo escrito", systemImage: "plus", action: createDocument)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 24)], spacing: 24) {
                    if showsNewCard {
                        Button(action: createDocument) {
                            VStack(alignment: .leading, spacing: 14) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(themeAccent)
                                Text("Nuevo escrito")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(chromePrimary)
                                Text("Crear un documento en blanco")
                                    .font(.callout).foregroundStyle(chromeSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            .padding(22)
                            .background(themeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(themeAccent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Crear un nuevo escrito")
                    }
                    if showsVirtualDraft {
                        Button {
                            hasChosenDocument = true
                            launchHome = false
                            showHome = false
                            focusEditor()
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(documentTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(chromePrimary).lineLimit(2)
                                Spacer(minLength: 8)
                                Text(String(text.prefix(140))).font(.callout).foregroundStyle(chromeSecondary).lineLimit(4)
                                Text("Borrador sin guardar").font(.caption).foregroundStyle(chromeSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                            .padding(22)
                            .background(themeAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(themeAccent.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Abrir borrador sin guardar")
                    }
                    ForEach(homeURLs, id: \.self) { url in
                        documentCard(for: url)
                    }
                    if homeURLs.isEmpty && !showsVirtualDraft {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: search.isEmpty ? destinationSymbol : "magnifyingglass",
                            description: Text(emptyMessage)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding(32)
            }
        }
        .background(homeBackground)
        .foregroundStyle(chromePrimary)
    }

    private func focusEditor() {
        guard !session.readingMode, let view = session.textView else { return }
        view.window?.makeFirstResponder(view)
    }

    private func insertImage() {
        let documentURL = imageDocumentURL
        let panel = NSOpenPanel()
        panel.message = "Elige una imagen"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source), let bitmap = NSImage(data: data),
              bitmap.size.width > 0, bitmap.size.height > 0 else {
            let alert = NSAlert()
            alert.messageText = "No se puede abrir esa imagen"
            alert.informativeText = "Elige un archivo de imagen compatible y vuelve a intentarlo."
            alert.runModal()
            return
        }
        let folder = documentURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        let name = UUID().uuidString + "." + source.pathExtension.lowercased()
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            guard (error as NSError).code == NSFileWriteNoPermissionError else {
                NSApplication.shared.presentError(error)
                return
            }
            guard grantImageFolderAccess(to: documentURL) else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch {
                NSApplication.shared.presentError(error)
                return
            }
        }
        let alt = source.deletingPathExtension().lastPathComponent
        let image = MarkdownImage(alt: alt, path: "images/" + name)
        session.send(.insertText("\n" + image.markdown + "\n"))
    }

    /// Al guardar un documento nuevo, sus imágenes pasan de la carpeta temporal a `images/` junto al archivo.
    private func adoptDraftImages(into documentURL: URL) {
        let draft = draftImagesURL
        guard FileManager.default.fileExists(atPath: draft.deletingLastPathComponent().path) else { return }
        do {
            try DraftImages.move(text: text, from: draft, to: documentURL)
        } catch where (error as NSError).code == NSFileWriteNoPermissionError {
            guard grantImageFolderAccess(to: documentURL) else { return }
            do {
                try DraftImages.move(text: text, from: draft, to: documentURL)
            } catch {
                NSApplication.shared.presentError(error)
                return
            }
        } catch {
            NSApplication.shared.presentError(error)
            return
        }
        draftImagesURL = DraftImages.makeDocumentURL()
        imageAccessRevision += 1
    }

    private func grantImageFolderAccess(to documentURL: URL) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = documentURL.deletingLastPathComponent()
        panel.message = "Elige la carpeta de este documento para guardar y mostrar sus imágenes."
        panel.prompt = "Dar acceso"
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        do {
            try DocumentImageAccess.remember(folder, for: documentURL)
            imageAccessRevision += 1
            session.refreshOutline(text)
            return true
        } catch {
            NSApplication.shared.presentError(error)
            return false
        }
    }

    private func requestImageAccessIfNeeded() {
        guard let documentURL = activeDocument?.fileURL ?? currentURL,
              !imageAccessAsked.contains(documentURL.path), text.contains("![") else { return }
        DocumentImageAccess.start(for: documentURL)
        let image = MarkdownDocument(text).lines.lazy.compactMap { MarkdownImage(line: $0.content) }.first
        guard let image, let url = image.fileURL(relativeTo: documentURL) else { return }
        imageAccessAsked.insert(documentURL.path)
        guard (try? Data(contentsOf: url)) == nil else { return }
        _ = grantImageFolderAccess(to: documentURL)
    }

    /// Guardar por voz ("Guarda el documento"): delega al NSDocument activo
    /// vía la cadena de respondedores (sin panel si ya tiene archivo; con
    /// panel si es borrador nuevo). Respeta autosave y sandbox del sistema.
    private func applyVoiceSave() {
        NSApplication.shared.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
    }

    /// Busca en los documentos que la biblioteca ya conoce. Si el nombre no
    /// identifica uno solo, deja elegirlo en el panel del sistema.
    private func applyVoiceOpen(name: String?) {
        if let name, let url = Self.matchVoiceDocument(name, in: availableURLs.filter({ !isTrashed($0) })) {
            open(url: url)
            return
        }
        let panel = NSOpenPanel()
        panel.message = name.map { "No encontré un documento único para «\($0)». Elígelo para abrir." }
            ?? "Elige el documento para abrir"
        panel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    static func matchVoiceDocument(_ spoken: String, in urls: [URL]) -> URL? {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_MX"))
        }
        var query = normalized(spoken)
        for article in ["el ", "la ", "los ", "las ", "un ", "una "] where query.hasPrefix(article) {
            query.removeFirst(article.count)
            break
        }
        guard !query.isEmpty else { return nil }
        let exact = urls.filter { normalized($0.deletingPathExtension().lastPathComponent) == query }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let partial = urls.filter { normalized($0.deletingPathExtension().lastPathComponent).contains(query) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Exportar por voz. pdf → diálogo de impresión (ahí se guarda como PDF);
    /// txt/rtf/word → panel de guardado con el contenido real (word en .docx).
    private func applyVoiceExport(_ format: String) {
        switch format {
        case "pdf":
            PrintDocument.run(text: text, title: documentTitle, window: session.textView?.window, documentURL: imageDocumentURL)
        case "txt", "rtf", "word":
            let exportFormat: DocumentExport.Format = switch format {
            case "txt": .plainText
            case "rtf": .richText
            default: .word
            }
            DocumentExport.run(format: exportFormat, text: text, title: documentTitle,
                               richText: session.textView?.textStorage,
                               documentURL: imageDocumentURL)
        default:
            break
        }
    }

    /// Renombrar por voz ("Cambia el título a X"): si el documento ya tiene
    /// archivo, actualiza el encabezado tras renombrarlo en disco
    /// vía NSDocument (misma carpeta, misma extensión, sin sobrescribir).
    /// Sin archivo (borrador sin guardar) el título queda visual hasta el
    /// primer guardado. El renombrado NO entra al UndoManager del texto:
    /// se deshace renombrando de nuevo.
    private func applyVoiceRename(_ raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80, !clean.contains("/"), !clean.contains(":") else { return }
        guard let doc = ownDocument ?? activeDocument else { return }
        guard let currentURL = doc.fileURL ?? currentURL else {
            documentTitle = clean
            return
        }
        let ext = currentURL.pathExtension
        let fileName = ext.isEmpty || clean.hasSuffix(".\(ext)") ? clean : "\(clean).\(ext)"
        let dest = currentURL.deletingLastPathComponent()
            .appendingPathComponent(fileName)
        guard dest.standardizedFileURL != currentURL.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            NSApplication.shared.presentError(NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "Ya existe un documento con ese título."]
            ))
            return
        }
        doc.move(to: dest) { error in
            if let error {
                NSApplication.shared.presentError(error)
            } else {
                moveStoredMarks(from: currentURL, to: dest)
                documentTitle = dest.deletingPathExtension().lastPathComponent
            }
        }
    }

    /// Regresa a la pantalla anterior: la última lista de notas vista o la
    /// nota que estaba abierta. Sin historial vuelve a Inicio.
    private func goBack() {
        guard let previous = screenHistory.popLast() else {
            guard !isShowingHome else { return }
            launchHome = false
            showHome = true
            return
        }
        launchHome = false
        destination = previous.destination
        showHome = !previous.inNote
        if previous.inNote { focusEditor() }
    }

    /// Carga un archivo en esta misma ventana, sin crear ventana ni documento nuevos.
    private func applySameWindowOpen(url: URL, text newText: String) {
        let controller = NSDocumentController.shared
        guard let mine = ownDocument ?? activeDocument else { return }
        let myURL = mine.fileURL ?? currentURL
        if let myURL, myURL.standardizedFileURL == url.standardizedFileURL {
            hasChosenDocument = true
            launchHome = false
            showHome = false
            focusEditor()
            return
        }
        let loadNew = {
            self.replaceDocument(mine, with: newText, at: url) {
                self.documentTitle = url.deletingPathExtension().lastPathComponent
                self.hasChosenDocument = true
                self.launchHome = false
                self.showHome = false
                controller.noteNewRecentDocumentURL(url)
                self.closeExtraWindows()
                self.focusEditor()
            }
        }
        saveBeforeSwitch(mine, then: loadNew)
    }

    private func saveBeforeSwitch(_ document: NSDocument, then continueSwitch: @escaping () -> Void) {
        let oldURL = document.fileURL ?? currentURL
        if (oldURL == nil && text.isEmpty) || (oldURL != nil && !document.isDocumentEdited) {
            continueSwitch()
            return
        }
        let save: (URL, NSDocument.SaveOperationType) -> Void = { url, operation in
            document.save(to: url, ofType: document.fileType ?? UTType.plainText.identifier, for: operation) { error in
                if let error { NSApplication.shared.presentError(error) }
                else { continueSwitch() }
            }
        }
        if let oldURL {
            save(oldURL, .saveOperation)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(documentTitle).md"
            if let cloudFolder { panel.directoryURL = cloudFolder }
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                save(url, .saveAsOperation)
            }
        }
    }

    /// `saveAs` necesita el texto nuevo en el binding; revierte si falla.
    private func replaceDocument(_ document: NSDocument, with newText: String, at url: URL, onSuccess: @escaping () -> Void) {
        let previousText = text
        autosaveWorkItem?.cancel()
        openingDocument = true
        session.textView?.isEditable = false
        session.textView?.isSelectable = false
        text = newText
        document.save(to: url, ofType: document.fileType ?? UTType.plainText.identifier, for: .saveAsOperation) { error in
            if let error {
                text = previousText
                NSApplication.shared.presentError(error)
            } else {
                session.textView?.undoManager?.removeAllActions()
                onSuccess()
            }
            openingDocument = false
            session.textView?.isEditable = !session.readingMode
            session.textView?.isSelectable = !session.readingMode
        }
    }

    /// Cierra ventanas sobrantes sin arriesgar trabajo sin guardar.
    private func closeExtraWindows() {
        let controller = NSDocumentController.shared
        guard let mine = ownDocument ?? activeDocument else { return }
        for document in controller.documents where document !== mine {
            if !document.isDocumentEdited {
                document.close()
            }
        }
    }

    /// Red de seguridad: si el sistema llegó a crear una ventana extra, reenvía
    /// su archivo a la ventana principal para que lo cargue en el mismo sitio.
    /// La principal lo aplica y cierra las sobrantes; aquí no se cierra nada.
    private func mergeExtraWindowIfNeeded() {
        DispatchQueue.main.async {
            let controller = NSDocumentController.shared
            guard controller.documents.count > 1 else { return }
            let firstURL = controller.documents.first?.fileURL?.standardizedFileURL
            let myURL = self.currentURL?.standardizedFileURL
            if myURL != firstURL, let fileURL = self.currentURL {
                SingleWindowCoordinator.shared.requestOpen(url: fileURL, text: self.text)
                return
            }
            if myURL == firstURL,
               let keyWindow = NSApp.keyWindow,
               let duplicate = controller.documents.first(where: { document in
                   document.windowControllers.contains(where: { $0.window == keyWindow })
               }),
               duplicate !== controller.documents.first,
               !duplicate.isDocumentEdited {
                duplicate.close()
            }
        }
    }

    private func createDocument() {
        guard let document = ownDocument ?? activeDocument else { return }
        let suggestedDirectory = cloudFolder
            ?? currentURL?.deletingLastPathComponent()
            ?? folders.first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = suggestedDirectory.path.hasPrefix(Bundle.main.bundleURL.path)
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("Samples", isDirectory: true)
            : suggestedDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseURL = directory.appendingPathComponent("Sin título.md")
        var url = baseURL
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Sin título \(suffix).md")
            suffix += 1
        }

        let startWriting = {
            replaceDocument(document, with: "", at: url) {
                hasChosenDocument = true
                launchHome = false
                documentTitle = url.deletingPathExtension().lastPathComponent
                destination = .home
                showHome = false
            }
        }

        saveBeforeSwitch(document, then: startWriting)
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        guard !openingDocument else { return }
        guard let document = activeDocument,
              document.fileURL != nil || currentURL != nil else { return }
        let workItem = DispatchWorkItem { [weak document] in
            guard let document, let url = document.fileURL ?? currentURL else { return }
            document.save(to: url, ofType: document.fileType ?? UTType.plainText.identifier, for: .saveOperation) { error in
                if let error { NSApplication.shared.presentError(error) }
            }
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func createFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir ubicación"
        panel.message = "Elige la carpeta donde se creará la nueva carpeta."
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            let hasAccess = parent.startAccessingSecurityScopedResource()
            defer { if hasAccess { parent.stopAccessingSecurityScopedResource() } }

            let alert = NSAlert()
            alert.messageText = "Nueva carpeta"
            alert.informativeText = "Escribe un nombre para la carpeta."
            let field = NSTextField(string: "Nueva carpeta")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Crear")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), !name.contains(":") else { return }
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                customFolderPaths = StoredPaths.setting(customFolderPaths, path: folder.path, present: true)
            } catch {
                NSApplication.shared.presentError(error)
            }
        }
    }

    private func commitTitle() {
        guard let document = activeDocument else { return }
        let documentURL = document.fileURL ?? currentURL
        let oldTitle = documentURL?.deletingPathExtension().lastPathComponent ?? "Sin título"
        let name = documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            documentTitle = oldTitle
            return
        }
        guard let documentURL else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(name).md"
            if let cloudFolder { panel.directoryURL = cloudFolder }
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                document.save(to: url, ofType: document.fileType ?? UTType.plainText.identifier, for: .saveAsOperation) { error in
                    if let error {
                        NSApplication.shared.presentError(error)
                    } else {
                        documentTitle = url.deletingPathExtension().lastPathComponent
                    }
                }
            }
            return
        }

        let extensionName = documentURL.pathExtension
        let fileName = extensionName.isEmpty || name.hasSuffix(".\(extensionName)") ? name : "\(name).\(extensionName)"
        let destination = documentURL.deletingLastPathComponent().appendingPathComponent(fileName)
        guard destination != documentURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            NSApplication.shared.presentError(NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "Ya existe un documento con ese título."]
            ))
            documentTitle = oldTitle
            return
        }

        document.move(to: destination) { error in
            if let error {
                NSApplication.shared.presentError(error)
                documentTitle = oldTitle
            } else {
                moveStoredMarks(from: documentURL, to: destination)
                documentTitle = destination.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func navigate(to heading: DocumentHeading) {
        session.readingMode = false
        session.send(.selectRange(TextRange(location: heading.offset, length: 0)))
    }
}

struct MiniHexPicker: View {
    @Binding var hex: String
    var body: some View {
        HStack(spacing: 4) {
            ColorPicker("", selection: Binding(
                get: { WritingStyle.swiftUIColor(fromHex: hex) ?? Color.gray },
                set: { hex = WritingStyle.hex(from: $0) }
            ))
            .labelsHidden()
            .frame(width: 22)
            Button {
                hex = "auto"
            } label: {
                Image(systemName: hex == "auto" ? "sparkles" : "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(hex == "auto" ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .help(hex == "auto" ? "Automático" : "Volver a automático (\(hex))")
        }
    }
}

struct QuickColorDot: View {
    @Binding var hex: String
    var body: some View {
        MiniHexPicker(hex: $hex)
    }
}
