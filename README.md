# EditorFinal

Editor nativo con edición Markdown, lectura y herramientas de concentración. Desarrollo y validación en macOS 27, destino mínimo macOS 26. Swift 6, SwiftUI, NSTextView y TextKit 2. Sin dependencias externas.

## Ejecutar

Para compilar sin abrir una ventana:

```sh
xcodebuild -project EditorFinal.xcodeproj -scheme EditorFinal -configuration Debug -derivedDataPath build build
```

Para usar la app manualmente, abre `EditorFinal.xcodeproj` y ejecuta el esquema `EditorFinal` en Xcode.

## Alcance de esta entrega

- Crear, abrir y guardar `.md` y `.txt` UTF-8 con el ciclo de documentos de SwiftUI. DocumentGroup gestiona autosave, cierre y recuperación mediante el sistema de macOS.
- Guardado en iCloud Drive (Configuración › Documentos): se autoriza una vez una carpeta de iCloud Drive y los documentos nuevos se crean allí. La carpeta aparece en la barra lateral con el icono de nube y macOS la sincroniza. Los documentos existentes no se mueven.
- Edición nativa con selección, copiar, pegar, deshacer, rehacer y búsqueda del sistema.
- Navegación por Inicio, Recientes, Favoritos, Archivado, Sin título y Papelera de EditorFinal. Esta última aparta archivos de la biblioteca sin moverlos del disco; desde allí se pueden enviar a la papelera del Mac. Las carpetas se obtienen de las ubicaciones reales de los documentos recientes; las notas aparecen en la columna central, no en el sidebar. El botón Volver de la barra superior, ⌘[, regresa a la última pantalla vista (la lista de notas anterior o la nota abierta).
- Concentración con ⇧⌘F, foco del párrafo con ⌥⌘F y máquina de escribir con ⌥⌘T.
- Títulos, negrita, cursiva y código con formato durante la edición. La vista de lectura, ⇧⌘R, oculta los marcadores sin cambiar el archivo. Al volver a editar se conserva la selección.
- Preferencias persistentes de fuente, tamaño, interlineado, ancho, apariencia y estadísticas. El índice y el conteo se actualizan tras una pausa de escritura.
- Menú Formato con negrita, cursiva, código, títulos, lista, cita y enlace. Repetir negrita o cursiva retira los marcadores de la selección.
- Imágenes en bloques Markdown: usa el botón de imagen para copiarlas a `images/` junto al documento. Arrastra la esquina inferior derecha para cambiar el tamaño, arrastra la imagen para moverla de párrafo y usa el menú contextual para alinearla. La vista de lectura, el PDF y Word muestran la imagen. En un documento sin guardar, las imágenes esperan en una carpeta temporal y pasan a `images/` junto al archivo cuando se guarda por primera vez. Fuera del contenedor, macOS puede pedir acceso a la carpeta del documento.
- Tablas Markdown (GFM): cabecera, fila de separación con alineación `:--`, `:-:` y `--:`, y filas con o sin barras en los extremos. En edición se ven como texto monoespaciado para alinear las columnas; la lectura, el PDF y Word las muestran como tablas.
- Diagramas de flujo en bloques ` ```diagram `: nodos `id[Texto]`, decisiones `id{¿Pregunta?}`, inicio/fin `id((Texto))`, píldoras `id[(Texto)]`, aristas `a -> b`, etiquetas `a -- Sí --> b` o `a -->|Sí| b` y `direction LR` para dibujar de izquierda a derecha. En edición el bloque es texto; la lectura, el PDF y Word lo dibujan. Un bloque que no se puede interpretar se muestra como código. Sintaxis completa en `Docs/Diagramas.md`.
- Imprimir o guardar PDF con ⌘P mediante el diálogo de macOS. El PDF usa texto negro, conserva los títulos con el párrafo siguiente y no corta imágenes ni diagramas entre páginas.
- Exportar por voz, con confirmación: «Exporta en Word», «Exporta en formato enriquecido», «Genera el documento en texto plano» o «Exporta en pdf». Word, RTF y texto abren el panel de guardado del sistema; no hay entrada de menú propia.
  - **Word (.docx):** usa el mismo render que la lectura, con el título del documento al inicio, formato en línea, listas, citas, tablas, imágenes y diagramas.
  - **RTF:** guarda el texto del editor con los atributos de edición. El Markdown no se interpreta: las tablas y los diagramas quedan como texto.
  - **Texto (.txt):** el Markdown original sin cambios.
  - **PDF:** abre el diálogo de impresión, igual que ⌘P.
- Sandbox con acceso a archivos elegidos por el usuario e impresión. No solicita red. El micrófono y el reconocimiento de voz solo se piden al usar el dictado por voz (⌃⌘V), que es una pieza extraíble: sin ella no se piden esos permisos.
- Gestos con la cámara desde el botón de la mano en la barra: mano abierta para elegir palabras, oraciones o párrafos, pinza quieta sobre una palabra para sinónimos locales (suelta para confirmar), pinza sobre una oración para cambiar su tono de frío a cálido (izquierda enfría, derecha templa), pinza + barrido lateral para deshacer/rehacer, dos manos para la longitud del párrafo o el ancho de una imagen (retira una para confirmar). El panel permite pausar los gestos sin apagar la cámara y probar las tarjetas sin pedir permiso. La cámara solo se pide al activarla y todo se procesa en el Mac. Ver `Docs/Integracion.md` para quitar la pieza.
- Dictado y comandos comparten el micrófono de la barra (⌃⌘V). Con Manos libres, el texto aparece en el documento mientras hablas y se inserta tras una pausa. El micrófono sigue escuchando: para cambiar algo, di el comando y luego «confirmar», «descartar» o «repetir». «Detener voz» termina la escucha. Buscar y seleccionar se aplican al momento. A una propuesta también se responde con «sí» o «no». «Nueva línea», «nuevo párrafo» y «punto y aparte» funcionan dentro del dictado, y las frases seguidas quedan separadas por un espacio. El panel del micrófono muestra ejemplos («qué puedo decir» los abre por voz) y recuerda las opciones entre sesiones. Ver `Docs/Integracion-Voz-Fase11.md` y `Docs/PruebaVozEnVivo.md`.

El formato cubre títulos ATX (incluido cierre `##`) y setext, código con cercas o sangría, listas con viñetas, ordenadas y de tareas, citas (`>` con o sin espacio, anidadas), reglas y formato en línea (`**`/`__`, `*`/`_`, `***`, `~~`, código, enlaces, autolinks y escapes). Admite imágenes locales en bloques propios, con ancho y alineación guardados en el título Markdown, tablas GFM y diagramas ` ```diagram `. Los enlaces de lectura solo admiten http, https y mailto.

`EditorCore` contiene comandos, rangos UTF-16 e índice. `EditorEngine` encapsula TextKit. `EditorUI` compone las vistas. `DocumentKit` valida y codifica UTF-8. El adaptador `FileDocument` vive en App, para mantener SwiftUI fuera de DocumentKit. El sistema realiza el I/O de documentos. `ExportFeature` prepara la impresión y el PDF y exporta a txt, rtf y Word sin intervenir en el motor de edición. `DiagramModule` interpreta, ordena y dibuja los diagramas sin dependencias externas.

## Verificación

```sh
swift test --package-path Packages/EditorModules
```

Las pruebas cubren Unicode, rangos inválidos, títulos, texto vacío y codificación de documentos de 100 000, 500 000 y 1 000 000 caracteres. También ejecutan inserción, selección, sustitución, formato, undo y redo sobre un NSTextView real. La exportación se verifica con un PDF de varias páginas, incluidos el primer y el último párrafo y los saltos de títulos. La voz se prueba sin micrófono (comandos, limpieza, bus, inserción y silencio). Los gestos se prueban sin cámara (histéresis, calibración, navegación, sinónimos locales, oraciones y tono) y la preview atómica sobre un NSTextView real (un solo undo al confirmar, restauración al cancelar, edición externa que cancela, bloqueo en lectura). La prueba de codificación de archivos grandes no equivale a una medición de fluidez con Instruments.

## Próximas entregas

1. Medir documentos grandes con Instruments y ampliar pruebas de recuperación, accesibilidad y métodos de entrada.
2. Sesión manual de gestos con cámara real, VoiceOver sobre tarjetas y panel, y contraste aumentado.

La especificación completa está en `Docs/Especificacion.md`. Se conserva como referencia original. La decisión posterior del usuario elimina la compatibilidad con macOS 15 y permite APIs exclusivas de macOS 27.

El mapa de reutilización está en `Docs/Integracion.md`.
