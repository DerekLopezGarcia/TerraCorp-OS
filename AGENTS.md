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
tools/check.lua       comprobador de sintaxis bajo OpenOS
tools/spike-rc.lua    banco de pruebas del enlace Redstone Control (spike)
tools/harness/        arnés Node (fengari) + comprobador
docs/                 arquitectura, opencomputers, roadmap, distribuido, larga-distancia
```

## Comandos

```bash
npm install        # solo para el arnés local
npm run check      # sintaxis de todos los .lua (Lua 5.3)
npm run sim        # ejecuta el OS con componentes falsos y vuelca pantalla
```

En el juego: `install <raizDelRepo> <direccionFilesystem> [--eeprom] [--yes]`.

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
- Mantener el arnés pasando (`npm run check` y `npm run sim`) antes de dar un cambio por hecho.
- No escribir este proyecto en la memoria de neXacom.

## Decisiones y trampas conocidas

- Framebuffer virtual + volcado por diferencias: menos llamadas a la GPU; el volcado agrupa celdas
  contiguas con el mismo par fg/bg (2026-10-23).
- Sistema de ficheros propio sobre el componente `filesystem`: no se asume OpenOS montado.
- `computer.pullSignal` es la API cruda de señales; `event` es de OpenOS y no se usa.
- Ancho de carácter = 1. Sin CJK/emoji; los acentos ocupan una celda.
- Las ventanas se apilan con desplazamiento 2; los bordes de la ventana inferior asoman un sliver.

## Memoria relacionada

- Solo local: este repo y `Memoria/` del workspace **no** se usan para este proyecto.
