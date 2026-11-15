-- Release notes shipped with the OS.
--
-- The kernel compares /var/version with the running version at boot. When they
-- differ it writes the notes for every version the node skipped into
-- /var/whatsnew.md, so an update can be read in-game with Files.
--
-- Keep one entry per released version, newest last. Bullets are plain text;
-- the file is Markdown and the pager does not interpret it.

return {
  order = {
    "0.3.21",
    "0.3.22",
    "0.3.23",
    "0.3.24",
    "0.3.25",
    "0.3.26",
    "0.3.27",
    "0.3.28",
    "0.3.29",
    "0.3.30",
    "0.3.31",
    "0.3.32",
    "0.3.33",
    "0.4.0",
    "0.4.1",
    "0.4.2",
    "0.4.4",
    "0.4.5",
    "0.4.7",
    "0.4.8",
  },
  notes = {
    ["0.3.21"] = {
      "Lab: write Lua in the OS, run it, and read every run in /var/log/lab.log.",
      "Files previews whole files with a pager: Tab focuses it, PgUp/PgDn scroll.",
    },
    ["0.3.22"] = {
      "Lua interpreter with named sessions (:new, :use, :list, :reset).",
      "The environment survives between lines and the log names the session.",
    },
    ["0.3.23"] = {
      "Paste from the game clipboard with Insert (or middle click) in the Lab and the Terminal.",
      "Shift+arrows select; Ctrl+C and Ctrl+V use an OS clipboard.",
      "component.gpu and the other kinds resolve in the interpreter.",
    },
    ["0.3.24"] = {
      "=expr works without a space after = (it compiled as the name returncomponent).",
      "Ctrl and Shift stay held until released: repeated Shift+Enter and Shift+arrows work.",
    },
    ["0.3.25"] = {
      "The interpreter tries an expression before a statement, like OpenOS, so component.list() prints.",
      "Strings print quoted and tables with sorted keys instead of table: 0x...",
    },
    ["0.3.26"] = {
      "Long results wrap inside the pane instead of running off the right edge.",
      "A table result lists one entry per line.",
    },
    ["0.3.27"] = {
      "Select text with the mouse: press, drag, release; Ctrl+C copies.",
      "The script editor selects code too.",
    },
    ["0.3.28"] = {
      "Enter on an open block keeps the text and opens a line; it no longer clears the cell.",
      "History recalls a multi-line cell as one entry.",
    },
    ["0.3.29"] = {
      "Ctrl+C and Ctrl+V work on clients that send the control character as the key text.",
      "Enter on an empty interpreter cell opens a line.",
    },
    ["0.3.30"] = {
      "Tried to expose collectgarbage; it does not work in-game. Use 0.3.31.",
    },
    ["0.3.31"] = {
      "collectgarbage removed: OpenComputers does not expose it.",
      "The memory probe reads computer.freeMemory(); the harness matches the game.",
    },
    ["0.3.32"] = {
      "After an update the OS writes the notes of every version you skipped to /var/whatsnew.md.",
      "A notice points at it and Files opens it with the pager.",
    },
    ["0.3.33"] = {
      "fs.write and fs.append over the External Link failed in-game because of a wrong argument order; fixed.",
      "link.interval sets the link polling cadence from the bridge (1-60 s); it needs no reboot.",
      "lua runs a chunk over the link with full control, with the Lab environment and its output.",
    },
    ["0.4.0"] = {
      "No visible changes: this release records the in-game probe that opens the plant readout work.",
      "Items, fluids, energy and drawer redstone now read with measured formats and a 50 ms cost per call.",
    },
    ["0.4.1"] = {
      "Plant: a local readout of line-boundary stocks with items, fluids and level alarms.",
      "A line is a black box: one input and one output stock; the machines inside are not read.",
      "The readout runs on one component call per second and makes none while the line is idle.",
      "Groundwork: the data-only /etc/lines/<line>.line parser (stock in/out, rules, items and fluids).",
    },
    ["0.4.2"] = {
      "Mirror: the plant readout now answers the External Link with plant.status, snapshot, delta and alarms.",
      "A reply larger than one frame is paged and reassembled; the bridge keeps the last parsed reply of each kind.",
      "The delta cursor only moves when a visible value changed, so idle scans no longer force a resync.",
    },
    ["0.4.4"] = {
      "History: a bounded ring keeps two hours of samples per stock and computes items/min and mB/min.",
      "STALLED fires when a stock marked flow does not move; TREND fires when its rate changes by the configured percentage.",
      "The ring is stored in /var/plant/history.tsv, survives a reboot and compacts so it never grows without a cap.",
      "Plant shows the rate next to the total; plant.snapshot carries rate and trend per stock.",
    },
    ["0.4.5"] = {
      "Book: the operated recipes live in /etc/recipes.tsv and /etc/recipe-io.tsv; line programs add their rules.",
      "plan() walks the chain, names the bottleneck and lists the shortfall against the cached stock.",
      "Calibration marks a recipe declared, verified or suspect; a contradicted quantity plans with the measured ratio.",
      "plant.book and plant.plan expose the book and the plan over the External Link, still read-only.",
    },
    ["0.4.7"] = {
      "MCP: a read-only stdio server next to the bridge answers plant situation, stock, alarm, history, plan, path, recipe and audit questions.",
      "Every answer cites the verb it came from; a missing reading is an error, never a zero.",
      "plant.history and plant.paths expose the sample ring and the semantic paths without UUIDs.",
    },
    ["0.4.8"] = {
      "Halls: /etc/halls.tsv names each computer and the merged view prefixes stocks with their hall; a missing hall is offline, not dropped.",
      "Gates: desired setpoints in /var/gates.tsv, local interlocks for empty input and full output, and DISOBEDIENT LINE after repeated refusals.",
      "Move: a bounded transfer by item name through a transposer, reporting what actually moved.",
      "The second hall, the gate and the transport are not built yet: these modules ship harness-tested and their in-game run is pending.",
    },
  },
}
