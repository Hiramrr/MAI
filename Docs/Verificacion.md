# Verificación del editor

Actualizada el 27 de octubre de 2026. Xcode 27 y SDK macOS 27. Destino mínimo macOS 26.

## Automatizada

`swift test --package-path Packages/EditorModules` ejecuta 320 pruebas XCTest. Cubren codificación, Unicode, índice, rangos, comandos sobre NSTextView, lectura y decoración Markdown (títulos ATX/setext con cierre, citas, listas ordenadas y de tareas, reglas, énfasis `**`/`__`/`*`/`_`/`***`/tachado, código, enlaces, autolinks y escapes, párrafos con saltos suaves), alternancia de formato con undo, exportación PDF multipágina, tablas GFM (celdas, alineación, `NSTextTable` en lectura y Word, paso a TextKit 1 en la vista de lectura), diagramas (parser, layout determinista sin solapes, adjunto en lectura y PDF sin cortes), imágenes de documentos sin guardar y su geometría sin salir de TextKit 2, bus de comandos y registro de módulos, lógica de gestos sin cámara (histéresis, calibración, navegación, sinónimos locales, oraciones y tono) y preview atómica sobre NSTextView real. Las pruebas de voz usan un reconocedor simulado; aún falta la sesión con micrófono real.

`AIGenerationTests.swift` añade nueve pruebas con proveedores simulados. Comprueban los plazos aunque la generación ignore la cancelación, la propagación de errores, el reuso de generaciones de gestos tras cerrar sus tarjetas y la cancelación de reescrituras de voz. Una respuesta cancelada no puede invalidar una propuesta posterior. Estas pruebas no miden la latencia de Apple Intelligence ni usan micrófono o cámara reales.

Otras 39 pruebas, también con dobles, cubren seis cambios del flujo de voz y gestos:

- Cierre por pausa (`VoiceEndpointActivityTests`): con el parcial quieto pero audio activo no cierra; tras voz y silencio sí; la escucha rearmada empieza con relojes nuevos; un ruido constante deja de contar como voz; push-to-talk nunca cierra por pausa. Usan un reloj manual, sin esperas reales.
- Texto recuperado (`VoiceRecoveryTests`): si `stop()` falla con texto parcial, el error sigue visible, el texto queda aparte y nada se ejecuta aunque parezca una orden. Insertar es explícito, ocurre una vez y se deshace con un undo; descartar no toca el documento; un parcial de una sesión cancelada no se recupera.
- Cancelar al preparar el micrófono (`VoiceStartCancellationTests`): cancelar y detener no esperan a un arranque suspendido; si ese arranque termina o falla después, no enciende el micrófono, no cambia el estado ni deja preview, y no afecta a una grabación nueva.
- Causas de fallo de IA (`VoiceRewriteFailureTests`, `ModelFailureTests` y pruebas de gestos): plazo vencido, Apple Intelligence no disponible, texto demasiado largo, salida no válida, selección ausente y selección que cambia mientras se genera llegan al panel o al aviso de la tarjeta; cancelar no se trata como error.
- Markdown en Longitud: código delimitado y con sangría, filas de tabla, títulos y enlaces se rechazan con explicación sin llamar al modelo, con botón y con dos manos; en una viñeta solo cambia el texto.
- Versiones parciales: corta válida y larga no válida, fría no válida y cálida válida, ninguna válida, caché parcial sin llamada extra, preview, confirmación y undo. Un nivel sin versión queda deshabilitado y la mano no puede llegar a él.

`swift test -c release -Xswiftc -enable-testing --package-path Packages/EditorModules --filter EditorPerformanceTests` imprime los tiempos de documentos de 100 000, 500 000 y 1 000 000 de caracteres. El 2 de octubre de 2026, con 1 000 000: análisis 0,08 s (0,10 s desde el texto del editor, fuera del hilo principal), decorado completo 0,14 s, edición 0,6 ms y redecorado incremental 3,5 ms.

`xcodebuild -project EditorFinal.xcodeproj -scheme EditorFinal -configuration Debug -derivedDataPath build build` compila y firma la app con sandbox. El compilador Swift no reporta advertencias. La herramienta de Xcode AppIntents emite su aviso de metadatos omitidos porque la app no usa AppIntents.

## En la aplicación

- Abrir el ejemplo Markdown y comprobar el índice y los controles con el árbol de accesibilidad.
- Verificar el diseño con una captura en modo oscuro.
- Buscar Cazador con ⌘F y obtener una coincidencia.
- Crear un documento con ⌘N y escribir.
- Activar Configuración › Documentos › Guardar documentos en iCloud Drive y elegir una carpeta dentro de iCloud Drive. Crear un documento con ⌘N y comprobar que el archivo aparece en esa carpeta, en la barra lateral y en otro dispositivo con la misma cuenta. Tras reiniciar la app, los documentos nuevos se deben seguir creando ahí sin volver a pedir la carpeta. Una carpeta fuera de iCloud Drive se rechaza con un aviso.
- Guardar con ⌘S en `build/Prueba de guardado.md`.
- Copiar y pegar texto con ⌘C y ⌘V, deshacer con ⌘Z y rehacer con ⇧⌘Z.
- Activar concentración y comprobar que desaparecen ambas columnas laterales.
- Guardar, cerrar y volver a abrir. Comprobar en disco y en el editor que persisten ambas líneas de prueba.

## Lectura, concentración y PDF

- Vista de lectura comprobada visualmente con títulos, énfasis, listas y enlaces. El editor de origen queda oculto también para accesibilidad y el lector recibe el foco.
- Búsqueda nativa disponible en la vista de lectura.
- Concentración oculta navegación e inspector. Se comprobaron los atajos de foco de párrafo y máquina de escribir.
- El diálogo de impresión abre con sandbox y el permiso de impresión firmado. No requiere seleccionar una impresora para guardar PDF.
- Prueba de exportación con 50 secciones. PDF de nueve páginas renderizado con Poppler e inspeccionado visualmente. La prueba comprueba que no termina ninguna página con un título aislado y que las secciones 1 y 50 permanecen en el archivo.
- El renderizado no reemplaza el texto ni añade operaciones al historial de deshacer.
- Se conservaron los cambios recientes del usuario en la distribución de paneles y el tamaño de ventana.

## Gestos (pieza extraíble)

Automatizado sin cámara: `GestureLogicTests` (pinza con histéresis, pérdida de seguimiento, dos manos, mediana y umbral de calibración, anclaje y pasos de palabra, avance de opción y de nivel, sinónimos y longitudes locales, rangos de oración sin marcas Markdown y validación de tono), `GestureIntegrationTests` (sesiones de sinónimos, tono, longitud e imagen de extremo a extremo con proveedores simulados) y `PreviewTests` (confirmar registra un único undo, sin cambios no registra nada, cancelar restaura, edición externa cancela en vez de aplicar a ciegas, lectura bloquea la preview).

Manual pendiente con cámara real:

- Sin activar la pieza no hay botón de mano en la barra y el sistema no pide cámara.
- Activar cámara pide permiso una sola vez; el panel muestra preview espejado, insignia en vivo y diagnóstico (mano, pinza, apertura + umbral).
- Mano abierta camina la selección palabra por palabra; pinza quieta abre sinónimos, mover cambia el preview, soltar confirma con un solo undo; abrir cancela y restaura.
- Pinza + barrido amplio ejecuta deshacer/rehacer una vez por pinza.
- Dos manos abren corto/medio/largo; retirar una confirma (con aviso y Deshacer), perder ambas restaura. Si no abre: el overlay debe etiquetar ambas manos (1 y 2) con la línea blanca entre ellas, la insignia debe decir "Dos manos" y la Separación del diagnóstico debe moverse; con las manos juntas Vision las fusiona en una.
- "Probar sin cámara" (Sinónimos/Longitud) abre las mismas tarjetas: clic confirma, ✕ cancela.
- Con Apple Intelligence real: si una sola versión de longitud o de tono sale válida, la otra aparece deshabilitada con su motivo; los avisos de fallo nombran la causa (plazo, no disponible, texto largo, respuesta no válida).
- Calibración en dos pasos de 3 s ajusta el umbral; muestras solapadas se rechazan con mensaje.

## Pendiente

Con micrófono real: que el cierre por pausa no corte mientras se habla y cierre tras callar, con ruido de fondo y sin él (el margen sobre el ruido, 0.12 en la escala del nivel, no se ha medido); que cancelar durante el permiso o la descarga del modelo devuelva el control sin encender el micrófono; y que un fallo del reconocedor ofrezca el texto recuperado. Nada de esto se ha probado con micrófono, cámara ni Apple Intelligence reales.

Prueba prolongada de autosave y recuperación tras interrupción, Instruments, VoiceOver con lector activo, contraste aumentado, rendimiento de escritura con un millón de caracteres y ejecución en un Mac con macOS 26. La cobertura Unicode automatizada no sustituye una sesión manual con un método de entrada japonés.
