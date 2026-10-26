# TerraCorp OS Dev Log — 0.3.x: the cluster grows up

*TerraCorp OS is a Lua desktop OS for OpenComputers (Minecraft 1.12.2,
Supersymmetry pack). Everything below shipped today as v0.3.1 through
v0.3.5 — five tagged releases, all verified by the local harness. They are
published but **not yet proven in-game**: the full 0.3.x verification run
(provisioning, updates, jobs, Vault, the works) is still pending, and it may
send fixes back before any of this is called stable. Repo:
https://github.com/DerekLopezGarcia/TerraCorp-OS*

---

## v0.3.1 "Pull" — network provisioning

The installer floppy used to carry the whole OS payload. Now it carries only
a **pull bootstrap** (~10 KB): a tiny `netfetch.lua` plus `tc.net`. An
unprovisioned server boots the floppy, says HELLO over the wired rack network,
and **pulls the runtime from the master** in 512 B chunks. The boot address
moves to the HDD only after a complete, verified copy — an interrupted install
just boots the floppy again. Node versions are tracked in the registry, the
Nodes app marks stale nodes (`· v0.3.0 (update)`), and the master can now
**update its slaves**: it checks GitHub for the latest stable release, stages
it on `/var/nodeupdate/`, and offers it to every node — even before the master
itself has been updated.

## v0.3.2 "Relay" — a job queue with no coordinator

Instead of a central broker, Relay is a **coordinator-less work queue**. Any
job is broadcast (`JOB`); the **first claim wins** (`CLAIM` → `GRANT` with a
lease token); results are idempotent; expired leases are re-offered (3
attempts); the publisher's journal lives on disk (`/var/jobs.tsv`), so a
master restart re-offers unfinished work. Workers run only **named,
contract-bound tasks** — never remote code. First built-ins: `fs.check`,
`disk.report`, `log.tail`, `comp.count`. Nodes can be **drained** (stop
claiming, survive reboots) from the Nodes app, and the header doubles as
`plant status`: up counts, queued/granted jobs, drained nodes.

## v0.3.3 "Waves" — batched node updates

Updating every node at once meant rebooting the whole rack. **Update** now
works in waves: each wave offers the update to **half of the remaining
nodes**, so part of the rack always stays online while the rest reboots into
the new version. A wave advances when its nodes report the new version, fall
offline, or hit the 120 s wave window. The Nodes line shows live progress
(`Update 0.3.5 · wave 2 · 1/4 updated · 2 queued`) and finishes with a
per-node count.

## v0.3.4 "Vault" — one big shared disk

Design decision: **no software RAID, no mirror**. Every server keeps its
system disk for the OS and programs; **all other disks across the network
join a single storage pool** presented as one namespace. Files are stored
whole on the disk with the most free space; the master keeps the index; each
node is a gateway that reads/writes only its own local disks (the only way
OpenComputers allows it); data crosses the network as ordered chunks, with
part-file + rename so a partial write never appears under the real name.
Files up to 64 KB in this build.

## v0.3.5 "Stash" — Vault gets a UI and a backup brain

- The **Vault app**: browse the namespace with sizes, read files into the
  cache with a preview, copy in from `/var/vault-in/`, copy out to
  `/var/vault-out/`, delete.
- Terminal commands: `vault`, `vls`, `vput`, `vget`, `vrm`.
- The **index is backed up to a pool disk** whenever it changes, and a fresh
  master with an empty index restores it from that backup — the index is no
  longer a single point of total loss.
- Pool usage shows up in the Nodes app.

## Redundancy, decided

The pack ships a **RAID block**, so TerraCorp will never implement mirroring
itself: a RAID volume is just one more disk as far as the OS is concerned and
joins the pool automatically. The only pending item is verifying the block's
component API in-game.

## Status: built, not yet proven

Everything above is on GitHub with tags and Releases, but the **in-game
verification of the whole 0.3.x phase is still to do**: real rack
provisioning, live updates by waves, job claiming under real latency, Vault
against actual disks (and the RAID block's component API), plus a clean 30
minute log. The harness is thorough, but OpenComputers always finds something.
Expect patch releases; the checklist lives in
[`docs/tests.md`](https://github.com/DerekLopezGarcia/TerraCorp-OS/blob/main/docs/tests.md).

## Numbers from this session

- **5 releases**, ~5,900 lines changed across 20+ commits.
- Harness gates: 42 files syntax-checked, manifest-synced; full test suites
  for framing/transport/registry, provisioning, boot, updater (4 suites),
  screens at 6 resolutions, GPU faults, icon drag/layout, and 7 strict
  desktop scenarios — all green before every tag.

## What's next

0.4 **Sessions**: replacing the desktop singleton with per-session windows and
packed framebuffers (2 bytes per cell), so apps can eventually run on the node
with the most free RAM and serve lightweight factory terminals (0.5).

*The step-by-step verification checklist for this whole phase lives in
[`docs/tests.md`](https://github.com/DerekLopezGarcia/TerraCorp-OS/blob/main/docs/tests.md).*
