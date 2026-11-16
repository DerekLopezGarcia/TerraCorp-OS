-- Node names and the paths they root.
--
-- A line node is named, and that name is the first segment of every path it
-- publishes (decision 26). The master assigns the name and the node adopts it;
-- this module is the single place that decides what a legal name is, how a guess
-- becomes a name, and how a local path is qualified with it.
--
-- A name must be a path segment: lowercase ASCII, digits, `_` and `-`. One name,
-- one spelling: `normalise` is applied when a human types it, and nothing
-- downstream re-derives a second form.

local naming = {}

naming.MAX_NAME = 24
naming.PROVISIONAL_PREFIX = "nodo-"

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Lowercase slug: every run of characters outside [a-z0-9] becomes one `-`,
-- leading and trailing dashes go, and the result is capped at MAX_NAME without
-- leaving a dangling dash. Returns nil when nothing usable is left.
function naming.slug(text)
  if type(text) ~= "string" then
    return nil
  end
  local value = trim(text):lower()
  value = value:gsub("[^a-z0-9_]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if value == "" then
    return nil
  end
  if #value > naming.MAX_NAME then
    value = value:sub(1, naming.MAX_NAME):gsub("%-+$", "")
    if value == "" then
      return nil
    end
  end
  return value
end

--- A stored name: already a slug, at most MAX_NAME characters.
function naming.valid(name)
  if type(name) ~= "string" or name == "" or #name > naming.MAX_NAME then
    return false
  end
  return naming.slug(name) == name
end

--- Normalise a name a human typed. Returns the stored form, or nil when the
-- text says nothing usable.
function naming.normalise(text)
  local value = naming.slug(text)
  if value and naming.valid(value) then
    return value
  end
  return nil
end

--- The name guessed from an output stack's display label, so an unconfigured
-- node can name itself after what its line produces: "EV Machine Casing" ->
-- "ev-machine-casing". Labels are display-only, which is why the guess is
-- persisted once and never recalculated.
function naming.fromLabel(label)
  return naming.normalise(label)
end

--- Provisional name for a node that has not guessed one yet, from its address.
function naming.provisional(address)
  local text = tostring(address or ""):lower():gsub("[^a-z0-9]", "")
  if text == "" then
    return nil
  end
  return naming.PROVISIONAL_PREFIX .. text:sub(1, 8)
end

--- First segment of a path.
function naming.root(path)
  if type(path) ~= "string" then
    return nil
  end
  return path:match("^([^/]+)")
end

--- Whether `path` is already rooted at `name`.
function naming.rooted(name, path)
  if type(name) ~= "string" or name == "" then
    return false
  end
  return naming.root(path) == name
end

--- `path` qualified with `name` as its only root. An already-rooted path is
-- returned unchanged; a path rooted somewhere else gets this name in front, so
-- the master can spot the mismatch instead of guessing.
function naming.qualify(name, path)
  if type(name) ~= "string" or name == "" or type(path) ~= "string" or path == "" then
    return path
  end
  if naming.rooted(name, path) then
    return path
  end
  return name .. "/" .. path
end

return naming
