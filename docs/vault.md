# Vault — pooled storage over the cluster (0.3.4)

> Decision: **no RAID and no mirror for now**. Every server's system disk
> stays local for the OS and programs; all other disks on every server join
> one shared storage pool, presented as a single namespace instead of X
> separate nodes. Mirroring and redundancy are future work (F5), not 0.3.4.

Transport: `tc.net` frames. A node reads and writes **its own** disks locally
(server HDD components are `Visibility.Neighbors`, so only the node itself can
touch them); only the file data crosses the network as frames.

## Layout

| Piece | Where | Holds |
|---|---|---|
| Pool index | master `/var/vault/index.tsv` | one line per file: `path`, `node`, `disk`, `size` |
| Disk table | master `/var/vault/disks.tsv` | one line per spare disk: `node`, `modem`, `disk`, `total` (KB) |
| File data | node spare disks | `vault/<path>` on the disk component |

- The **system disk** of every server (the boot volume) is never part of the
  pool. Every other local `filesystem` component that is not read-only joins
  it — on the reference build, three disks per server.
- The namespace is a **virtual tree**: directories exist only as path prefixes
  in the index, so listing never touches the network.
- Placement picks the disk with the most free space (index sizes count as
  used). A file is stored whole on one disk; files up to 64 KB in 0.3.4a.
- The master is the single keeper of the index in 0.3.4a. Losing it loses the
  names (the data is still on the disks). An index backup on a pool disk is
  planned for 0.3.4b together with the UI.

## Frames

| Message | Direction | Fields |
|---|---|---|
| `VDISK` | node → master | `id`, `disks` (`addr:KB,addr:KB` of its spare disks) |
| `VOPEN` | master → node | `id`, `disk`, `path`, `size` |
| `VDATA` | master → node | `id`, `off`, `data` (≤ 512 B per frame) |
| `VDACK` | node → master | `id`, `off` (bytes accepted so far) |
| `VDONE` | node → master | `id`, `size` (writes and deletes) |
| `VERR` | node → master | `id` (any failed transfer) |
| `VREAD` | master → node | `id`, `disk`, `path`, `off` |
| `VDIRS` | node → master | `id`, `path`, `files`, `dirs` |
| `VDEL` | master → node | `id`, `disk`, `path` |

Write flow: `VOPEN` → `VDATA`/`VDACK` handshake, one chunk per tick, in
order. The node writes to `vault/<path>.part` and renames it on the final
`VDONE` after checking the size, so a partial write never shows under the
real name. Read flow: `VREAD` per 512 B slice, node answers `VDATA` with the
total size; the master assembles the body across ticks.

## Master API (tc.vault, one transfer at a time)

- `write(path, body)` / `read(path)` / `remove(path)` — start an async
  transfer; `tick` advances it one step per tick so the desktop stays
  responsive.
- `list(path)` / `usage()` — synchronous: the namespace comes from the index
  and usage is per disk (`total`, `used`, `free`) plus pool totals.
- Completed reads are cached in memory and served from the cache.

## Phasing

1. **0.3.4a — shipped in v0.3.4.** Protocol, node disk gateway, master pool,
   index and API. Harness tests cover the full write/read/delete flows
   against fake disks, pool discovery, and index persistence.
2. **0.3.4b — shipped in v0.3.5.** The **Vault** app (browse the namespace,
   read into the cache, store from `/var/vault-in`, save out to
   `/var/vault-out`, delete), the `vault`/`vls`/`vput`/`vget`/`vrm` Terminal
   commands, pool usage in the Nodes idle line, and the index backup: the
   master writes its index to a pool disk whenever it changes and a fresh
   master with an empty index restores it from that backup.

## Redundancy: the RAID block, not software mirroring

TerraCorp does not implement mirroring. The pack ships a **RAID block** that
composes disks into a redundant volume exposing a `filesystem` component; a
RAID volume is just one more spare disk as far as this OS is concerned:

- The node gateway already reports any local non-boot `filesystem` component,
  so a RAID block's volume joins the pool automatically with its full
  capacity, and Vault stores files on it like any other disk.
- Redundancy, rebuilds, and failure behavior stay the RAID block's problem;
  the F5 mirror work is dropped. The only TerraCorp-side item left is
  surfacing per-disk health/usage in the data-center views.
- **Pending in-game verification:** the RAID block's component kind, whether
  its volume reports `spaceTotal`/`spaceUsed` in bytes like other disks, and
  how it behaves when a member disk fails. Until verified, do not assume its
  API; see [`opencomputers.md`](opencomputers.md).
