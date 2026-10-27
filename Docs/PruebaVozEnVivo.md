# Prueba de voz en la app

Esta prueba usa el micrófono, el reconocedor y la ventana real de EditorFinal.
Los tests de Swift no miden estos tres juntos. No hay resultados registrados
todavía.

## Preparación

1. Abre la app compilada en un Mac con macOS 26 o posterior. Crea un documento
   de prueba llamado `acta vieja.md` y otro borrador con el texto
   `TDAH y metodología de usabilidad.`. Abre el borrador.
2. Usa el mismo micrófono, distancia y lugar durante toda la sesión. Anota
   modelo de Mac, versión de macOS, micrófono, idioma y ruido aproximado.
3. Deja `Manos libres` activado. No corrijas el transcript antes de
   anotarlo. Si el cierre por pausa corta una frase, registra ambos trozos.

## Enunciados

Haz tres rondas de la lista. Restaura el borrador antes de cada ronda.
En cada fila anota el transcript que muestra el panel, la propuesta, si
el texto apareció en el documento mientras hablabas, el resultado tras
«confirmar» o «descartar», y si el cierre
por pausa cortó o juntó enunciados.

| Prueba | Di exactamente | Resultado esperado |
| --- | --- | --- |
| Frase ambigua | Titula bien tus ideas | Di «usar como texto» y luego «confirmar»; inserta el texto |
| Dictado | Esta es una frase con una pausa para pensar y luego continúa | Texto provisional visible; una inserción tras la pausa, sin corte intermedio |
| Dictado | Primera idea, pausa, segunda idea | Dos inserciones separadas por un espacio |
| Dictado | Nuevo párrafo | Línea en blanco al momento, sin propuesta |
| Dictado | Hola punto y aparte seguimos | Dos párrafos; el segundo empieza con mayúscula |
| Ayuda | Qué puedo decir | El panel abre los ejemplos; texto intacto |
| Navegación | Busca TDAH | Selección inmediata, texto intacto |
| Navegación | Selecciona metodología | Selección inmediata, texto intacto |
| Cambio | Cambia el título a prueba de usabilidad | Propuesta con el título exacto; «descartar» no renombra |
| Cambio | Cambia el título de prueba | Propuesta; «confirmar» renombra una vez |
| Cambio | Ponlo en negritas | Propuesta; «confirmar» cambia la selección una vez |
| Cambio | Borra la selección | Propuesta; «descartar» conserva el texto |
| Cambio | Sustituye esto por diseño | Propuesta; «confirmar» reemplaza solo la selección |
| Cambio | Deshaz el cambio | Propuesta; «confirmar» deshace una vez |
| Archivo | Guarda el documento | Propuesta; «confirmar» guarda mediante NSDocument |
| Archivo | Recupera el acta vieja | Propuesta; «confirmar» abre el documento único |

Prueba también dos frases seguidas sin pausa larga, como `Busca TDAH` y
`Selecciona metodología`. Cuenta si el cierre automático las junta.
Repite dos cambios respondiendo «sí» y «no» en lugar de «confirmar» y
«descartar». Con Manos libres y sin propuesta, di solo «no»: debe
escribirse como texto.
Para abrir por nombre, prueba después dos archivos que contengan `acta`
en el título. La app debe pedir que elijas uno.

## Reescritura local (fase 12)

Con el mismo borrador, selecciona `metodología` y di «Hazlo más breve».
Comprueba que el panel muestre la propuesta y que el documento siga intacto.
Di «descartar» y verifica que deshacer no tenga una operación nueva. Repite,
di «confirmar» y comprueba que un solo deshacer restaure la selección original.

Repite con una selección que incluya el espacio y el salto de línea antes y
después del texto. La propuesta y el resultado deben conservar esos bordes.
Por último, mientras el panel muestra una propuesta, cambia la selección con
el ratón y pulsa Confirmar. El documento debe conservar la edición del usuario
y mostrar que la propuesta caducó.

## Registro y criterio

Guarda una fila por intento en un CSV con las columnas `ronda`, `prueba`,
`esperado`, `escuchado`, `propuesta`, `decision`, `resultado`, `corte` y
`union`. `esperado` es la frase pronunciada, no el nombre del comando.
Para WER, normaliza minúsculas y puntuación y calcula la distancia de
Levenshtein entre las palabras de `esperado` y `escuchado`. Divide la suma
de errores entre la suma de palabras esperadas. Cuenta por separado:

- Comandos correctos de extremo a extremo sobre los 30 intentos de
  navegación, cambios y archivos, incluyendo el argumento exacto y el efecto tras confirmar.
- Mutaciones de comandos antes de «confirmar»: debe ser 0.
- Errores de corte y unión sobre los intentos con pausas y frases seguidas.
- Propuestas descartadas por voz que dejaron el documento intacto.

Anota la duración entre terminar de hablar y ver la propuesta. Ajusta
`autoEndpointSilence` solo tras medir tres rondas con el valor actual de
1.6 segundos y repite las mismas frases con el nuevo valor. No compares
sesiones con distinto micrófono como si midieran solo el temporizador.

El cierre también espera 1.6 s sin voz en el micrófono. Repite una ronda con
ruido de fondo constante (ventilador) y anota si la frase se cierra sola. En
otra ronda pulsa «Descartar» mientras aparece «Preparando micrófono…» y
comprueba que el indicador de micrófono de macOS no se enciende después.
