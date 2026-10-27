# Integración voz Fase 11 ↔ rama full (action-classifier)

## Qué se integró

Rama `prueba/action-classifier-voice-integration` = `prueba/action-classifier`
(menús nuevos, `VoiceModule` dictado, `GestureModule`, `ModuleKit`, bus de
comandos) + cambios de voz probados en `prueba/real-editor-command-integration`
(commit `3bc7e37`):

- `EditorEngine/VoiceCommandIntegration.swift` — `EditorCommandTarget`,
  `EditorCommandExecutor`, `EditorCommandResult`, `RealEditorTarget`,
  snapshot/stale, previews C20, fixtures, store temporal, harness.
- `EditorEngine/EditorSession+Voice.swift` — `session.makeVoiceExecutor(...)`.
- `VoiceRealEditorTests.swift` — 109 tests (verdes aquí: 178/178 total).
- `command-grammar/` completo — parser/gramática/STT/policy + 447/352/406/
  29/44/96 suites verdes + live 36/36.
- `Docs/Fase11-RealEditor.md` — entrega y métricas.

## Costura entre los dos sistemas de voz (intencionalmente sin auto-cablear)

- `VoiceModule` (dictado) → `EditorCommandBus` → `session.send(...)`:
  flujo existente, intacto, sigue funcionando.
- Fase 11 (`VoiceCommand` + `EditorCommandExecutor`): taxonomía de comandos
  validada con confirmación obligatoria. Expuesto vía
  `session.makeVoiceExecutor(title:titleWriter:store:)`.
- NO se conectó el transcript del dictado al executor porque eso exigiría:
  1. importar la gramática probada (vive en `command-grammar`, paquete
     ejecutable no importable; duplicarla violaría el congelamiento), y
  2. UI de confirmación (proposal/Enter/Esc), explícitamente fuera del
     alcance de Fase 11 ("No UI final").
- Cablear sin confirmación violaría el invariante `wrongAuto = 0`.
  El siguiente paso es una UI de modo-comando que use `makeVoiceExecutor`
  (proposal → Enter/Esc/R), no un atajo automático.

## Actualización: comandos completos por voz (2026-09-23)

Los 12 comandos probadas ahora funcionan en la app, SIN duplicar la
gramática: `command-grammar` expone la librería `CommandGrammar`
(`Types`+`Grammar`, solo cambio de acceso a `public` + `Sendable`; cero
funcional) y `VoiceModule` depende de ella (fuente única).

Ruta: transcript → legacy (frases exactas) → `parseCommand` real (+reintento
"cambia el título de X"→"a X", adaptación en app, `Grammar.swift` intacta)
→ `[EditorCommand]` → bus → sesión/pantalla.

Cobertura: find/select inmediatos (solo selección), delete/replace/format/
undo/redo/rename/save/open/export ejecutados, rewrite con propuesta local
y confirmación, unsupported/unknown/múltiple → dictado o aviso, 0 comandos.

El panel de voz muestra la transcripción y la propuesta. Dictado y comandos
comparten el mismo micrófono. En el modo por turnos, Enter confirma, Esc
descarta y R vuelve a grabar. Buscar y seleccionar se ejecutan al momento;
las acciones que cambian estado esperan confirmación. Si una frase como
«Titula bien tus ideas» se reconoce como comando, «Usar como texto» cambia
la propuesta a dictado sin volver a hablar.
Tras confirmar, el panel conserva la transcripción junto al resultado.
«Corrige eso» propone deshacer el último cambio.

Abrir por nombre consulta los documentos conocidos de la biblioteca. Solo
abre directamente cuando el nombre identifica un archivo único. Si no hay
coincidencia única, muestra el panel de apertura del sistema.

Manos libres: `continuousListening` (defecto sí) cierra cada frase tras 1.6 s
sin cambios en el parcial. El dictado parcial aparece en el documento sin
guardarse y se inserta al cerrar la pausa. El micrófono se rearma. Para un
cambio pendiente, sigue escuchando «confirmar», «descartar», «repetir» o
«usar como texto». «Detener voz» termina la escucha. El silencio total nunca
cierra solo. El umbral aún requiere medición con micrófono real.

Actualización: el cierre también exige 1.6 s sin voz en el micrófono. Un
nivel cuenta como voz si supera el umbral del reconocedor y el ruido de
fondo más un margen; el ruido se estima en cada escucha (baja en el acto y
sube despacio). Así, si Speech se atrasa mientras se sigue hablando, no se
corta; push-to-talk sigue cerrando solo al soltar. Si `stop()` falla con
texto reconocido, el panel muestra el error y el texto aparte para copiarlo,
insertarlo como texto incompleto o descartarlo; no se ejecuta como orden ni se
inserta solo, y no se empieza otra grabación hasta decidir. Cancelar mientras
se piden permisos o se descarga el modelo vuelve al momento: el reconocedor
numera cada sesión y un arranque que despierta tarde no abre el micrófono.
Un fallo de reescritura dice la causa (plazo, Apple Intelligence no
disponible, texto largo, respuesta no válida, selección ausente o cambiada).

## Actualización: reescritura real y Word (2026-09-23)

- «Hazlo más breve» y otras instrucciones de reescritura generan una
  propuesta con Foundation Models en este Mac. El panel muestra el texto
  generado antes de confirmar. Aceptar reemplaza la selección en un único
  undo; descartar conserva el documento y el historial. Si no hay selección,
  el modelo falla o cambia el documento o la selección, no aplica nada.
- «Exporta en Word» es real: `EditorScreen` guarda .docx (Office Open XML
  desde la lectura renderizada) vía panel del sistema. «Exporta a pdf»
  sigue yendo al diálogo de impresión.
- Harness (`VoiceCommandIntegration`, doble de pruebas): export pdf (PDF
  headless al store temporal) y word (.docx al store) reales. Rewrite sigue
  simulado a propósito (doble determinista para la política de
  confirmación; el path real de producción es `EditorSession`).

## Fase 12: verificación de reescritura local (2026-09-23)

- `EditorSession` envía solo la selección y la instrucción a Foundation Models
  en este Mac. El texto original y el historial de deshacer no cambian hasta
  que la persona confirma la propuesta visible.
- Cambiar el documento, la selección o el archivo antes de confirmar invalida
  la propuesta. Detener voz también la descarta e ignora respuestas tardías.
  Los espacios y saltos de línea al borde de la selección se conservan.
- `swift test --package-path Packages/EditorModules` pasó con 227 pruebas.
  Una prueba de consola con Foundation Models disponible devolvió una
  reescritura breve. Falta comprobar el flujo completo con micrófono y la
  interfaz en ejecución.

## Actualización: panel más simple y dictado continuo (2026-10-02)

- Panel: un título de estado, un botón principal y una línea que explica el
  modo activo. «Qué puedo decir» lista ejemplos por grupo y «Opciones»
  reúne Manos libres, ⌥Espacio, estilo e idioma. Decir «qué puedo decir»
  abre los ejemplos. Las pruebas comprueban cada ejemplo contra el parser.
- Las opciones se guardan en `UserDefaults` (`voice.*`). Las pruebas crean el
  módulo con `preferences: nil` y no tocan preferencias reales.
- Respuestas a una propuesta: además de «confirmar», «descartar», «repetir»
  y «usar como texto», valen «sí», «dale», «no», «mejor no», «otra vez» y
  «es texto». Las formas cortas solo cuentan con una propuesta a la vista;
  sin ella son dictado.
- Saltos: «nueva línea» y «nuevo párrafo» se insertan al momento en Manos
  libres, como el resto del dictado. En el modo por turnos siguen pasando
  por la propuesta. Dentro de una frase, `DictationCleaner` convierte
  «nueva línea», «nuevo párrafo», «punto y aparte» y «abre/cierra
  interrogación» o «exclamación». El estilo formal pone mayúscula al
  empezar cada línea y punto al cerrarla.
- `EditorSession.spacedDictation` antepone un espacio al dictado de Manos
  libres cuando el texto anterior no termina en espacio, salto ni signo de
  apertura. La inserción confirmada del modo por turnos (`insertText`) no
  cambia.
- `swift test --package-path Packages/EditorModules` pasó con 270 pruebas y
  la app compila. Falta la sesión con micrófono y la interfaz en ejecución.
