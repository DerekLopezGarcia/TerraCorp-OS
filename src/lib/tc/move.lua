-- Move by name through a transposer.
--
-- A move is a bounded action: read the source inventory, find the stacks that
-- match the key, transfer slot by slot, and report what actually moved. The
-- caller retries from that answer. It never assumes a full request succeeded
-- and never scans a machine buffer.

local move = {}

move.MAX_PER_CALL = 512
move.DEFAULT = 64

--- Read the source and transfer up to `n` units of `key`. `proxy` is a
-- Transposer (or a compatible object). `options`:
--   from, to   sides to transfer between
--   key        item/fluid registry name
--   damage     optional item metadata
--   n          units to move (1..MAX_PER_CALL)
--   guard      optional function(options) -> ok, reason, checked before moving
-- Returns { moved, slots, reason }.
function move.run(proxy, options)
  options = options or {}
  local from, to = options.from, options.to
  local key = options.key
  if from == nil or to == nil then
    return { moved = 0, slots = {}, reason = "missing_side" }
  end
  if type(key) ~= "string" or key == "" then
    return { moved = 0, slots = {}, reason = "missing_key" }
  end
  local wanted = math.floor(tonumber(options.n) or move.DEFAULT)
  if wanted < 1 then
    return { moved = 0, slots = {}, reason = "bad_count" }
  end
  wanted = math.min(wanted, move.MAX_PER_CALL)

  if type(options.guard) == "function" then
    local ok, reason = options.guard(options)
    if not ok then
      return { moved = 0, slots = {}, reason = reason or "guard_refused" }
    end
  end

  if type(proxy) ~= "table" and type(proxy) ~= "userdata" then
    return { moved = 0, slots = {}, reason = "transport_unavailable" }
  end
  if type(proxy.getAllStacks) ~= "function" or type(proxy.transferItem) ~= "function" then
    return { moved = 0, slots = {}, reason = "transport_unavailable" }
  end

  local okRead, stacks = pcall(proxy.getAllStacks, from)
  if not okRead or type(stacks) ~= "table" then
    return { moved = 0, slots = {}, reason = "source_unreadable" }
  end

  local damage = options.damage ~= nil and tonumber(options.damage) or nil
  local moved = 0
  local slots = {}
  local refused = false

  for slot, stack in ipairs(stacks) do
    if moved >= wanted then
      break
    end
    if type(stack) == "table" and stack.name == key
      and (damage == nil or (tonumber(stack.damage) or 0) == damage) then
      local size = tonumber(stack.size) or 0
      local take = math.min(size, wanted - moved)
      if take > 0 then
        local okMove, success, transferred =
          pcall(proxy.transferItem, from, to, slot, take)
        local sent = okMove and success == true and tonumber(transferred) or 0
        if sent and sent > 0 then
          moved = moved + sent
          slots[#slots + 1] = { slot = slot, count = sent }
        else
          refused = true
          break
        end
      end
    end
  end

  if moved == 0 then
    return {
      moved = 0,
      slots = {},
      reason = refused and "transport_refused" or "key_not_found",
    }
  end
  return {
    moved = moved,
    slots = slots,
    reason = refused and "partial" or nil,
  }
end

return move
