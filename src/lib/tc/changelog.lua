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
  },
}
