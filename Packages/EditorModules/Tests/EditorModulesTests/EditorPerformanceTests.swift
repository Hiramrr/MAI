import XCTest
import AppKit
import DesignSystem
import DocumentKit
@testable import EditorCore
@testable import EditorEngine

final class EditorPerformanceTests: XCTestCase {
    @MainActor func testIncrementalDecorationMatchesFullFormatting() {
        let view = WritingTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.string = "# Inicio\n\n**Café** y 👩🏽‍💻.\n\nTítulo\n===\n\n```\n**literal**\n```\n\n*Fin*\n"
        func check() {
            let document = MarkdownDocument(view.string)
            view.applyAnalysis(document)
            let expected = NSMutableAttributedString(string: view.string)
            MarkdownAppearance.decorate(expected, document: document, style: view.style)
            XCTAssertTrue(view.textStorage!.isEqual(to: expected), "\(view.string)")
        }
        func replace(_ old: String, with new: String) {
            let range = (view.string as NSString).range(of: old)
            XCTAssertNotEqual(range.location, NSNotFound)
            view.textStorage!.replaceCharacters(in: range, with: new)
        }
        check()
        // Cambios separados antes de la siguiente pausa, con desplazamientos UTF-16.
        replace("Café", with: "Niñez 日本語")
        replace("# Inicio", with: "# 🐈 Inicio")
        replace("*Fin*", with: "~~Fin~~")
        check()
        replace("===", with: "texto")
        check()
        replace("```\n**literal**", with: "**literal**")
        check()
        replace("```", with: "")
        check()
        replace("\n\n", with: "\n")
        check()
        replace("~~Fin~~", with: "~~Fin~~") // Mismo texto con atributos heredados nuevos.
        check()
        view.style = WritingStyle(size: 24, family: "serif", syntax: false)
        check()
        view.style = WritingStyle()
        check()
        view.string = ""
        check()
        view.string = "# Nuevo\r\n\r\n**Español** 日本語\r\n"
        check()
    }

    @MainActor func testNativeCopyKeepsTextAndUTF16Offsets() {
        let view = NSTextView(usingTextLayoutManager: true)
        view.string = "Café 👩🏽‍💻 日本語\r\nfin"
        let lone = String(utf16CodeUnits: [0x61, 0xD83D, 0x62], count: 3)
        view.textStorage?.append(NSAttributedString(string: lone))
        let bridged = view.string
        let copy = bridged.nativeCopy()
        XCTAssertTrue(copy.isContiguousUTF8)
        XCTAssertEqual(copy.utf16.count, (bridged as NSString).length)
        XCTAssertEqual(copy, bridged)
        XCTAssertEqual("".nativeCopy(), "")
        XCTAssertEqual(copy.nativeCopy(), copy)
    }

    @MainActor func testLibraryListsOnlySupportedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["uno.md", "DOS.TXT", "tres.markdown", ".oculto.md", "foto.png"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("carpeta.md"), withIntermediateDirectories: false)
        let documents = await DocumentLibrary.documents(in: [folder, folder, folder.appendingPathComponent("ausente")])
        XCTAssertEqual(Set(documents.map(\.lastPathComponent)), ["uno.md", "DOS.TXT", "tres.markdown"])
        XCTAssertEqual(documents.count, 3)
    }

    func testRecentDocumentsKeepOrderWithoutDuplicatesOrArchivedFiles() {
        let folder = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        let first = folder.appendingPathComponent("one.md")
        let second = folder.appendingPathComponent("two.md")
        let missing = folder.appendingPathComponent("missing.md")
        let ordered = DocumentLibrary.orderedRecents(
            [second, first, second, missing],
            available: [first, second],
            excluding: [first.standardizedFileURL.path]
        )
        XCTAssertEqual(ordered, [second])
    }

    @MainActor func testPlainTextDecoration() {
        let source = String(repeating: "Una frase sencilla sin formato.\n", count: 20_000)
        let document = MarkdownDocument(source)
        let output = NSMutableAttributedString(string: source)
        let start = ContinuousClock.now
        MarkdownAppearance.decorate(output, document: document, style: WritingStyle())
        print("PLAIN DECORATION: \(start.duration(to: .now))")
        XCTAssertNotNil(output.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertNotNil(output.attribute(.font, at: output.length - 1, effectiveRange: nil))
    }

    @MainActor func testLargeDocumentEditing() throws {
        _ = NSApplication.shared
        let clock = ContinuousClock()
        let paragraph = "Texto con **énfasis**, café y 日本語. Una frase para escribir.\n\n"
        for size in [100_000, 500_000, 1_000_000] {
            let source = "# Inicio\n\n" + String(String(repeating: paragraph, count: size / paragraph.count + 1).prefix(size)) + "\n# Fin\n"
            let view = WritingTextView(usingTextLayoutManager: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.isRichText = false
            view.allowsUndo = true
            view.string = source
            let session = EditorSession()
            session.textView = view
            window.makeFirstResponder(view)
            defer { session.stop(); window.orderOut(nil) }

            let start = clock.now
            let analysis = MarkdownDocument(source)
            let analyzed = clock.now
            view.applyAnalysis(analysis)
            let decorated = clock.now
            XCTAssertEqual(analysis.headings.map(\.title), ["Inicio", "Fin"])
            XCTAssertEqual(analysis.statistics.characters, source.count)
            let untouched = NSAttributedString.Key("unchangedHeading")
            view.textStorage?.addAttribute(untouched, value: true, range: NSRange(location: 0, length: 1))

            let range = (source as NSString).range(of: "Una frase", options: [], range: NSRange(location: size / 2, length: (source as NSString).length - size / 2))
            session.send(.selectRange(TextRange(location: range.location, length: range.length)))
            view.undoManager?.groupsByEvent = false
            view.undoManager?.beginUndoGrouping()
            let editing = clock.now
            session.send(.replaceSelection("Una edición 👩🏽‍💻"))
            let edited = clock.now
            view.undoManager?.endUndoGrouping()
            view.breakUndoCoalescing()
            let updated = view.string
            let reanalyzing = clock.now
            let updatedAnalysis = MarkdownDocument(updated)
            let redecorating = clock.now
            view.applyAnalysis(updatedAnalysis)
            let finished = clock.now
            XCTAssertEqual(view.string, updated)
            XCTAssertEqual(view.textStorage?.attribute(untouched, at: 0, effectiveRange: nil) as? Bool, true,
                           "Una edición local no debe volver a formatear el título inicial.")
            XCTAssertEqual(try UTF8Document.decode(UTF8Document.encode(updated)), updated)
            session.send(.undo)
            XCTAssertEqual(view.string, source)
            session.send(.redo)
            XCTAssertEqual(view.string, updated)
            print("PERFORMANCE \(size): analysis=\(start.duration(to: analyzed)) decoration=\(analyzed.duration(to: decorated)) edit=\(editing.duration(to: edited)) reanalysis=\(reanalyzing.duration(to: redecorating)) redecorate=\(redecorating.duration(to: finished))")
        }
    }
}
