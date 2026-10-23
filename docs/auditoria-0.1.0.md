# Auditoría 0.1.0 "Foundry"

Auditoría del esqueleto de TerraCorp OS: código, arnés de verificación y documentación. Se hizo
leyendo el código fuente de OpenComputers (`master-MC1.12`) para contrastar cada API usada, y
ejecutando el OS contra componentes falsos **fieles** a esa API.

Fecha: 2026-10-23. Alcance: `src/`, `eeprom/`, `tools/`, `docs/`.

## Veredicto

La arquitectura se sostiene (kernel mínimo, vfs propio, framebuffer con volcado por diferencias,
contrato de app claro). El problema estaba en la verificación: el arnés inventaba la API de
OpenComputers, así que los gates salían verdes con tres fallos que rompen el producto en partida.

## Hallazgos

| # | Severidad | Hallazgo | Estado |
|---|---|---|---|
| C1 | Crítico | `vfs.list` iteraba la tabla que devuelve el componente: Ficheros y `ls` mostraban "no se pudo listar" | Corregido |
| C2 | Crítico | `vfs.space()` llamaba a un método inexistente y mezclaba bytes con KB: tarjeta de almacenamiento siempre vacía | Corregido |
| C3 | Crítico | El arnés devolvía un iterador en `list`, definía `space()` y permitía escribir en directorios inexistentes | Corregido |
| A1 | Alto | `screen_resized` llamaba a `kernel.rebindScreen` sin `self`: error y escritorio corrupto al cambiar resolución | Corregido |
| A2 | Alto | `view:box` no recortaba y el panel dibujaba la 2.ª columna fuera de la ventana por debajo de 62 columnas | Corregido |
| A3 | Alto | El instalador daba la EEPROM por grabada aunque `component.invoke` devolviera error | Corregido |
| M1 | Medio | `/etc` no se creaba al arrancar: los ajustes no persistían en instalaciones manuales | Corregido |
| M2 | Medio | Un fallo de render dejaba `dirty = false` (pantalla congelada) y escribía en disco por frame | Corregido |
| M3 | Medio | `files:draw` hacía una llamada `size` por fila y frame | Corregido |
| M4 | Medio | Hitboxes de Ajustes descuadradas: los botones se solapaban 2 columnas | Corregido |
| M5 | — | `install.lua` comprobaba `proxy.type`: **verificado**, el proxy real expone `address`, `type`, `slot` y `fields` | Sin cambio |
| B1 | Bajo | Código muerto en `util`, `text`, `log`, `keys`, `gfx`, `ui` | Corregido |
| B2 | Bajo | `console`: scroll sin tope, `open` sin `trim`, relleno de `ls` contado en bytes | Corregido |
| B3 | Bajo | `vfs.read` no cortaba una lectura que devolviera cadena vacía (riesgo de bucle) | Corregido |
| B4 | Bajo | URL del repositorio en minúsculas en Acerca de | Corregido |
| B5 | Bajo | `docs/arquitectura.md` documentaba mal `vfs.space` y recomendaba un `gfx:invalidate` que no se usaba | Corregido |

## Contratos verificados contra OpenComputers

- `filesystem.list(path)` devuelve una **tabla 1..n** (`String[]` en `FileSystem.scala`), no un
  iterador. OpenOS la envuelve en un iterador en `lib/filesystem.lua`.
- El espacio se lee con `spaceUsed()` y `spaceTotal()`, **en bytes**. No existe `space()`.
- `component.proxy(address)` devuelve `{ address, type, slot, fields }` más los métodos.
- `component.invoke` devuelve `nil, motivo` en los fallos: `pcall` no los detecta.
- `computer.callBudgets` por defecto: `0.5`, `1.0` y `1.5` por tick según CPU.
- Un `read` al final del fichero devuelve `nil`, sin motivo.

## Cómo se verificó

El arnés (`tools/harness/`) usa ahora componentes falsos fieles: `list` devuelve tabla,
`spaceUsed`/`spaceTotal` en bytes y `open` en escritura exige que exista el directorio padre.
`npm run sim:oc` ejecuta los cuatro escenarios con comprobaciones de contrato y falla si el OS deja
de hablar esa API.

Gates ejecutados sobre el árbol corregido:

| Gate | Resultado |
|---|---|
| `npm run check` | 21 ficheros, 0 errores |
| `npm run sim` | ok, 859 `gpu.set`, sin errores |
| `npm run sim:oc` | 4 escenarios (dashboard, console, files, settings), sin errores |
| Contraste con el kernel de `HEAD` | `files`: 1 problema · `dashboard`: 2 problemas (el gate los detecta) |
| Config sin `/etc` | con `HEAD`: "no such file or directory"; corregido: `accent` persistido |
| Render con GPU rota (120 iteraciones) | 5 líneas de registro (antes 31) y "render recuperado tras 39 fallos" |
| Llamadas `size` en el escenario Ficheros | 41 → 16 |
| Hitboxes de Ajustes | clic en el valor cicla el acento; el hueco entre botones no dispara; "Restablecer" vuelve a `cyan` |
| `ls /` | 6 entradas con tamaños alineados |
| `open` con espacios | "open: falta el id de la aplicación" |

## Decisiones

- `vfs.space()` sigue devolviendo **kilobytes** (contrato que ya usaban `humanSize`, el panel y el
  instalador) y convierte desde los bytes del componente en un solo sitio.
- El registro de errores de render se limita a uno por arranque de la racha y luego uno cada 30
  intentos: el objetivo es no inundar el disco, no ocultar el fallo.
- `theme.palette` se mantiene exportado como mapa de la paleta; el resto del código muerto se retiró.

## Fuera del alcance

- Prueba en partida (F0): sigue pendiente y es la que valida energía, GPU y disco reales.
- Fases F1–F6 del roadmap: este trabajo no adelanta ninguna.
