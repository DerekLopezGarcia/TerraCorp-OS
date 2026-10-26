# Terminal protocol (0.5)

Message contract for remote terminals: the session runs on a core node, the
terminal renders spans and sends input. The model, refresh policy, and memory
budget live in `distributed.md`; this document fixes the verb-level contract
so 0.4.0 can freeze the backend interface it depends on.

## Participants

- **Host**: the core running the session (master in 0.4; in 0.5 any node).
- **Terminal**: screen + keyboard + network card; a tablet may be a terminal
  (it cannot host sessions).

Transports: cable within a base, Linked Card between bases (`long-distance.md`).
Never the Redstone Control channel (too slow for frames; acceptable for an
alarm echo only).

## Verbs

All frames are `tc.net`-encoded (32-bit framing, `net.md`). `sid` is the
session id (host-assigned), `seq` a per-direction counter, `tok` the resume
token.

| Verb | Direction | Fields | Meaning |
|---|---|---|---|
| `THELO` | T→H | `w`, `h`, `profile` | Terminal requests a session (`profile`: `desktop` or `kiosk:<app>`) |
| `TWELCOME` | H→T | `sid`, `w`, `h`, `profile` | Session created/resumed; next FRAME is a full redraw |
| `TRESUME` | T→H | `tok`, `w`, `h` | Reconnect: find the session by token instead of creating one |
| `TREJECT` | H→T | `reason` | No capacity, unknown token, profile unsupported |
| `TFRAME` | H→T | `sid`, `seq`, `lastIn`, `full`, `spans` | Render spans; `lastIn` piggybacks the last processed input seq (input ACK); `full=true` → spans cover the whole screen |
| `TINPUT` | T→H | `sid`, `seq`, `events` | Batched input events, ≤ 8 per packet |
| `TPING` | both | `seq` | Link keepalive (10 s cadence, same as RC `PING`) |
| `TCLOSE` | both | `sid`, `reason` | Clean end; token becomes invalid unless `keep` is set |

`spans` is a string of packed spans: `(row, col, fg, bg, len, chars…)`,
fg/bg as palette indices, len ≤ 24. Encoding mirrors the local renderer's
span runs so `tc.display.remote` can forward `framebuffer:diff` output
unmodified.

## Input reliability

Input must not drop keystrokes, but `modem_message` is best-effort. Rule:

- Every `TINPUT` carries `seq`; the host echoes the highest processed seq in
  the next `TFRAME` (`lastIn`).
- The terminal retransmits un-acked input after 0.5 s (max 3 retries), then
  sends `TPING` and shows "link degraded" instead of inventing input.
- Input events are idempotent under replay: key events are absolute codes;
  repeated `key_down` for the same key+timestamp is suppressed by `seq`.

## Frame reliability

Frames are best-effort with gap detection:

- Terminal tracks `seq`; a gap means lost packets → send `THELO`-style
  `TRESYNC` (or set a flag on the next `TINPUT`) and the host answers with a
  full redraw (`full=true`). No per-frame ACKs: a lost frame is healed by the
  next frame or the resync, never retransmitted.
- At connect, after app switch, resize, or resync, the host always sends
  `full=true`.

## Bandwidth budget

Constraints from `distributed.md`: relay paths are ~4 packets/s — terminals
must ride direct cable/Linked Card, not relays; `maxPacketSize` 8192 default.

| Flow | Budget |
|---|---|
| Full redraw 80x25 | ~150 spans ≈ 3–4 KB → one packet, or 2 if fragmented by card limit |
| Steady state | 1 packet per frame flip; ≤ 10 Hz; typical idle frame = no packet at all (no dirty cells → no send) |
| Input | 1 packet per event batch, ≤ 8 events; typing at 10 keys/s ≈ 1–2 packets/s |
| Keepalive | 1 packet / 10 s each way |
| Hard ceiling | 20 packets/s per terminal; the host must coalesce frames rather than queue them (queue depth 1: latest frame wins, older dirty spans merge) |

Latency targets: key-echo round trip ≤ 250 ms on cable, ≤ 2 s over a Linked
Card (measure in the verification session).

## Session placement hook (0.5)

`TWELCOME` may include `node` (the hosting node). A placement request is out
of band (Relay job), never inline in the terminal handshake — the terminal
only ever talks to one host address.

## Verification checklist

1. Round-trip key echo over cable and over Linked Card (record both).
2. Full redraw packet count at 80x25 on a T2 card (`maxPacketSize`).
3. Kill the host mid-session: terminal shows "link degraded"; on host return,
   `TRESUME` restores the session from the token.
4. Two terminals, one session: second terminal gets `TREJECT` (one operator
   rule) or becomes viewer if we later decide that.
5. Tablet: token persistence across dimension change and reconnect delay.

Cross-links: `distributed.md` (model), `long-distance.md` (transports),
`sessions.md` (0.4.0 backend interface this builds on).
