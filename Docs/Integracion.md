# Referencias e integración pendiente

## Gestos

Implementado como pieza extraíble (21-sep-2026). Fuente: `/Users/hiram/Proyectos/EditorTDAH/Enfoque/Gestures` (más `LocalFallback` de `Intelligence/WritingAssistant.swift` para sinónimos locales).

- `GestureModule` (target en `Packages/EditorModules`, sin dependencias externas): `GestureTuning` + `GestureThresholds` (clave propia `editor.pinchActivation`, no se comparte con Enfoque), `HandLandmarks`/`GestureState`/`GestureRecognizer` (histéresis), `GestureCalibrationMath`, `GestureUnit` (palabra/oración/párrafo)/`WordNavigator`/`PinchStep`/`LengthLevel`/`LengthSpanStep`, `GestureSentences`/`ToneLevel`/`GestureTone` (rangos de oración sin marcas Markdown y validación de tono), `ToneProvider` + `FoundationModelsToneProvider` (versiones fría y cálida on-device; sin modelo la sesión no abre y se explica el motivo), `GestureSynonyms` (listas locales inmediatas), `SynonymProvider` (protocolo) + `FoundationModelsSynonymProvider` (mejora con Apple Intelligence on-device si hay modelo; si no, vacío y la tarjeta conserva locales) + `LocalSynonymProvider`, `CameraManager` (permiso solo al activar), `HandPoseDetector` (Vision on-device), `GestureModule` (máquina de estados), `GestureControl` (botón y panel: preview espejado, diagnóstico, umbral, calibración, estado de IA, pruebas sin cámara) y `GestureCards` (tarjetas de sinónimos, tono, longitud y aviso con Deshacer).
- Frontera: el módulo nunca toca `NSTextView`. Navegación (`selectRange`) y barrido (`.undo`/`.redo`) viajan como `EditorCommand` por el bus en orden FIFO. Las sesiones usan comandos atómicos nuevos (`beginPreview`/`showPreview`/`commitPreview`/`cancelPreview`) que `EditorSession` aplica sin ensuciar undo ni guardado: el binding, el autosave y el índice ignoran la preview (`NativeTextEditor` la respeta) y al terminar se sincroniza vía `onPreviewCommitted`. Confirmar registra un único undo (o ninguno si no hubo cambio). El documento llega al módulo como instantánea (`updateDocument(text:selection:)` desde `onGestureDocument`); si el texto cambia por fuera, la sesión se cancela, nunca se confirma a ciegas. La pérdida de seguimiento (0.3 s de gracia) cancela y restaura; retirar UNA mano confirma la longitud, perder AMBAS la restaura. El tono reutiliza la sesión de pinza (`PinchSession.isTone`) en modo oraciones: niveles fijos [frío, original, cálido], los extremos no se previsualizan hasta que el modelo responde y soltar antes confirma sin cambios (la generación termina y queda en caché para la siguiente pinza).
- La longitud usa Foundation Models en este Mac para generar una versión corta completa y otra más extensa. Mientras se generan, la tarjeta no permite confirmarlas. Si el modelo no está disponible o las versiones no cumplen los mínimos de longitud, conserva el párrafo y explica el motivo. Los sinónimos conservan su lista local.
- Cada versión de longitud (corta, larga) y de tono (fría, cálida) se valida por separado. Si solo una sirve, la otra queda deshabilitada con su motivo y ni el clic ni la mano pueden previsualizarla o confirmarla; el original siempre sigue disponible. Si ninguna sirve, la sesión se cierra con la causa. Los avisos distinguen plazo vencido, Apple Intelligence no disponible, texto demasiado largo, modelo ocupado y respuesta no válida (`ModelFailure` en `EditorCore`).
- La longitud solo reescribe prosa. Usa el análisis de `MarkdownDocument`: rechaza con explicación el interior de bloques de código (también con sangría), filas de tabla, títulos, reglas y párrafos con enlaces, imágenes, código en línea o HTML, sin llamar al modelo. En citas y listas solo cambia el texto tras la marca.
- El panel permite cambiar la navegación de palabras a párrafos y pausar la interpretación sin cerrar la cámara. La pausa cancela cualquier vista previa activa y conserva el texto original.
- Diferencias con Enfoque: sin anclaje de tarjeta sobre la palabra (overlay inferior), sin "el ratón manda" (el módulo no ve el ratón; los rangos obsoletos se rechazan al validar).
- Permisos: la cámara se pide solo al pulsar "Activar cámara" (`NSCameraUsageDescription`, entitlement `device.camera`). Sin la pieza, la app no la pide. Todo on-device, sin guardar vídeo.
- Quitar: borrar el bloque "Pieza Lego: Gestos" de `App/EditorApp.swift`, el target `GestureModule` de `Package.swift` y su producto del `.xcodeproj`. `EditorScreen` compila con `gesturePanel == nil` y Ajustes > Voz muestra "Módulo no disponible" en Gestos.
- Pruebas en `GestureLogicTests.swift` (histéresis, tracking, dos manos, calibración, navegadores, sinónimos, oraciones y tono), `GestureIntegrationTests.swift` (flujos completos sin cámara, incluida la pinza de tono) y `PreviewTests.swift` (commit con un solo undo, sin cambios sin undo, cancelación, edición externa, bloqueo en lectura).

## Diagramas

Pieza extraíble (28-sep-2026). `DiagramModule` (target sin dependencias) contiene `DiagramParser`, `DiagramLayout` y `DiagramRenderer`. `MarkdownAppearance.readingText` lo usa para los bloques ` ```diagram ` en lectura, PDF y Word; en edición el bloque es texto y no participa en undo, guardado ni índice.

- Quitar: borrar el target de `Package.swift` (y de las dependencias de `EditorEngine` y de las pruebas), `renderDiagram` y su llamada en `MarkdownAppearance`. Todo bloque vuelve a verse como código.
- Pruebas en `TableDiagramTests.swift` (parser, layout determinista y sin solapes, adjunto en lectura, degradación a código y PDF).
- Diseño y pendientes en `Docs/Diagramas.md`.

## Voz

No apareció una carpeta llamada MiyuFlow en Proyectos. El proyecto de voz encontrado es `/Users/hiram/Proyectos/MiyuWisp/LocalFlow`.

Se revisaron su README, `SpeechRecognitionService.swift`, `VoiceResult.swift` y `RuleBasedIntentParser.swift`. La ruta Apple usa SpeechAnalyzer y DictationTranscriber de macOS 26. Existe también una variante WhisperKit, que no se añadió a EditorFinal.

Implementado como pieza Lego extraíble (21-sep-2026):

- `ModuleKit`: `EditorCommandBus` (actor con difusión), `EditorModuleContext`, `EditorInputModule`, `ModuleDescriptor`, `ModuleRegistry` (registro para Ajustes).
- `VoiceModule`: `VoiceModule` + `VoiceControl` (botón y HUD, ⌃⌘V), `AppleSpeechRecognizer` (micrófono local, parciales y nivel), `VoiceCommandParser` (comandos: nueva línea, nuevo párrafo, deshacer, borra eso, cancelar), `DictationCleaner` (muletillas, puntuación dictada, estilo formal).
- Frontera: la voz produce `EditorCommand` vía bus; nunca toca `NSTextView`. Sin inserción por Accesibilidad, atajos globales ni control de otras apps. "Borra eso" equivale a undo del editor. En lectura los comandos se ignoran solos.
- Permisos: micrófono y voz se piden solo al dictar (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, entitlement `audio-input`). Sin la pieza, la app no los pide.
- Quitar: borrar el bloque "Pieza Lego: Voz" de `App/EditorApp.swift`, los productos `VoiceModule`/`ModuleKit` de `Package.swift` y del `.xcodeproj`. `EditorScreen` compila con `voicePanel == nil` y Ajustes > Voz muestra "Módulo no disponible".
- Pruebas sin micrófono en `VoiceModuleTests.swift` (parser, limpieza, bus, registro, inserción y undo por bus, silencio).

## Frontera futura

`EditorCore.EditorCommand` no importa AppKit ni SwiftUI. `EditorSession.send` recibe intenciones y aplica las operaciones al NSTextView. El bus (`EditorCommandBus`) y `ModuleKit` ya existen con el primer módulo (voz), con pruebas de cancelación, cierre y silencio. Falta probar destino por documento si alguna vez hay más de una ventana.

## Referencia de persistencia

La primera entrega usa DocumentGroup y FileDocument para conservar el ciclo nativo de documentos. Referencia de Apple: https://developer.apple.com/documentation/swiftui/documentgroup

### iCloud Drive

`DocumentKit.CloudDocuments` guarda un marcador con alcance de seguridad (`com.apple.security.files.bookmarks.app-scope`) de una carpeta de iCloud Drive elegida en un panel. `EditorScreen` crea allí los documentos nuevos y abre en ella los paneles de guardado de borradores. NSDocument coordina la escritura y macOS se encarga de la sincronización. No se usa un contenedor iCloud propio (`NSUbiquitousContainers`) porque requiere los derechos `com.apple.developer.icloud-*`, que un equipo personal gratuito no puede firmar. Si más adelante hay una cuenta de pago, se puede añadir el contenedor y usar `FileManager.url(forUbiquityContainerIdentifier:)` antes del marcador.
