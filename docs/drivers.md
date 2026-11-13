# Drivers — declarative plugins for component kinds

Status: **design** (0.4.1). Requested by the pack's co-operator: an Adapter can
expose signs, chests, tanks, drawers, crates, machines and whatever the pack adds
next, each with its own method names. If those names live in the kernel, the plant
freezes at the components we know today. They must be **registerable**, and
registering must not mean writing code into the world.

## Principle: a descriptor is data, not code

A driver is a plain table: method names, argument order, field paths, units.
**No functions, no expressions, no Lua chunks.**

The reason is not style. `/etc` is writable through the external link
(`linkControl = write`), so a descriptor that executes Lua would turn a config
edit into remote code execution — exactly what "no frame carries code" forbids.
The kernel interprets the descriptor; the descriptor never runs.

## Closed capability vocabulary

New **kinds** map onto existing capabilities. New **capabilities** are kernel
work, decided on purpose, not discovered by accident.

| Capability | Operations | Consumers |
|---|---|---|
| `inventory` | size, stack(side, slot), key fields, count field | stock reader, `move`, craft loop |
| `tank` | level, capacity, fluid key | fluid stocks |
| `energy` | stored, capacity | power readout, plant alarms |
| `redstone` | getInput, getOutput, setOutput | gates, alarms, interlocks |
| `text` | read, write | signs and labels in the hall, tiny readouts |
| `transfer` | transfer(from, to), transferInto | `move` |

That table is the contract outward: a component with `inventory` can be a stock
member, one with `redstone` can be a gate, one with `text` can be a wall. The
service never learns the block's name — only which capabilities it has.

## Descriptor shape

Placeholders below; the real method names come from the probe (`driver.dump`),
not from this document.

```lua
return {
  kind = "inventory",
  sides = true,                      -- methods take a side argument
  capabilities = {
    inventory = {
      size  = { method = "getInventorySize", args = { "side" } },
      stack = { method = "getStackInSlot",  args = { "side", "slot" } },
      key   = { fields = { "name", "damage" } },   -- how to build an item key
      count = { field  = "size" },
    },
  },
}
```

```lua
return {
  kind = "tank",
  sides = false,
  capabilities = {
    tank = {
      level    = { method = "getTankLevel",    args = { "tank" } },
      capacity = { method = "getTankCapacity", args = { "tank" } },
      fluid    = { method = "getFluidInTank",  args = { "tank" }, key = { "name" } },
    },
  },
}
```

```lua
return {
  kind = "sign",
  sides = false,
  capabilities = {
    text = {
      read  = { method = "getValue" },
      write = { method = "setValue" },
    },
  },
}
```

## Adding a kind, end to end

1. The block is placed and the Adapter sees it. The kind has no driver, so
   `component.list` reports it as `driver=unknown` — visible, not ignored.
2. `driver.dump <address>` returns `component.methods` and `component.doc` for
   that address. That is data, safe to move around and paste into a ticket.
3. The operator (or the agent, as a `proposal_create`) writes
   `/etc/drivers/<kind>.lua` following the shape above.
4. `driver.reload` re-parses and revalidates — no reboot, so iterating on a new
   block is a file edit plus one command.
5. If the block needs an operation the vocabulary lacks, **stop**: that is a
   kernel decision, recorded, tested. It is not a config escape hatch.

## What the registry carries per component

`address, kind, driver, capabilities, faces, first_seen, paths`.

`path.query` returns capabilities with the members, so an app can ask "can this
path hold items?" before issuing a call, instead of discovering it through
errors.

## Failure modes

| Case | Behaviour |
|---|---|
| Descriptor names a method the component lacks | Member goes `driver_invalid` naming the missing method; no silent degradation |
| Two drivers claim one kind | Declared priority decides; a tie is `driver_conflict` |
| Descriptor uses an unknown capability | Refused at load and listed; the capability vocabulary does not stretch |
| Descriptor file is broken | That kind falls back to `unknown`; the rest of the registry keeps working, boot is unaffected |
| Component replaced by another kind | `wrong_kind` on every operation, never a reinterpretation |

## What this is not

Not a scripting layer for plant logic. A descriptor says **how to call a block**,
never **what the plant should do**. Recipes, thresholds and alarms stay outside
the game (decision 16).

## In-game verification checklist

1. `driver.dump` for: Storage Drawer, GT crate, chest, multiblock tank, **sign**,
   transposer. The first six descriptors are written from these dumps.
2. Round trip: descriptor → read a drawer → the number matches a hand count.
3. `driver.reload` with a deliberate typo: the kind degrades to `unknown` and the
   rest of the plant keeps reading.
4. Replace a chest with a sign under the same path: `wrong_kind`, and the path
   reports it rather than silently summing zero.
5. A sign as a wall: write a stock number into it from the service and read it
   back. If that works, the simplest possible hall readout costs one sign.

Cross-links: [`names.md`](names.md) (addresses, paths, registry),
[`middleware.md`](middleware.md) (proxy and profile), [`roadmap.md`](roadmap.md)
(decision 22), `docs/opencomputers.md` (verified mod facts).
