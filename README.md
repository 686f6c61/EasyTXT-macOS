# EasyTXT

EasyTXT es un editor TXT-first para macOS, inspirado en el flujo de Notepad++, pero adaptado a un entorno nativo de Mac. Está pensado para trabajar rápido con texto plano, notas técnicas y documentos mixtos (texto + Markdown + imágenes), sin forzarte a un formato complejo.

Autor: **686f6c61**

## Qué hace diferente a EasyTXT

El foco principal es la persistencia. Si cierras la app y vuelves otro día, las pestañas y el contenido siguen ahí. Incluso ante cierre forzado, EasyTXT mantiene borradores locales y restaura el estado automáticamente al volver a abrir. La idea es que nunca tengas que pensar en “guardar para no perder”.

Además, el editor mantiene un enfoque técnico: búsqueda y reemplazo con regex, operaciones rápidas sobre líneas, control de codificación y fin de línea, y una vista de proyecto para navegar texto en carpetas completas.

## Flujo de trabajo diario

EasyTXT abre con tus pestañas anteriores y te permite continuar sin fricción. Puedes crear notas rápidas sin nombre (`Untitled`) y renombrarlas al vuelo desde la propia pestaña. Cuando quieras formalizar una nota, la guardas como `TXT`, `MD` o `RTF`, y el documento conserva codificación y EOL configurables (`UTF-8`, `UTF-16`, `Latin-1`, `Windows-1252`, `LF`, `CRLF`).

Si trabajas con documentación o especificaciones, puedes editar en texto y, cuando lo necesites, activar `Split Preview` para ver Markdown y Mermaid renderizados sin abandonar el editor.

## IA integrada (OpenAI + Claude)

La IA está pensada como herramienta de edición, no como chat aislado. Tienes tres acciones directas:

- `AI Correct`: corrige ortografía, puntuación y claridad.
- `AI Expand`: desarrolla una idea manteniendo el contexto.
- `AI Idea`: genera ideas accionables en formato breve.

Cuando seleccionas texto, la acción se aplica solo a esa selección. Si no hay selección, se aplica al documento completo. El resultado se inserta directamente en el editor, sin popup recortado.

La configuración está en `Tools > AI Settings` (o botón `AI Settings` en la barra superior), con proveedor y modelo por separado para Claude y OpenAI.

## Seguridad de API keys

Las claves no se guardan en texto plano. EasyTXT utiliza Keychain local del sistema con política `WhenUnlockedThisDeviceOnly`. En la UI no se muestran claves existentes: solo puedes introducir una nueva para reemplazar o marcar borrado explícito.

También puedes usar variables de entorno:

```bash
export ANTHROPIC_API_KEY="tu_clave"
export ANTHROPIC_MODEL="claude-sonnet-4-5"
export OPENAI_API_KEY="tu_clave"
export OPENAI_MODEL="gpt-5"
```

## Personalización de edición

Puedes ajustar tema (`Light`/`Dark`), tamaño de fuente y fuente de trabajo monoespaciada. En ventanas anchas tienes selector directo en la barra superior; en ventana compacta puedes cambiarla desde `View > Working Font...` (`⌥⌘T`).

## Menús y herramientas

El menú está organizado para un uso rápido:

- `File`: creación/apertura/guardado y cierre de pestañas.
- `Edit`: búsqueda, reemplazo, operaciones de línea, snippets e inserción de imagen.
- `View`: modos de visualización, panel de proyecto, números de línea, tema y tipografía.
- `Tools`: acciones IA, ajustes IA, macros y recuperación de snapshot.

## Ejecutar en desarrollo

```bash
swift build
swift run
```

## Generar la app `.app`

```bash
./scripts/package_app.sh
```

La app empaquetada queda en:

`/Users/00b/Desktop/AppTxt/dist/EasyTXT.app`
