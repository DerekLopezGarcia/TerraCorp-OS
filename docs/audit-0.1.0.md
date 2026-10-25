# TerraCorp OS 0.1.0 “Foundry” Audit

This audit reviewed `src/`, `eeprom/`, `tools/`, and `docs/` against the
OpenComputers `master-MC1.12` source and ran the OS against API-faithful fake
components. Date: 2026-10-23.

## Summary

The architecture (small kernel, own VFS, difference-based framebuffer, clear
app contract) was sound. The original harness had modeled several OpenComputers
APIs incorrectly, producing false-green tests. The following defects were
corrected:

| Severity | Finding | Status |
|---|---|---|
| Critical | VFS treated `filesystem.list`'s table as an iterator | Fixed |
| Critical | Storage used nonexistent `space()` and mixed bytes/KB | Fixed |
| Critical | Harness faked `list`, disk space, and directory-write behavior | Fixed |
| High | `screen_resized` called `rebindScreen` without `self` | Fixed |
| High | Clipped boxes could draw outside small windows | Fixed |
| High | Installer ignored component-invoke failures while flashing EEPROM | Fixed |
| Medium | `/etc` was missing in manual installs; settings did not persist | Fixed |
| Medium | Render failures could freeze output or flood the log | Fixed |
| Medium | File sizes were queried once per row/frame | Fixed |
| Medium | Settings click targets overlapped | Fixed |
| Low | Dead code, console parsing/scroll issues, and incorrect docs/URLs | Fixed |

## Verified OpenComputers contracts

- `filesystem.list(path)` returns a Lua table (`String[]`), not an iterator.
- Disk capacity is queried through `spaceUsed()` and `spaceTotal()` in bytes.
- `component.proxy(address)` includes `address`, `type`, `slot`, `fields`, and
  component methods.
- `component.invoke` may return `nil, reason` on failure; `pcall` alone does
  not detect that result.
- A filesystem read at EOF returns `nil` without a reason.
- GPU `set`, `fill`, and `copy` return `true` on success and may return
  `nil, "not enough energy"` on failure.

## Verification at audit time

The corrected harness used table-based directory listings, byte capacities,
and required parent directories for writes. `npm run sim:oc` ran Dashboard,
Console, Files, and Settings with strict API checks. Fault injection confirmed
the final display matched a run without GPU write failures.

This audit did not establish in-game performance; the F0 game test is recorded
separately in [`tests.md`](tests.md).
