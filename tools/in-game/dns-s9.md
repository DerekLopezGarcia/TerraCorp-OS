# DNS1 M0 — S9 in-game runbook (a1 / a5 / a6)

**Owner of the run:** Derek (his world). **Not evidence by itself:** this file is
the script. Evidence is the transcript archived in `docs/tests.md` §In-game
protocol → §DNS1 M0 (S9), a row in §Results log, and the three QA cases
`c8-3546` (modem_message + wireless limit), `c9-e8cb` (direct REPL, master off)
and `c10-fdce` (2 nodes + master matrix) marked with the result. Until then
a1/a5/a6 stay unsigned and the card stays blocked.

The fengari harness already proved the protocol logic (111 repo checks + 137
QA probe checks): frame codec, 4201 on every modem, reply by ingress side,
dedupe, HELLO/DESCRIBE, catalog, allowed/denied EXEC, path results and the
direct fallback. What only real OpenComputers can prove is the **runtime
shape**: argument order of `modem_message`, reply through the receiving modem,
the wireless packet limit, and the tablet REPL with the master powered off.

This runbook is written to be short: five probes, one table, one archive
snippet. Budget ≈30–40 minutes on a test rig. Do not run it on the plant.

---

## 0. TL;DR

1. Record the addresses (master, N1, N2, tablet, W1) in a desktop Lab REPL.
2. Configure: master `dnsMaster=self`; N1/N2 `role=line` + `master`/`dnsMaster=<master>`;
   tablet `dnsMaster=<master>`. Reboot all.
3. **Probe A** (shape) and **Probe B** (wireless limit) with the master off.
4. **Probe C** (direct client, master still off) → a5.
5. Power the master on, **Probe D** (catalog + 2-node matrix) → a6.
6. **Probe E** (TC1 path) on the master; then archive in `docs/tests.md`.

If anything fails, stop and record it; do not edit code during the session.

---

## 1. Rig

| Machine | Role | Modem(s) | Config |
|---|---|---|---|
| Master | desktop | one wired **and** one wireless | `dnsMaster=self`, `dnsPort=4201` |
| N1 | line | wired only (no wireless modem) | `role=line`, `master=<MASTER>`, `dnsMaster=<MASTER>` |
| N2 | line | wireless only (no wired modem, no cable) | `role=line`, `master=<MASTER>`, `dnsMaster=<MASTER>` |
| Tablet | desktop | wireless | `dnsMaster=<MASTER>` |
| W1 | plain OpenOS laptop | wireless | used as sender in Probes A/B |

The master needs both transports because N1 is wired-only and N2 wireless-only.
Keep the machines within wireless range. A wired-only node is a machine with a
wired modem connected by cable to the master's wired modem (or to a switch);
"wireless-only" means no wired modem at all.

> The nodes end up headless (`role=line`). Configure them **while they still
> run the desktop UI**, then set `role=line` last and reboot. To reconfigure a
> headless node, boot it from OpenOS or reinstall; do not try to reach a Lab on
> a line node.

---

## 2. Configure (Lab REPL, before reboot)

Open **Terminal → `lua`** on each desktop. The Lab REPL has `computer`,
`component`, `config`, `kernel`, `vfs` and `version` in scope. Run the block for
that machine, check every printed value is `true`, then `reboot`.

First fill these globals once (same values for the whole session):

```lua
MASTER = "<MASTER>"; N1 = "<N1>"; N2 = "<N2>"; TABLET = "<TABLET>"
```

Master:

```lua
print(config.set("role", "desktop"), config.set("dnsMaster", "self"),
      config.set("dnsPort", 4201), config.set("dnsTransport", "auto"))
print(config.save(vfs))
```

N1 (run this on N1 while it is still a desktop; `role` last):

```lua
print(config.set("master", MASTER), config.set("dnsMaster", MASTER),
      config.set("dnsPort", 4201), config.set("dnsTransport", "auto"))
print(config.set("role", "line"))
print(config.save(vfs))
```

N2: same as N1 but on N2.

Tablet:

```lua
print(config.set("role", "desktop"), config.set("dnsMaster", MASTER),
      config.set("dnsPort", 4201))
print(config.save(vfs))
```

After the reboot, confirm on the tablet and master:

```lua
print("role=" .. config.get("role"), "master=" .. config.get("master"),
      "dnsMaster=" .. config.get("dnsMaster"), "port=" .. config.get("dnsPort"))
```

Expected: master `role=desktop master= dnsMaster=self port=4201`;
tablet `role=desktop dnsMaster=<MASTER> port=4201`.

---

## 3. Record addresses and modems

Run on each machine (desktop Lab; for N1/N2 before `role=line`):

```lua
print("computer", computer.address(), "terracorp", version.version)
for a in component.list("modem") do
  print("modem", a, "wired=" .. tostring(component.invoke(a, "isWired")))
end
```

Record in the archive:

| Machine | computer address | modem address(es) | wired? |
|---|---|---|---|
| Master | | | |
| N1 | | | true only |
| N2 | | | false only |
| Tablet | | | false |
| W1 | | | false |

N1 must print exactly one modem with `wired=true`; N2 exactly one with
`wired=false`. If not, fix the wiring before continuing.

---

## 4. Probe A — raw `modem_message` shape (a1)

Run the receiver on the **tablet**:

```lua
local m; for a in component.list("modem") do m = a end
component.invoke(m, "open", 4201)
local stop = computer.uptime() + 45
repeat
  local p = table.pack(pcall(computer.pullSignal, 1)) -- p[1]=ok, p[2]=event, p[3..]=args (kernel pack shape)
  if p[2] == "modem_message" then
    for i = 1, p.n do print(i, type(p[i]), tostring(p[i])) end
    stop = 0
  end
until computer.uptime() > stop
if stop ~= 0 then print("NO modem_message within 45 s") end
```

Then, on **W1** (the second wireless computer), broadcast a marker on 4201:

```lua
local m; for a in component.list("modem") do m = a end
print(component.invoke(m, "broadcast", 4201, "s9-shape"))
```

The tablet prints one line per value. Expected from the official OC order
`modem_message(localAddress, remoteAddress, port, distance, ...)` — see
[`component:modem`](https://ocdoc.cil.li/component:modem) and the assumption
recorded in `docs/opencomputers.md:26-36`:

| line | value |
|---|---|
| `p[3]` | tablet modem address (the modem that received) |
| `p[4]` | W1 computer address (the sender) |
| `p[5]` | 4201 |
| `p[6]` | distance (a number; ignore the value) |
| `p[7]` | `s9-shape` |

Record the actual values. Then confirm the DNS1 parser sees the same mapping —
on the tablet:

```lua
local w, e = kernel.dnsclient:who(5, N2)
print(e or ("who " .. w.node .. " " .. w.proto .. " v" .. w.ver .. " boot=" .. tostring(w.boot)))
local s = kernel.dnsnet:shape()
if s then
  print("first=" .. tostring(s.first), "second=" .. tostring(s.second),
        "side=" .. tostring(s.side), "from=" .. tostring(s.from))
else
  print("no DNS1 shape recorded")
end
```

Expected: `shape.first` = tablet modem address, `shape.second` = N2 computer
address, `shape.side = first`, `shape.from = second` (the parser learned the
side, which is what makes the reply leave through the receiving modem).

If `p[4]` is the sender's **modem** address rather than its computer address,
record it: DNS1 addresses nodes by computer address, and that would be a real
finding (stop and report; do not guess).

---

## 5. Probe B — wireless packet limit (a1 input)

Keep the master powered **off**. On the tablet (receiver, wireless):

```lua
local m; for a in component.list("modem") do
  if component.invoke(a, "isWired") == false then m = a end
end
print("receiver", m)
component.invoke(m, "open", 4199)
local stop = computer.uptime() + 30
repeat
  local p = table.pack(pcall(computer.pullSignal, 1)) -- p[1]=ok, p[2]=event, p[3..]=args (kernel pack shape)
  if p[2] == "modem_message" and p[5] == 4199 then
    print("got", #tostring(p[7]))
  end
until computer.uptime() > stop
```

Immediately, on W1 (or any second wireless computer):

```lua
local m; for a in component.list("modem") do
  if component.invoke(a, "isWired") == false then m = a end
end
for _, n in ipairs({ 256, 512, 900, 2048 }) do
  print(n, pcall(component.invoke, m, "broadcast", 4199, string.rep("x", n)))
end
```

Record which sizes arrived and the largest one. `MAX_TX` is 900 B today; if the
largest received is below 900, a1 is **partial** and M1 must lower `MAX_TX` and
re-split the snapshot. If 2048 arrives, optionally repeat with 4096 once.

---

## 6. Probe C — direct client with the master off (a5)

Keep the master **powered off**. On the tablet:

```lua
c = kernel.dnsclient
print("client", c ~= nil)
```

Expected `client true`. If it prints `false`, `dnsMaster` was not set/saved —
fix it and rerun the config step.

Use **N2** for the direct probes: the tablet is wireless, so with the master
off it can only reach the wireless-only node. (N1 is wired-only; reaching it
directly would require a wired modem on the tablet. That is not a failure of
a5 — the fallback is proven against N2.)

Name resolution (direct, no master):

```lua
local t = computer.uptime()
local w, e = c:who(5, N2)
print(string.format("%.1fs", computer.uptime() - t),
      e or (w.node .. " " .. w.proto .. " v" .. w.ver .. " boot=" .. tostring(w.boot)))
```

Describe node and endpoint (the master route times out, then the client asks
the node directly — this is the fallback under test):

```lua
local t = computer.uptime()
local b, e = c:describe(N2, "node")
print(string.format("%.1fs", computer.uptime() - t), e or "ok")
if b then print(b.name, "transports=" .. tostring(b.transports),
                "endpoints=" .. #b.endpoints, "paths=" .. #b.paths) end
local b2, e2 = c:describe(N2, "endpoint:inventory_controller")
print(e2 or "ok")
if b2 then print(b2.name, "allow=" .. table.concat(b2.allow, ","),
                 "docs=" .. tostring(b2.docs):sub(1, 60)) end
```

Expected: describe node shows N2's name, transports `wireless`, 2 endpoints and
1 path; the endpoint shows `allow=getAllStacks`, docs text. Total time for the
first describe ≈2–5 s (master timeout + WHO + direct request) — record it.

Allowed EXEC:

```lua
local v, e = c:exec(N2, "endpoint:inventory_controller", "getAllStacks")
print(e or ("stacks=" .. #v))
```

Denied EXEC (must not invoke the component):

```lua
local v, e = c:exec(N2, "endpoint:inventory_controller", "getStackInSlot", { 1 })
print(tostring(v), e)
```

Expected: `nil denied`.

Path (one result per member, alphabetical: `dns.status` then
`inventory_controller`):

```lua
local v, e = c:exec(N2, "path:spike", "getAllStacks")
if not v then print(e) else
  for _, m in ipairs(v.members) do
    print(m.endpoint, m.ok, m.error or (m.value and #m.value))
  end
end
```

Expected: `dns.status false unknown_method` and
`inventory_controller true 2`.

If the tablet also has a wired modem connected to the wired network, repeat
the block for N1; otherwise record that N1 direct is unreachable with the
master off (expected by the topology, not a defect).

Record the transcript lines and stop when the master is still off.

---

## 7. Probe D — master on: catalog and the real 2-node matrix (a6)

Power the master on. Wait 10 s (nodes tick every second and publish). On the
tablet:

```lua
c = kernel.dnsclient
local b, e = c:catalog()
if not b then print(e) else
  print("nodes", #b.nodes)
  for _, n in ipairs(b.nodes) do print(n.id, n.name, "stale=" .. tostring(n.stale)) end
end
```

Expected: `nodes 2`, N1 and N2, `stale=false`. Then the matrix with the master
on, for each node:

```lua
for _, node in ipairs({ N1, N2 }) do
  local b, e = c:describe(node, "node")
  print(node, "describe", e or (b.name .. " transports=" .. tostring(b.transports)))
  local v, e2 = c:exec(node, "endpoint:inventory_controller", "getAllStacks")
  print(node, "getAllStacks", e2 or ("stacks=" .. #v))
  local d, e3 = c:exec(node, "endpoint:inventory_controller", "getStackInSlot", { 1 })
  print(node, "getStackInSlot", tostring(d), e3)
  local p, e4 = c:exec(node, "path:spike", "getAllStacks")
  if p then
    for _, m in ipairs(p.members) do
      print(node, "path", m.endpoint, m.ok, m.error or (m.value and #m.value))
    end
  else
    print(node, "path", e4)
  end
end
```

Expected for both nodes: `describe ok`, `getAllStacks stacks=2`,
`getStackInSlot nil denied`, path `dns.status false unknown_method` +
`inventory_controller true 2`.

Fill the real matrix (this is the a6 evidence; it goes into the archive as-is):

| Check | N1 (wired) | N2 (wireless) | Expected |
|---|---|---|---|
| `who` | | | WHOACK node / DNS1 / ver 1 / boot |
| `describe node` | | | name, transports, 2 endpoints, 1 path |
| `describe endpoint:inventory_controller` | | | allow `getAllStacks`, docs |
| `exec getAllStacks` | | | 2 stacks |
| `exec getStackInSlot` | | | `denied`, component not invoked |
| `exec path:spike` | | | 2 members, one result each |
| `catalog` | 2 nodes | 2 nodes | not stale |

If the tablet's master route ever times out, the client silently falls back
direct. For the row above, also note the latency: a relayed EXEC is <1 s, a
fallback is ≈2–5 s. If you see ≈2 s on the first EXEC after the master boot,
note it (it would be the rid collision from BUG-002, which is fixed in this
tree; it should not happen).

---

## 8. Probe E — TC1 kernel path (pre-S9 finding, not M0 scope)

The master's legacy TC1 registry (port 4200) is what the plant uses today.
`src/boot/kernel.lua:323` unpacks `table.unpack(pack, 2, pack.n)` for
`master:handle`, while `src/lib/tc/report.lua:498` unpacks from slot 3. With the
documented event order, at most one is right. The check below settles it.

On the **master**, with N1 online:

```lua
local s = kernel.master:status()
print("before", "received=" .. s.received, "nodes=" .. #kernel.master.nodes,
      "online=" .. s.online)
```

Reboot N1 (power cycle; a line node publishes a HELLO immediately in
`report:start`). Wait 30 s, then:

```lua
local s = kernel.master:status()
print("after", "received=" .. s.received, "nodes=" .. #kernel.master.nodes,
      "online=" .. s.online)
for _, n in ipairs(kernel.master.nodes) do print(n.name, n.state) end
```

Expected if the argument order is correct: `received` increases and N1 is
`online`. Expected with the current code (the bug): `received` stays the same,
N1 never appears. The failure is silent (no log line), so do **not** use
`grep` as proof; the counter is the proof. Still archive any log line:

```sh
grep -i "master" /var/log/tc.log | tail -20
```

If `received` stays flat, say so in the archive; it is a pre-existing TC1
defect, outside M0, and product decides whether to open the bug after S9. Do
not patch `kernel.lua` during the session.

---

## 9. Archive the evidence

### 9.1 `docs/tests.md` — after `## In-game protocol`

Insert this subsection (fill it, do not leave placeholders):

```md
### DNS1 M0 (S9)

- Date/owner: 2026-__-__ · Derek
- Build: TerraCorp OS <version> (working tree, no commit) · harness pre-check: 111 repo checks + 137 QA probe checks (fengari)
- Topology: N1 `<addr>` wired-only · N2 `<addr>` wireless-only · master `<addr>` · tablet `<addr>`
- `modem_message` raw shape (`p[3..7]`): `<localAddr>` `<remoteAddr>` `<port>` `<distance>` `<message>`
- DNS1 shape: `first=<...> second=<...> side=<...> from=<...>`
- Wireless limit (port 4199, `x` payload): 256 `<ok/lost>`, 512 `<ok/lost>`, 900 `<ok/lost>`, 2048 `<ok/lost>`; max received `<n>` B
- Direct client, master off (N2, wireless): `who` `<node/ver/boot>` · `describe node` `<name/transports/endpoints>` · `describe endpoint:inventory_controller` allow `getAllStacks` · `exec getAllStacks` `<n>` stacks · `exec getStackInSlot` `denied` · `path:spike` `<members>`
- Master on: `catalog` `<n>` nodes (`stale=` `<bool>`) · relayed `getAllStacks` `<n>` stacks · relayed `getStackInSlot` `denied`
- Real matrix: see the table below
- TC1 path: `kernel.master:status().received` before `<x>`, after N1 reboot `<y>`; nodes online `<n>/2`; log `<excerpt>`
- Result: a1 `<pass/partial/fail>`, a5 `<pass/fail>`, a6 `<pass/fail>`; leftover risk `<...>`

| Check | N1 (wired) | N2 (wireless) |
|---|---|---|
| `describe node` | | |
| `describe endpoint:inventory_controller` | | |
| `exec getAllStacks` | | |
| `exec getStackInSlot` | | |
| `exec path:spike` | | |
```

### 9.2 `docs/tests.md` — one row in `## Results log`

```md
| 2026-__-__ | DNS1 M0 S9: N1 `<addr>` wired, N2 `<addr>` wireless-only, master `<addr>`, tablet `<addr>` | n/a | n/a | n/a | n/a | n/a | a1/a5/a6 `<pass/fail>`; details in §In-game protocol → DNS1 M0 (S9) |
```

If the Results-log columns do not apply (this is not a UI render test), add the
same text as a short paragraph under the table and say why the row is `n/a`.

### 9.3 Card `t-a330038a`

Post one comment with: the archived section link/line, the filled matrix, the
wireless max, the TC1 counter before/after, and one sentence per acceptance
item (a1/a5/a6). Then the QA cases `c8-3546` / `c9-e8cb` / `c10-fdce` can be
marked with the result and a1/a5/a6 can be ticked by the acceptance owner.
Do not sign the requirement from the runbook alone.

---

## 10. Abort / failure handling

| Symptom | What to do |
|---|---|
| No `modem_message` within 45 s | Check modem opened on 4201, wired cable/switch, wireless distance, and that the sender's broadcast actually happened. Record `kernel.dnsnet:stats()` on the receiver. |
| `p[4]` is a modem address, not the sender computer | Stop the DNS1 probes. DNS1 addresses nodes by computer address; this is a real finding for the next design round. Archive raw `p[3..7]` and report. |
| Wireless max < 900 B | Record it; a1 is partial; a6 can still run but note `MAX_TX` must shrink in M1. Do not change code. |
| Tablet `client false` | `dnsMaster` not set/saved, or the desktop did not start because the config is wrong; fix config, reboot, rerun. |
| Master catalog 0 nodes | Wait 10 s, check node config `master`/`dnsMaster`, check the master's two modems, then `kernel.dnsnet:stats()` on a node (sent/publish). Record. |
| TC1 `received` flat after reboot | Pre-existing kernel path bug (see §8). Archive the counter; do not patch. |
| Any crash/traceback | Copy the full traceback from the screen or `/var/log/lab.log`; stop. |

Do not modify `src/` during the session, do not commit, and keep the other
card's flash/size changes untouched.

---

## 11. What fengari already proved (and what it cannot)

Re-run before the session to confirm the tree:

```sh
npm run test:dns
node qa/dns-m0/run.js all
```

Expected: `PASS dns: 111 checks passed` and `PASS all: 137 checks passed`
(second command from `C:\Users\Derek\dsh-workspace`).

Fengari covers: both `modem_message` layouts (with and without the pcall
status), side/from selection, reply through the ingress modem, dedupe
`(from,rid)` TTL/cap, HELLO/DESCRIBE, catalog paging/stale, allowed/denied
EXEC, path results with the fixed `value` codec, and the direct fallback with
missing/offline/mute master. It **cannot** cover: real event order, a real
wireless packet budget, a real tablet screen/REPL, or the TC1 branch in
`kernel.lua:323` — that is exactly what Probes A–E add.

---

## Appendix — fill-in record

```text
MASTER computer: ................  modems: ................
N1     computer: ................  modem:  ................  wired
N2     computer: ................  modem:  ................  wireless
TABLET computer: ................  modem:  ................  wireless
W1     computer: ................  modem:  ................  wireless

modem_message p[3..7]: ................
DNS1 shape first/second/side/from: ................
wireless 256 / 512 / 900 / 2048: ................
master off direct: who .... describe .... exec .... path ....
master on catalog: .... nodes; relayed exec: ....
TC1 received before/after: .... / ....
S9 verdict: a1 .... a5 .... a6 ....
```
