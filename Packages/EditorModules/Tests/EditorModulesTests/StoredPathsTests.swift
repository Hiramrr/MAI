import XCTest
@testable import DocumentKit

final class StoredPathsTests: XCTestCase {
    func testRoundTripKeepsPipeInFileName() {
        let paths: Set<String> = ["/Users/prueba/Ideas | 2026.md", "/Users/prueba/notas.md"]
        XCTAssertEqual(StoredPaths.decode(StoredPaths.encode(paths)), paths)
    }

    func testEmptyListEncodesAsEmptyString() {
        XCTAssertEqual(StoredPaths.encode([]), "")
        XCTAssertEqual(StoredPaths.decode(""), [])
    }

    func testReadsLegacyPipeSeparatedValue() {
        XCTAssertEqual(
            StoredPaths.decode("/Users/prueba/a.md|/Users/prueba/b|c.md"),
            ["/Users/prueba/a.md", "/Users/prueba/b|c.md"]
        )
    }

    func testSettingAndTogglingMigrateLegacyValue() {
        let raw = StoredPaths.setting("/Users/prueba/a.md", path: "/Users/prueba/b.md", present: true)
        XCTAssertTrue(raw.hasPrefix("["))
        XCTAssertEqual(StoredPaths.decode(raw), ["/Users/prueba/a.md", "/Users/prueba/b.md"])
        XCTAssertEqual(StoredPaths.decode(StoredPaths.toggling(raw, path: "/Users/prueba/a.md")), ["/Users/prueba/b.md"])
    }

    func testRenamingMovesMark() {
        let raw = StoredPaths.encode(["/Users/prueba/viejo.md", "/Users/prueba/otro.md"])
        let renamed = StoredPaths.renaming(raw, from: "/Users/prueba/viejo.md", to: "/Users/prueba/nuevo.md")
        XCTAssertEqual(StoredPaths.decode(renamed), ["/Users/prueba/nuevo.md", "/Users/prueba/otro.md"])
    }

    func testRenamingUnmarkedPathLeavesValueUnchanged() {
        let raw = StoredPaths.encode(["/Users/prueba/otro.md"])
        XCTAssertEqual(StoredPaths.renaming(raw, from: "/Users/prueba/viejo.md", to: "/Users/prueba/nuevo.md"), raw)
    }
}
