import Foundation

public struct MarkdownImage: Equatable, Sendable {
    private static let expression = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^\s)]+)(?: "width=([0-9]+);align=(left|center|right)")?\)$"#)
    public enum Alignment: String, CaseIterable, Sendable { case left, center, right }
    public let alt: String
    public let path: String
    public let width: Int
    public let alignment: Alignment

    public init?(line: String) {
        guard line.hasPrefix("![") else { return nil }
        guard let result = Self.expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              result.range.length == (line as NSString).length,
              let altRange = Range(result.range(at: 1), in: line),
              let pathRange = Range(result.range(at: 2), in: line) else { return nil }
        let path = String(line[pathRange])
        guard !path.hasPrefix("/"), !path.contains("://"), !path.split(separator: "/").contains("..") else { return nil }
        self.alt = String(line[altRange])
        self.path = path
        if let range = Range(result.range(at: 3), in: line), let value = Int(line[range]) {
            width = min(1200, max(80, value))
        } else {
            width = 480
        }
        if let range = Range(result.range(at: 4), in: line) {
            alignment = Alignment(rawValue: String(line[range])) ?? .left
        } else {
            alignment = .left
        }
    }

    public init(alt: String, path: String, width: Int = 480, alignment: Alignment = .left) {
        self.alt = alt.replacingOccurrences(of: "]", with: "")
        self.path = path
        self.width = min(1200, max(80, width))
        self.alignment = alignment
    }

    public var markdown: String { "![\(alt)](\(path) \"width=\(width);align=\(alignment.rawValue)\")" }

    public func fileURL(relativeTo documentURL: URL) -> URL? {
        guard let decoded = path.removingPercentEncoding else { return nil }
        let folder = documentURL.deletingLastPathComponent().standardizedFileURL
        let url = folder.appendingPathComponent(decoded).standardizedFileURL
        guard url.path.hasPrefix(folder.path + "/") else { return nil }
        return url
    }
}

@MainActor public enum DocumentImageAccess {
    // ponytail: conserva el acceso hasta cerrar la app; liberar por documento si se editan cientos de carpetas por sesión.
    private static var activeFolders: [String: URL] = [:]

    public static func start(for documentURL: URL) {
        let path = documentURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard activeFolders[path] == nil,
              let bookmark = UserDefaults.standard.data(forKey: "image-folder:" + path) else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
              folder.startAccessingSecurityScopedResource() else { return }
        activeFolders[path] = folder
    }

    public static func remember(_ folder: URL, for documentURL: URL) throws {
        let path = documentURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard folder.resolvingSymlinksInPath().path == path else { throw CocoaError(.fileReadNoPermission) }
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "image-folder:" + path)
        start(for: documentURL)
    }
}

public struct MarkdownLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case heading(Int)
        case quote
        case list
        case orderedList(number: Int)
        case taskList(checked: Bool, number: Int?)
        case code
        /// Valla de código. `info` es el texto tras la apertura (`diagram`, `swift`…); vacío en el cierre.
        case fence(info: String)
        /// Fila de tabla GFM; `header` marca la primera.
        case tableRow(header: Bool)
        /// Fila de separación de una tabla (`| --- | :-: |`).
        case tableDelimiter
        case rule
        case hidden
    }
    public let range: NSRange
    public let content: String
    public let prefixLength: Int
    public let trailingLength: Int
    public let kind: Kind

    public init(range: NSRange, content: String, prefixLength: Int, trailingLength: Int = 0, kind: Kind) {
        self.range = range
        self.content = content
        self.prefixLength = prefixLength
        self.trailingLength = trailingLength
        self.kind = kind
    }

    func with(kind: Kind) -> MarkdownLine {
        MarkdownLine(range: range, content: content, prefixLength: prefixLength, trailingLength: trailingLength, kind: kind)
    }
}

/// Celdas y alineación de tablas GFM. Solo texto: el render vive en EditorEngine.
public enum MarkdownTable {
    public enum Alignment: Sendable, Equatable { case natural, left, center, right }

    /// Celdas de una fila, sin las barras de los extremos. `\|` es una barra literal.
    public static func cells(in line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Alineación de cada columna, o `nil` si la línea no es una fila de separación.
    public static func alignments(delimiter line: String) -> [Alignment]? {
        let cells = cells(in: line)
        var result: [Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .right : left ? .left : .natural)
        }
        return result
    }
}

public struct DocumentStatistics: Sendable, Equatable {
    public var words = 0
    public var characters = 0
    public var paragraphs = 0
    public var readingMinutes: Int { max(1, Int(ceil(Double(words) / 220))) }
    public init() {}
}

public struct MarkdownDocument: Sendable {
    public let lines: [MarkdownLine]
    public let statistics: DocumentStatistics

    public var headings: [DocumentHeading] {
        lines.compactMap { line in
            guard case .heading(let level) = line.kind else { return nil }
            return DocumentHeading(title: line.content, offset: line.range.location, level: level)
        }
    }

    public init(_ source: String) {
        // `NSTextView.string` llega puenteado; recorrerlo así es varias veces más lento.
        let text = source.nativeCopy()
        var parsed: [MarkdownLine] = []
        var fence: (Character, Int)?
        var offset = 0
        var statistics = DocumentStatistics()
        var inParagraph = false
        var previousWasBlank = true

        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            let raw = String(text[range])
            let (indentChars, indentWidth) = Self.leadingIndent(raw)
            let stripped: String = indentWidth <= 3 ? String(raw.dropFirst(indentChars)) : raw
            var kind: MarkdownLine.Kind = .text
            var content = raw
            var prefixChars = 0
            var trailingChars = 0

            if let current = fence {
                let marker = stripped.first
                let count = stripped.prefix(while: { $0 == marker }).count
                if marker == current.0, count >= current.1,
                   stripped.dropFirst(count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    kind = .fence(info: "")
                    prefixChars = indentChars + count
                    content = String(raw.dropFirst(min(prefixChars, raw.count)))
                    fence = nil
                } else {
                    kind = .code
                    content = raw
                }
            } else if let fenceOpen = Self.fenceOpen(stripped) {
                // Evita que ``` con backticks en el info se tome como valla.
                if fenceOpen.marker == "`", stripped.dropFirst(fenceOpen.count).contains("`") {
                    kind = .text
                } else {
                    fence = (fenceOpen.marker, fenceOpen.count)
                    prefixChars = indentChars + fenceOpen.count
                    content = String(raw.dropFirst(min(prefixChars, raw.count)))
                    kind = .fence(info: content.trimmingCharacters(in: .whitespaces))
                }
            } else if let heading = Self.atxHeading(raw: raw, indentChars: indentChars, stripped: stripped) {
                kind = .heading(heading.level)
                prefixChars = heading.prefixChars
                trailingChars = heading.trailingChars
                content = heading.content
            } else if Self.isThematicBreak(stripped) {
                kind = .rule
                content = raw
            } else if let quote = Self.quotePrefix(line: stripped, indentChars: indentChars) {
                kind = .quote
                prefixChars = quote
                content = String(raw.dropFirst(min(prefixChars, raw.count)))
            } else if let list = Self.listPrefix(line: stripped, indentChars: indentChars) {
                kind = list.kind
                prefixChars = list.prefixChars
                content = String(raw.dropFirst(min(prefixChars, raw.count)))
            } else if indentWidth >= 4, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, previousWasBlank {
                kind = .code
                content = Self.stripIndentWidth(raw, width: 4)
            }

            let blank = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !blank, !inParagraph { statistics.paragraphs += 1 }
            inParagraph = !blank
            previousWasBlank = blank

            let utf16Prefix = prefixChars > 0 ? raw.prefix(prefixChars).utf16.count : 0
            let utf16Trailing = trailingChars > 0 ? raw.suffix(trailingChars).utf16.count : 0
            let length = text[enclosing].utf16.count
            parsed.append(MarkdownLine(
                range: NSRange(location: offset, length: length),
                content: content,
                prefixLength: utf16Prefix,
                trailingLength: utf16Trailing,
                kind: kind
            ))
            offset += length
        }

        // Tablas GFM: cabecera con `|` seguida de una fila de separación con el mismo número de celdas.
        var row = 0
        while row + 1 < parsed.count {
            let header = parsed[row]
            let delimiter = parsed[row + 1]
            guard header.kind == .text, header.content.utf8.contains(UInt8(ascii: "|")),
                  delimiter.kind == .text || delimiter.kind == .rule,
                  let alignments = MarkdownTable.alignments(delimiter: delimiter.content),
                  alignments.count == MarkdownTable.cells(in: header.content).count else {
                row += 1
                continue
            }
            parsed[row] = header.with(kind: .tableRow(header: true))
            parsed[row + 1] = delimiter.with(kind: .tableDelimiter)
            row += 2
            while row < parsed.count, parsed[row].kind == .text,
                  !parsed[row].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed[row] = parsed[row].with(kind: .tableRow(header: false))
                row += 1
            }
        }

        // Segunda pasada: títulos setext (`===` / `---` bajo un párrafo).
        if parsed.count >= 2 {
            for index in 1..<parsed.count {
                let current = parsed[index]
                let previous = parsed[index - 1]
                guard case .text = previous.kind,
                      !previous.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let trimmed = current.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if current.kind == .text, trimmed.allSatisfy({ $0 == "=" }) {
                    parsed[index - 1] = MarkdownLine(
                        range: previous.range, content: previous.content,
                        prefixLength: previous.prefixLength, trailingLength: previous.trailingLength,
                        kind: .heading(1)
                    )
                    parsed[index] = MarkdownLine(
                        range: current.range, content: "",
                        prefixLength: 0, trailingLength: 0, kind: .hidden
                    )
                } else if current.kind == .rule, trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "").allSatisfy({ $0 == "-" }) {
                    parsed[index - 1] = MarkdownLine(
                        range: previous.range, content: previous.content,
                        prefixLength: previous.prefixLength, trailingLength: previous.trailingLength,
                        kind: .heading(2)
                    )
                    parsed[index] = MarkdownLine(
                        range: current.range, content: "",
                        prefixLength: 0, trailingLength: 0, kind: .hidden
                    )
                }
            }
        }

        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            statistics.words += 1
        }
        statistics.characters = text.count
        self.lines = parsed
        self.statistics = statistics
    }

    // MARK: - Bloques

    private static func leadingIndent(_ raw: String) -> (chars: Int, width: Int) {
        var chars = 0
        var width = 0
        for scalar in raw {
            if scalar == " " { chars += 1; width += 1 }
            else if scalar == "\t" { chars += 1; width += 4 }
            else { break }
        }
        return (chars, width)
    }

    private static func stripIndentWidth(_ raw: String, width target: Int) -> String {
        var consumed = 0
        var chars = 0
        for scalar in raw {
            if consumed >= target { break }
            if scalar == " " { consumed += 1; chars += 1 }
            else if scalar == "\t" { consumed += 4; chars += 1 }
            else { break }
        }
        return String(raw.dropFirst(chars))
    }

    private static func fenceOpen(_ line: String) -> (marker: Character, count: Int)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let count = line.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        return (marker, count)
    }

    private struct HeadingParse {
        let level: Int
        let prefixChars: Int
        let trailingChars: Int
        let content: String
    }

    private static func atxHeading(raw: String, indentChars: Int, stripped: String) -> HeadingParse? {
        let level = stripped.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        guard stripped.count == level || stripped.dropFirst(level).first?.isWhitespace == true else { return nil }
        var prefixChars = indentChars + level
        // Consume hasta un espacio/tab y el resto del sangrado tras las almohadillas.
        if stripped.count > level {
            prefixChars += 1
            var extra = 0
            let after = stripped.dropFirst(level + 1)
            for scalar in after {
                if scalar == " " || scalar == "\t" { extra += 1 } else { break }
            }
            prefixChars += extra
        }
        guard prefixChars <= raw.count else { return nil }
        let middle = String(raw.dropFirst(prefixChars))
        // Separa espacios finales para detectar el cierre ` ##`.
        var coreEnd = middle.endIndex
        while coreEnd > middle.startIndex, middle[middle.index(before: coreEnd)] == " " || middle[middle.index(before: coreEnd)] == "\t" {
            coreEnd = middle.index(before: coreEnd)
        }
        let trailingSpaces = String(middle[coreEnd...])
        let corePlusClosing = String(middle[..<coreEnd])
        // Solo almohadillas: título vacío con cierre (`## ###`).
        if !corePlusClosing.isEmpty, corePlusClosing.allSatisfy({ $0 == "#" }) {
            return HeadingParse(level: level, prefixChars: prefixChars, trailingChars: middle.count, content: "")
        }
        // Cierre ` +#+` precedido de espacio.
        if let hashStart = closingHashStart(in: corePlusClosing) {
            let content = String(corePlusClosing[..<hashStart]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let suffix = String(corePlusClosing[hashStart...]) + trailingSpaces
            return HeadingParse(level: level, prefixChars: prefixChars, trailingChars: suffix.count, content: content)
        }
        let content = corePlusClosing
        return HeadingParse(level: level, prefixChars: prefixChars, trailingChars: trailingSpaces.count, content: content)
    }

    private static func closingHashStart(in text: String) -> String.Index? {
        // Busca ` +#+` al final: espacios + almohadillas hasta el final.
        var index = text.endIndex
        while index > text.startIndex, text[text.index(before: index)] == "#" {
            index = text.index(before: index)
        }
        guard index < text.endIndex else { return nil }
        guard index > text.startIndex else { return nil }
        let before = text[text.index(before: index)]
        guard before == " " || before == "\t" else { return nil }
        // Retrocede los espacios para que el sufijo los incluya.
        var start = text.index(before: index)
        while start > text.startIndex {
            let prev = text[text.index(before: start)]
            if prev == " " || prev == "\t" { start = text.index(before: start) }
            else { break }
        }
        // El contenido previo no puede estar vacío salvo el caso solo-almohadillas ya tratado.
        let head = text[..<start].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !head.isEmpty || text[..<start].isEmpty == false else { return nil }
        // Si el contenido es vacío (`##  ##`), se acepta: head vacío pero había prefijo.
        // Solo se rechaza si todo el texto eran espacios (imposible aquí porque termina en #).
        _ = head
        return start
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard let lead = line.utf8.first(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }),
              lead == UInt8(ascii: "-") || lead == UInt8(ascii: "*") || lead == UInt8(ascii: "_") else { return false }
        let filtered = line.filter { $0 != " " && $0 != "\t" }
        guard filtered.count >= 3 else { return false }
        guard let first = filtered.first, first == "-" || first == "*" || first == "_" else { return false }
        return filtered.allSatisfy { $0 == first }
    }

    private static func quotePrefix(line: String, indentChars: Int) -> Int? {
        var consumed = 0
        var index = line.startIndex
        var found = false
        while index < line.endIndex, line[index] == ">" {
            found = true
            consumed += 1
            index = line.index(after: index)
            // Consume todos los espacios/tabs tras cada `>`.
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                consumed += 1
                index = line.index(after: index)
            }
        }
        guard found else { return nil }
        return indentChars + consumed
    }

    private struct ListParse {
        let kind: MarkdownLine.Kind
        let prefixChars: Int
    }

    private static func listPrefix(line: String, indentChars: Int) -> ListParse? {
        if let ordered = orderedPrefix(line: line, indentChars: indentChars) { return ordered }
        guard let marker = line.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        let after = line.dropFirst()
        guard after.isEmpty || after.first?.isWhitespace == true else { return nil }
        var consumed = 1
        var rest = after
        while let first = rest.first, first == " " || first == "\t" {
            consumed += 1
            rest = rest.dropFirst()
        }
        if let task = taskSuffix(rest: String(rest), basePrefix: indentChars + consumed) {
            return ListParse(kind: .taskList(checked: task.checked, number: nil), prefixChars: task.prefixChars)
        }
        return ListParse(kind: .list, prefixChars: indentChars + consumed)
    }

    private static func orderedPrefix(line: String, indentChars: Int) -> ListParse? {
        var digitCount = 0
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, digitCount < 9 {
            // Solo dígitos ASCII para marcadores (`1.` no `١.`).
            guard line[index].isASCII, let scalar = line[index].unicodeScalars.first, scalar.value >= 48, scalar.value <= 57 else { break }
            digitCount += 1
            index = line.index(after: index)
        }
        guard digitCount >= 1, index < line.endIndex else {
            // `1.` al final sin contenido también es lista.
            if digitCount >= 1, index == line.endIndex {
                return ListParse(kind: .orderedList(number: Int(line.prefix(digitCount)) ?? 1), prefixChars: indentChars + digitCount)
            }
            return nil
        }
        let delimiter = line[index]
        guard delimiter == "." || delimiter == ")" else { return nil }
        let number = Int(line.prefix(digitCount)) ?? 1
        var consumed = digitCount + 1
        var rest = line.dropFirst(consumed)
        if rest.isEmpty {
            return ListParse(kind: .orderedList(number: number), prefixChars: indentChars + consumed)
        }
        guard let first = rest.first, first.isWhitespace else { return nil }
        while let first = rest.first, first == " " || first == "\t" {
            consumed += 1
            rest = rest.dropFirst()
        }
        if let task = taskSuffix(rest: String(rest), basePrefix: indentChars + consumed) {
            return ListParse(kind: .taskList(checked: task.checked, number: number), prefixChars: task.prefixChars)
        }
        return ListParse(kind: .orderedList(number: number), prefixChars: indentChars + consumed)
    }

    private static func taskSuffix(rest: String, basePrefix: Int) -> (checked: Bool, prefixChars: Int)? {
        guard rest.hasPrefix("[") else { return nil }
        let chars = Array(rest)
        guard chars.count >= 3, chars[0] == "[", chars[2] == "]" else { return nil }
        let middle = chars[1]
        guard middle == " " || middle == "x" || middle == "X" else { return nil }
        let after = String(chars.dropFirst(3))
        if !after.isEmpty, !(after.first?.isWhitespace == true) { return nil }
        var consumed = 3
        var tail = after
        while let first = tail.first, first == " " || first == "\t" {
            consumed += 1
            tail = String(tail.dropFirst())
        }
        return (middle == "x" || middle == "X", basePrefix + consumed)
    }
}

public extension MarkdownLine.Kind {
    /// Líneas cuyo texto fuente se muestra tal cual en edición (código y tablas).
    var keepsSource: Bool {
        switch self {
        case .code, .fence, .hidden, .tableRow, .tableDelimiter: true
        default: false
        }
    }
}
