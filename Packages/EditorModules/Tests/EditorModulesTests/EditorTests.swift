import XCTest
import AppKit
import SwiftUI
@testable import EditorCore
@testable import DocumentKit
@testable import EditorEngine
import DesignSystem
import PDFKit
@testable import ExportFeature

final class EditorTests: XCTestCase {
    @MainActor func testDocumentSwitchLocksEditing() throws {
        let session = EditorSession()
        let editor = NativeTextEditor(text: .constant("Antes"), session: session, isOpeningDocument: true)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(session.textView)
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.isSelectable)
        host.rootView = NativeTextEditor(text: .constant("Después"), session: session)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        window.orderOut(nil)
    }

    func testUTF8RoundTripAndInvalidData() throws {
        for text in ["", "Español, 日本語, 👩🏽‍💻\r\n", String(repeating: "á", count: 100_000), String(repeating: "文", count: 500_000), String(repeating: "x", count: 1_000_000)] {
            XCTAssertEqual(try UTF8Document.decode(UTF8Document.encode(text)), text)
        }
        XCTAssertThrowsError(try UTF8Document.decode(Data([0xFF, 0xFE, 0x80])))
    }

    func testUTF16RangesAndOutline() {
        let text = "🐈\r\n## Cazador\r\nTexto\n```\n# código\n```\n# Fin"
        let headings = DocumentOutline.headings(in: text)
        XCTAssertEqual(headings.map(\.title), ["Cazador", "Fin"])
        XCTAssertEqual(headings.first?.offset, 4)
        XCTAssertNil(TextRange(location: -1, length: 1).validated(in: text))
        XCTAssertNil(TextRange(location: 1, length: 0).validated(in: text))
        XCTAssertNil(TextRange(location: 0, length: Int.max).validated(in: text))
        XCTAssertNotNil(TextRange(location: 0, length: 2).validated(in: text))
    }

    @MainActor func testNativeCommandsUndoAndRedo() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = true
        window.contentView = view
        window.makeFirstResponder(view)
        let session = EditorSession()
        session.textView = view
        view.undoManager?.groupsByEvent = false
        view.undoManager?.beginUndoGrouping()
        session.send(.insertText("Hola 🐈"))
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        session.send(.selectRange(TextRange(location: 5, length: 2)))
        view.undoManager?.beginUndoGrouping()
        session.send(.replaceSelection("mundo"))
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        XCTAssertEqual(view.string, "Hola mundo")
        session.send(.undo)
        XCTAssertEqual(view.string, "Hola 🐈")
        session.send(.redo)
        XCTAssertEqual(view.string, "Hola mundo")
        session.send(.selectAll)
        view.undoManager?.beginUndoGrouping()
        session.send(.toggleBold)
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.string, "**Hola mundo**")
        session.stop()
        window.orderOut(nil)
    }
}

final class MarkdownExperienceTests: XCTestCase {
    @MainActor func testImageBlockPreservesMarkdownAndReflowsText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assets = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: assets.appendingPathComponent("sample.png"))
        let documentURL = folder.appendingPathComponent("note.md")
        let image = MarkdownImage(alt: "Muestra", path: "images/sample.png", width: 240, alignment: .center)
        XCTAssertEqual(MarkdownImage(line: image.markdown), image)
        XCTAssertNil(MarkdownImage(line: "![x](../outside.png)"))
        let text = "Antes\n\(image.markdown)\nDespués"
        let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.documentURL = documentURL
        view.string = text
        view.applyAnalysis(MarkdownDocument(text))
        XCTAssertEqual(view.string, text)
        let range = (text as NSString).range(of: image.markdown)
        let paragraph = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(paragraph.minimumLineHeight, 120)
        let tallCaret = NSRect(x: 28, y: 20, width: 1, height: paragraph.minimumLineHeight)
        XCTAssertLessThan(view.insertionPointRect(tallCaret, at: range.location).height, 40)
        XCTAssertEqual(view.insertionPointRect(tallCaret, at: 0), tallCaret)
        view.setFrameSize(NSSize(width: 180, height: 800))
        let resized = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertLessThan(resized.minimumLineHeight, paragraph.minimumLineHeight)
        view.setFrameSize(NSSize(width: 600, height: 800))
        let session = EditorSession()
        session.textView = view
        session.send(.beginPreview(TextRange(location: range.location, length: range.length)))
        session.send(.showPreview(MarkdownImage(alt: image.alt, path: image.path, width: 400, alignment: image.alignment).markdown))
        let previewHeight = (view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0
        XCTAssertGreaterThan(previewHeight, paragraph.minimumLineHeight)
        session.send(.cancelPreview)
        XCTAssertEqual(view.string, text)
        let reading = MarkdownAppearance.readingText(text, document: MarkdownDocument(text), style: WritingStyle(), documentURL: documentURL)
        XCTAssertTrue(reading.string.contains("\u{FFFC}"))
        let standard = "![Muestra](images/sample.png)\n"
        view.string = standard
        view.applyAnalysis(MarkdownDocument(standard))
        XCTAssertGreaterThan((view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0, 50)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = view
        let imagePoint = NSPoint(x: 100, y: 100)
        XCTAssertNotNil(view.imageRange(at: imagePoint))
        let clip = scroll.contentView
        let visiblePoint = clip.convert(imagePoint, from: view)
        let normalized = CGPoint(
            x: (visiblePoint.x - clip.bounds.minX) / clip.bounds.width,
            y: clip.isFlipped
                ? (visiblePoint.y - clip.bounds.minY) / clip.bounds.height
                : (clip.bounds.maxY - visiblePoint.y) / clip.bounds.height
        )
        session.textView = view
        XCTAssertEqual(session.imageRange(atNormalizedPoint: normalized), NSRange(location: 0, length: (standard as NSString).length - 1))
    }

    @MainActor func testImageGeometryStaysInTextKit2() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("a.png"))
        let image = MarkdownImage(alt: "A", path: "a.png", width: 300, alignment: .right).markdown
        let text = "# Título\n\nUn párrafo largo que se envuelve en varias líneas dentro del contenedor del editor para mover la imagen.\n" + image + "\nFin\n\n" + image + "\n"
        let view = WritingTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 28, height: 24)
        view.documentURL = folder.appendingPathComponent("nota.md")
        view.string = text
        view.applyAnalysis(MarkdownDocument(text))
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        var previousBottom = -CGFloat.infinity
        for (index, location) in [(0, (text as NSString).range(of: image).location),
                                  (1, (text as NSString).range(of: image, options: .backwards).location)] {
            let rect = try XCTUnwrap(view.imageRect(at: index))
            let start = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: location))
            let line = try XCTUnwrap(layout.textLayoutFragment(for: start)).layoutFragmentFrame
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            // La imagen ocupa el hueco que TextKit 2 reservó para su línea.
            XCTAssertGreaterThanOrEqual(rect.minY, line.minY)
            XCTAssertLessThanOrEqual(rect.maxY, line.maxY)
            XCTAssertGreaterThan(rect.minY, previousBottom)
            XCTAssertEqual(rect.maxX, view.textContainerOrigin.x + (view.textContainer?.size.width ?? 0), accuracy: 0.5)
            previousBottom = rect.maxY
        }
        XCTAssertNotNil(view.imageRange(at: NSPoint(x: 500, y: 200)))
        XCTAssertNotNil(view.textLayoutManager, "Las imágenes no deben pasar el editor a TextKit 1.")
    }

    func testFencesUnicodeAndStatistics() {
        let source = "# Café 🐈\r\n\r\n~~~swift\r\n# No es título\r\n```\r\n~~~\r\n## Fin\r\n"
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.headings.map(\.title), ["Café 🐈", "Fin"])
        XCTAssertEqual(document.headings.last?.offset, (source as NSString).range(of: "## Fin").location)
        XCTAssertEqual(document.lines.map(\.kind).filter { if case .fence = $0 { true } else { false } }, [.fence(info: "swift"), .fence(info: "")])
        XCTAssertEqual(document.statistics.characters, source.count)
        XCTAssertGreaterThan(document.statistics.words, 0)
        XCTAssertEqual(MarkdownDocument("").statistics.words, 0)
        XCTAssertEqual(MarkdownDocument("uno dos\n\ntres").statistics.paragraphs, 2)
    }

    @MainActor func testReadingAndDecorationPreserveSource() {
        let source = "# Título\n\n**Negrita** y *cursiva* con 🐈.\n- Elemento\n> Cita\n~~~\n**literal**\n~~~\n[Seguro](https://example.com) [No](file:///tmp/secret)"
        let document = MarkdownDocument(source)
        let storage = NSMutableAttributedString(string: source)
        let style = WritingStyle()
        MarkdownAppearance.decorate(storage, document: document, style: style)
        XCTAssertEqual(storage.string, source)
        let headingFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, 18)
        let boldRange = (source as NSString).range(of: "Negrita")
        let bold = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        let reading = MarkdownAppearance.readingText(source, document: document, style: style)
        XCTAssertTrue(reading.string.hasPrefix("Título\n"))
        XCTAssertTrue(reading.string.contains("Negrita y cursiva con 🐈."))
        XCTAssertTrue(reading.string.contains("• Elemento"))
        XCTAssertTrue(reading.string.contains("**literal**"))
        XCTAssertFalse(reading.string.contains("~~~"))
        let noLink = (reading.string as NSString).range(of: "No")
        XCTAssertNil(reading.attribute(.link, at: noLink.location, effectiveRange: nil))
        let safeLink = (reading.string as NSString).range(of: "Seguro")
        XCTAssertNotNil(reading.attribute(.link, at: safeLink.location, effectiveRange: nil))
        let renderedBold = reading.attribute(.font, at: (reading.string as NSString).range(of: "Negrita").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(renderedBold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, "\(reading.attributes(at: (reading.string as NSString).range(of: "Negrita").location, effectiveRange: nil))")
    }

    @MainActor func testFormatTogglePreservesEmojiAndNativeUndo() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = WritingTextView(usingTextLayoutManager: true)
        window.contentView = view
        view.allowsUndo = true
        view.isRichText = false
        view.string = "Café 👩🏽‍💻"
        let session = EditorSession()
        session.textView = view
        view.undoManager?.groupsByEvent = false
        session.send(.selectAll)
        view.undoManager?.beginUndoGrouping()
        session.send(.toggleBold)
        view.undoManager?.endUndoGrouping()
        let formatted = view.string
        view.applyAnalysis(MarkdownDocument(formatted))
        XCTAssertEqual(view.string, "**Café 👩🏽‍💻**")
        view.undoManager?.beginUndoGrouping()
        session.send(.toggleBold)
        view.undoManager?.endUndoGrouping()
        XCTAssertEqual(view.string, "Café 👩🏽‍💻")
        session.send(.undo)
        XCTAssertEqual(view.string, formatted)
        session.readingMode = true
        session.send(.insertText("No debe escribirse"))
        XCTAssertEqual(view.string, formatted)
        session.stop()
    }

    @MainActor func testWritingStyleFamilyAppliesToBodyAndHeadings() {
        let expectedFragment = [
            "serif": "Georgia",
            "palatino": "Palatino",
            "helvetica": "Helvetica",
            "verdana": "Verdana",
            "mono": "Mono",
        ]
        XCTAssertEqual(Set(WritingStyle.availableFamilies.map(\.id)),
                       ["system", "serif", "palatino", "helvetica", "verdana", "mono"])
        for option in WritingStyle.availableFamilies {
            let style = WritingStyle(size: 18, family: option.id, spacing: 6)
            let source = "# Título\n\nCuerpo con texto."
            let document = MarkdownDocument(source)
            let storage = NSMutableAttributedString(string: source)
            MarkdownAppearance.decorate(storage, document: document, style: style)
            let heading = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let bodyRange = (source as NSString).range(of: "Cuerpo")
            let body = storage.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
            if let fragment = expectedFragment[option.id] {
                XCTAssertTrue(body?.fontName.contains(fragment) == true, "\(option.id): \(body?.fontName ?? "?")")
                XCTAssertTrue(heading?.fontName.contains(fragment) == true, "\(option.id): \(heading?.fontName ?? "?")")
                XCTAssertGreaterThan(heading?.pointSize ?? 0, body?.pointSize ?? 0)
            } else {
                XCTAssertNotNil(body)
                XCTAssertGreaterThan(heading?.pointSize ?? 0, 18)
            }
            let reading = MarkdownAppearance.readingText(source, document: document, style: style)
            let readingHeading = reading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            if let fragment = expectedFragment[option.id] {
                XCTAssertTrue(readingHeading?.fontName.contains(fragment) == true, "lectura \(option.id): \(readingHeading?.fontName ?? "?")")
            }
        }
    }

    @MainActor func testWritingStyleParagraphSpacing() {
        let style = WritingStyle(size: 18, family: "system", spacing: 6, paragraph: 8)
        let paragraphStyle = style.attributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraphStyle?.paragraphSpacing, 8)
        XCTAssertEqual(style.paragraph, 8)
        XCTAssertEqual(WritingStyle().paragraph, 0)
    }
}


final class ExportTests: XCTestCase {
    @MainActor func testMultipagePDFContainsFirstAndLastParagraph() throws {
        _ = NSApplication.shared
        let text = (1...50).map { "## Sección \($0)\n\nUna frase con **negrita** y café.\n\n" }.joined()
        let operation = PrintDocument.makeOperation(text: text, title: "Prueba de exportación")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EditorFinal-export-test.pdf")
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        XCTAssertTrue(operation.run())
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Sección 1") == true)
        XCTAssertTrue(document.string?.contains("Sección 50") == true)
        XCTAssertTrue(document.string?.contains("café") == true)
        XCTAssertFalse(document.string?.contains("**negrita**") == true)
        for index in 0..<document.pageCount {
            let lastLine = document.page(at: index)?.string?.split(separator: "\n").last
            XCTAssertFalse(lastLine?.hasPrefix("Sección ") == true, "Título aislado al final de la página \(index + 1)")
        }
    }

    @MainActor func testFileExportFormatsKeepContent() throws {
        let text = "Una frase con **negrita** y café."
        let plain = try XCTUnwrap(DocumentExport.data(format: .plainText, text: text, title: "Notas", richText: nil))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), text)

        XCTAssertNil(try DocumentExport.data(format: .richText, text: text, title: "Notas", richText: nil))
        let rtf = try XCTUnwrap(DocumentExport.data(format: .richText, text: text, title: "Notas", richText: NSAttributedString(string: text)))
        let readRTF = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(readRTF.string, text)

        let word = try XCTUnwrap(DocumentExport.data(format: .word, text: text, title: "Notas", richText: nil))
        let readWord = try NSAttributedString(data: word, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(readWord.string.contains("Notas"))
        XCTAssertTrue(readWord.string.contains("café"))
        XCTAssertFalse(readWord.string.contains("**negrita**"))
    }
}

final class MarkdownRenderingImprovementsTests: XCTestCase {
    func testClosedHeadingsStripSuffix() {
        let source = "## Título ##\n# Solo #\n####### No\n"
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.headings.map(\.title), ["Título", "Solo"])
        XCTAssertEqual(document.headings.map(\.level), [2, 1])
        XCTAssertGreaterThan(document.lines[0].trailingLength, 0)
        XCTAssertGreaterThan(document.lines[1].trailingLength, 0)
        XCTAssertEqual(document.lines[2].kind, .text)
    }

    func testSetextHeadings() {
        let source = "Título\n===\n\nSub\n---\n"
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.headings.map(\.title), ["Título", "Sub"])
        XCTAssertEqual(document.headings.map(\.level), [1, 2])
        XCTAssertEqual(document.lines.filter { $0.kind == .hidden }.count, 2)
    }

    func testQuotesWithoutSpaceAndNested() {
        let source = ">Cita\n>> Anidada\n> \n>\n"
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.lines.filter { $0.kind == .quote }.count, 4)
        XCTAssertEqual(document.lines[0].content, "Cita")
        XCTAssertEqual(document.lines[1].content, "Anidada")
    }

    func testOrderedAndTaskLists() {
        let source = "1. Uno\n2) Dos\n10. Diez\n"
        let document = MarkdownDocument(source)
        XCTAssertEqual(document.lines[0].kind, .orderedList(number: 1))
        XCTAssertEqual(document.lines[1].kind, .orderedList(number: 2))
        XCTAssertEqual(document.lines[2].kind, .orderedList(number: 10))
        let tasks = MarkdownDocument("- [ ] Todo\n- [x] Hecho\n- [X] Hecho2\n1. [ ] Ordenada\n")
        XCTAssertEqual(tasks.lines[0].kind, .taskList(checked: false, number: nil))
        XCTAssertEqual(tasks.lines[1].kind, .taskList(checked: true, number: nil))
        XCTAssertEqual(tasks.lines[2].kind, .taskList(checked: true, number: nil))
        XCTAssertEqual(tasks.lines[3].kind, .taskList(checked: false, number: 1))
        XCTAssertEqual(tasks.lines[0].content, "Todo")
    }

    func testThematicBreaksWithSpaces() {
        let source = "---\n***\n___\n* * *\n- - -\n"
        let document = MarkdownDocument(source)
        XCTAssertTrue(document.lines.allSatisfy { $0.kind == .rule })
    }

    @MainActor func testInlineDecorationVariants() {
        let source = "**a** __b__ *c* _d_ ***e*** ___f___ ~~g~~ `h` ``i`` [t](https://example.com) <https://example.com> \\*j\\* foo_bar_baz"
        let document = MarkdownDocument(source)
        let storage = NSMutableAttributedString(string: source)
        MarkdownAppearance.decorate(storage, document: document, style: WritingStyle())
        XCTAssertEqual(storage.string, source)
        func traits(of substring: String) -> NSFontTraitMask {
            let range = (source as NSString).range(of: substring)
            XCTAssertNotEqual(range.location, NSNotFound, substring)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            return font.map { NSFontManager.shared.traits(of: $0) } ?? []
        }
        XCTAssertTrue(traits(of: "a").contains(.boldFontMask))
        XCTAssertTrue(traits(of: "__b__").contains(.boldFontMask))
        XCTAssertTrue(traits(of: "c").contains(.italicFontMask))
        XCTAssertTrue(traits(of: "_d_").contains(.italicFontMask))
        let both = traits(of: "***e***")
        XCTAssertTrue(both.contains(.boldFontMask) && both.contains(.italicFontMask))
        let strikeRange = (source as NSString).range(of: "g")
        XCTAssertNotNil(storage.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil))
        let codeRange = (source as NSString).range(of: "h")
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil))
        let linkRange = (source as NSString).range(of: "t](")
        // El texto del enlace va en acento y subrayado; la URL atenuada.
        let labelRange = (source as NSString).range(of: "[t]")
        let labelColor = storage.attribute(.foregroundColor, at: labelRange.location + 1, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(labelColor)
        _ = linkRange
        // `_` dentro de palabra no es énfasis.
        let barRange = (source as NSString).range(of: "bar")
        XCTAssertFalse(traits(of: "bar").contains(.italicFontMask), "foo_bar_baz no debe cursivar: \(barRange)")
        // Escape: `j` no debe ir en cursiva/negrita.
        XCTAssertFalse(traits(of: "j").contains(.italicFontMask))
        XCTAssertFalse(traits(of: "j").contains(.boldFontMask))
    }

    @MainActor func testReadingJoinsSoftBreaksAndLists() {
        let style = WritingStyle()
        var document = MarkdownDocument("Línea uno\nLínea dos\n\nNuevo párrafo\n")
        var reading = MarkdownAppearance.readingText("", document: document, style: style)
        XCTAssertTrue(reading.string.contains("Línea uno Línea dos\n"))
        XCTAssertTrue(reading.string.contains("Nuevo párrafo\n"))
        document = MarkdownDocument("1. Uno\n2. Dos\n\n- [ ] Todo\n- [x] Hecho\n")
        reading = MarkdownAppearance.readingText("", document: document, style: style)
        XCTAssertTrue(reading.string.contains("1. Uno"))
        XCTAssertTrue(reading.string.contains("2. Dos"))
        XCTAssertTrue(reading.string.contains("☐ Todo"))
        XCTAssertTrue(reading.string.contains("☑ Hecho"))
        document = MarkdownDocument("> Cita uno\n> Cita dos\n")
        reading = MarkdownAppearance.readingText("", document: document, style: style)
        XCTAssertTrue(reading.string.contains("│"))
        XCTAssertTrue(reading.string.contains("Cita uno Cita dos"))
        document = MarkdownDocument("## Título ##\n")
        reading = MarkdownAppearance.readingText("", document: document, style: style)
        XCTAssertTrue(reading.string.hasPrefix("Título\n"))
        XCTAssertFalse(reading.string.contains("##"))
        document = MarkdownDocument("Título\n===\n")
        reading = MarkdownAppearance.readingText("", document: document, style: style)
        XCTAssertTrue(reading.string.hasPrefix("Título\n"))
    }

    @MainActor func testCuadernoSampleRendersWithoutMarkerGaps() {
        let style = WritingStyle(size: 19, family: "ABC Areal", spacing: 6)
        let source = "A veces basta cambiar *rápido* por *deprisa*. Otras veces conviene dejar la frase.\n\nEste cuaderno admite **negritas**, *cursivas*, `código` y [enlaces](https://es.wikipedia.org/wiki/Felis_catus). La vista de lectura los presenta sin los marcadores.\n"
        let document = MarkdownDocument(source)
        let reading = MarkdownAppearance.readingText(source, document: document, style: style)
        XCTAssertFalse(reading.string.contains("  "), "dobles espacios en: \(reading.string.debugDescription)")
        XCTAssertTrue(reading.string.contains("negritas,"))
        XCTAssertTrue(reading.string.contains("cursivas,"))
        XCTAssertTrue(reading.string.contains("enlaces."))
        let linkRange = (reading.string as NSString).range(of: "enlaces")
        XCTAssertNotNil(reading.attribute(.link, at: linkRange.location, effectiveRange: nil))
        let codeRange = (reading.string as NSString).range(of: "código")
        XCTAssertNotNil(reading.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil))
    }

    @MainActor func testReadingCombinedEmphasisAndLinks() {        let style = WritingStyle()
        var document = MarkdownDocument("***ambas***\n")
        var reading = MarkdownAppearance.readingText("", document: document, style: style)
        let range = (reading.string as NSString).range(of: "ambas")
        let font = reading.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        XCTAssertTrue(traits.contains(.boldFontMask) && traits.contains(.italicFontMask), "\(String(describing: font))")
        document = MarkdownDocument("[Seguro](https://example.com)\n")
        reading = MarkdownAppearance.readingText("", document: document, style: style)
        let linkRange = (reading.string as NSString).range(of: "Seguro")
        XCTAssertNotNil(reading.attribute(.link, at: linkRange.location, effectiveRange: nil))
        XCTAssertNotNil(reading.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil))
        document = MarkdownDocument("---\n")
        reading = MarkdownAppearance.readingText("", document: document, style: style)
        XCTAssertTrue(reading.string.contains("────────────"))
    }
}
