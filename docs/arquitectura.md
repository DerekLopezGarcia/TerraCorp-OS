# Arquitectura

## Cadena de arranque

```
EEPROM (eeprom/init.lua)          BIOS de OpenComputers (sin EEPROM propia)
        │                                   │
        └──────────────┬────────────────────┘
                       ▼
        <volumen>/init.lua   ← encuentra el volumen con /boot/kernel.lua
                       ▼
        <volumen>/boot/kernel.lua
        1. monta el volumen como vfs (componente filesystem)
        2. carga módulos tc.* desde /lib/tc
        3. lee /etc/terracorp.cfg y pinta el splash
        4. crea el escritorio y carga apps.*
        5. bucle de señales (computer.pullSignal)
```

El BIOS de OpenComputers compila y ejecuta `/init.lua` del volumen de arranque. Por eso `src/` es el
volumen: `init.lua` en la raíz y el kernel en `/boot`.

La EEPROM solo aporta dos cosas: elige un volumen que contenga `/boot/kernel.lua` y le cede el control.
Si no hay EEPROM propia, el BIOS arranca el volumen directamente.

## Capas

| Capa | Fichero | Responsabilidad |
|---|---|---|
| Entrada | `src/init.lua` | localizar volumen, leer el kernel, enlazar GPU |
| Kernel | `boot/kernel.lua` | vfs, cargador de módulos, servicios, bucle de señales |
| Base | `lib/tc/{version,util,text}` | identidad, utilidades, UTF-8 por puntos de código |
| Servicios | `lib/tc/{log,config,theme}` | registro, preferencias, paleta y glifos |
| Presentación | `lib/tc/{gfx,ui}` | framebuffer con doble búfer, ventanas y eventos |
| Apps | `apps/*.lua` | interfaz y lógica de cada módulo |

No se usa el `require`, `event`, `fs` ni `shell` de OpenOS. El kernel instala su propio cargador:

```lua
require("tc.theme")  -- -> /lib/tc/theme.lua
require("apps.files") -- -> /apps/files.lua
```

Cada módulo se compila con `load(source, "=/ruta", "t", env)` en un entorno con las librerías estándar,
`component`, `computer` y el `require` del kernel. La caché es por identificador.

## Sistema de ficheros (vfs)

`makeVfs(volume)` envuelve el componente `filesystem` del volumen de arranque y normaliza errores:

```lua
vfs.read(path) -> string | nil, motivo
vfs.write(path, data) / vfs.append(path, data)
vfs.exists(path) / vfs.isDirectory(path) / vfs.size(path) -> bytes
vfs.list(path) -> lista ordenada | nil, motivo
vfs.ensureDir(path) / vfs.remove(path) / vfs.rename(from, to)
vfs.space() -> usado, total (KB; el componente los da en bytes)
```

Toda llamada va protegida con `pcall`: un disco desconectado devuelve error, no rompe el OS.
`vfs.list` acepta la tabla que devuelve el componente (`String[]`) y, por compatibilidad, un iterador.

## Framebuffer y volcado

`gfx` mantiene tres matrices planas (`ch`, `fg`, `bg`) y su copia anterior (`pch`, `pfg`, `pbg`).
`flush()` recorre por filas y agrupa celdas contiguas con el mismo par color de fondo/texto, enviando
un único `gpu.set` por tramo. Solo se escriben celdas distintas del frame anterior.

Consecuencias:

- Redibujar el escritorio cuesta proporcional a lo que cambia, no a la pantalla completa.
- Un cambio de resolución o de GPU crea un framebuffer nuevo (`gfx:resize()` reinicia la caché de
  celdas), así que la siguiente composición repinta todo.
- El coste de memoria es de tres tablas de `w*h` (118x44 ≈ 15 500 celdas).

Las apps nunca escriben en el framebuffer raíz: reciben `ctx.view`, una subvista con origen y recorte.
Sus coordenadas son locales (`1..w`, `1..h`), lo que permite mover o redimensionar la ventana sin tocar
la app.

## Ventanas y eventos

`ui` mantiene la lista de ventanas con `z` incremental, foco y un `dragging` para el arrastre. El
reparto de eventos:

| Señal | Destino |
|---|---|
| `touch` | dock, barra de título (cerrar/minimizar/arrastrar) o contenido |
| `drag` / `drop` | arrastre de ventana o reenvío a la app |
| `scroll` | reenvío a la app bajo el cursor |
| `key_down` | atajos globales (`Esc`, `F1`–`F5`) o app con foco |
| `screen_resized` | `kernel:rebindScreen()` |
| `interrupted` | se ignora (el OS no debe caerse con Ctrl+Alt+C) |

Cada llamada a la app va dentro de `pcall`; un error se registra y se pinta en la ventana sin tumbar
el escritorio.

## Contrato de aplicación

```lua
-- /apps/ejemplo.lua
local app = {}
app.id = "ejemplo"
app.title = "Ejemplo"
app.short = "Ejemplo"      -- etiqueta del dock
app.order = 6              -- posición en el dock

function app.create(ctx)
  local self = setmetatable({}, { __index = app })
  self.contador = 0
  return self
end

function app:draw(ctx)
  ctx.view:clear(" ", ctx.colors.text, ctx.colors.deep)
  ctx.view:put(1, 1, "Hola desde " .. ctx.kernel.hostname, ctx.colors.accent, ctx.colors.deep)
end

function app:handle(ctx, name, a, b, c)
  if name == "key" and a == " " then
    self.contador = self.contador + 1
    return true            -- true = repintar
  end
  return false
end

function app:tick(ctx)   -- una vez por segundo
  return false
end

function app:close()
end

return app
```

`ctx` incluye: `ui`, `kernel`, `theme`, `colors`, `glyphs`, `log`, `config`, `version`, `util`, `text`,
`win`, `x`, `y`, `w`, `h` y `view`. El contexto se reconstruye en cada llamada: no guardar `ctx.view`
entre frames.

Para registrarla, añade su id a `APP_IDS` en `boot/kernel.lua`.

## Energía y apagado

`kernel:energyPercent()` devuelve 100 si el ordenador no reporta energía (por ejemplo, alimentado por
un adaptador creativo). `kernel:poweroff(reboot)` pinta el aviso, espera 0,3 s y llama a
`computer.shutdown(reboot)`; es el único punto de apagado.

## Límites conocidos

- Un carácter = una celda; sin ancho doble ni emoji.
- Sin red todavía: no hay mensajería por módem.
- Sin multiusuario ni bloqueo de sesión.
- Las ventanas no se redimensionan con el ratón (solo se mueven).
- El historial de la consola y el registro en memoria se pierden al reiniciar; solo se persisten avisos
  y errores en `/var/log/tc.log`.
