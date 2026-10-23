# Modelo distribuido y CPD

Fija **qué se puede construir** con OpenComputers y qué modelo adopta TerraCorp OS: **un servidor de
aplicaciones y terminales ligeras en cada fábrica**. Es diseño; nada de esto existe todavía salvo el
núcleo local.

## 1. Límites reales del mod

Verificado en la documentación y el código de OpenComputers:

| Pieza | Hecho | Implicación |
|---|---|---|
| RAM | Cada nodo tiene la suya; no se comparte | No hay memoria distribuida que sumar |
| Relay | 1 paquete/250 ms (4/s) sin CPU/RAM; cola 20; máx. 5 saltos; mejora con CPU/RAM/HDD | Ancho de banda escaso y frágil |
| Relay y componentes | No exponen componentes, solo pasan mensajes | El plano distribuido es RPC, no proxies |
| Rack | 4 servidores + terminal server; switch y energía integrados; buses por lado | El CPD se organiza por racks |
| Terminal Server | `terminalsPerServer = 4`; equivale a pantalla+teclado tier 2 | Administración remota nativa y barata |
| Linked Card | Red cuántica punto a punto (`tunnel`) | Enlace entre bases o dimensiones |
| RAID | Agrega discos en un volumen | Almacenamiento del CPD |
| Net Splitter | Separa redes sin enrutar | Segmentación por zonas |

Números de referencia: una pantalla de 80x25 son 2 000 celdas. Un frame completo con colores ronda los
4–6 KB; a 4 paquetes/s, **transmitir el framebuffer entero cada frame no es viable**. Se envían
diferencias.

## 2. Modelo: servidor de aplicaciones + terminales

El objetivo no es repartir RAM, es que **las apps corran en el servidor y que en cada fábrica haya una
terminal que solo pinte y envíe eventos**. Es el modelo mainframe, y encaja con el mod.

| Rol | Hardware | Responsabilidad |
|---|---|---|
| `core` | Servidor con CPU/RAM; **sin pantalla** | Runtime, sesiones, apps, registro |
| `terminal` | Ordenador con pantalla+teclado+red | Pinta la sesión y envía eventos |
| `storage` | Servidor con RAID | Ficheros, réplica, copias |
| `worker` | Servidor sin pantalla | Trabajos batch |
| `gateway` | Relay / Net Splitter | Segmenta; no ejecuta servicios |

### Sesiones

- Cada terminal abre una **sesión** con su propio escritorio (ventanas, apps, foco).
- Perfiles de terminal:
  - `desktop`: escritorio completo, para el despacho.
  - `kiosk:<app>`: una app a pantalla completa; el panel de producción de la nave.
- El estado vive en el servidor. La terminal es reemplazable: si se rompe, se pone otra y se reanuda.
- Varios jugadores, pero uno operando a la vez: el servidor etiqueta la sesión con el jugador que está
  conectado. Sin cuentas ni contraseñas.

## 3. Pantalla remota

El servidor **ya calcula diferencias por filas** para su GPU local. La terminal remota reutiliza ese
mismo flujo: cada frame produce tramos `(fila, columna, fg, bg, texto)` y solo se envía eso.

- Repintado completo de 80x25 al conectar o cambiar de app: unos pocos KB, una vez.
- Un clic o una tecla: 1–3 tramos.
- Refresco máximo 10 Hz; los tramos del mismo frame se agrupan.
- RLE por fila para fondos y líneas repetidas.
- Sin vídeo, sin imágenes: solo celdas.

Backends de pantalla (F2 los separa del framebuffer):

```lua
tc.display.local     -- gpu.set (escritorio local)
tc.display.remote    -- serializa tramos hacia la sesión
tc.display.headless  -- descarta; servidor sin GPU ni pantalla
```

## 4. Presupuesto de RAM

Cada sesión necesita su framebuffer. Con las tablas Lua actuales, 80x25 con doble búfer ronda
200–250 KB: dos sesiones no caben en tier 2.

Por eso F2 empaqueta las celdas en cadenas (2 bytes por celda: carácter + colores):

| Elemento | Coste estimado |
|---|---|
| Búfer frontal 80x25 empaquetado | ~4 KB |
| Búfer trasero (para diferencias) | ~4 KB |
| Estado de ventanas + apps de una sesión | ~20–40 KB |
| **Presupuesto por sesión** | **< 64 KB** |
| 4 sesiones + núcleo | < 400 KB |

Si no se cumple, se recorta resolución de terminal antes de recortar sesiones.

## 5. Enlaces según distancia

| Ámbito | Medio | Límite |
|---|---|---|
| Mismo rack | bus del rack | sin coste de red |
| Misma base | cable + módem | red local, sin relay |
| Entre zonas de la base | relay / net splitter | 4 paquetes/s, cola 20, 5 saltos |
| Misma dimensión, cerca | wireless | rango por tier; más energía a más distancia |
| Otra base o dimensión | **Linked Card** (`tunnel`) | punto a punto; un par por enlace |
| Otra base o dimensión | **Redstone Control** (wireless) | interdimensional; ~80 B/s por canal; solo comandos y telemetría |
| Móvil | **Tablet** por wireless | no admite RC; no persiste al cambiar de dimensión |

Recomendación: **cable dentro de la base, Linked Card entre bases, relay solo para segmentar**. El
wireless para terminales móviles o de obra, no para el CPD. RC es el canal de emergencia y de telemetría
cuando la autopista no llega. Diseño y protocolo en `larga-distancia.md`.

## 6. Terminal nativa o propia

| Opción | Coste | Límite | Uso |
|---|---|---|---|
| Remote Terminal nativa | Nulo | 4 por terminal server; solo servidores en rack; pantalla tier 2 | Administrar el CPD |
| Terminal TerraCorp | Alto (protocolo) | Requiere nuestro cliente y enlace | Fábricas, kiosko, apps propias |

**Decisión:** las dos. La nativa para operar el rack y arrancar el core; la propia para las terminales
de planta, porque permite kiosko, multi-sesión y apps propias.

## 7. Servicios y contratos

La app nunca habla con la red: habla con un servicio, y el servicio decide si es local o remoto.

```lua
local storage = services.get("storage")
storage.read("/planos/reactor.txt")        -- igual si vive al lado o en otra base

local telemetry = services.get("telemetry")
telemetry.push("produccion", { hierro = 128 })
```

- `tc.service`: registro, capacidades, ciclo de vida y transporte (`local` / `net`).
- Versión de contrato obligatoria; dos nodos incompatibles no se emparejan.
- Migrar un servicio de nodo no toca las apps.
- Telemetría **por eventos**, nunca polling más rápido de 1 Hz.

## 8. CPD: topología y operación

```
                 [ Net Splitter ]
                        │
        ┌───────────────┼───────────────┐
   [ Rack A ]      [ Rack B ]      [ Terminal planta ]
   4 servidores    4 servidores      kiosko producción
   terminal srv    terminal srv
        │               │
   [ RAID ]        [ RAID réplica ]
                        │
                 [ Linked Card ] ─── terminal de otra base
```

### Energía: central propia + SAI

- El CPD tiene **central propia**; la SAI (capacitores + cargadores) cubre huecos y transitorios.
- La SAI no es para seguir produciendo: es para **apagar en orden** y para absorber el pico de arranque.
- Presupuesto: ≥ 3 minutos de consumo a plena carga y ≥ 2× el pico de arranque.
- Medición: cada nodo reporta `computer.energy()`; la planta se lee con Adapter (producción/consumo).
- Descarte por escalones si la SAI baja del umbral:
  1. workers
  2. terminales no críticas
  3. storage (solo tras cerrar ficheros)
  4. core (el último, y con aviso)
- Nunca se apaga storage a mitad de escritura: primero se detiene el servicio, después el nodo.

### Arranque automático (decidido)

- El CPD arranca **siempre**, sin operador, en cuanto la SAI supera el 60 % de carga.
- Orden: red → storage → core → workers → terminales.
- **Arranque escalonado** (un nodo cada ~5 s) para no vaciar la SAI de golpe ni disparar el pico.
- Tras cada nodo: responder al `PING` antes de arrancar el siguiente.
- Requisito duro: **chunkloader permanente**. Sin chunks cargados no hay arranque automático posible.
- Watchdog: si el core no responde tras N intentos, se reinicia el nodo si el rack lo permite y se
  registra; si no, alerta al operador.
- Apagado: solo por orden del operador o por SAI por debajo del mínimo; nunca por un corte transitorio.

### Operación

- **Inventario:** nodos, discos, energía y red. El mod no expone temperaturas.
- **Alertas:** nodo caído, disco lleno, relay saturado, SAI baja, planta por debajo del consumo.

## 9. Seguridad y sesión

- **Sin cuentas.** Varios jugadores, uno operando a la vez. Sin login ni contraseñas.
- **Atribución:** `touch`, `drag` y `key_down` incluyen el nombre del jugador; el OS lo muestra en la
  barra y lo escribe en el registro.
- **Sin bloqueo de sesión** mientras no haya concurrencia real. Si aparece, *claim* con liberación por
  inactividad.
- **Máquina a máquina:** clave compartida por segmento (`/etc/terracorp.net`). Empareja nodos, no
  autentica personas.
- Un trabajo remoto no puede pedir componentes: solo métodos del contrato.

## 10. Riesgos

1. **Saturación del relay** con varias terminales. Mitigación: deltas, 10 Hz, eventos y medición previa.
2. **RAM por sesión** si no se empaqueta el framebuffer. Es el riesgo técnico número uno del modelo.
3. **Chunkloading** del CPD y de las terminales.
4. **Energía**: un CPD grande consume y se apaga desordenado sin política.
5. **Complejidad prematura**: construir red antes de que el núcleo local y las sesiones funcionen.
6. **Integración GT** por verificar antes de F6.
