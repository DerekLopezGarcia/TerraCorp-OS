# Interdimensional links (F4.5 research)

Research for `tc.net` transports beyond the wired rack segment. Goal: connect
TerraCorp installations across bases and dimensions with a documented,
verifiable path. Status: **research only** — nothing here is implemented, and
every item marked VERIFY needs an in-game probe before any code is written.

## Candidate transports

### 1. Linked Card (preferred for packets)

The GTNH OpenComputers fork (the one Supersymmetry ships) provides the
**Linked Card**: a pair-bonded network card that delivers `modem_message`
events **across dimensions**, at modem packet semantics (port, distance,
payload up to `maxPacketSize`).

- Why preferred: it is a drop-in transport for `tc.net` — same event shape,
  same framing, same port model. `net.lua` already decodes
  `modem_message(sender, receiver, port, distance, data)`; a linked-card
  message differs only in that `distance` is meaningless and the sender is in
  another dimension.
- What it gives us: SESSION/FRAME/INPUT (0.5 terminals), Relay jobs across
  bases, Vault extension to a second base — everything already designed.
- What to verify:
  - [ ] Component kind name (`component.list("linked_card")`? `tunnel`?).
  - [ ] Is it bidirectional without configuration? (Pair by crafting or by
        `open(port)` on both ends?)
  - [ ] Packet size limit (`maxPacketSize()` on the card).
  - [ ] Latency and tick cost vs wired modem (measure 100 frames round-trip).
  - [ ] Does it deliver to *all* linked cards of the pair, or one packet per
        send? Do both ends need the port open?
  - [ ] Behavior when the remote dimension chunk is unloaded (queued, lost,
        or delayed until load?).

### 2. Wireless network card (intra-dimension long range)

- `modem.setStrength(n)` sends wireless `modem_message` up to `n` blocks
  (energy cost per message scales with strength). Standard OC behavior;
  cross-dimension delivery is NOT expected on vanilla OC.
- Use case: base-to-shed links inside one dimension where cable runs are
  impractical. Cheap to support: `net.lua` gains a `strength` option.
- What to verify:
  - [ ] `setStrength` availability on the pack's card tier (T2 = wireless).
  - [ ] Whether the Supersymmetry OC build patched in cross-dimension
        wireless (some forks do; test explicitly before assuming the Linked
        Card is required).

### 3. Redstone Control (signal-level, not packets)

The **Redstone Control** mod (CD4017BE, 1.12.2, MIT) is a redstone logic
remake of Automated Redstone: ports with analog signals **not limited to
0–15**, point-to-point wires, and **interdimensional wireless signal
transmission** between ports.

- Important: this transports *signals* (integers), not OC network packets.
  It is a serial line, not a LAN. TerraCorp would need a codec: frame a byte
  stream into pulse-encoded integers on a redstone output port, read them on
  the remote side.
- OC integration is **unconfirmed**: the 1.12.2 README lists "programmable
  circuits" as planned, not shipped. If Redstone Control exposes ports as
  components (Adapter or native), Lua can drive them; if it is GUI-only, the
  only OC-side hook is a plain OC Redstone Card reading/writing the block's
  I/O — which still works if the block accepts vanilla-style redstone input
  and exposes its signal as output.
- Honest assessment: only worth it as a **fallback alarm/status channel**
  (a few bytes per second) if the Linked Card is unavailable, or as an
  independent emergency path that survives OC network outages. It cannot
  carry Vault transfers or sessions.
- What to verify:
  - [ ] Does Redstone Control expose any component to OC?
        `component.list()` next to a port; check kinds.
  - [ ] Can an OC Redstone Card set/read the port's signal (analog value
        range, event on change — does the port emit a `redstone_changed`
        signal)?
  - [ ] Interdimensional latency and whether the remote chunk must be loaded.
  - [ ] Signal value range through the interdimensional path (does the analog
        value survive intact, or clamp?).

## Recommended design (pending verification)

Layered transports under `tc.net`, all presenting the same `send/decode`
surface (the framing/transport/registry tests already force this):

| Transport | Scope | Role |
|---|---|---|
| Wired modem | Rack segment | Everything (current behavior) |
| Wireless modem | Same dimension | Long-range links, kiosks |
| Linked Card | Cross-dimension | Base-to-base sessions, Relay, Vault |
| Redstone serial | Cross-dimension | Fallback alarm channel only |

`net.newModem` gains a `transport` parameter; `modem:send` routes by
destination segment. A cross-segment message is wrapped (`seg`, `to`) and
forwarded by each segment's gateway — same pattern the Vault node gateway
already uses for disks.

## Sequencing

1. In-game verification session (all three checklists above) — one hour with
   a linked-card pair and a Redstone Control port.
2. 0.5.x: wireless transport option (lowest risk, same dimension).
3. 0.5.x: Linked Card transport + cross-segment gateway (needed for remote
   terminals).
4. F4.5 optional: redstone serial codec, only if a real need shows up.

Cross-links: `docs/roadmap.md` F4.5, `docs/net.md` (framing), `docs/cluster.md`
(STATUS routing).
