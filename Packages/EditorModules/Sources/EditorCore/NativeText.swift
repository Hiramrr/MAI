import Foundation

public extension String {
    /// Copia nativa en UTF-8 del texto. `NSTextView.string` llega puenteado de
    /// un `NSMutableString`: compararlo o recorrerlo por caracteres lee unidad
    /// a unidad (≈45 ms por comparación en 1 MB). La copia en bloque cuesta
    /// ≈1 ms y después comparar es un `memcmp`. Una suplente suelta pasa a
    /// U+FFFD, igual que al puentear, así que los offsets UTF-16 no cambian.
    func nativeCopy() -> String {
        if isContiguousUTF8 { return self }
        let source = self as NSString
        let length = source.length
        guard length > 0 else { return "" }
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: length) { buffer in
            source.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length))
            return String(decoding: buffer, as: UTF16.self)
        }
    }
}
