# Long-Distance Links and Tablets

This complements [`distributed.md`](distributed.md) with transport choices for
operating a remote base and using tablets as mobile terminals.

## Verified behavior and assumptions

Redstone Control (Cd4017BE, Minecraft 1.12.2) supports signals beyond vanilla
redstone levels, point-to-point sockets, interdimensional wireless, FPGA-style
processing, and an OpenComputers Adapter. Its exact Adapter API and throughput
must still be measured in the target instance.

OpenComputers tablets are portable computers but cannot interact with the
world or use a Redstone Card. They do not persist across dimension changes or
player reconnects. Their internal disk can be mounted from a computer attached
to a Charger.

## Transport comparison

| Link | Range | Approximate throughput/latency | Use |
|---|---|---|---|
| OpenComputers wireless | Tier/config limited | Local-network packets | Mobile terminals |
| Linked Card | Point-to-point, distance-independent | OpenComputers network | Primary inter-base link |
| Redstone Control | Interdimensional | ~80 B/s/channel at 20 TPS; ~50 ms/word | Telemetry, commands, heartbeat |
| Relay / Net Splitter | Same network | ~4 packets/s, queue 20, 5 hops | Segment zones |

Linked Card is the high-throughput link; Redstone Control is the low-rate
fallback for essential commands and state. A 32-bit signal at 20 ticks/s is
about 80 bytes/s per channel. An 80x25 full frame of 4-6 KB would take 6-13
seconds over one channel, so Redstone Control must not carry a desktop
framebuffer, video, or large files. It can carry compact state, alarms, commands,
heartbeat, and emergency control.

## TC-Link/RC protocol proposal

```text
32-bit word:
  [2] version | [3] type | [6] sequence | [4] length | [1] ACK | [16] payload

frame: header + N words + CRC32 word
types: HELLO, STATE, CMD, ACK, PING
```

- `CMD`: stop-and-wait ACK, 1-second timeout, at most 3 retries; use sequence
  numbers for idempotency.
- `STATE`: best effort, no ACK; retain the last valid state.
- `PING`: every 10 seconds; three failures mark the link down.
- A 16-bit link ID prevents mixing channels between bases.
- This is framing, not cryptography; trust the physical socket and segment key.

Implement RC as another `tc.net` transport using the same send/event contract
as cable, Linked Card, and wireless.

## Tablet client

The tablet should only render and send input; the desktop remains on the server.
It needs a resume token on its internal disk to reconnect after a dimension
change. Keep the client small enough for Tier 1, with no apps and no local VFS
except the token. It cannot host the RC gateway.

## Required measurement spike

Before implementing RC, run `tools/spike-rc.lua` on a computer connected to the
Adapter:

1. `spike-rc probe` to list components and discover actual Adapter methods.
2. Fill in the script's `ADAPTER` block with the methods found.
3. `spike-rc width` to detect signal truncation (4/8/16/32 bits).
4. `spike-rc bench 200` to measure round-trip latency.
5. `spike-rc stream 500` to measure loss and throughput.
6. `spike-rc selftest` to validate the in-memory test adapter.

Also confirm interdimensional wireless is enabled in Supersymmetry and measure
tablet memory and reconnect behavior.

## Transport verification checklists

Run these probes before writing transport code (consolidated from the 0.3
research session; the OC API references below are community-documented and
**pending in-game verification**).

**Linked Card** (preferred for packets):

- [ ] Component kind name (`component.list()` next to a paired card).
- [ ] Pairing mechanism (crafting? explicit open on both ends?).
- [ ] Packet size limit (`maxPacketSize()` on the card).
- [ ] Latency/tick cost vs wired modem (100 frames round-trip).
- [ ] One packet per send or broadcast to all ends of the pair? Do both ends
      need the port open?
- [ ] Behavior when the remote dimension chunk is unloaded (queued, lost,
      delayed?).

**Wireless network card** (long range, same dimension):

- [ ] `setStrength(n)` available on the pack's card tier (T2 = wireless).
- [ ] Whether the Supersymmetry OC build patched cross-dimension wireless —
      if so, the Linked Card may not be required.
- [ ] Energy cost per message as a function of strength.

**Redstone Control** (signal-level fallback):

- [ ] Does the mod expose ports as OC components (`component.list()` next to
      a port)? Its 1.12.2 README lists "programmable circuits" as planned, so
      Adapter integration is unconfirmed.
- [ ] Can an OC Redstone Card set/read the port signal (analog value range,
      change events)?
- [ ] Does the analog value survive the interdimensional path intact?
- [ ] Cross-dimension latency and chunk-load requirements.

**Exit criteria:** transfer 1 KB with a valid CRC between dimensions and execute
a command round-trip in under 2 seconds. Risks include a narrower-than-expected
signal, an Adapter API that differs from assumptions, unavailable RC in the
pack, and server tick contention under a loaded data center.
