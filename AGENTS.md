# TerraCorp — contexto para agentes

> Proyecto **personal**. No usar la memoria de neXacom: el contexto vive aquí y en este repo.

## Descripción

TerraCorp OS: sistema operativo con escritorio en Lua para OpenComputers, implementado dentro del
modpack **Supersymmetry** (Minecraft 1.12.2 + Forge). Susy-Core es el coremod del pack, no el pack.
El OS se instala en los ordenadores del jugador; no modifica el pack.

## Referencia

- GitHub (personal): `https://github.com/dereklopezagarcia/TerraCorp-OS`
- Rama base: `main`
- Entorno objetivo: Supersymmetry · `https://github.com/SymmetricDevs/Supersymmetry`
  (coremod `https://github.com/SymmetricDevs/Susy-Core`, GPLv3)
- Inspiración: MineOS · `https://github.com/IgorTimofeev/MineOS` (MIT, **no** es un fork)

## Datos estables

- Runtime: **Lua 5.3** (el de OpenComputers). No hay build.
- OpenComputers: 1.7.x probado a nivel de API; objetivo 1.8.x.
- Pantalla mínima 80x25; resolución objetivo 118x44.
- Idioma del producto y de los docs: español.
- Licencia: MIT.
- Verificación local: `npm run check` y `npm run sim` (Node 20+, fengari como devDependency).

## Estructura

```
src/                  volumen de arranque
  init.lua            entrada (BIOS/EEPROM) -> kernel
  boot/kernel.lua     vfs, carga de módulos, servicios, bucle de señales
  lib/tc/*.lua        version, util, text, log, config, theme, gfx, ui, keys
  apps/*.lua          dashboard, files, console, settings, about
eeprom/init.lua       gestor de arranque para la EEPROM
tools/install.lua     instalador bajo OpenOS
tools/fetch.lua       descargador para OpenOS (sigue tools/manifest.txt)
tools/make-manifest.js genera tools/manifest.txt desde el árbol
tools/check.lua       comprobador de sintaxis bajo OpenOS
tools/spike-rc.lua    banco de pruebas del enlace Redstone Control (spike)
tools/harness/        arnés Node (fengari) + comprobador
docs/                 arquitectura, opencomputers, roadmap, distribuido, larga-distancia
```

## Comandos

```bash
npm install        # solo para el arnés local
npm run check      # sintaxis de todos los .lua (Lua 5.3) + manifiesto en sync
npm run manifest   # regenera tools/manifest.txt (lo que descarga fetch.lua)
npm run sim        # ejecuta el OS con componentes falsos y vuelca pantalla
npm run sim:oc     # gate estricto: 4 escenarios con la API real de OpenComputers
npm run test:install # detección de volumen y copia del instalador (OpenOS simulado)
npm run test:boot  # gestor de arranque de la EEPROM (sandbox 1.7.x y 1.8+)
```

En el juego: `wget .../tools/fetch.lua /tmp/fetch.lua` → `lua /tmp/fetch.lua` →
`cd /home/TerraCorp-OS/tools && ./install.lua /home/TerraCorp-OS [dir] [--eeprom] [--yes] [--list]`.
Sin `dir` detecta un volumen escribible, distinto del disco de OpenOS y vacío o ya TerraCorp; nunca
uno con datos ajenos. Ojo: `install` a secas es el instalador de OpenOS.

## Convenciones

- **Núcleo mínimo**: el OS debe arrancar y ser útil en un solo nodo, sin red y con 1 MB. Nada entra en
  el núcleo si puede ser un servicio o una app opcional.
- Fase actual y criterios de salida: `docs/roadmap.md`. Modelo distribuido y límites del mod:
  `docs/distribuido.md`. No adelantar fases.
- Cada módulo devuelve una tabla; se carga con `require("tc.x")` / `require("apps.x")` **del kernel**,
  nunca con el `require` de OpenOS.
- Rutas de módulos: `tc.*` → `/lib/tc/*.lua`, `apps.*` → `/apps/*.lua`.
- App = `{ id, title, short, order, create(ctx) }`; instancia = `{ draw(ctx), handle(ctx, name, a, b, c),
  tick(ctx), close(ctx) }`. La UI llama con `:` (self = instancia).
- Dibujo solo a través de `ctx.view` (subvista con recorte y coordenadas locales 1..w / 1..h).
- Nada de `os.shutdown`/`computer.shutdown` fuera de `kernel:poweroff`.
- Colores solo desde `theme.colors`; glifos desde `theme.glyphs` (hay juego ASCII alternativo).
- Texto: usar `ctx.text` (UTF-8 por puntos de código), no `#cadena`, para contar columnas.

## Reglas duras

- No `git push`: lo hace el usuario. `git commit` solo con OK explícito y solo con ficheros propios.
- No tocar `node_modules/` ni añadir dependencias de runtime: el OS debe correr sin OpenOS.
- Cualquier API de OpenComputers que se use debe estar verificada (ver `docs/opencomputers.md`);
  lo no verificado se documenta como pendiente.
- Los componentes falsos del arnés deben replicar la API real: `list` devuelve tabla y el espacio se lee
  con `spaceUsed`/`spaceTotal` en bytes. Un arnés que invente la API da gates verdes falsos.
- Si añades o quitas un `.lua` en `src/`, `eeprom/` o `tools/`, ejecuta `npm run manifest`: `npm run
  check` falla si el manifiesto se desfasa, porque de él depende la instalación en partida.
- Mantener el arnés pasando (`npm run check`, `npm run sim` y `npm run sim:oc`) antes de dar un cambio por hecho.
- No escribir este proyecto en la memoria de neXacom.

## Decisiones y trampas conocidas

- Framebuffer virtual + volcado por diferencias: menos llamadas a la GPU; el volcado agrupa celdas
  contiguas con el mismo par fg/bg (2026-10-23).
- Sistema de ficheros propio sobre el componente `filesystem`: no se asume OpenOS montado.
- `computer.pullSignal` es la API cruda de señales; `event` es de OpenOS y no se usa.
- Ancho de carácter = 1. Sin CJK/emoji; los acentos ocupan una celda.
- Las ventanas se apilan con desplazamiento 2; los bordes de la ventana inferior asoman un sliver.
- CPD: arranque automático siempre, con SAI (capacitores) y central propia; descarte por escalones y el
  core es el último en apagarse.
- `filesystem.list` devuelve una tabla y el espacio se lee con `spaceUsed`/`spaceTotal` en bytes;
  `vfs.space()` los convierte a KB (2026-10-23).
- En OC 1.7.x el sandbox de la EEPROM no trae `computer.getBootAddress`/`setBootAddress`: las define
  `bios.lua` en tiempo de ejecución sobre `eeprom.getData`/`setData`. Un gestor propio debe crearlas
  (`eeprom/init.lua`) y el `init.lua` del volumen debe tolerar que falten (2026-10-23).
- Un fallo de render vuelve a marcar el escritorio sucio y se registra con límite: nunca se deja la
  pantalla congelada ni se escribe un error por frame (2026-10-23).
- Contrato real de la GPU, verificado en `GraphicsCard.scala` (rama `master-MC1.12`):
  `gpu.set`/`fill`/`copy` devuelven `true` al escribir y `nil, "not enough energy"` si no hay energía;
  `setBackground`/`setForeground` devuelven el color anterior. El volcado por diferencias solo se da
  por bueno cuando el retorno es `true` (2026-10-23).
- `ui:render` no limpia el framebuffer a negro antes de dibujar: pinta el fondo del escritorio y cada
  sección (barra, dock, ventanas, aviso) con `pcall` independiente. Si una falla, queda el frame
  anterior y se pinta una banda de error; una app que falla 3 veces al dibujar se congela con aviso
  en vez de reintentar el error cada frame (2026-10-23).
- Referencia de arquitectura de MineOS estudiada en `docs/mineos-referencia.md` (2026-10-23).

## Memoria relacionada

- Solo local: este repo y `Memoria/` del workspace **no** se usan para este proyecto.
