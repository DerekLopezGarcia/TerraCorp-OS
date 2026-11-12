# External Link bridge

The other end of the External Link protocol described in
[`docs/external-link.md`](../../docs/external-link.md). TerraCorp OS is always
the client: it polls this bridge over outbound HTTP from its Internet Card, and
the bridge answers with queued work. The bridge never connects to a computer.

Frames are the TC1 lines from `src/lib/tc/net.lua`, one per line:

```text
TC1 <VERB> key=value key=value ...
```

A value escapes `%` as `%25`, space as `%20`, tab as `%09`, CR as `%0D`, LF as
`%0A` and `=` as `%3D`. A frame may not exceed 1024 bytes and a request body may
not exceed 64 KiB.

## Requirements

Node.js 20 or newer. No dependencies, no install step.

## Run

```text
node tools/bridge/bridge.js --token <secret>
```

The token is taken from `--token`, then the `LINK_TOKEN` environment variable,
then the positional argument. The bridge refuses to start without one. Every
request must send it in the `X-Link-Token` header, otherwise the answer is 401 and
nothing is processed or stored. The comparison is constant time.

| Option | Default | Meaning |
|---|---|---|
| `--token <value>` | `LINK_TOKEN` | Shared secret |
| `--port <n>` | `8787` | Listen port |
| `--host <addr>` | `127.0.0.1` | Listen address |

`127.0.0.1` is the default on purpose. Bind a public interface only behind TLS or
on a trusted LAN: the token is the only gate the protocol has.

## Endpoints

| Endpoint | Body | Reply |
|---|---|---|
| `POST /link/next?node=<addr>` | Result frames `LREP`, `LDATA`, `LEND`, one per line, or empty | The node's queued `LINK` frames, one per line, or empty |
| `POST /link/queue?node=<addr>` | One or more `LINK` frames, one per line | `queued=<n>` |
| `GET /link/results?node=<addr>` | none | Assembled result bodies |
| `GET /link/state` | none | JSON counters: `nodes`, `queued`, `delivered`, `results` |
| `GET /` | none | Plain text help |

`GET /` also requires the token: the gate covers every request, not only the
ones that carry frames.

`/link/next` consumes what it hands out; a `LINK` frame is never delivered twice.
Every frame is validated before anything is stored, so one invalid frame rejects
the whole request with 400 and the reply names the line and the reason. Results
stay available on `/link/results` until the bridge restarts.

`/link/results` prints one block per `id`:

```text
# id=<id> state=<state> size=<size>
<body>
# end
```

The body is the `LDATA` payloads concatenated in `off` order and terminated by a
newline. `size` comes from `LEND`, else from `LREP`, else from the body length. A
result whose `LREP` has not arrived yet reports `state=unknown`.

## Examples

```sh
curl -s -X POST -H "X-Link-Token: $LINK_TOKEN" \
  --data-binary 'TC1 LINK id=c1 token=secret cmd=status' \
  'http://127.0.0.1:8787/link/queue?node=1a2b3c4d'

curl -s -X POST -H "X-Link-Token: $LINK_TOKEN" \
  'http://127.0.0.1:8787/link/next?node=1a2b3c4d'
```

## State

Everything is held in memory. A restart drops the queues and the results, and the
OS sees an empty reply on its next poll. Nothing is written to disk.
