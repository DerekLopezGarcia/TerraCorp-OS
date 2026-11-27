# DNS settings UI

Status: **implemented for 0.4.10**. The 0.4.9 release configured DNS by
editing `/etc/terracorp.cfg` and rebooting. Settings now has a **DNS** page with
Off, Master and Client modes, a master address, port and transport; Apply stops
the old service and starts the new one without rebooting the desktop.

This document started as the hand-off for that slice. Checklist items are kept
so the in-game acceptance and the remaining polish stay visible.

## Why

The three modes are:

| Mode | `dnsMaster` | What it does |
|---|---|---|
| Off | `""` | No DNS service on this desktop |
| Master | `"self"` | This desktop listens on the DNS port and holds the catalog |
| Client | a master address | This desktop reads the catalog through that master |

The file-only path was acceptable for commissioning, but it made a mode change
look like an install change: edit, save, reboot, then verify. Settings is the
right place for a runtime choice, and it shows whether the choice is actually
working.

## Naming

The product-facing name for a headless publisher is **Slave**. It describes the
role generically: a subordinate computer that publishes its document to a
master, whether it watches a production line, a power buffer, or anything else.

The 0.4.9 code and configuration still use `line` as the role value. That is a
compatibility alias, not a name to show in Settings, status text, logs, or new
documentation. The rename is deliberately separate from the Settings slice so
that existing installs keep booting:

- [x] Add `slave` to the accepted roles and keep `line` as a legacy alias.
- [x] Switch the installer and flasher default from `line` to `slave`.
- [x] Update the kernel role branch, status strings and log messages.
- [x] Update configuration examples and the role descriptions in the canonical
      document, the status page and the installer guide.
- [x] Add a migration test: a 0.4.9 volume with `role="line"` still boots, and a
      new install writes `role="slave"`.

## Scope

In scope:

- A **DNS** section in Settings with the three modes above.
- Master address field for Client mode, validated before it is saved.
- Port and transport controls, with the defaults used today.
- A status line for the current mode: listening, connected, or off.
- Apply without a reboot: stop the old DNS service and start the new one.
- Persist the choice through the existing configuration writer.
- Keep the slave-node path unchanged: a slave node has no Settings window and
  continues to receive its publish target from the installer or its
  configuration file.

Out of scope:

- Changing the OS role between desktop and slave from Settings.
- Authentication. The DNS protocol still has none, so do not present a password
  field as if it protects the service.
- A general-purpose service manager for TC1 or the external link.
- Automatic discovery of masters. The first slice uses a UUID typed or pasted
  by the operator; discovery is a later feature.

## UX tasks

- [x] Add a **DNS** group to `src/apps/settings.lua`, below the existing
      station preferences.
- [x] Render the current mode as a row that cycles `Off → Master → Client`. Keep
      the three labels exact.
- [x] In Master mode, show a read-only line with this computer's full address so
      a second machine can be pointed at it.
- [x] In Client mode, add an address field with inline validation: non-empty,
      exactly a 36-character address, not a hostname such as `TC-81dd`.
- [x] Add a numeric port field. Reject empty, non-numeric, out-of-range and
      non-integer values without writing the file.
- [x] Add a transport row that cycles the supported values. The port and
      transport stay editable in Off mode so a mode can be prepared before it is
      started.
- [x] Show a status line: `Master · port 4201 · N nodes`, `Master · port 4201
      not open`, `Client · <short id>`, or `Off`.
- [x] On apply, show a success or failure notification and leave the form usable
      on failure.
- [x] Disable the address field in Master and Off modes.
- [x] Add a short confirmation when changing from Master to another mode, since
      the catalog stops being served locally.

## Runtime tasks

- [x] Add a kernel method that tears down and rebuilds the DNS runtime without
      restarting the desktop:
      - close the transport and save the master cache;
      - clear `dnsmaster`, `dnsclient` and the transport hooks;
      - start the service selected by the new configuration.
- [x] Handle the main transitions explicitly: Off→Master, Master→Off and
      Master↔Client. A slave role is rejected with `DNS settings are
      desktop-only`.
- [x] Make repeated apply operations idempotent: every apply tears down the old
      `dnsnet`/master/client before starting the new one.
- [x] Preserve `/var/dns` across a master restart; a mode change does not delete
      cached snapshots.
- [x] Keep the client fallback to a direct node query when the master is
      silent, and surface the selected mode in Settings.
- [x] Do not touch the slave node's `startDnsNode` path; it is not a desktop and
      has no Settings UI.

## Validation and persistence

- [x] Reuse the accepted configuration rules; do not duplicate them in the app.
      Settings mirrors the address/port limits so it can explain a rejection
      before saving; a shared validator would remove that duplication.
- [x] Save through the existing configuration writer, not with a hand-built
      file.
- [x] If the write fails, keep the old runtime active and tell the operator.
- [x] Ensure a power cycle restores the chosen mode. The values go through
      `config.save`; add a kernel boot assertion for this.
- [x] Keep unknown keys and the rest of the file intact.

## Tests

- [x] Unit-test the mode transitions and the invalid-address, invalid-port and
      invalid-transport cases.
- [x] Test that applying the same mode twice leaves one listener and one saved
      configuration.
- [x] Test that a master keeps its cache across a transition to Off and back.
- [x] Extend the Settings app tests for rendering, field focus, validation
      messages and apply success/failure.
- [x] Extend the screen matrix: the Settings scenario switches to DNS, applies
      Master and asserts the live status at every supported size.
- [x] Update the DNS section of the canonical document, the status page, the
      test matrix and this task list when the slice lands.
- [x] Run the documentation gate after the counts change.

## Manual acceptance (in game)

- [ ] A fresh desktop starts in Off and the DNS app says no master is
      configured.
- [ ] Switch to Master; the status says listening, and a node publishes without
      editing the node.
- [ ] Switch to Client and enter the master's address; the catalog loads and a
      document edit reports the new revision.
- [ ] Enter a bad address, port and transport; each is refused inline and the
      running service does not change.
- [ ] Return to Off; the port is released and the DNS app reports that DNS is
      off.
- [ ] Reboot; the selected mode is still in effect.
- [ ] A slave node continues to publish to the same master after the master's
      mode was changed and restored.

## Files touched

- `src/apps/settings.lua`
- `src/boot/kernel.lua`
- `src/lib/tc/config.lua`
- `src/lib/tc/installer.lua`
- `src/lib/tc/master.lua`
- `src/lib/tc/dnsnet.lua`
- `src/lib/tc/dnsmaster.lua`
- `src/lib/tc/dnsclient.lua`
- `src/lib/tc/version.lua`
- `src/lib/tc/changelog.lua`
- `src/apps/lines.lua`
- `src/apps/nodes.lua`
- `package.json`, `package-lock.json`
- `tools/harness/apps-test.lua`
- `tools/harness/installer-test.lua`
- `tools/harness/flash-test.lua`
- `tools/harness/master-test.lua`
- `tools/harness/dns-test.lua`
- `tools/harness/harness.lua`
- `tools/harness/test-screens.js`
- `docs/canonical.md`
- `docs/status.md`
- `docs/tests.md`
- `docs/versioning.md`
- `docs/roadmap.md`
- `README.md`
