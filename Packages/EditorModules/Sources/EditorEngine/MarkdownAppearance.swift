import AppKit
import EditorCore
import DesignSystem
import DiagramModule

@MainActor public enum MarkdownAppearance {
    private static let inlineMarkers = CharacterSet(charactersIn: "\\`<[!*_~")
    // Derivar fuentes con NSFontManager/CoreText domina el decorado de
    // documentos grandes; cada combinación se repite miles de veces.
    private struct TraitKey: Hashable {
        let font: NSFont
        let traits: UInt
    }
    private static var traitFonts: [TraitKey: NSFont] = [:]
    private static var markerFonts: [NSFont: NSFont] = [:]
    private static let markerAttributes: [NSAttributedString.Key] = [
        .backgroundColor, .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor, .link,
    ]

    public static func decorate(_ storage: NSMutableAttributedString, document: MarkdownDocument, style: WritingStyle, lines: Range<Int>? = nil) {
        let selectedLines = document.lines[lines ?? document.lines.indices]
        let affected: NSRange
        if lines != nil {
            guard let first = selectedLines.first, let last = selectedLines.last else { return }
            affected = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        } else {
            affected = NSRange(location: 0, length: storage.length)
        }
        guard affected.length > 0, NSMaxRange(affected) <= storage.length else { return }
        storage.setAttributes(style.attributes, range: affected)
        guard style.syntax else { return }
        let mono = NSFont.monospacedSystemFont(ofSize: style.size - 1, weight: .regular)
        for line in selectedLines {
            guard line.range.length > 0, NSMaxRange(line.range) <= storage.length else { continue }
            switch line.kind {
            case .heading(let level):
                storage.addAttribute(.font, value: style.headingFont(level: level), range: line.range)
            case .code, .fence:
                storage.addAttribute(.font, value: mono, range: line.range)
                storage.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: line.range)
            case .hidden:
                storage.addAttribute(.foregroundColor, value: style.tertiaryTextColor, range: line.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: line.range)
            case .rule:
                storage.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: line.range)
            case .tableRow(let header):
                // Monoespaciada para que las columnas del texto fuente se alineen.
                storage.addAttribute(.font, value: header ? NSFont.monospacedSystemFont(ofSize: style.size - 1, weight: .semibold) : mono, range: line.range)
                let source = storage.string as NSString
                for offset in 0..<line.range.length where source.character(at: line.range.location + offset) == 124 {
                    storage.addAttribute(.foregroundColor, value: style.tertiaryTextColor, range: NSRange(location: line.range.location + offset, length: 1))
                }
            case .tableDelimiter:
                storage.addAttribute(.font, value: mono, range: line.range)
                storage.addAttribute(.foregroundColor, value: style.tertiaryTextColor, range: line.range)
            case .text, .list, .orderedList, .taskList:
                break
            }
            if !line.kind.keepsSource {
                decorateInline(in: storage, lineRange: line.range, style: style)
            }
            if line.prefixLength > 0, line.range.location + line.prefixLength <= storage.length {
                storage.addAttribute(.foregroundColor, value: style.tertiaryTextColor, range: NSRange(location: line.range.location, length: line.prefixLength))
            }
            if line.trailingLength > 0 {
                let location = NSMaxRange(line.range) - line.trailingLength
                // Evita teñir el salto de línea final como sufijo.
                let lineText = (storage.string as NSString).substring(with: line.range)
                let newlineLength = lineText.hasSuffix("\r\n") ? 2 : (lineText.hasSuffix("\n") || lineText.hasSuffix("\r") ? 1 : 0)
                if location >= line.range.location, line.trailingLength <= line.range.length - newlineLength {
                    storage.addAttribute(.foregroundColor, value: style.tertiaryTextColor, range: NSRange(location: location, length: line.trailingLength))
                }
            }
        }
    }

    // MARK: - Edición: inline sin regex

    private static func decorateInline(in storage: NSMutableAttributedString, lineRange: NSRange, style: WritingStyle) {
        let nsString = storage.string as NSString
        var effectiveLength = lineRange.length
        while effectiveLength > 0 {
            let code = nsString.character(at: lineRange.location + effectiveLength - 1)
            if code == 10 || code == 13 { effectiveLength -= 1 } else { break }
        }
        guard effectiveLength > 0 else { return }
        let effectiveRange = NSRange(location: lineRange.location, length: effectiveLength)
        let marker = nsString.rangeOfCharacter(from: inlineMarkers, range: effectiveRange)
        guard marker.location != NSNotFound else { return }
        // Copia nativa: recorrer por Character un String puenteado es varias veces más lento.
        var lineText = nsString.substring(with: effectiveRange)
        lineText.makeContiguousUTF8()
        scanInline(lineText: lineText, baseOffset: effectiveRange.location, storage: storage, style: style)
    }

    private static func nsRange(of range: Range<String.Index>, in text: String, base: Int) -> NSRange? {
        guard let utf16Range = NSRange(range, in: text) as NSRange? else { return nil }
        return NSRange(location: base + utf16Range.location, length: utf16Range.length)
    }

    private static func isWordChar(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isEscapable(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        let value = scalar.value
        // Puntuación ASCII escapable en Markdown.
        switch value {
        case 33...47, 58...64, 91...96, 123...126: return true
        default: return false
        }
    }

    private static func fontAdding(traits wanted: NSFontTraitMask, to font: NSFont) -> NSFont {
        let key = TraitKey(font: font, traits: wanted.rawValue)
        if let cached = traitFonts[key] { return cached }
        if traitFonts.count > 512 { traitFonts.removeAll() }
        let result = deriveFont(adding: wanted, to: font)
        traitFonts[key] = result
        return result
    }

    private static func deriveFont(adding wanted: NSFontTraitMask, to font: NSFont) -> NSFont {
        let current = NSFontManager.shared.traits(of: font)
        if current.contains(wanted) { return font }
        let combined = current.union(wanted)
        let converted = NSFontManager.shared.convert(font, toHaveTrait: combined)
        if NSFontManager.shared.traits(of: converted).contains(wanted) { return converted }
        // Reintento rasgo por rasgo para no perder la base cuando falta la variante combinada.
        var result = font
        if wanted.contains(.boldFontMask) {
            let candidate = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
            if NSFontManager.shared.traits(of: candidate).contains(.boldFontMask) { result = candidate }
        }
        if wanted.contains(.italicFontMask) {
            let candidate = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
            if NSFontManager.shared.traits(of: candidate).contains(.italicFontMask) { result = candidate }
        }
        return result
    }

    /// Colapsa un marcador markdown (`**`, `` ` ``, `[]()`, `\`…) para que no
    /// deje huecos en el modo editor: lo deja con tamaño mínimo y transparente
    /// pero sin borrarlo del texto (sigue editable y se copia con la fuente).
    /// Conserva negrita/cursiva para no romper el estilo exterior.
    private static func collapseMarker(in storage: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let base = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        storage.addAttributes([.font: markerFont(for: base), .foregroundColor: NSColor.clear], range: range)
        // Quitar un atributo ausente también cuesta una edición del storage.
        for key in markerAttributes {
            var effective = NSRange()
            if storage.attribute(key, at: range.location, effectiveRange: &effective) != nil
                || NSMaxRange(effective) < NSMaxRange(range) {
                storage.removeAttribute(key, range: range)
            }
        }
    }

    private static func markerFont(for base: NSFont) -> NSFont {
        if let cached = markerFonts[base] { return cached }
        if markerFonts.count > 256 { markerFonts.removeAll() }
        let tiny = NSFontManager.shared.convert(base, toSize: 0.1)
        let result: NSFont = tiny.pointSize < 1 ? tiny : (NSFont(descriptor: base.fontDescriptor, size: 0.1) ?? tiny)
        markerFonts[base] = result
        return result
    }

    private static func scanInline(lineText: String, baseOffset: Int, storage: NSMutableAttributedString, style: WritingStyle) {
        var index = lineText.startIndex
        while index < lineText.endIndex {
            let character = lineText[index]
            let nextIndex = lineText.index(after: index)
            // Escape `\*`: oculta la barra (colapsada, sin hueco) y salta el siguiente carácter.
            if character == "\\", nextIndex < lineText.endIndex, isEscapable(lineText[nextIndex]) {
                if let range = nsRange(of: index..<nextIndex, in: lineText, base: baseOffset) {
                    collapseMarker(in: storage, range: range)
                }
                index = lineText.index(after: nextIndex)
                continue
            }
            // Código `...` o ``...``.
            if character == "`" {
                if let end = handleCodeSpan(lineText: lineText, from: index, baseOffset: baseOffset, storage: storage, style: style) {
                    index = end
                    continue
                }
            }
            // Autolink `<https://…>`.
            if character == "<" {
                if let end = handleAutolink(lineText: lineText, from: index, baseOffset: baseOffset, storage: storage, style: style) {
                    index = end
                    continue
                }
            }
            // Imagen o enlace `[texto](url)`.
            let isLinkStart = character == "[" || (character == "!" && nextIndex < lineText.endIndex && lineText[nextIndex] == "[")
            if isLinkStart {
                if let end = handleLink(lineText: lineText, from: index, baseOffset: baseOffset, storage: storage, style: style) {
                    index = end
                    continue
                }
            }
            // Énfasis y tachado: prueba el marcador más largo primero.
            guard character == "*" || character == "_" || character == "~" else {
                index = nextIndex
                continue
            }
            var consumed = false
            for marker in ["***", "___", "**", "__", "~~", "*", "_"] {
                guard lineText[index...].hasPrefix(marker) else { continue }
                if let end = handleEmphasis(lineText: lineText, from: index, marker: marker, baseOffset: baseOffset, storage: storage, style: style) {
                    index = end
                    consumed = true
                    break
                }
                // Si el marcador largo no cierra, no intentes uno más corto en la misma posición
                // cuando comparte carácter (`***` fallido no es `**` + `*`).
                if marker == "***" || marker == "___" { break }
            }
            if consumed { continue }
            index = nextIndex
        }
    }

    private static func runLength(in text: String, from index: String.Index, char: Character) -> Int {
        var count = 0
        var cursor = index
        while cursor < text.endIndex, text[cursor] == char {
            count += 1
            cursor = text.index(after: cursor)
        }
        return count
    }

    private static func handleCodeSpan(lineText: String, from index: String.Index, baseOffset: Int, storage: NSMutableAttributedString, style: WritingStyle) -> String.Index? {
        let openLen = runLength(in: lineText, from: index, char: "`")
        guard openLen >= 1 else { return nil }
        var cursor = lineText.index(index, offsetBy: openLen, limitedBy: lineText.endIndex) ?? lineText.endIndex
        while cursor < lineText.endIndex {
            if lineText[cursor] == "`" {
                let closeLen = runLength(in: lineText, from: cursor, char: "`")
                if closeLen == openLen {
                    let closeEnd = lineText.index(cursor, offsetBy: closeLen, limitedBy: lineText.endIndex) ?? lineText.endIndex
                    let innerStart = lineText.index(index, offsetBy: openLen, limitedBy: lineText.endIndex) ?? lineText.endIndex
                    let inner = String(lineText[innerStart..<cursor])
                    guard !inner.isEmpty, !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    if let fullRange = nsRange(of: index..<closeEnd, in: lineText, base: baseOffset) {
                        let mono = NSFont.monospacedSystemFont(ofSize: style.size - 1, weight: .regular)
                        storage.addAttribute(.font, value: mono, range: fullRange)
                        storage.addAttribute(.backgroundColor, value: style.faintFillColor, range: fullRange)
                        storage.addAttribute(.foregroundColor, value: style.effectiveTextColor, range: fullRange)
                        if let openRange = nsRange(of: index..<innerStart, in: lineText, base: baseOffset) {
                            collapseMarker(in: storage, range: openRange)
                        }
                        if let closeRange = nsRange(of: cursor..<closeEnd, in: lineText, base: baseOffset) {
                            collapseMarker(in: storage, range: closeRange)
                        }
                    }
                    return closeEnd
                }
                cursor = lineText.index(cursor, offsetBy: closeLen, limitedBy: lineText.endIndex) ?? lineText.endIndex
            } else if lineText[cursor] == "\\" {
                let after = lineText.index(after: cursor)
                cursor = after < lineText.endIndex ? lineText.index(after: after) : lineText.endIndex
            } else {
                cursor = lineText.index(after: cursor)
            }
        }
        return nil
    }

    private static func handleAutolink(lineText: String, from index: String.Index, baseOffset: Int, storage: NSMutableAttributedString, style: WritingStyle) -> String.Index? {
        guard let close = lineText[index...].firstIndex(of: ">") else { return nil }
        let innerStart = lineText.index(after: index)
        guard innerStart < close else { return nil }
        let inner = String(lineText[innerStart..<close])
        guard !inner.isEmpty, !inner.contains(" "), !inner.contains("\n") else { return nil }
        guard inner.contains(":") || inner.contains("@") else { return nil }
        let closeEnd = lineText.index(after: close)
        if let fullRange = nsRange(of: index..<closeEnd, in: lineText, base: baseOffset) {
            storage.addAttribute(.foregroundColor, value: style.effectiveAccentColor, range: fullRange)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
            if let openRange = nsRange(of: index..<innerStart, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: openRange)
            }
            if let closeRange = nsRange(of: close..<closeEnd, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: closeRange)
            }
        }
        return closeEnd
    }

    private static func findUnescaped(_ text: String, from start: String.Index, target: Character) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor] == "\\" {
                let after = text.index(after: cursor)
                cursor = after < text.endIndex ? text.index(after: after) : text.endIndex
                continue
            }
            if text[cursor] == target { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func handleLink(lineText: String, from index: String.Index, baseOffset: Int, storage: NSMutableAttributedString, style: WritingStyle) -> String.Index? {
        var textStart = index
        let isImage: Bool
        if lineText[index] == "!" {
            let after = lineText.index(after: index)
            guard after < lineText.endIndex, lineText[after] == "[" else { return nil }
            isImage = true
            textStart = lineText.index(after: after)
        } else {
            isImage = false
            textStart = lineText.index(after: index)
        }
        guard let bracketClose = findUnescaped(lineText, from: textStart, target: "]") else { return nil }
        let labelRange = textStart..<bracketClose
        let afterBracket = lineText.index(after: bracketClose)
        // Enlace en línea `[texto](url)`.
        if afterBracket < lineText.endIndex, lineText[afterBracket] == "(" {
            let urlStart = lineText.index(after: afterBracket)
            guard let parenClose = findUnescaped(lineText, from: urlStart, target: ")") else { return nil }
            let urlInner = String(lineText[urlStart..<parenClose])
            // La URL puede estar vacía mientras se escribe; el título tras espacio se ignora para el estilo.
            _ = urlInner
            let linkEnd = lineText.index(after: parenClose)
            styleLink(labelRange: labelRange, bracketClose: bracketClose, parenOpen: afterBracket, urlRange: urlStart..<parenClose, end: linkEnd, start: index, isImage: isImage, lineText: lineText, baseOffset: baseOffset, storage: storage, style: style)
            // Recursión para énfasis/código dentro del texto del enlace.
            if !labelRange.isEmpty {
                let labelText = String(lineText[labelRange])
                let labelNS = NSRange(labelRange, in: lineText)
                let labelBase = baseOffset + labelNS.location
                scanInline(lineText: labelText, baseOffset: labelBase, storage: storage, style: style)
                // Reafirma el color del enlace tras la recursión (la recursión no lo pisa salvo código).
                if let reaffirm = nsRange(of: labelRange, in: lineText, base: baseOffset) {
                    if !isImage {
                        storage.addAttribute(.foregroundColor, value: style.effectiveAccentColor, range: reaffirm)
                        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: reaffirm)
                    }
                }
            }
            return linkEnd
        }
        // Referencia `[texto][ref]` o colapsada `[texto][]`.
        if afterBracket < lineText.endIndex, lineText[afterBracket] == "[" {
            let refStart = lineText.index(after: afterBracket)
            guard let refClose = findUnescaped(lineText, from: refStart, target: "]") else { return nil }
            let linkEnd = lineText.index(after: refClose)
            if let labelNSRange = nsRange(of: labelRange, in: lineText, base: baseOffset) {
                storage.addAttribute(.foregroundColor, value: isImage ? style.secondaryTextColor : style.effectiveAccentColor, range: labelNSRange)
                if !isImage {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: labelNSRange)
                }
            }
            if let openRange = nsRange(of: index..<textStart, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: openRange)
            }
            if let midRange = nsRange(of: bracketClose..<refStart, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: midRange)
            }
            if let closeRange = nsRange(of: refClose..<linkEnd, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: closeRange)
            }
            return linkEnd
        }
        return nil
    }

    private static func styleLink(labelRange: Range<String.Index>, bracketClose: String.Index, parenOpen: String.Index, urlRange: Range<String.Index>, end: String.Index, start: String.Index, isImage: Bool, lineText: String, baseOffset: Int, storage: NSMutableAttributedString, style: WritingStyle) {
        if !labelRange.isEmpty, let labelNS = nsRange(of: labelRange, in: lineText, base: baseOffset) {
            if isImage {
                storage.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: labelNS)
            } else {
                storage.addAttribute(.foregroundColor, value: style.effectiveAccentColor, range: labelNS)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: labelNS)
            }
        }
        // `!` + `[` en imágenes o `[` en enlaces.
        let openEnd: String.Index = {
            var cursor = lineText.index(after: start)
            if cursor < lineText.endIndex, lineText[cursor] == "[" {
                cursor = lineText.index(after: cursor)
            }
            return min(cursor, lineText.endIndex)
        }()
        if start < openEnd, let openRange = nsRange(of: start..<openEnd, in: lineText, base: baseOffset) {
            collapseMarker(in: storage, range: openRange)
        }
        if bracketClose < lineText.endIndex {
            let closeBracketEnd = lineText.index(after: bracketClose)
            if let closeBracket = nsRange(of: bracketClose..<closeBracketEnd, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: closeBracket)
            }
        }
        if parenOpen < lineText.endIndex {
            let parenOpenEnd = lineText.index(after: parenOpen)
            if let parenOpenRange = nsRange(of: parenOpen..<parenOpenEnd, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: parenOpenRange)
            }
        }
        if !urlRange.isEmpty, let urlNS = nsRange(of: urlRange, in: lineText, base: baseOffset) {
            collapseMarker(in: storage, range: urlNS)
        }
        if end > lineText.startIndex {
            let parenClose = lineText.index(before: end)
            if parenClose >= urlRange.upperBound, let closeRange = nsRange(of: parenClose..<end, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: closeRange)
            }
        }
    }

    private static func handleEmphasis(lineText: String, from index: String.Index, marker: String, baseOffset: Int, storage: NSMutableAttributedString, style: WritingStyle) -> String.Index? {
        let markerLen = marker.count
        guard lineText[index...].hasPrefix(marker) else { return nil }
        let markerChar = marker.first ?? "*"
        // El marcador no debe formar parte de una racha más larga (`**` dentro de `***`).
        if index > lineText.startIndex, lineText[lineText.index(before: index)] == markerChar { return nil }
        let afterOpen = lineText.index(index, offsetBy: markerLen, limitedBy: lineText.endIndex) ?? lineText.endIndex
        guard afterOpen <= lineText.endIndex else { return nil }
        if afterOpen < lineText.endIndex, lineText[afterOpen] == markerChar { return nil }
        // Apertura: el contenido no empieza con espacio.
        guard afterOpen < lineText.endIndex, lineText[afterOpen] != " ", lineText[afterOpen] != "\t" else { return nil }
        if marker.contains("_") {
            // `_` dentro de palabra no es énfasis (`foo_bar`).
            if index > lineText.startIndex, isWordChar(lineText[lineText.index(before: index)]) { return nil }
        }
        var search = afterOpen
        while search < lineText.endIndex {
            guard let candidate = lineText[search...].range(of: marker)?.lowerBound else { return nil }
            // Cierre exacto, no parte de racha más larga.
            if candidate > lineText.startIndex, lineText[lineText.index(before: candidate)] == markerChar, markerLen == 1 {
                // Para `*` одино, el retroceso ya lo impide si venía de `**`; aquí solo evita `**` como cierre de `*`.
                // Comprueba la racha completa en el candidato.
                let run = runLength(in: lineText, from: candidate, char: markerChar)
                if run != markerLen {
                    search = lineText.index(candidate, offsetBy: run, limitedBy: lineText.endIndex) ?? lineText.endIndex
                    continue
                }
            } else {
                let run = runLength(in: lineText, from: candidate, char: markerChar)
                if run != markerLen {
                    search = lineText.index(candidate, offsetBy: max(1, run), limitedBy: lineText.endIndex) ?? lineText.endIndex
                    continue
                }
            }
            let candidateEnd = lineText.index(candidate, offsetBy: markerLen, limitedBy: lineText.endIndex) ?? lineText.endIndex
            if candidateEnd < lineText.endIndex, lineText[candidateEnd] == markerChar {
                search = candidateEnd
                continue
            }
            // Cierre: el contenido no termina con espacio.
            let contentEnd = candidate
            guard contentEnd > afterOpen else {
                search = candidateEnd
                continue
            }
            let lastContent = lineText[lineText.index(before: contentEnd)]
            guard lastContent != " ", lastContent != "\t" else {
                search = candidateEnd
                continue
            }
            if marker.contains("_") {
                if candidateEnd < lineText.endIndex, isWordChar(lineText[candidateEnd]) {
                    search = candidateEnd
                    continue
                }
            }
            // Evita que un escape anule el cierre.
            if isEscaped(in: lineText, at: candidate) {
                search = candidateEnd
                continue
            }
            let contentRange = afterOpen..<contentEnd
            let fullRange = index..<candidateEnd
            guard let fullNS = nsRange(of: fullRange, in: lineText, base: baseOffset) else { return nil }
            let baseFont = storage.attribute(.font, at: fullNS.location, effectiveRange: nil) as? NSFont ?? style.font
            switch marker {
            case "***", "___":
                let both: NSFontTraitMask = [.boldFontMask, .italicFontMask]
                storage.addAttribute(.font, value: fontAdding(traits: both, to: baseFont), range: fullNS)
            case "**", "__":
                storage.addAttribute(.font, value: fontAdding(traits: .boldFontMask, to: baseFont), range: fullNS)
            case "*", "_":
                storage.addAttribute(.font, value: fontAdding(traits: .italicFontMask, to: baseFont), range: fullNS)
            case "~~":
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullNS)
                storage.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: fullNS)
            default:
                break
            }
            // Colapsa los marcadores (sin huecos) en vez de atenuarlos.
            if let openNS = nsRange(of: index..<afterOpen, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: openNS)
            }
            if let closeNS = nsRange(of: candidate..<candidateEnd, in: lineText, base: baseOffset) {
                collapseMarker(in: storage, range: closeNS)
            }
            // Recursión para anidado (`**negrita *cursiva* **`).
            if !contentRange.isEmpty, lineText[contentRange].rangeOfCharacter(from: inlineMarkers) != nil {
                let innerText = String(lineText[contentRange])
                let innerNS = NSRange(contentRange, in: lineText)
                let innerBase = baseOffset + innerNS.location
                // Evita recursión infinita con el mismo marcador en los extremos.
                if innerText.count < lineText.count {
                    scanInline(lineText: innerText, baseOffset: innerBase, storage: storage, style: style)
                    // Reafirma el estilo exterior tras la recursión (el interior ya combinó rasgos).
                    if let reaffirm = nsRange(of: contentRange, in: lineText, base: baseOffset) {
                        switch marker {
                        case "***", "___":
                            let current = storage.attribute(.font, at: reaffirm.location, effectiveRange: nil) as? NSFont ?? baseFont
                            storage.addAttribute(.font, value: fontAdding(traits: [.boldFontMask, .italicFontMask], to: current), range: reaffirm)
                        case "**", "__":
                            let current = storage.attribute(.font, at: reaffirm.location, effectiveRange: nil) as? NSFont ?? baseFont
                            storage.addAttribute(.font, value: fontAdding(traits: .boldFontMask, to: current), range: reaffirm)
                        case "*", "_":
                            let current = storage.attribute(.font, at: reaffirm.location, effectiveRange: nil) as? NSFont ?? baseFont
                            storage.addAttribute(.font, value: fontAdding(traits: .italicFontMask, to: current), range: reaffirm)
                        default:
                            break
                        }
                    }
                }
            }
            return candidateEnd
        }
        return nil
    }

    private static func isEscaped(in text: String, at index: String.Index) -> Bool {
        var backslashes = 0
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if text[cursor] == "\\" { backslashes += 1 } else { break }
        }
        return backslashes % 2 == 1
    }

    // MARK: - Lectura

    public static func readingText(_ source: String, document: MarkdownDocument, style: WritingStyle, forPrint: Bool = false, documentURL: URL? = nil) -> NSAttributedString {
        if let documentURL { DocumentImageAccess.start(for: documentURL) }
        let result = NSMutableAttributedString()
        let color = forPrint ? NSColor.black : style.effectiveTextColor
        let secondary = forPrint ? NSColor.darkGray : style.secondaryTextColor
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []
        var listBuffer: [(kind: MarkdownLine.Kind, content: String, indent: Int)] = []
        var codeBuffer: [String] = []
        var tableBuffer: [MarkdownLine] = []
        var fenceInfo: String?

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
            paragraphBuffer.removeAll()
            guard !joined.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            result.append(renderBlock(content: joined, style: style, color: color, secondary: secondary, forPrint: forPrint, block: .paragraph))
        }

        func flushQuote() {
            guard !quoteBuffer.isEmpty else { return }
            // Agrupa citas separadas por `>` vacías en párrafos distintos.
            var groups: [[String]] = [[]]
            for entry in quoteBuffer {
                if entry.trimmingCharacters(in: .whitespaces).isEmpty {
                    groups.append([])
                } else {
                    groups[groups.count - 1].append(entry)
                }
            }
            quoteBuffer.removeAll()
            for group in groups {
                guard !group.isEmpty else { continue }
                let joined = group.joined(separator: " ")
                guard !joined.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                result.append(renderBlock(content: joined, style: style, color: secondary, secondary: secondary, forPrint: forPrint, block: .quote))
            }
        }

        func flushList() {
            guard !listBuffer.isEmpty else { return }
            for (kind, content, indent) in listBuffer {
                let prefix: String
                switch kind {
                case .orderedList(let number):
                    prefix = "\(number). "
                case .taskList(let checked, let number):
                    let box = checked ? "☑ " : "☐ "
                    if let number {
                        prefix = "\(number). " + box
                    } else {
                        prefix = box
                    }
                default:
                    prefix = "• "
                }
                let display = prefix + content
                result.append(renderBlock(content: display, style: style, color: color, secondary: secondary, forPrint: forPrint, block: .listItem(indent: indent, task: isTask(kind))))
            }
            listBuffer.removeAll()
        }

        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            let joined = codeBuffer.joined(separator: "\n")
            codeBuffer.removeAll()
            if fenceInfo?.lowercased() == "diagram",
               let diagram = renderDiagram(source: joined, style: style, forPrint: forPrint) {
                result.append(diagram)
            } else {
                result.append(renderCodeBlock(content: joined, style: style, forPrint: forPrint))
            }
        }

        func flushTable() {
            guard !tableBuffer.isEmpty else { return }
            result.append(renderTable(tableBuffer, style: style, color: color, secondary: secondary, forPrint: forPrint))
            tableBuffer.removeAll()
        }

        func flushAll() {
            flushParagraph(); flushQuote(); flushList(); flushCode(); flushTable()
        }

        func isTask(_ kind: MarkdownLine.Kind) -> Bool {
            if case .taskList = kind { return true }
            return false
        }

        for line in document.lines {
            if case .text = line.kind,
               let documentURL, let image = MarkdownImage(line: line.content),
               let url = image.fileURL(relativeTo: documentURL),
               let data = try? Data(contentsOf: url), let bitmap = NSImage(data: data), bitmap.size.width > 0, bitmap.size.height > 0 {
                flushAll()
                let attachment = NSTextAttachment()
                attachment.image = bitmap
                let width = min(CGFloat(image.width), forPrint ? 480 : 680)
                attachment.bounds = NSRect(x: 0, y: 0, width: width, height: width * bitmap.size.height / bitmap.size.width)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = switch image.alignment {
                case .left: .left
                case .center: .center
                case .right: .right
                }
                result.append(NSAttributedString(attachment: attachment))
                result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: result.length - 1, length: 1))
                result.append(NSAttributedString(string: "\n"))
                continue
            }
            if case .tableRow(let header) = line.kind, header { flushTable() }
            switch line.kind {
            case .fence:
                flushAll()
                // Las vallas alternan apertura y cierre; la apertura guarda su info string.
                fenceInfo = fenceInfo == nil ? line.content.trimmingCharacters(in: .whitespaces) : nil
                continue
            case .hidden:
                flushAll()
                continue
            case .code:
                flushParagraph(); flushQuote(); flushList(); flushTable()
                codeBuffer.append(line.content)
                continue
            case .tableRow, .tableDelimiter:
                flushParagraph(); flushQuote(); flushList(); flushCode()
                tableBuffer.append(line)
                continue
            case .heading, .rule:
                flushAll()
            case .quote:
                flushParagraph(); flushList(); flushCode(); flushTable()
            case .list, .orderedList, .taskList:
                flushParagraph(); flushQuote(); flushCode(); flushTable()
            case .text:
                flushQuote(); flushList(); flushCode(); flushTable()
            }
            switch line.kind {
            case .heading(let level):
                let title = line.content.isEmpty ? " " : line.content
                result.append(renderBlock(content: title, style: style, color: color, secondary: secondary, forPrint: forPrint, block: .heading(level: level)))
            case .rule:
                result.append(renderRule(style: style, forPrint: forPrint))
            case .quote:
                quoteBuffer.append(line.content)
            case .list, .orderedList, .taskList:
                let indent = max(0, line.prefixLength - markerWidth(for: line.kind, content: line.content))
                listBuffer.append((line.kind, line.content, indent))
            case .text:
                if line.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    flushParagraph()
                } else {
                    paragraphBuffer.append(line.content.trimmingCharacters(in: .whitespaces))
                }
            case .code, .fence, .hidden, .tableRow, .tableDelimiter:
                break
            }
        }
        flushAll()
        // Garantiza al menos un salto final sin acumular líneas vacías por bloques vacíos.
        if result.length == 0 {
            result.append(NSAttributedString(string: "\n", attributes: style.attributes))
        }
        return result
    }

    private static func markerWidth(for kind: MarkdownLine.Kind, content: String) -> Int {
        switch kind {
        case .list: return 2
        case .orderedList(let number): return "\(number)".count + 2
        case .taskList(_, let number):
            if let number { return "\(number)".count + 6 }
            return 6
        default: return 0
        }
    }

    private enum ReadingBlock {
        case paragraph
        case heading(level: Int)
        case quote
        case listItem(indent: Int, task: Bool)
    }

    private static func renderBlock(content: String, style: WritingStyle, color: NSColor, secondary: NSColor, forPrint: Bool, block: ReadingBlock) -> NSAttributedString {
        let output: NSMutableAttributedString
        if let parsed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            output = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        } else {
            output = NSMutableAttributedString(string: content)
        }
        output.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: 0, length: output.length)
        output.addAttributes(style.attributes, range: range)
        output.addAttribute(.foregroundColor, value: color, range: range)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.spacing
        paragraph.paragraphSpacing = style.paragraph
        paragraph.alignment = style.textAlignment
        switch block {
        case .heading(let level):
            let headingFont = style.headingFont(level: level)
            output.addAttribute(.font, value: headingFont, range: range)
            paragraph.headerLevel = level
            paragraph.paragraphSpacingBefore = 12
            paragraph.paragraphSpacing = 6
            // Reaplica cursiva/código/tachado con el tamaño del título (la base ya es seminegrita).
            output.enumerateAttribute(.inlinePresentationIntent, in: range) { value, run, _ in
                guard let intent = intent(from: value) else { return }
                if intent.contains(.emphasized) {
                    let current = output.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont ?? headingFont
                    output.addAttribute(.font, value: fontAdding(traits: .italicFontMask, to: current), range: run)
                }
                if intent.contains(.code) {
                    output.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: headingFont.pointSize - 1, weight: .regular), range: run)
                    output.addAttribute(.backgroundColor, value: forPrint ? NSColor(white: 0.95, alpha: 1) : style.faintFillColor, range: run)
                }
                if intent.contains(.strikethrough) {
                    output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                }
            }
        case .quote:
            paragraph.headIndent = 22
            paragraph.firstLineHeadIndent = 22
            paragraph.paragraphSpacing = max(style.paragraph, 4)
            output.addAttribute(.foregroundColor, value: secondary, range: range)
            // Barra lateral tenue `│ ` delante del texto citado.
            output.insert(NSAttributedString(string: "│ ", attributes: [
                .font: style.font,
                .foregroundColor: style.tertiaryTextColor,
            ]), at: 0)
            let full = NSRange(location: 0, length: output.length)
            output.addAttribute(.paragraphStyle, value: paragraph, range: full)
            fixInline(output: output, style: style, forPrint: forPrint, range: full)
            sanitizeLinks(in: output, style: style, forPrint: forPrint, range: full)
            return output
        case .listItem(let indent, _):
            let extra = min(48, indent * 4)
            paragraph.headIndent = 20 + CGFloat(extra)
            paragraph.firstLineHeadIndent = 20 + CGFloat(extra)
            paragraph.paragraphSpacing = max(style.paragraph, 2)
            output.addAttribute(.paragraphStyle, value: paragraph, range: range)
            fixInline(output: output, style: style, forPrint: forPrint, range: range)
            sanitizeLinks(in: output, style: style, forPrint: forPrint, range: range)
            return output
        case .paragraph:
            output.addAttribute(.paragraphStyle, value: paragraph, range: range)
            fixInline(output: output, style: style, forPrint: forPrint, range: range)
            sanitizeLinks(in: output, style: style, forPrint: forPrint, range: range)
            return output
        }
        output.addAttribute(.paragraphStyle, value: paragraph, range: range)
        // En títulos no se llama a fixInline genérico (usa tamaño de título); enlaces sí.
        sanitizeLinks(in: output, style: style, forPrint: forPrint, range: range)
        return output
    }

    private static func renderCodeBlock(content: String, style: WritingStyle, forPrint: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: content + "\n")
        let range = NSRange(location: 0, length: output.length)
        output.addAttributes(style.attributes, range: range)
        output.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: style.size - 1, weight: .regular), range: range)
        output.addAttribute(.foregroundColor, value: forPrint ? NSColor.darkGray : style.secondaryTextColor, range: range)
        output.addAttribute(.backgroundColor, value: forPrint ? NSColor(white: 0.95, alpha: 1) : style.faintFillColor, range: range)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.spacing
        paragraph.paragraphSpacing = max(style.paragraph, 4)
        paragraph.alignment = style.textAlignment
        paragraph.headIndent = 12
        paragraph.firstLineHeadIndent = 12
        output.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return output
    }

    /// Bloque ```diagram como imagen; `nil` si no se puede interpretar y debe verse como código.
    private static func renderDiagram(source: String, style: WritingStyle, forPrint: Bool) -> NSAttributedString? {
        guard let graph = try? DiagramParser.parse(source) else { return nil }
        let palette = forPrint ? DiagramRenderer.Palette.print : DiagramRenderer.Palette(
            text: style.effectiveTextColor, secondary: style.secondaryTextColor, fill: style.faintFillColor,
            stroke: style.tertiaryTextColor, background: style.effectiveBackgroundColor)
        let font = NSFont.systemFont(ofSize: max(10, style.size - 3))
        guard let image = DiagramRenderer.image(for: graph, font: font, palette: palette) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Cabe en el ancho de lectura y como mucho en 3× ese ancho de alto; al imprimir, en una página.
        let maxWidth: CGFloat = forPrint ? 480 : 680
        let maxHeight: CGFloat = forPrint ? 620 : maxWidth * 3
        let scale = min(1, maxWidth / image.size.width, maxHeight / image.size.height)
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = max(style.paragraph, 8)
        paragraph.paragraphSpacingBefore = 4
        let output = NSMutableAttributedString(attachment: attachment)
        output.append(NSAttributedString(string: "\n"))
        output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
        return output
    }

    private static func renderTable(_ rows: [MarkdownLine], style: WritingStyle, color: NSColor, secondary: NSColor, forPrint: Bool) -> NSAttributedString {
        let alignments = rows.first { $0.kind == .tableDelimiter }.flatMap { MarkdownTable.alignments(delimiter: $0.content) } ?? []
        let bodyRows = rows.filter { $0.kind != .tableDelimiter }
        let columns = max(1, alignments.count)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let border = forPrint ? NSColor.gray : style.tertiaryTextColor
        let headerFill = forPrint ? NSColor(white: 0.93, alpha: 1) : style.faintFillColor
        let output = NSMutableAttributedString()
        for (rowIndex, row) in bodyRows.enumerated() {
            let header: Bool = if case .tableRow(true) = row.kind { true } else { false }
            // GFM: faltan celdas → vacías; sobran → se descartan.
            var cells = MarkdownTable.cells(in: row.content)
            cells = Array(cells.prefix(columns)) + Array(repeating: "", count: max(0, columns - cells.count))
            for (column, cell) in cells.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                if header { block.backgroundColor = headerFill }
                let content = renderBlock(content: cell.isEmpty ? " " : cell, style: style, color: color, secondary: secondary, forPrint: forPrint, block: .paragraph)
                let cellText = NSMutableAttributedString(attributedString: content)
                let range = NSRange(location: 0, length: cellText.length)
                if header {
                    cellText.enumerateAttribute(.font, in: range) { value, run, _ in
                        let font = value as? NSFont ?? style.font
                        cellText.addAttribute(.font, value: fontAdding(traits: .boldFontMask, to: font), range: run)
                    }
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = style.spacing
                paragraph.textBlocks = [block]
                paragraph.alignment = switch alignments.indices.contains(column) ? alignments[column] : .natural {
                case .natural, .left: .left
                case .center: .center
                case .right: .right
                }
                cellText.addAttribute(.paragraphStyle, value: paragraph, range: range)
                output.append(cellText)
            }
        }
        // Separación tras la tabla sin heredar sus bloques.
        let spacer = NSMutableParagraphStyle()
        spacer.paragraphSpacing = max(style.paragraph, 4)
        output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: spacer]))
        return output
    }

    private static func renderRule(style: WritingStyle, forPrint: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "────────────\n")
        let range = NSRange(location: 0, length: output.length)
        output.addAttributes(style.attributes, range: range)
        output.addAttribute(.foregroundColor, value: forPrint ? NSColor.darkGray : style.tertiaryTextColor, range: range)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = style.spacing
        paragraph.paragraphSpacing = 8
        paragraph.paragraphSpacingBefore = 8
        output.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return output
    }

    private static func intent(from value: Any?) -> InlinePresentationIntent? {
        if let direct = value as? InlinePresentationIntent { return direct }
        if let number = value as? NSNumber {
            return InlinePresentationIntent(rawValue: number.uintValue)
        }
        return nil
    }

    private static func fixInline(output: NSMutableAttributedString, style: WritingStyle, forPrint: Bool, range: NSRange) {
        output.enumerateAttribute(.inlinePresentationIntent, in: range) { value, run, _ in
            guard let intent = intent(from: value) else { return }
            var font = output.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont ?? style.font
            var traits = NSFontTraitMask()
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                font = fontAdding(traits: traits, to: font)
            }
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: style.size - 1, weight: .regular)
                output.addAttribute(.backgroundColor, value: forPrint ? NSColor(white: 0.95, alpha: 1) : style.faintFillColor, range: run)
            }
            output.addAttribute(.font, value: font, range: run)
            if intent.contains(.strikethrough) {
                output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run)
            }
        }
    }

    private static func sanitizeLinks(in output: NSMutableAttributedString, style: WritingStyle, forPrint: Bool, range: NSRange) {
        output.enumerateAttribute(.link, in: range) { value, run, _ in
            guard let url = value as? URL else { return }
            if !["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                output.removeAttribute(.link, range: run)
            } else {
                output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                if !forPrint {
                    output.addAttribute(.foregroundColor, value: style.effectiveAccentColor, range: run)
                }
            }
        }
    }
}
