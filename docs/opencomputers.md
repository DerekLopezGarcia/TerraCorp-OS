# Notas de OpenComputers

Hechos verificados contra el código de OpenComputers (`master-MC1.12`) antes de escribir el OS. Son la
base de las decisiones del proyecto; si algo cambia, actualizar este documento.

## Arranque

- El BIOS (`lua/bios.lua`) enlaza la primera GPU a la primera pantalla y ejecuta `/init.lua` del volumen
  de arranque con `load(buffer, "=init")`.
- El volumen de arranque puede ser cualquier componente `filesystem`, no solo un disquete.
- `computer.getBootAddress()` / `computer.setBootAddress(address)` permiten fijar el volumen.
- En 1.7.x **esas dos funciones no existen en el entorno de la EEPROM**: las define `bios.lua` al
  arrancar, guardando el volumen en la propia EEPROM (`eeprom.getData`/`setData`). Un gestor de arranque
  propio debe crearlas o falla con `bios:NN: attempt to call a nil value (field 'getBootAddress')`.
- En el entorno del BIOS solo están garantizados `component`, `computer`, `load` y las librerías
  estándar de Lua. **No** hay `require`, `event`, `fs` ni `shell`: son de OpenOS.
- `computer.beep(frequency, duration)` está disponible antes de cargar OpenOS.

Conclusión: `src/init.lua` no puede asumir OpenOS y debe leer el kernel con `component.invoke(addr,
"open"/"read"/"close")`.

## Señales

- La API cruda es `computer.pullSignal(timeout)`, no `event.pull`. Devuelve la señal como valores
  múltiples; puede devolver `nil` por timeout.
- Señales relevantes: `key_down(addr, char, code)`, `key_up`, `touch(addr, x, y, button, player)`,
  `drag`, `drop`, `scroll(addr, x, y, direction, player)`, `screen_resized(addr, w, h)`,
  `component_added`, `component_removed`, `modem_message`, `interrupted`, `shutdown`.
- `interrupted` es lo que emite Ctrl+Alt+C en OpenOS; el OS lo ignora a propósito.
- Las coordenadas de `touch` son de la pantalla, con origen 1,1 arriba a la izquierda.

## Teclado

Códigos (subconjunto de `openos/lib/keyboard.lua`), usados en `lib/tc/keys.lua`:

| Tecla | Código | Tecla | Código |
|---|---|---|---|
| Esc | `0x01` | Retroceso | `0x0E` |
| Tab | `0x0F` | Enter | `0x1C` |
| Espacio | `0x39` | Inicio | `0xC7` |
| Flecha arriba | `0xC8` | RePág | `0xC9` |
| Flecha izquierda | `0xCB` | Flecha derecha | `0xCD` |
| Fin | `0xCF` | Flecha abajo | `0xD0` |
| AvPág | `0xD1` | Suprimir | `0xD3` |
| F1–F10 | `0x3B`–`0x44` | | |

`key_down` entrega `char` solo para teclas imprimibles; para flechas y funciones hay que usar `code`.
Los eventos de modificadores (Ctrl/Alt) llegan como `key_down`/`key_up` de sus propios códigos, pero
el OS no depende de ellos para los atajos.

## Componentes

- `component.list(kind)` devuelve un iterador `(address, kind)`: `component.list("gpu")()` obtiene la
  primera GPU.
- `component.proxy(address)` devuelve una tabla con los métodos del componente; es mucho más rápido que
  `component.invoke` por celda y es lo que usa `gfx`.
- `component.invoke(address, method, ...)` es la vía sin proxy; se usa en el arranque, antes de tener
  servicios.
- `computer.energy()` devuelve `stored, maximum`; puede fallar si el ordenador no tiene bloque de
  energía. Siempre con `pcall`.
- `computer.totalMemory()` / `freeMemory()` en bytes; `filesystem.spaceUsed()` / `spaceTotal()` también en
  bytes (no existe `filesystem.space()`). `vfs.space()` del kernel convierte a kilobytes.
- `filesystem.list(path)` devuelve una **tabla 1..n** con los nombres, no un iterador. OpenOS la envuelve
  en un iterador en `lib/filesystem.lua`; el kernel de TerraCorp trabaja con la tabla directamente.
- Los handles de `filesystem` (`open` → `read`/`write`/`close`) se pasan a `component.invoke` como
  valores opacos. Un `read` al final del fichero devuelve `nil` sin motivo.

## GPU

- `gpu.setResolution(w, h)` cambia la resolución virtual; el máximo lo da `gpu.maxResolution()`.
- `gpu.set(x, y, text)` escribe una cadena; `gpu.fill(x, y, w, h, ch)` rellena.
- Los colores son 16 índices fijos (paleta de Minecraft), no RGB.
- `gpu.bind(screen)` asocia una GPU a una pantalla; el BIOS ya lo hace, pero se repite al arrancar.
- **Valor de retorno** (verificado en `GraphicsCard.scala`, rama `master-MC1.12`): `gpu.set`, `gpu.fill`
  y `gpu.copy` devuelven `true` si escriben y `nil, "not enough energy"` si la GPU no tiene energía.
  `gpu.setBackground`/`gpu.setForeground` devuelven el color anterior. Una escritura rechazada no se
  puede dar por pintada: el volcado por diferencias tiene que reintentarla o deja huecos permanentes.
  `npm run test:faults` lo comprueba comparando la pantalla con y sin fallos inyectados.
- `gpu.setBackground(color, isPaletteIndex)` y `gpu.setForeground(color, isPaletteIndex)` interpretan
  `color` como RGB de 24 bits si `isPaletteIndex` es `nil` o `false`; para índices 0..15 hay que pasar
  `true`. La paleta editable de una pantalla T3 empieza en escala de grises, así que TerraCorp inicializa
  los 16 índices con la paleta clásica de OpenComputers cuando el hardware permite editarla. Sin esto,
  los índices 0..15 se interpretarían como RGB muy oscuros y el escritorio sería casi negro.

## Trampas que afectan al diseño

1. **Ancho de carácter**: OpenComputers dibuja una celda por punto de código. Los caracteres de doble
   ancho (CJK, emoji) rompen la alineación; no se admiten. Los acentos ocupan una celda.
2. **`#cadena` cuenta bytes**, no caracteres. Para anchos se usa `lib/tc/text.lua`.
3. **`require` no existe fuera de OpenOS**. El kernel compila sus módulos con `load` y su propio
   resolvedor.
4. **`io.open` no es fiable como API del OS**: el volumen se lee con el componente `filesystem`, que
   funciona con o sin OpenOS montado.
5. **`os.sleep` existe en OpenOS**, no en el Lua del BIOS; se usa siempre con `pcall`.
6. **Una señal con `nil` en medio** (por ejemplo `key_down` sin `char`) exige `table.pack`/`unpack` con
   límites explícitos; `{...}` y `#` no son seguros.
7. **Redibujar todo cada frame** es caro en tier 2; de ahí el volcado por diferencias.
