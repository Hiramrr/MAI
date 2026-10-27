import Foundation

/// Lista de rutas guardada en una sola cadena de preferencias (favoritos,
/// archivado, papelera y carpetas propias). Se codifica como arreglo JSON:
/// `|` es válido en nombres de archivo de macOS y no sirve de separador.
public enum StoredPaths {
    public static func decode(_ raw: String) -> Set<String> {
        if raw.hasPrefix("["),
           let data = raw.data(using: .utf8),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            return Set(paths.filter { !$0.isEmpty })
        }
        return legacy(raw)
    }

    public static func encode(_ paths: Set<String>) -> String {
        let sorted = paths.filter { !$0.isEmpty }.sorted()
        guard !sorted.isEmpty,
              let data = try? JSONEncoder().encode(sorted),
              let raw = String(data: data, encoding: .utf8) else { return "" }
        return raw
    }

    public static func setting(_ raw: String, path: String, present: Bool) -> String {
        var paths = decode(raw)
        if present { paths.insert(path) } else { paths.remove(path) }
        return encode(paths)
    }

    public static func toggling(_ raw: String, path: String) -> String {
        setting(raw, path: path, present: !decode(raw).contains(path))
    }

    /// Lleva la marca de `old` a `new` tras renombrar o mover un documento.
    /// Sin marca en `old` devuelve `raw` tal cual.
    public static func renaming(_ raw: String, from old: String, to new: String) -> String {
        var paths = decode(raw)
        guard paths.remove(old) != nil else { return raw }
        paths.insert(new)
        return encode(paths)
    }

    /// Formato anterior: rutas unidas con `|`. Las rutas son absolutas, así
    /// que solo un `|` seguido de `/` separa; uno dentro de un nombre se
    /// conserva.
    private static func legacy(_ raw: String) -> Set<String> {
        let parts = raw.components(separatedBy: "|/")
        let paths = parts.enumerated().map { index, part in index == 0 ? part : "/" + part }
        return Set(paths.filter { !$0.isEmpty })
    }
}
