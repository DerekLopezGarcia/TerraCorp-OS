# TerraCorp OS

Sistema operativo con escritorio para **OpenComputers**, pensado para correr dentro del modpack
**Supersymmetry** (Minecraft 1.12.2 + Forge). Susy-Core es el coremod de ese pack; TerraCorp OS no
lo modifica ni lo redistribuye: se instala en los ordenadores del jugador.

Estado: **0.1.0 "Foundry"** — arranca, monta escritorio, 5 aplicaciones, configuración persistente y
registro. Validado con un arnés que ejecuta el OS en un intérprete Lua 5.3 real; **pendiente de
prueba en partida**.

## Qué incluye

- Escritorio con barra corporativa, dock y ventanas (arrastrar, minimizar, cerrar).
- **Panel de planta**: nodo, memoria, energía, periféricos enlazados, disco y registro.
- **Ficheros**: navegación por el volumen, tamaños y vista previa de texto.
- **Consola**: shell propia (`ls`, `cd`, `cat`, `log`, `open`, `theme`, `reboot`…).
- **Ajustes**: acento, juego de caracteres, formato de hora, arranque y nivel de registro.
- **Acerca de**: versión, nodo y créditos.
- Framebuffer virtual con volcado por diferencias (solo redibuja lo que cambia).
- Sin dependencia de OpenOS: carga sus propios módulos y monta su propio sistema de ficheros.

## Requisitos

| Elemento | Mínimo | Recomendado |
|---|---|---|
| Minecraft / Forge | 1.12.2 | 1.12.2 |
| Modpack | Supersymmetry | Supersymmetry |
| OpenComputers | 1.7.x | 1.8.x |
| CPU | Tier 2 | Tier 3 |
| Pantalla | Tier 2 (80x25) | Tier 3 (hasta 118x44) |
| Disco | 1 MB libre | 2 MB |
| Memoria | 1 MB | 2 MB |

La UI se adapta al tamaño de pantalla, pero por debajo de 80x25 el dock y las tarjetas quedan muy
comprimidos.

## Instalación

El volumen de arranque es el contenido de `src/`. El BIOS de OpenComputers ejecuta `/init.lua` del
volumen marcado como de arranque, así que no hace falta OpenOS para que funcione.

1. Consigue una copia del repo dentro del ordenador (tarjeta de red + `wget`, disquete o `edit`).
2. Ejecuta el instalador bajo OpenOS:

   ```lua
   install /home/TerraCorp-OS <direccionDelDisco> --eeprom
   ```

   - `<direccionDelDisco>` es la dirección del componente `filesystem` de destino (`df` o
     `components` la muestran).
   - Sin `--eeprom` solo copia los ficheros y fija el volumen de arranque.
   - Con `--eeprom` graba `eeprom/init.lua` en la EEPROM; si el flasheo falla, el propio instalador
     avisa y puedes grabar ese fichero a mano.
3. Reinicia el ordenador (`reboot` o palanca).

Sin instalador: copia `src/*` a la raíz del disco, deja `/boot/kernel.lua` en su sitio y arranca desde
ese disco. La EEPROM es opcional: el BIOS puede arrancar directamente el volumen.

## Controles

- **Dock**: clic en `1 Panel`, `2 Ficheros`, `3 Consola`, `4 Ajustes`, `5 Acerca`.
- **Teclado global**: `F1`–`F5` abren la app correspondiente; `Esc` minimiza la ventana activa.
- **Ventanas**: arrastra desde la barra de título, `[-]` minimiza, `[x]` cierra.
- **Ficheros**: `↑`/`↓` mover, `Enter` abrir, `Retroceso` subir, `r` recargar.
- **Consola**: `↑`/`↓` historial, `Retroceso`, `Enter`; `help` lista comandos.
- **Ajustes**: clic en cada valor para ciclarlo.

## Estructura

```
src/                    volumen de arranque (lo que se copia al disco)
  init.lua              entrada: encuentra el volumen, enlaza GPU y llama al kernel
  boot/kernel.lua       servicios, carga de módulos, bucle de señales
  lib/tc/               version, util, text, log, config, theme, gfx, ui, keys
  apps/                 dashboard, files, console, settings, about
eeprom/init.lua         gestor de arranque para grabar en la EEPROM
tools/install.lua       instalador (se ejecuta bajo OpenOS)
tools/check.lua         comprobador de sintaxis dentro de OpenComputers
tools/harness/          arnés de simulación y comprobador local (Node)
docs/                   arquitectura, notas de OpenComputers y roadmap
```

## Desarrollo

El código no necesita compilación. Para validarlo sin abrir Minecraft:

```bash
npm install
npm run check          # compila todos los .lua con Lua 5.3 (fengari)
npm run sim            # ejecuta el OS, reproduce eventos y vuelca la pantalla
npm run sim:dashboard  # escenarios: dashboard, console, files, settings
```

El arnés sirve como prueba de humo: componentes falsos, disco en memoria y GPU que rasteriza en una
matriz. No sustituye a probarlo en el juego.

## Decisiones de diseño

- **Sin OpenOS**: el OS no asume `require`, `event`, `fs` ni `shell`. Todo se carga desde su volumen.
- **Framebuffer propio**: se dibuja en memoria y se envían a la GPU solo las celdas que cambian.
- **16 colores**: el tema es una asignación de tokens a la paleta de Minecraft, no colores libres.
- **Un carácter = una celda**: no hay soporte de ancho doble (CJK/emoji); ver `docs/opencomputers.md`.

## Licencia y créditos

MIT (ver `LICENSE`).

- Inspirado en la arquitectura y la experiencia de escritorio de [MineOS](https://github.com/IgorTimofeev/MineOS)
  (Igor Timofeev, MIT). **No es un fork**: no se ha copiado código.
- Entorno objetivo: [Supersymmetry](https://github.com/SymmetricDevs/Supersymmetry) y su coremod
  [Susy-Core](https://github.com/SymmetricDevs/Susy-Core) (GPLv3). No se modifican ni se redistribuyen.
- OpenComputers es MIT y pertenece a sus autores.
