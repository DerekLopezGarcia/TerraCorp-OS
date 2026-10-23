# MineOS — referencia de arquitectura

> Estudio del código real de [IgorTimofeev/MineOS](https://github.com/IgorTimofeev/MineOS) (MIT)
> clonado en `E:\Workspace\mineos`, para decidir qué copiar y qué no en TerraCorp OS.
>
> Fecha de estudio: 2026-10-23. Commit: `main` (clone `--depth 1`).

## Resumen

MineOS es una capa gráfica + gestor de escritorio sobre OpenOS/OpenComputers. No es un kernel:
reutiliza el ecosistema de OpenComputers y añade su propio `require`, su librería de pantalla con
doble búfer y una librería GUI de widgets. Su rasgo más importante para nosotros: **nunca deja la
pantalla en negro sin explicación** — cada nivel de ejecución está envuelto en `xpcall` y, al fallar,
redibuja el escritorio y muestra una ventana de error modal.

## 1. Arranque (`OS.lua`, 234 líneas)

```lua
local bootFilesystemProxy = component.proxy(component.invoke(component.list("eeprom")(), "getData"))
```

- Obtiene el volumen de arranque **desde la EEPROM** (`getData` = dirección del filesystem).
- Define su propio `dofile(path)` que lee el fichero por trozos de `math.huge` y hace `load(data, "=" .. path)`.
- Define su propio `require` con `package.paths = { ["/Libraries/"] = true }`, cache en
  `package.loaded`, detección de recursión en `package.loading`, y tolerancia a sistemas de ficheros
  no case-sensitive (`unicode.lower` + variantes con mayúscula inicial).
- Pinta una barra de progreso mientras carga **14 librerías** (`UIRequire`).

Orden de carga: `Bit32 → Paths → Event → Filesystem → Component → Keyboard → Color → Text → Number →
Image → Screen → GUI → System → Network`.

Al final rellena `package.loaded` con `bit32`, `computer`, `component`, `unicode` "for OpenOS bitches"
— capa de compatibilidad para programas de OpenOS.

## 2. Bucle principal y recuperación de errores

```lua
system.authorize()  -- login (usuarios + contraseña)

while true do
  local success, path, line, traceback = system.call(workspace.start, workspace, 0)
  if success then break
  else
    system.updateWorkspace(); system.updateDesktop(); workspace:draw()
    system.error(path, line, traceback)
    workspace:draw()
  end
end
```

**Este es el patrón clave.** El bucle de eventos entero está dentro de `xpcall`. Si algo revienta:

1. se reconstruye el escritorio,
2. se dibuja,
3. se superpone la ventana de error con el código fuente y la línea resaltada,
4. se vuelve a dibujar.

La pantalla nunca se queda negra: siempre hay escritorio + ventana de error.

### `system.call(method, ...)` — `System.lua:306`

```lua
local xpcallSuccess, xpcallReason = xpcall(launchMethod, tracebackMethod)
...
if not xpcallSuccess and not xpcallReason.traceback:match("^table")
   and not xpcallReason.traceback:match("interrupted") then
  return false, xpcallReason.path, xpcallReason.line, xpcallReason.traceback
end
return true
```

- El handler de `xpcall` parsea `debug.traceback()` para extraer **fichero y línea**.
- Ignora errores con `"interrupted"` (Ctrl+Alt+C) y errores que son tablas (se usan para control de flujo).

### `system.error(path, line, traceback)` — `System.lua:2792`

Ventana modal con:
- `GUI.codeView` a la izquierda con el fichero y la línea del error resaltada en `0xFF4444`,
- `GUI.textBox` a la derecha con el stacktrace,
- botón *Close* + `Enter` para cerrar,
- dos `computer.beep(1900, 0.05)`.

### `system.execute(path, ...)` — `System.lua:2857`

Para lanzar apps sueltas: guarda resolución, `loadfile`, `system.call`, restaura resolución, y si falla
→ `system.error`. Es decir, **el mismo contrato de recuperación a nivel de app**.

## 3. Modelo de aplicación

Cada app es un **directorio** `Nombre.app/`:

```
Console.app/
  Main.lua          -- se ejecuta al abrir; devuelve la ventana
  Icon.pic          -- icono (formato propio de Image.lua)
  Localizations/    -- opcional: <Idioma>.lang
```

`Main.lua` típico (`Console.app`, 86 líneas):

```lua
local workspace, window, menu = system.addWindow(GUI.filledWindow(1, 1, 82, 28, 0x000000))
...
window.onResize = function(newWidth, newHeight) ... end
window.onResize(window.width, window.height)
return window
```

- La app **no tiene bucle propio**: registra `window.eventHandler` y devuelve la ventana.
- `system.addWindow(window)` la integra en el escritorio, la registra en el Dock y le añade handlers.
- Hay 38 apps en `Applications/` (Finder, Console, Settings, MineCode IDE, Paint, IRC, VK, …).

**Contraste con TerraCorp**: nuestro contrato es `{ id, title, short, order, create(ctx) }` +
instancia `{ draw, handle, tick, close }` con módulos sueltos en `/apps/*.lua` y `APP_IDS` fijo en
`kernel.lua`. MineOS descubre apps recorriendo el directorio.

## 4. Pantalla (`Libraries/Screen.lua`, 1085 líneas)

Estado por celda en tres arrays paralelos: `currentFrameBackgrounds`, `currentFrameForegrounds`,
`currentFrameChars` + los equivalentes `newFrame*`. Índice `= width * (y-1) + x`.

### `update(force)` — línea 824

1. Recorre solo el área de dibujo (`drawLimit`).
2. Compara `current` vs `new`; si cambió (o `force`):
   - copia el valor nuevo a `current`,
   - **agrupa caracteres consecutivos con el mismo `char`** (`equalChars`) para mandarlos en un solo
     `gpu.set` — con soporte de caracteres de doble ancho (`unicodeWlen`).
3. Agrupa los cambios en `changes[background][foreground] = { x1,y1,str, x2,y2,str, ... }`.
4. Vuelca:

```lua
for background, foregrounds in pairs(changes) do
  componentInvoke(GPUAddress, "setBackground", background)
  for foreground, pixels in pairs(foregrounds) do
    if currentForeground ~= foreground then
      componentInvoke(GPUAddress, "setForeground", foreground); currentForeground = foreground
    end
    for i = 1, #pixels, 3 do
      componentInvoke(GPUAddress, "set", pixels[i], pixels[i+1], pixels[i+2])
    end
  end
end
```

**Diferencia con TerraCorp**: nosotros agrupamos por *tramos contiguos en la misma fila* con el mismo
par fg/bg (`gfx:flush`). MineOS agrupa **por par de color en toda la pantalla** y además une
caracteres iguales dentro del tramo. Para un escritorio con muchos colores distintos, el enfoque de
MineOS reduce llamadas; para texto uniforme, el nuestro es más simple y suficiente.

MineOS **no comprueba el valor de retorno** de `setBackground`/`setForeground`/`set` (usa
`componentInvoke` a pelo). TerraCorp sí lo comprueba y reintenta el tramo — eso es una mejora nuestra
para el caso "GPU sin energía", pero introduce el riesgo opuesto: si un driver devuelve `nil` en éxito,
reintentaríamos para siempre. **Pendiente de verificar contra el código real de OC.**

## 5. Eventos (`Libraries/Event.lua`, 140 líneas)

- `event.addHandler(callback, interval, times)` → handlers con `nextTriggerTime`.
- `event.pull(timeout)` calcula el mínimo `nextTriggerTime` y llama a `computer.pullSignal` con ese
  timeout; después ejecuta los handlers cuyo tiempo venció.
- `event.skip(signalType)` descarta la señal actual después de procesar handlers (se usa para
  sintetizar `double_touch` desde dos `touch`).
- **Interrupción**: Ctrl+Alt+C (códigos `29`, `46`, `56`) llama a `event.interruptingFunction`, que por
  defecto hace `error("interrupted", 0)`. Esto es lo que permite matar un script colgado.
- `event.sleep(t)` es *busy-wait* sobre `event.pull`, no `os.sleep`.

TerraCorp usa `computer.pullSignal(0.2)` directo en `kernel:loop` y no tiene interrupción por teclado.

## 6. Teclado (`Libraries/Keyboard.lua`, 117 líneas)

Solo tabla de códigos + estado de teclas pulsadas, mantenido por un handler de `key_down`/`key_up`
registrado en `Event`. Helpers: `isKeyDown`, `isControl`, `isAltDown`, `isControlDown`, `isShiftDown`,
`isCommandDown`.

Nuestro `tc.keys` cubre un subconjunto equivalente (Esc, Back, Tab, Enter, flechas, PageUp/Down,
Home/End/Delete, F1–F10) — suficiente.

## 7. Ventanas y bucle de la GUI (`GUI.lua`, 162 KB)

`GUI.workspace()` devuelve un contenedor con:

- `draw` → `containerDraw(self)` + `screen.update()`
- `start` → `workspaceStart` (bucle de eventos)
- `stop` → `needClose = true`

`workspaceStart`:

```lua
repeat
  e1..e32 = event.pull(workspace.animations and 0 or workspace.eventPullTimeout)
  isScreenEvent = e1 == "touch" or "drag" or "drop" or "scroll" or "double_touch"
  if isScreenEvent then roundedX, roundedY = ceil(e3), ceil(e4) end
  processObject(workspace, ...)   -- recorrido recursivo del árbol
  -- animaciones
until workspace.needClose
```

`processObject` recorre los hijos **de atrás adelante** (último dibujado = primero en recibir el
evento), intersecta los bounds del contenedor con los del hijo, y para eventos de pantalla **corta el
recorrido** cuando un objeto lo consume (`blockScreenEvents` / `govno`). `workspace.capturedObject`
implementa el *capture* de ratón para arrastrar.

**Diferencia con TerraCorp**: nuestro `ui` es plano (lista de ventanas + z-order) con hit-test por
rectángulo. No tenemos captura de ratón ni widgets anidados. Para lo que hacemos, es suficiente y
mucho más simple de auditar.

## 8. Qué copiar y qué no

### Copiar (alto valor, bajo coste)

1. **Recuperación a prueba de pantalla negra** (prioridad 1).
   - Envolver el frame completo en un `xpcall` que, al fallar, pinte un panel de error *encima* del
     último frame bueno en vez de limpiar a negro.
   - Hoy `ui:render` hace `gfx:clear(bg)` **antes** de dibujar. Si algo revienta después, el kernel
     llama a `emergency()`, pero el framebuffer ya está en negro y depende de que `flush()` funcione.
   - Mejor orden: dibujar en un búfer, y solo si el frame se completó, volcarlo. Si falló, volcar el
     frame anterior + banda de error.

2. **Trazabilidad de errores por app**: ya tenemos `pcall` en `drawWindow`/`forward`/`tick` y log a
   `/var/log/tc.log`. Falta **mostrarlo en pantalla** dentro de la ventana (hoy solo `notify`).

3. **`onResize` por app**: MineOS lo usa para recalcular layouts. Nuestro `ctx` se reconstruye por
   frame, así que no hace falta, pero conviene que las apps no cacheen `ctx.w`/`ctx.h` entre frames.

4. **Descubrimiento de apps** (opcional): escanear `/apps/*.lua` en vez de `APP_IDS` fijo. Bajo coste,
   pero cambia el contrato de arranque: posponer hasta cerrar el bug de pantalla negra.

### No copiar

- `GUI.lua` (162 KB de widgets): no lo necesitamos; nuestro `gfx` + `ui` cubren el caso.
- Sistema de usuarios con contraseña: fuera de alcance.
- Mercado de apps, localizaciones, temas, fondos animados: no aportan al objetivo.
- Compatibilidad OpenOS (`package.loaded.computer = ...`): TerraCorp arranca limpio y no depende de
  OpenOS; no la necesitamos.

## 9. Diferencias estructurales

| Aspecto | MineOS | TerraCorp OS |
|---|---|---|
| Arranque | EEPROM → filesystem proxy → `OS.lua` | EEPROM → `init.lua` → `kernel.start` |
| `require` | propio, `/Libraries/` | propio, `/lib/tc/` y `/apps/` |
| Pantalla | doble búfer, agrupación por color global | doble búfer, agrupación por tramos de fila |
| Bucle | `event.pull` + árbol de objetos | `computer.pullSignal(0.2)` + lista de ventanas |
| Apps | directorio `.app` + `Main.lua` | módulo `.lua` + `APP_IDS` |
| Errores | `xpcall` global + ventana modal con código | `pcall` por app + `emergency()` en GPU cruda |
| Interrupción | Ctrl+Alt+C | ninguna |
| Tamaño | ~111 ficheros Lua, GUI 162 KB | 15 ficheros Lua, ~85 KB total |

## 10. Preguntas abiertas — resueltas

- ¿`gpu.set()` devuelve `true` o `nil` en éxito? **Resuelto** en `GraphicsCard.scala` (rama
  `master-MC1.12`): devuelve `true`, y `nil, "not enough energy"` si la GPU no tiene energía. `fill` y
  `copy` igual. `gfx:flush` sólo da el tramo por pintado con `true`.
- ¿`gpu.setBackground()` devuelve el color anterior? **Resuelto**: sí, el color previo. Si no hay
  pantalla enlazada devuelve `nil`, así que `flush` reintenta el tramo.
- ¿Qué tamaño de pantalla real tiene el nodo del usuario? **Ya no importa**: el escritorio adopta la
  resolución que tenga la pantalla (ver `npm run test:screens`, de 40x16 a 160x50).

## Referencias

- Repo: `https://github.com/IgorTimofeev/MineOS` (MIT)
- Wiki GUI: `https://github.com/IgorTimofeev/MineOS/wiki/GUI-API`
- Librerías del autor: `GUI`, `DoubleBuffering`, `Image`, `Color`
- Copia local: `E:\Workspace\mineos`

## Notas de actualización

- 2026-10-23: estudio inicial completo (OS.lua, System.lua, Screen.lua, Event.lua, Keyboard.lua,
  GUI.lua, modelo de apps, instalador y EFI).
