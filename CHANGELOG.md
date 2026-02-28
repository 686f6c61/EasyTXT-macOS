# Changelog

Todos los cambios relevantes de EasyTXT se documentan en este archivo.

## [1.0.1] - 2026-02-28

### Changed

- Versión de app actualizada a `1.0.1` en el bundle.
- Release de mantenimiento centrada en estabilidad de edición y flujo diario.

### Fixed

- Atajos de edición restaurados y enrutados al editor activo:
  - `Cmd+A` seleccionar todo
  - `Cmd+C` copiar
  - `Cmd+X` cortar
  - `Cmd+V` pegar
- Resultado de IA aplicado directamente en el documento completo/selección (sin popup recortado).
- Limpieza de salida IA para evitar bloques markdown envolventes en texto final.
- Persistencia reforzada para mantener contenido y pestañas de forma fiable al reabrir.

## [0.1.0] - 2026-02-28

### Added

- Base del editor macOS con arquitectura por pestañas.
- Restauración de sesión y recuperación de borradores locales.
- Persistencia siempre activa (autosave en segundo plano + flush al perder foco/cerrar app).
- Soporte de formatos `TXT`, `Markdown` y `RTF`.
- Inserción/pegado de imágenes y redimensionado de imagen seleccionada.
- Guardado de assets de imagen al exportar Markdown.
- Vista `Text` y `Split Preview` con render de Markdown + Mermaid.
- Búsqueda/reemplazo local (incluyendo regex) y búsqueda en proyecto.
- Acciones de edición rápida: duplicar línea, mover línea, comentar, snippets y macros.
- Historial local por snapshots y restauración del último snapshot.
- Tema claro/oscuro, tamaño de fuente y selector de fuente de trabajo.
- Integración IA con OpenAI y Anthropic:
  - `AI Correct`, `AI Expand`, `AI Idea`
  - selector de proveedor/modelo
  - guardado de API keys en Keychain.

### Changed

- Rediseño de `AI Settings` para separar claramente proveedor, modelo y claves.
- Actualización del catálogo de modelos IA a opciones actuales y usables por proveedor.
- Aplicación de salida IA directamente en editor (sin popup intermedio).
- Normalización de respuesta IA para evitar bloques markdown envolventes.
- Mejoras de barra superior para comportamiento responsive.

### Fixed

- Cierre de pestañas mediante `x` en tabs.
- Problemas de alineación/compresión de iconos en tamaños de ventana reducidos.
- Fallos de layout en el modal de `AI Settings`.
- Casos de persistencia perdidos cuando la app no cerraba de forma limpia.
