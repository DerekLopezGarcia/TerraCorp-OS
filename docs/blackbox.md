# TerraCorp OS — Black Box

The system described only by what crosses its boundary: what it reads, what it
writes, what it needs, and what it explicitly does not claim. Internal modules
are named only when naming them is the only way to state a fact.

Every statement below is traceable to a file in this repository. Anything not
traceable is listed in [Unverified](#unverified-do-not-assert) instead of being
presented as fact.

## Identity

| Field | Value | Source |
|---|---|---|
| Product | TerraCorp OS | `src/lib/tc/version.lua` |
| Version | 0.3.20 "Stash", API 1 | `src/lib/tc/version.lua` |
| Vendor string | TerraCorp Industrial Systems | `src/lib/tc/version.lua` |
| License | MIT | `LICENSE` |
| Host | OpenComputers, Minecraft 1.12.2 + Forge, Supersymmetry pack | `README.md` |
| Runtime | Lua 5.3, no build step | `AGENTS.md` |

It runs on player-owned computers inside the pack. It does not modify or
redistribute Supersymmetry or Susy-Core.

## Boundary

### Inputs

| Channel | Contract | Source |
|---|---|---|
| BIOS | Executes `/init.lua` from the selected boot filesystem with `load` | `docs/opencomputers.md` |
| Signals | `computer.pullSignal(1/30)`; `nil` on timeout | `src/boot/kernel.lua` |
| Signal kinds consumed | `key_down`, `key_up`, `touch`, `drag`, `drop`, `scroll`, `screen_resized`, `component_added`, `component_removed`, `modem_message`, `interrupted`, `shutdown` | `docs/opencomputers.md` |
| Keyboard | `key_down(address, char, code, playerName)`; `char` is a numeric code point or 0, `code` carries arrows/F-keys | `docs/opencomputers.md` |
| Pointer | `touch` on press, `drag` on movement, `drop` on release; a release without movement still emits `drop` | `docs/opencomputers.md` |
| Components | `filesystem`, `gpu`, `screen`, `modem`, `internet`, `disk_drive` | `src/init.lua`, `src/boot/kernel.lua`, `src/lib/tc/net.lua`, `src/lib/tc/updater.lua`, `src/lib/tc/cluster.lua` |
| Network frames | Protocol `TC1` version `1` on port `4200`, framed as `<protocol> <verb> <rest>` | `src/lib/tc/net.lua` |
| Boot gesture for icons | Icons open on `drop`, so the same gesture can drag instead of opening | `docs/opencomputers.md` |

### Outputs

| Channel | Contract | Source |
|---|---|---|
| Framebuffer | Writes through the bound GPU only; no OpenOS `term`, `shell`, or `event` | `src/boot/kernel.lua`, `AGENTS.md` |
| Files | The paths in [Persisted state](#persisted-state) | see table |
| Network | `TC1` frames over the first modem found | `src/lib/tc/net.lua` |
| HTTP | GitHub Releases only, through the `internet` component, for the updater | `src/lib/tc/updater.lua`, `docs/versioning.md` |
| Shutdown | `computer.shutdown` is reachable only through `kernel:poweroff` | `AGENTS.md` |

There is no telemetry endpoint and no third-party network destination in the
repository.

### Boot sequence

1. Find a boot volume: `computer.getBootAddress()` if the function exists,
   otherwise scan `component.list("filesystem")` for a volume that can open
   `/boot/kernel.lua`. The discovered address is written back with
   `setBootAddress` when available. (`src/init.lua`)
2. Bind the first `gpu` to the first `screen`. Failure here does not abort boot.
   (`src/init.lua`)
3. If `/var/update/pending` exists, load and run `/boot/apply.lua` before the
   kernel starts. The applier owns the screen, rolls back on failure, and boot
   continues either way. A marker that cannot be applied is removed so it cannot
   wedge every future boot. (`src/init.lua`)
4. Load `/boot/kernel.lua` from the volume and call `kernel.start{address,
   invoke, read}`. Kernel create `/etc` and `/var/log` and open
   `/var/log/tc.log` before loading preferences. (`src/boot/kernel.lua`)
5. Mount the desktop and run the signal loop at a 1/30 s idle wait — a target of
   30 loop iterations per second, not a promise of 30 visible frames.
   (`src/boot/kernel.lua`, `docs/opencomputers.md`)

Module resolution is fixed: `tc.*` maps to `/lib/tc/*.lua` and `apps.*` to
`/apps/*.lua`, loaded by the kernel, never by OpenOS `require`.
(`src/boot/kernel.lua`, `AGENTS.md`)

### Apps

Nine app ids are registered: `dashboard`, `files`, `console`, `settings`,
`notes`, `update`, `nodes`, `vault`, `gaia`. (`src/boot/kernel.lua`)

`README.md` and `AGENTS.md` list the same nine ids.

Every app must expose a desktop icon: a registered id, a 3-cell `icon` code, a
`short` label and a 9x5 `iconArt` pictogram. `npm run check` fails otherwise.
(`AGENTS.md`)

## Persisted state

All state lives on the boot volume. Nothing is stored outside it.

| Path | Purpose | Source |
|---|---|---|
| `/etc/terracorp.cfg` | Settings, theme, icon layout | `src/lib/tc/config.lua` |
| `/var/log/tc.log` | System log; truncated when it grows too large | `src/boot/kernel.lua` |
| `/var/notes.txt` | Notes scratchpad | `src/apps/notes.lua` |
| `/var/nodes.tsv` | Node registry | `src/lib/tc/registry.lua` |
| `/var/jobs.tsv` | Job journal | `src/lib/tc/jobs.lua` |
| `/var/vault/index.tsv`, `/var/vault/disks.tsv` | Vault index and disk reports | `src/lib/tc/vault.lua` |
| `/var/vault-in`, `/var/vault-out` | Vault inbox and outbox | `src/apps/vault.lua`, `src/apps/console.lua` |
| `/var/nodeupdate` | Node update staging root | `src/lib/tc/cluster.lua` |
| `/var/update/pending` | Update marker; presence triggers the boot-time applier | `src/boot/apply.lua` |
| `/var/update/status` | Result of the last update attempt | `src/boot/apply.lua` |
| `/var/update/stage`, `/var/update/backup` | Staging and rollback trees | `src/boot/apply.lua` |

The updater changes OS files on the boot filesystem only. It does not modify
`/etc`, user data (`/var/notes.txt`, `/var/nodes.tsv`), OpenOS, the BIOS, or the
EEPROM. (`docs/versioning.md`)

## Hardware contract

From `README.md`:

| Component | Minimum | Recommended |
|---|---|---|
| Minecraft / Forge | 1.12.2 | 1.12.2 |
| Modpack | Supersymmetry | Supersymmetry |
| OpenComputers | 1.7.x | 1.8.x |
| CPU | Tier 2 | Tier 3 |
| Screen | Tier 2 (80x25) | Tier 3 (up to 160x50) |
| Disk | 1 MB free | 2 MB |
| Memory | 1 MB | 2 MB |

The desktop adapts from 40x16 to 160x50 and uses the display's real resolution.
Below 80x25 the System cards compress. (`README.md`)

A floppy holds 512 KB in Supersymmetry, enough for the runtime; the pack allows
8192-byte network packets. (`docs/opencomputers.md`)

## OpenComputers version matrix

This is the part that must not be guessed. The repository carries two different
statements and they are not the same statement:

- `README.md` and `AGENTS.md` say the **1.7.x API is verified** and **1.8.x is a
  target**.
- `docs/opencomputers.md` says the **rack and server behaviour** was verified
  against `master-MC1.12` (1.8.x) and the pack's 1.8.9a build.

So: the desktop and filesystem layer is grounded in 1.7.x, while the cluster
layer is grounded in 1.8.x. Neither claim covers the other.

| Area | Status | Source |
|---|---|---|
| Minimal BIOS environment, `load`, `component`/`computer` | Verified | `docs/opencomputers.md` |
| `pullSignal`, signal names, scan codes | Verified subset | `docs/opencomputers.md` |
| `filesystem.list` returns a table, `spaceUsed`/`spaceTotal` in bytes | Verified | `docs/opencomputers.md` |
| GPU `set`/`fill`/`copy` returning `nil, "not enough energy"` | Verified | `docs/opencomputers.md` |
| Tier 3 palette being editable grayscale until set | Verified | `docs/opencomputers.md` |
| Racks, mountables, bus visibility, netboot floppy | Verified on 1.8.x | `docs/opencomputers.md` |
| `computer.getBootAddress` in the 1.7.x EEPROM sandbox | May be absent; the optional EEPROM manager supplies it | `docs/opencomputers.md`, `eeprom/init.lua` |
| `computer.realTime` behaviour in 1.7.x | **Pending in-game verification** | `docs/opencomputers.md` |
| GPU VRAM buffers / `bitblt` (1.7.5 dev builds, 1.8) | **Pending in-game verification**; every use is behind a `pcall` probe with the span path as fallback | `docs/opencomputers.md`, `docs/render.md` |

Consequences that hold regardless of version:

- `computer.energy()` may fail on nodes without an energy component and is called
  under `pcall`.
- `setBackground` / `setForeground` return the **previous color**, not a success
  boolean; palette indexing requires an explicit `true`.
- A failed framebuffer span must stay dirty and be retried.
- One Unicode code point occupies one cell; wide CJK and emoji break alignment
  and are unsupported, and `#string` counts bytes, so display widths come from
  `src/lib/tc/text.lua`.

## Non-goals

- No OpenOS runtime dependency. `require`, `event`, `fs` and `shell` are not
  used anywhere in the boot path.
- No runtime dependency of any kind; `fengari` is a dev dependency of the local
  harness.
- No modification of the world outside the computer: no block placement, no
  effect on Supersymmetry itself.
- No automatic EEPROM write on a normal install; the EEPROM manager is optional.
- No silent update: a release is fetched only when asked, and a failed
  fetch/validate leaves the current installation in place.

## Unverified (do not assert)

The following are unknown or unmeasured, and must not be stated as fact:

- Real in-game memory use and wall-clock boot time. The local harness does not
  measure either; use `/var/log/tc.log` and the F0 protocol.
- Visible frame rate. OpenComputers documents resolution and color depth but no
  fixed refresh in Hz; 30 iterations/second is a requested idle wait, and input
  signals can wake the loop sooner.
- Behaviour of `computer.realTime` on 1.7.x. The tick-rate estimate degrades to
  "no data" when it is missing or non-numeric.
- Whether the VRAM buffer API exists on the target build. It is probed, never
  assumed; the span path is the fallback.
- Whether a short-form component address resolves on 1.7.5 and 1.8
  (`docs/names.md` records the open question).

## Verification gates

Before a change is considered complete the repository requires `npm run check`,
`npm run sim`, `npm run sim:oc`, plus the focused test for whatever was touched
(`AGENTS.md`). `npm run check` currently reports 42 files checked, 0 errors, and
a 37-file manifest.
