-- Tests for tc.naming: the one rule that turns a guessed or typed label into the
-- root of a node's paths. Run through tools/harness/test-naming.js.

local naming = require("tc.naming")

local failures = {}
local checked = 0

local function check(condition, message)
  checked = checked + 1
  if not condition then
    failures[#failures + 1] = message
  end
end

local function equal(actual, expected, message)
  checked = checked + 1
  if actual ~= expected then
    failures[#failures + 1] = message ..
      " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")"
  end
end

--------------------------------------------------------------------------------
-- slug
--------------------------------------------------------------------------------

equal(naming.slug("EV Machine Casing"), "ev-machine-casing", "a label slugs to its words")
equal(naming.slug("  GT  pipe  "), "gt-pipe", "runs of separators collapse to one dash")
equal(naming.slug("casing_2"), "casing_2", "underscores survive")
equal(naming.slug("casing-2"), "casing-2", "existing dashes survive")
equal(naming.slug(""), nil, "empty text has no slug")
equal(naming.slug("   "), nil, "blank text has no slug")
equal(naming.slug("!!!"), nil, "punctuation only has no slug")
equal(naming.slug(nil), nil, "a nil label has no slug")
equal(naming.slug(42), nil, "a number is not a label")

local long = naming.slug("supercalifragilisticexpialidocious machine")
equal(#long, naming.MAX_NAME, "a long label is capped")
check(long:sub(-1) ~= "-", "a capped label never ends in a dash")

local dashed = naming.slug("abcdefghijklmnopqrstuvw-xyz")
check(dashed:sub(-1) ~= "-", "a dash at the cap boundary is dropped")
equal(#dashed, naming.MAX_NAME - 1, "dropping that dash shortens the name by one")

--------------------------------------------------------------------------------
-- valid / normalise
--------------------------------------------------------------------------------

check(naming.valid("casing"), "a lowercase slug is a valid name")
check(naming.valid("casing_2"), "underscores are valid")
check(not naming.valid("Casing"), "uppercase is not a stored name")
check(not naming.valid("casing hall"), "a space is not a stored name")
check(not naming.valid("casing/in"), "a path is not a name")
check(not naming.valid(""), "an empty name is invalid")
check(not naming.valid(nil), "a nil name is invalid")
check(not naming.valid(string.rep("a", naming.MAX_NAME + 1)), "a name longer than the cap is invalid")
check(naming.valid(string.rep("a", naming.MAX_NAME)), "a name exactly at the cap is valid")

equal(naming.normalise("Casing Hall"), "casing-hall", "a typed name is normalised once")
equal(naming.normalise("  casing  "), "casing", "surrounding space is trimmed")
equal(naming.normalise("!!!"), nil, "a name with nothing usable is rejected")

--------------------------------------------------------------------------------
-- the guess
--------------------------------------------------------------------------------

equal(naming.fromLabel("EV Machine Casing"), "ev-machine-casing",
  "the name is guessed from the output label")
equal(naming.fromLabel("Titanium Ingot"), "titanium-ingot", "items guess the same way")
equal(naming.fromLabel(""), nil, "an empty label does not guess")
equal(naming.fromLabel(nil), nil, "a missing label does not guess")

equal(naming.provisional("502a3776-1234-4abc-9def-001122334455"), "nodo-502a3776",
  "an address gives a provisional name")
equal(naming.provisional(""), nil, "an empty address gives no provisional name")
equal(naming.provisional(nil), nil, "a nil address gives no provisional name")

--------------------------------------------------------------------------------
-- qualifying
--------------------------------------------------------------------------------

equal(naming.qualify("casing", "in"), "casing/in", "a bare path is rooted at the name")
equal(naming.qualify("casing", "casing/in"), "casing/in", "an already rooted path is untouched")
equal(naming.qualify("casing", "other/in"), "casing/other/in",
  "a path rooted elsewhere is prefixed, so the master sees the mismatch")
equal(naming.qualify("casing", "in/and/deeper"), "casing/in/and/deeper",
  "only the root is added, not each segment")
equal(naming.qualify("", "in"), "in", "without a name the path is unchanged")
equal(naming.qualify(nil, "in"), "in", "a nil name leaves the path alone")
equal(naming.qualify("casing", ""), "", "an empty path stays empty")

equal(naming.root("casing/in"), "casing", "the root is the first segment")
equal(naming.root("casing"), "casing", "a single segment is its own root")
equal(naming.root(""), nil, "an empty path has no root")
equal(naming.root(nil), nil, "a nil path has no root")

check(naming.rooted("casing", "casing/in"), "a qualified path is rooted at the name")
check(naming.rooted("casing", "casing"), "a bare name is its own root")
check(not naming.rooted("casing", "caster/in"), "a longer sibling name does not match")
check(not naming.rooted("casing", "casing-2/in"), "a suffixed sibling does not match")
check(not naming.rooted("casing", "other/casing/in"), "the root is the first segment only")
check(not naming.rooted("", "casing/in"), "an empty name roots nothing")

--------------------------------------------------------------------------------
-- the provisional name is a name
--------------------------------------------------------------------------------

local guessed = naming.provisional("502a3776-1234")
check(naming.valid(guessed), "the provisional name passes validation")
check(naming.rooted(guessed, naming.qualify(guessed, "in")), "the provisional name roots paths")

if checked == 0 then
  failures[#failures + 1] = "no assertions ran"
end

return table.concat(failures, "\n")
