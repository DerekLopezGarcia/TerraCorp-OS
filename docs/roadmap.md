# Roadmap

## 0.1.0 — Foundry (actual)

- [x] Cadena de arranque BIOS/EEPROM con volumen propio.
- [x] Kernel con vfs, cargador de módulos, servicios y bucle de señales.
- [x] Framebuffer con doble búfer y volcado por diferencias.
- [x] Escritorio: barra, dock, ventanas, arrastre, minimizar y cerrar.
- [x] Apps: Panel, Ficheros, Consola, Ajustes, Acerca de.
- [x] Configuración persistente en `/etc/terracorp.cfg`.
- [x] Registro en memoria y persistencia de avisos/errores en `/var/log/tc.log`.
- [x] Instalador y comprobador de sintaxis para OpenOS.
- [x] Arnés de simulación local (fengari) con volcado de pantalla.

## 0.2.0 — Telemetría

- [ ] Prueba real en Supersymmetry y ajuste de rendimiento en CPU tier 2.
- [ ] Tarjetas del panel configurables (qué periférico mirar en cada una).
- [ ] Journal completo en `/var/log` con rotación y `dmesg` propio.
- [ ] Editor de texto básico (abrir/guardar) integrado en Ficheros.
- [ ] Redimensión de ventanas con el ratón y maximizar.
- [ ] Fondo de escritorio con patrón corporativo configurable.

## 0.3.0 — Planta conectada

- [ ] Mensajería por módem: descubrimiento de nodos y estado remoto.
- [ ] Cliente de terminal remoto entre ordenadores de la planta.
- [ ] Alertas del panel (energía baja, disco lleno, componente desconectado).
- [ ] Perfiles de usuario con bloqueo de sesión.

## Ideas aparcadas

- Paquete de instalación por `wget` desde GitHub Releases.
- Integración con el speaker para avisos sonoros.
- Modo kiosco para pantallas grandes de la fábrica.

## Problemas conocidos

- Sin probar en partida: el arnés valida ejecución y dibujo, no el comportamiento de un servidor
  multijugador ni el consumo real de energía.
- El desbordamiento de texto en la consola recorta por ancho de ventana; si la ventana se estrecha
  mucho, las líneas ya envueltas se reajustan al siguiente repintado.
- Las ventanas apiladas dejan ver un borde de la ventana inferior cuando el desplazamiento es de 2
  celdas.
- `screen_resized` vuelve a leer la resolución, pero no reajusta el tamaño de las ventanas abiertas
  (solo las recorta al nuevo límite).
