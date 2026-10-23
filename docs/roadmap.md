# Roadmap

> Principio rector: **núcleo mínimo, todo lo demás opcional**. TerraCorp OS debe arrancar y ser útil en
> un solo ordenador, sin red y con 1 MB. La red, los servidores y el CPD se añaden por capas, y ninguna
> capa puede romper el caso de un nodo aislado.
>
> Modelo objetivo: **un servidor de aplicaciones y terminales ligeras en cada fábrica**. Ver
> `distribuido.md`.

## Fases

Cada fase tiene un criterio de salida medible. No se abre la siguiente sin cumplirlo.

### F0 — Prototipo congelado (0.1.x) · ahora

**Objetivo:** dejar de añadir funciones y averiguar cómo se comporta lo que ya hay.

- Probar en Supersymmetry con CPU tier 2 y pantalla tier 2/3.
- Medir: memoria libre, tiempo de arranque, celdas redibujadas por segundo.
- Corregir lo que salga; decidir qué apps sobran.
- Rellenar `docs/pruebas.md` con el resultado real (protocolo y medidas del arnés ya están allí).

**Salida:** 30 min de sesión sin errores, ≥ 250 KB libres en tier 2, arranque ≤ 2 s.

### F1 — Núcleo mínimo (0.2)

**Objetivo:** reducir superficie antes de crecer.

- Separar `kernel` (arranque, vfs, señales) de `services` (registro e interfaces).
- Las apps dejan de llamar a `kernel.*`: piden servicios.
- Recorte: Shell, Ficheros y Editor como apps núcleo; Panel y Ajustes como apps del sistema.
- Subir `api` a 2 y documentar contratos de app y de servicio.
- Suprimir lo que no se use.

**Salida:** núcleo ≤ 1 200 líneas, arranque ≤ 1,5 s, mismas funciones, arnés verde con tests de contrato.

### F2 — Sesiones y pantalla (0.3)

**Objetivo:** que el escritorio deje de ser un singleton. Es el cambio estructural que hace posible el
servidor de aplicaciones; si se deja para F3, F3 es una reescritura.

- `tc.session`: estado por sesión (ventanas, apps, foco) y gestor de sesiones.
- `tc.display` con tres backends: `local` (GPU), `remote` (tramos hacia una terminal) y `headless`.
- Framebuffer **empaquetado en cadenas** (2 bytes/celda) en lugar de tablas Lua.
- Perfiles de sesión: `desktop` y `kiosk:<app>` (el kiosko puede quedar como esqueleto).
- La sesión local es una más: el comportamiento actual no cambia.

**Salida:** dos sesiones headless y una local por debajo de 200 KB; ≤ 64 KB por sesión; arranque ≤ 1,5 s;
arnés con test de sesión múltiple.

### F3 — Servidor de aplicaciones y terminales (0.4)

**Objetivo:** el escenario pedido: apps en un servidor, terminales en las fábricas.

- `tc.net`: tramas, tamaño máximo medido, ACK, reintento, idempotencia.
- Protocolo de sesión: `HELLO` (versión, pantalla, capacidades), `SESSION`, `FRAME` (tramos), `INPUT`
  (teclas y clic), `PING`.
- Reconexión con reanudación: una terminal que se cae vuelve a su sesión.
- Descubrimiento de cores y clave compartida por segmento.
- Cliente de terminal (nodo mínimo con pantalla) y perfil kiosko.
- Límite de refresco 10 Hz y agrupación de tramos.

**Salida:** dos terminales (una por cable, otra por Linked Card) contra un core sin pantalla; reconexión
< 5 s; ancho de banda y latencia medidos y documentados; sin pérdida de estado al caer una terminal.

### F3.5 — Larga distancia y tablets (opcional, no bloquea F4)

**Objetivo:** operar una base en otra dimensión sin depender de la distancia.

- Spike previo obligatorio: ancho y tick de Redstone Control, API del Adapter de OC, wireless
  interdimensional de la instancia y límites de la tablet.
- Transporte RC como variante de `tc.net`: tramas de 32 bits, ACK para comandos, estado best-effort.
- Linked Card como enlace principal entre bases.
- Cliente de tablet con reanudación de sesión (no persiste al cambiar de dimensión ni al reconectar).
- Kiosko lunar reducido: estado y botones de emergencia, sin escritorio completo.

**Salida:** 1 KB con CRC correcto entre dos dimensiones; comando ida-vuelta < 2 s; la caída del enlace
principal no deja la base sin control. Ver `larga-distancia.md`.

### F4 — CPD y almacenamiento (0.5)

**Objetivo:** operar la sala de servidores y servir datos a las terminales.

- Inventario: nodos, discos, energía y red.
- Roles por nodo: `core`, `storage`, `worker`, `edge`.
- SAI y central propia: lectura de producción/consumo, presupuesto de respaldo y descarte por escalones.
- Arranque automático escalonado al superar la SAI el 60 %, con verificación por nodo y watchdog.
- Apagado ordenado: workers → terminales → storage → core (el último).
- Chunkloader permanente como requisito documentado.
- `storage` remoto sobre RAID, con copia en segundo nodo.
- Atribución de operador (nombre en barra y registro, sin cuentas).
- Mapa del CPD y alertas: nodo caído, disco lleno, relay saturado, SAI baja.

**Salida:** 2 racks / 6 nodos inventariados; el CPD arranca solo tras recargar el mundo al superar la SAI
el 60 %; una terminal lee y escribe ficheros del storage; caída de un nodo sin corromper datos ni tumbar
el resto.

### F5 — Cluster ligero (0.6)

**Objetivo:** reparto de trabajo y continuidad, sin prometer alta disponibilidad.

- Cola de trabajos con workers y resultado devuelto al solicitante.
- Réplica de ficheros (2 copias) y verificación.
- Failover del registro si cae el core.
- CLI de planta (`plant status`, `node drain`).

**Salida:** un trabajo batch se ejecuta en un worker y el resultado aparece en la terminal que lo pidió;
caída del core sin pérdida de datos.

### F6 — Exploración: fábrica

**Objetivo:** integrar la planta con el pack, no solo con ordenadores.

- Telemetría de máquinas GT mediante Adapter (inventarios/tanques): **por verificar** qué expone GTCE.
- Alertas de parada y contadores de producción en el kiosko.

No se planifica más hasta probarlo en partida.

## Backlog priorizado

| # | Tarea | Fase | Tamaño |
|---|---|---|---|
| 1 | Prueba real en Supersymmetry + `docs/pruebas.md` | F0 | S |
| 2 | Medir RAM y arranque con el arnés y en juego | F0 | S |
| 3 | Extraer `tc.service` y `tc.session` | F1–F2 | L |
| 4 | Framebuffer empaquetado + backends de pantalla | F2 | L |
| 5 | Recorte de apps y código muerto | F1 | S |
| 6 | Contratos versionados (app y servicio) | F1 | S |
| 7 | `tc.net` con tramas y ACK | F3 | L |
| 8 | Protocolo de sesión (FRAME/INPUT) | F3 | L |
| 9 | Cliente de terminal + kiosko | F3 | M |
| 10 | Inventario, salud y energía del CPD | F4 | M |
| 11 | Storage remoto sobre RAID | F4 | M |
| 12 | Cola de trabajos | F5 | L |
| 13 | Réplica de ficheros | F5 | M |
| 14 | Spike de RC: ancho, tick y Adapter de OC | F3.5 | S |
| 15 | Transporte RC (tramas de 32 bits + ACK) | F3.5 | M |
| 16 | Cliente de tablet con reanudación | F3.5 | M |
| 17 | Política de energía: SAI, escalones y alertas | F4 | M |
| 18 | Arranque automático escalonado + watchdog | F4 | M |

## Decisiones

1. **Modelo:** servidor de aplicaciones + terminales ligeras. **Decidido.**
2. **Multiusuario:** descartado. Varios jugadores, uno operando; atribución por nombre, sin cuentas.
   **Decidido.**
3. **Terminales:** Remote Terminal nativa para administrar el rack y terminal propia para las fábricas.
   **Decidido.**
4. **Autonomía del CPD:** arranque automático siempre, con SAI y central propia. **Decidido.** La SAI
   cubre el arranque y permite apagar en orden; el descarte es por escalones.
5. **Apps núcleo:** propuesta Shell, Ficheros y Editor; Panel y Ajustes como apps del sistema. Pendiente
   de confirmar en F1.

## Cómo se mide el éxito

- **Núcleo:** arranque, memoria libre, líneas de código, dependencias (deben ser 0).
- **Sesiones:** RAM por sesión, sesiones simultáneas, reanudación tras caída.
- **Red:** latencia de un RPC, caudal de ficheros, paquetes perdidos por minuto, KB por frame.
- **CPD:** nodos vivos, tiempo de arranque ordenado, datos verificados tras caída.
