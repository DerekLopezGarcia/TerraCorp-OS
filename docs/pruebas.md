# Pruebas — F0

> Criterio de salida de F0 (ver `roadmap.md`): **30 min de sesión sin errores, ≥ 250 KB libres en
> tier 2 y arranque ≤ 2 s**, probado en Supersymmetry. Lo medido con el arnés ya está aquí; lo que
> sólo se puede medir en juego queda como casilla pendiente con el comando exacto.

## 1. Medido con el arnés (Lua 5.3 real)

`npm run measure` (2026-10-23, resolución nativa de la pantalla):

```
núcleo : 2095 líneas · 60.3 KB · init 104 · boot 552 · lib 1439
apps   : 1000 líneas · 29.7 KB (5 apps)
total  : 3095 líneas · 90.0 KB en 16 módulos (disco tier 2: 1 MB)
```

| Escenario | Pantalla | Celdas pintadas | `gpu.set` | Señales |
|---|---|---|---|---|
| dashboard | 160x50 | 1810/8000 (22,6 %) | 359 | 14 |
| console | 160x50 | 959/8000 (12,0 %) | 279 | 9 |
| files | 160x50 | 904/8000 (11,3 %) | 443 | 13 |
| settings | 160x50 | 848/8000 (10,6 %) | 296 | 5 |
| all | 160x50 | 1564/8000 (19,6 %) | 814 | 13 |
| dashboard | 80x25 | 592/2000 (29,6 %) | 145 | 14 |
| console | 80x25 | 585/2000 (29,3 %) | 161 | 9 |
| files | 80x25 | 542/2000 (27,1 %) | 235 | 13 |
| settings | 80x25 | 482/2000 (24,1 %) | 162 | 5 |
| all | 80x25 | 770/2000 (38,5 %) | 329 | 13 |

**Qué vale y qué no.** El arnés corre en fengari sobre Node, con la API de OpenComputers replicada
(incluidos los valores de retorno reales de la GPU). Sirve para comparar versiones y para detectar
regresiones, pero **no** para cifras de juego:

- El arranque es **síncrono**: el primer frame se pinta antes de consumir ninguna señal, así que el
  arnés no mide tiempo de arranque. Las «señales» son el número de eventos que consume el escenario.
- `collectgarbage("count")` no existe en fengari (`lua_gc` sin implementar), así que la memoria no se
  mide aquí. Se lee en juego con `computer.freeMemory()`.
- El reloj avanza 0,25 s por señal: es una ficción útil para el guion, no tiempo de pared.

Lo que **sí** es real y comparable: el tamaño del código (líneas y bytes) y el coste de pintado
(celdas y llamadas a `gpu.set`), que es lo que decide si el volcado por diferencias aguanta en un
tier 2.

## 2. Protocolo en juego

1. Instalar:

   ```
   wget https://raw.githubusercontent.com/dereklopezagarcia/TerraCorp-OS/main/tools/fetch.lua /tmp/fetch.lua
   lua /tmp/fetch.lua
   cd /home/TerraCorp-OS/tools
   ./install.lua /home/TerraCorp-OS [dir] --eeprom --yes
   ```

2. Rearrancar el ordenador y **cronometrar hasta ver el escritorio**. Apuntar los segundos.
3. Leer la traza de arranque:

   ```
   cat /var/log/tc.log
   ```

   Cada línea acaba en `[Ns]`, el uptime del ordenador en el momento de escribirla (incluye BIOS y
   gestor de arranque, que es lo que interesa):

   ```
   22:50:53 TRZ arranque TerraCorp OS 0.1.0 en TC-ABC1 [0.00s]
   ...
   22:50:53 TRZ gpu gpu- · pantalla scre · 160x50 · 1562 KB libres [0.00s]
   22:50:54 TRZ primer render ok [0.00s]
   ```

   - **Arranque** = el `[Ns]` de `primer render ok`.
   - **Memoria libre** = los `KB libres` de la línea `gpu` (leídos con `computer.freeMemory()`).
   - **Resolución** = el `WxH` de esa misma línea: debe ser la de la pantalla, sin recortes.
4. Sesión de 30 minutos: abrir las cinco apps, escribir en la consola (`help`, `ls`, `df`), mover y
   redimensionar ventanas, cambiar la resolución de la pantalla desde OpenOS (`gpu.setResolution`) y
   volver. Al final:

   ```
   grep ERR /var/log/tc.log
   ```

   Debe salir vacío.
5. Repetir con CPU/GPU tier 2 y pantalla tier 2 (80x25), que es el caso peor.

## 3. Registro de la prueba

| Fecha | Nodo | CPU / GPU / Pantalla | Resolución | KB libres | Arranque | 30 min sin `ERR` | Notas |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

## 4. Criterios de salida de F0

| Criterio | Cómo se mide | Estado |
|---|---|---|
| 30 min de sesión sin errores | paso 4 (`grep ERR`) | pendiente en juego |
| ≥ 250 KB libres en tier 2 | línea `gpu` del registro | pendiente en juego (arnés: 1562 KB) |
| Arranque ≤ 2 s | `[Ns]` de `primer render ok` | pendiente en juego |
| Se adapta a la pantalla real | resolución nativa + `npm run test:screens` | verificado (40x16 a 160x50) |
| Sin huecos al rechazar la GPU una escritura | `npm run test:faults` | verificado |
| Núcleo contenido antes de crecer | `npm run measure` | 2095 líneas (objetivo F1: ≤ 1200) |

## 5. Si sale pantalla negra

La traza se abre **antes** de crear la GPU, así que el registro dice hasta dónde llegó el arranque.
Última línea de `/var/log/tc.log`:

| Última línea | Interpretación |
|---|---|
| nada / no existe | el fallo es anterior al OS: BIOS, EEPROM o volumen de arranque |
| `TRZ arranque ...` | murió antes de crear la GPU (componente ausente o `component.proxy` falló) |
| `TRZ splash` | murió al pintar el splash o al cargar módulos |
| `TRZ gpu ...` | murió al fijar resolución o al primer frame |
| `TRZ primer render` sin `ok` | el primer frame lanzó un error: buscar la línea `ERR` siguiente |
| `TRZ primer render ok` | el OS arrancó; si la pantalla está negra, el problema es de energía de la GPU o del cable |
