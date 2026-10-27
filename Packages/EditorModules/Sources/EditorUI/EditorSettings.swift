import SwiftUI
import DesignSystem
import DocumentKit
import ModuleKit

public struct EditorSettings: View {
    private var modules: ModuleRegistry
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
    @AppStorage(CloudDocuments.enabledKey) private var saveToICloud = false
    @AppStorage(CloudDocuments.pathKey) private var cloudFolderPath = ""
    @State private var fontSearch = ""
    @State private var confirmingReset = false
    @State private var editingScheme: ColorScheme = .light
    public init(modules: ModuleRegistry = ModuleRegistry()) {
        self.modules = modules
    }

    private var filteredSystemFonts: [String] {
        let all = WritingStyle.systemFontFamilies
        let query = fontSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedStandardContains(query) }
    }

    private var editingText: Binding<String> {
        Binding(
            get: { editingScheme == .dark ? darkTextHex : lightTextHex },
            set: { if editingScheme == .dark { darkTextHex = $0 } else { lightTextHex = $0 } }
        )
    }

    private var editingBackground: Binding<String> {
        Binding(
            get: { editingScheme == .dark ? darkBackgroundHex : lightBackgroundHex },
            set: { if editingScheme == .dark { darkBackgroundHex = $0 } else { lightBackgroundHex = $0 } }
        )
    }

    private var editingAccent: Binding<String> {
        Binding(
            get: { editingScheme == .dark ? darkAccentHex : lightAccentHex },
            set: { if editingScheme == .dark { darkAccentHex = $0 } else { lightAccentHex = $0 } }
        )
    }

    private var activePresetID: String? {
        let current = [lightTextHex, lightBackgroundHex, lightAccentHex, darkTextHex, darkBackgroundHex, darkAccentHex]
        return WritingStyle.themePresets.first { preset in
            let colors = [preset.lightTextHex, preset.lightBackgroundHex, preset.lightAccentHex,
                          preset.darkTextHex, preset.darkBackgroundHex, preset.darkAccentHex]
            return zip(colors, current).allSatisfy { $0.0.caseInsensitiveCompare($0.1) == .orderedSame }
        }?.id
    }

    private var effectiveScheme: ColorScheme {
        if appearance == "dark" { return .dark }
        if appearance == "light" { return .light }
        return systemScheme
    }

    public var body: some View {
        TabView {
            Form {
                Section("Modo de la app") {
                    Picker("Apariencia", selection: $appearance) {
                        Text("Según el Mac").tag("system")
                        Text("Claro").tag("light")
                        Text("Oscuro").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Text("Según el Mac cambia entre claro y oscuro con el sistema.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Ventana") {
                    Picker("Barra de navegación", selection: $sidebarSide) {
                        Text("Izquierda").tag(SidebarSide.leading.rawValue)
                        Text("Derecha").tag(SidebarSide.trailing.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text("El inspector del documento se coloca en el lado contrario. Muestra u oculta cada panel con ⌃⌘S y ⌥⌘0, o desde el menú Visualización.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Combinación de colores") {
                    Text("Cada combinación incluye colores para los modos claro y oscuro.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(WritingStyle.themePresets) { preset in
                            themePresetButton(preset)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Personalizar colores") {
                    Picker("Editar el modo", selection: $editingScheme) {
                        Text("Claro").tag(ColorScheme.light)
                        Text("Oscuro").tag(ColorScheme.dark)
                    }
                    .pickerStyle(.segmented)
                    themePreview
                    ThemeColorRow(
                        title: "Texto",
                        subtitle: "Color de la letra en escritura y lectura",
                        hex: editingText,
                        defaultHex: editingScheme == .dark ? "#E6E6E6" : "#24211C"
                    )
                    ThemeColorRow(
                        title: "Fondo",
                        subtitle: "Fondo del lienzo de escritura",
                        hex: editingBackground,
                        defaultHex: editingScheme == .dark ? "#1E1E1E" : "#FAF7F0"
                    )
                    ThemeColorRow(
                        title: "Acento",
                        subtitle: "Cursor, enlaces y resaltado de párrafo",
                        hex: editingAccent,
                        defaultHex: editingScheme == .dark ? "#0A84FF" : "#8A6D3B"
                    )
                    Menu("Aplicar combinación solo a este modo") {
                        ForEach(WritingStyle.themePresets) { preset in
                            Button(preset.name) { applyTheme(preset, to: editingScheme) }
                        }
                    }
                    Text("«Automático» usa el color del sistema. Con «Según el Mac», la app cambia entre los colores claros y oscuros que elegiste.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Apariencia", systemImage: "circle.lefthalf.filled") }

            fontBrowser
                .tabItem { Label("Fuentes", systemImage: "textformat.abc") }

            Form {
                Section("Tamaño y espaciado") {
                    Slider(value: $fontSize, in: 12...32, step: 1) { Text("Tamaño: \(Int(fontSize)) pt") }
                    Slider(value: $spacing, in: 0...14, step: 1) { Text("Interlineado adicional: \(Int(spacing)) pt") }
                    Slider(value: $paragraph, in: 0...16, step: 1) { Text("Espaciado entre párrafos: \(Int(paragraph)) pt") }
                    Slider(value: $tracking, in: -0.5...3, step: 0.1) { Text(String(format: "Espaciado entre letras: %.1f pt", tracking)) }
                    Picker("Alineación", selection: $alignment) {
                        ForEach(WritingStyle.availableAlignments, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    Picker("Ancho de lectura", selection: $width) {
                        Text("Estrecho").tag(600.0)
                        Text("Medio").tag(760.0)
                        Text("Amplio").tag(920.0)
                    }
                }
                Section("Presentación") {
                    Toggle("Dar formato a los títulos Markdown al escribir", isOn: $syntax)
                    Toggle("Mostrar estadísticas al pie", isOn: $statistics)
                }
                Section("Vista previa de tipografía") {
                    fontPreview
                }
                Section("Restablecer") {
                    Button("Restablecer todas las preferencias…", role: .destructive) {
                        confirmingReset = true
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Lectura", systemImage: "textformat") }
            Form {
                Section("Edición") {
                    LabeledContent("Buscar", value: "⌘F")
                    LabeledContent("Negrita · Cursiva", value: "⌘B · ⌘I")
                }
                Section("Lectura") {
                    LabeledContent("Concentración", value: "⇧⌘F")
                    LabeledContent("Vista de lectura", value: "⇧⌘R")
                    LabeledContent("Foco de párrafo", value: "⌥⌘F")
                    LabeledContent("Máquina de escribir", value: "⌥⌘T")
                }
                Section("Archivo") {
                    LabeledContent("Imprimir o guardar PDF", value: "⌘P")
                }
                Text("Tus documentos siguen siendo archivos Markdown o texto UTF-8. La vista de lectura y las preferencias no modifican el archivo.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
            }.formStyle(.grouped)
            .tabItem { Label("Atajos", systemImage: "keyboard") }
            Form {
                Section("Voz") {
                    if modules.isRegistered(identifier: "voice.dictation") {
                        LabeledContent("Estado", value: "Disponible")
                        LabeledContent("Dictar", value: "⌃⌘V")
                        LabeledContent("Mantener para hablar", value: "⌥Espacio")
                        LabeledContent("Confirmar un cambio", value: "«sí» o Enter")
                        LabeledContent("Descartar un cambio", value: "«no» o Esc")
                        LabeledContent("Ver ejemplos", value: "«qué puedo decir»")
                        LabeledContent("Terminar", value: "«detener voz»")
                        Text("Pulsa el micrófono y habla: cada pausa escribe lo dictado. Las órdenes que cambian el documento piden confirmación. El panel del micrófono muestra ejemplos y recuerda tus opciones (Manos libres, ⌥Espacio, estilo e idioma). El audio se procesa en este Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("La voz no está disponible en esta versión de la app.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Gestos") {
                    if modules.isRegistered(identifier: "gestures.hand") {
                        LabeledContent("Estado", value: "Disponible")
                        Text("Pulsa la mano de la barra para activar la cámara. Señala una palabra para seleccionarla; una pinza muestra sinónimos y soltarla confirma. En modo párrafo, señala el párrafo y usa la pinza para moverlo. En modo palabra, pinza y barrido lateral deshacen o rehacen. Apunta con el índice a una imagen y muestra la otra mano: acércalas o sepáralas para cambiar su tamaño. Fuera de una imagen, dos manos ajustan la longitud del párrafo. Retira una para confirmar o ambas para cancelar. «Probar sin cámara» abre las mismas tarjetas. La cámara se solicita al activarla y todo se procesa en este Mac. Los sinónimos usan Apple Intelligence cuando está disponible o listas locales.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Los gestos no están disponibles en esta versión de la app.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            .tabItem { Label("Voz y gestos", systemImage: "mic") }
            Form {
                Section("iCloud Drive") {
                    Toggle("Guardar documentos en iCloud Drive", isOn: Binding(
                        get: { saveToICloud && !cloudFolderPath.isEmpty },
                        set: { enabled in
                            if !enabled { CloudDocuments.disable() }
                            else if !CloudDocuments.enableIfAuthorized() { CloudFolderPicker.choose() }
                        }
                    ))
                    if !cloudFolderPath.isEmpty {
                        LabeledContent("Carpeta", value: URL(fileURLWithPath: cloudFolderPath).lastPathComponent)
                            .help(cloudFolderPath)
                        Button("Cambiar carpeta…") { CloudFolderPicker.choose() }
                    }
                    Text("Los documentos nuevos se crean en esa carpeta y aparecen en la barra lateral. macOS los sincroniza con tus otros dispositivos. Al guardar un borrador sin archivo, el panel se abre en esa carpeta. Los documentos que ya existen se quedan donde están.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            .tabItem { Label("Documentos", systemImage: "icloud") }
        }
        .padding(12).frame(width: 640, height: 640)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .onAppear { editingScheme = effectiveScheme }
        .onChange(of: effectiveScheme) { _, scheme in editingScheme = scheme }
        .confirmationDialog("¿Restablecer todas las preferencias?", isPresented: $confirmingReset) {
            Button("Restablecer", role: .destructive) { resetPreferences() }
        } message: {
            Text("Se restablecerán la tipografía, los colores, el tema y la presentación. Tus documentos no cambiarán.")
        }
    }

    private func resetPreferences() {
        fontSize = 18; family = "system"; fontWeight = "regular"
        spacing = 6; paragraph = 0; tracking = 0; alignment = "natural"; width = 760
        lightTextHex = "auto"; lightBackgroundHex = "auto"; lightAccentHex = "auto"
        darkTextHex = "auto"; darkBackgroundHex = "auto"; darkAccentHex = "auto"
        syntax = true; statistics = true; appearance = "system"
        sidebarSide = SidebarSide.leading.rawValue
    }

    private var themePreview: some View {
        let textColor = WritingStyle.swiftUIColor(fromHex: editingText.wrappedValue) ?? .primary
        let backgroundColor = WritingStyle.swiftUIColor(fromHex: editingBackground.wrappedValue) ?? Color(nsColor: .textBackgroundColor)
        let accentColor = WritingStyle.swiftUIColor(fromHex: editingAccent.wrappedValue) ?? .accentColor
        return VStack(alignment: .leading, spacing: 8) {
            Text("Así se ve una nota").font(.title3).foregroundStyle(textColor)
            Text("Este es el color del texto.").foregroundStyle(textColor)
            Text("Así se ve un enlace").underline().foregroundStyle(accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(backgroundColor)
        .overlay(Rectangle().stroke(Color.primary.opacity(0.12)))
        .environment(\.colorScheme, editingScheme)
    }

    private var fontPreview: some View {
        let style = WritingStyle(size: fontSize, family: family, spacing: spacing, paragraph: paragraph, tracking: tracking, alignment: alignment, weight: fontWeight)
        return Text("El bosque se queda en silencio.\nLuego vuelve a escucharse la lluvia.")
            .font(Font(style.font))
            .tracking(tracking)
            .lineSpacing(spacing)
            .multilineTextAlignment(alignment == "center" ? .center : alignment == "right" ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: alignment == "center" ? .center : alignment == "right" ? .trailing : .leading)
            .padding(.vertical, 8)
    }

    private var fontBrowser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fuentes").font(.title2)
            HStack(spacing: 16) {
                Picker("Estilo rápido", selection: $family) {
                    ForEach(WritingStyle.availableFamilies, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                    if !WritingStyle.isPresetFamily(family) {
                        Text(family).tag(family)
                    }
                }
                Picker("Grosor", selection: $fontWeight) {
                    ForEach(WritingStyle.availableWeights, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
            }
            TextField("Buscar fuentes del Mac", text: $fontSearch)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("Vista previa: \(WritingStyle.displayName(for: family))")
                    .font(.caption).foregroundStyle(.secondary)
                fontPreview
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.12)))
            Text("\(filteredSystemFonts.count) fuentes instaladas")
                .font(.caption).foregroundStyle(.secondary)
            if filteredSystemFonts.isEmpty {
                Text("No hay fuentes con ese nombre.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSystemFonts, id: \.self) { name in
                            Button {
                                family = name
                            } label: {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(name).font(.caption).foregroundStyle(.secondary)
                                        Text("Mañana escribiré una historia.")
                                            .font(Font(WritingStyle(size: 17, family: name).font))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if family == name { Image(systemName: "checkmark") }
                                }
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(family == name ? Color.accentColor.opacity(0.12) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(family == name ? [.isSelected] : [])
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Rectangle().stroke(Color.primary.opacity(0.12)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func themePresetButton(_ preset: WritingThemePreset) -> some View {
        let selected = activePresetID == preset.id
        return Button {
            applyTheme(preset)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 2) {
                    themeSample(preset, for: .light)
                    themeSample(preset, for: .dark)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    Text(preset.name).lineLimit(1)
                }
                .font(.callout)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Combinación \(preset.name), modos claro y oscuro")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func themeSample(_ preset: WritingThemePreset, for scheme: ColorScheme) -> some View {
        let hexes = preset.hexes(for: scheme)
        let textColor = WritingStyle.swiftUIColor(fromHex: hexes.text) ?? .primary
        let backgroundColor = WritingStyle.swiftUIColor(fromHex: hexes.background) ?? Color(nsColor: .textBackgroundColor)
        let accentColor = WritingStyle.swiftUIColor(fromHex: hexes.accent) ?? .accentColor
        return VStack(alignment: .leading, spacing: 4) {
            Text("Aa").font(.system(size: 19, weight: .semibold)).foregroundStyle(textColor)
            Rectangle().fill(accentColor).frame(width: 24, height: 2)
            Text(scheme == .dark ? "Oscuro" : "Claro")
                .font(.caption2).foregroundStyle(textColor)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(backgroundColor)
        .environment(\.colorScheme, scheme)
    }

    private func applyTheme(_ preset: WritingThemePreset, to scheme: ColorScheme? = nil) {
        if scheme == nil || scheme == .light {
            lightTextHex = preset.lightTextHex
            lightBackgroundHex = preset.lightBackgroundHex
            lightAccentHex = preset.lightAccentHex
        }
        if scheme == nil || scheme == .dark {
            darkTextHex = preset.darkTextHex
            darkBackgroundHex = preset.darkBackgroundHex
            darkAccentHex = preset.darkAccentHex
        }
    }

    @Environment(\.colorScheme) private var systemScheme
}

struct ThemeColorRow: View {
    let title: String
    let subtitle: String
    @Binding var hex: String
    var defaultHex: String = "#000000"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if hex != "auto" {
                    Text(hex).font(.caption).monospaced().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker(title, selection: Binding(
                get: { hex == "auto" ? "auto" : "custom" },
                set: { hex = ($0 == "auto") ? "auto" : defaultHex }
            )) {
                Text("Automático").tag("auto")
                Text("Personalizado").tag("custom")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Tipo de color para \(title.lowercased())")
            .frame(width: 220)
            if hex != "auto" {
                ColorPicker(title, selection: Binding(
                    get: { WritingStyle.swiftUIColor(fromHex: hex) ?? WritingStyle.swiftUIColor(fromHex: defaultHex) ?? .black },
                    set: { hex = WritingStyle.hex(from: $0) }
                ))
                .labelsHidden()
                .accessibilityLabel("Color de \(title.lowercased())")
            }
        }
        .padding(.vertical, 4)
    }
}
