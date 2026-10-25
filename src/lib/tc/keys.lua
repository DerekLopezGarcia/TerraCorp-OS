-- OpenComputers key codes (subset verified against openos/lib/keyboard.lua).
-- The raw `char` field is a numeric Unicode code point, or zero when absent.

local keys = {
  esc = 0x01,
  back = 0x0E,
  tab = 0x0F,
  enter = 0x1C,
  space = 0x39,
  home = 0xC7,
  up = 0xC8,
  pageUp = 0xC9,
  left = 0xCB,
  right = 0xCD,
  ["end"] = 0xCF,
  down = 0xD0,
  pageDown = 0xD1,
  delete = 0xD3,
  F1 = 0x3B,
  F2 = 0x3C,
  F3 = 0x3D,
  F4 = 0x3E,
  F5 = 0x3F,
  F6 = 0x40,
  F7 = 0x41,
  F8 = 0x42,
  F9 = 0x43,
  F10 = 0x44,
}

return keys
