# Enlaces de largo alcance y tablets

Complemento de `distribuido.md`. Aquí está el diseño de los enlaces que permiten operar la base desde
otra dimensión y de las tablets como terminales móviles.

## 1. Lo que hay (verificado)

**Redstone Control** (Cd4017BE, MC 1.12.2):

- Señales fuera del rango 0–15 de vanilla.
- Cableado punto a punto entre sockets.
- **Transmisión inalámbrica interdimensional**.
- Procesadores/FPGA con RAM externa, operaciones bit a bit y formato bitmap de E/S.
- **Integración con el Adapter de OpenComputers**: el changelog de la 0.3.x menciona «buffered, tick
  precise I/O operations to OpenComputers Adapter». Es decir, hay puente OC ↔ RC sin inventarlo.

**Tablets de OpenComputers**:

- Ordenador portátil; **no interactúa con el mundo** (no admiten Redstone Card).
- **No persisten** al cambiar de dimensión ni al salir y volver a entrar el jugador.
- Se cargan en un Charger; el disco interno se puede montar desde un ordenador conectado al Charger.

## 2. Mapa de enlaces

| Enlace | Alcance | Caudal estimado | Latencia | Coste | Uso |
|---|---|---|---|---|---|
| Wireless OC (tarjeta) | rango por tier (config) | paquetes de red local | ms | energía según distancia | tablets y terminales móviles |
| Linked Card | punto a punto, sin distancia | el de la red OC | ms | un par por enlace | entre bases y dimensiones |
| Redstone Control | **interdimensional, sin distancia** | ~80 B/s por canal a 20 tps | ~50 ms por palabra | adapter + señales | telemetría, comandos, latido |
| Relay / Net Splitter | misma red | 4 paquetes/s, cola 20, 5 saltos | — | barato | segmentar zonas |

Los tres no compiten: **Linked Card es la autopista, RC es el telégrafo**. La autopista para la UI; el
telégrafo para lo que tiene que llegar siempre, aunque no haya pareja de linked cards o estés en la luna.

## 3. Capacidad real de RC

Si una señal transporta 32 bits (2³² valores), son 4 bytes por actualización. A 20 ticks/s:

```
1 canal  -> 32 bits × 20 Hz = 640 bit/s = 80 B/s
8 canales -> 640 B/s
16 canales -> 1,28 KB/s
```

Un frame completo de 80x25 son 4–6 KB: por RC tardaría **6–13 segundos**. Por tanto:

- **No**: escritorio remoto, framebuffer, vídeo, transferencia de ficheros grandes.
- **Sí**: estado compacto (números y bits), alarmas, comandos, latido, paginación y control de
  emergencia.

Si el ancho real fuese menor (16 bits), todo se escala con más canales; el diseño no cambia.

## 4. Protocolo TC-Link/RC

```
palabra de 32 bits
  [2] versión | [3] tipo | [6] secuencia | [4] longitud | [1] ack | [16] carga útil

tramas: cabecera + N palabras + CRC32 (1 palabra)
tipos : HELLO, STATE, CMD, ACK, PING
```

- `CMD`: stop-and-wait con ACK y timeout de 1 s; reintento máximo 3; idempotencia por secuencia para no
  repetir una orden al reenviar.
- `STATE`: best-effort, sin ACK; el receptor guarda el último estado válido.
- `PING` cada 10 s; tres fallos marcan el enlace como caído.
- Identificador de enlace de 16 bits en la cabecera para no mezclar canales entre bases.
- No es criptografía: solo evita cruces accidentales. La confianza es física (quién tiene el socket).

Se implementa como un transporte más de `tc.net`:

```lua
-- misma interfaz para cable, linked card, wireless o RC
link.send(tipo, carga)   -- fragmenta y encola según el medio
link.on("state", fn)
```

Capacidades anunciadas: `bandwidth=80B/s`, `latency=50ms`, `range=∞`.

## 5. Tablets

- El cliente de tablet **solo dibuja y envía eventos**: el escritorio vive en el servidor.
- No pueden llevar RC: el gateway RC es un nodo fijo con Adapter.
- Al cambiar de dimensión o reconectar, la tablet arranca de cero: el cliente debe **reanudar sesión**
  con un token guardado en su disco interno.
- Debe caber en tier 1: cliente mínimo, sin apps, sin vfs propio salvo el token.

## 6. Escenario «luna»

```
Base lunar                                  Base terrestre
  [ gateway RC ]  <--- interdimensional ---> [ gateway RC ]
  [ linked card ] <--- quantum tunnel -----> [ linked card ]
  [ terminal ]                                [ core + storage ]
```

- La UI va por Linked Card.
- Los comandos y el estado van por RC: funcionan aunque el Linked Card falle o no haya pareja.
- El kiosko lunar muestra un panel reducido y botones de emergencia; no se replica el escritorio.
- Si se pierde el enlace principal, RC mantiene el control: parar reactor, cerrar válvulas, pedir
  diagnóstico.

## 7. Verificación previa (spike obligatorio)

Antes de implementar nada, ejecutar `tools/spike-rc.lua` en el ordenador conectado al Adapter:

1. `spike-rc probe` — enumera componentes y métodos; localizar el Adapter de RC y sus métodos de señal.
2. Rellenar el bloque `ADAPTER` del script con la lectura y la escritura reales.
3. `spike-rc width` — ancho efectivo de la señal (detecta truncamientos a 4/8/16 bits).
4. `spike-rc bench 200` — latencia ida-vuelta media, mínima y máxima.
5. `spike-rc stream 500` — ráfaga: pérdidas, desajustes y caudal real.
6. `spike-rc selftest` — comprueba el propio banco con un adaptador en memoria (sin hardware).

Además, en partida:

- Confirmar que el wireless interdimensional está activo en la instancia de Supersymmetry.
- Tablet: RAM por tier, tarjeta wireless incluida y comportamiento al cambiar de dimensión.

**Criterio de salida:** 1 KB transferido con CRC correcto entre dos dimensiones y un comando ida-vuelta
en menos de 2 s.

## 8. Riesgos

- El ancho de 32 bits es una suposición: el spike lo confirma y el diseño escala por canales.
- El Adapter puede no exponer las señales como esperamos; si no, el enlace RC no existe y queda el
  Linked Card.
- RC podría no estar en la instancia real del pack.
- El tick de RC compite con el del servidor: medir con el CPD lleno, no en vacío.
