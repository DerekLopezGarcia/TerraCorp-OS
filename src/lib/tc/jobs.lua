-- Publisher side of the Relay work queue (no coordinator).
--
-- A publisher only bookkeeps its own jobs: it broadcasts JOB, grants the first
-- CLAIM, and keeps a disk journal in /var/jobs.tsv so a restart re-offers
-- unfinished work. Workers claim, run, and answer; the publisher never runs
-- remote code and only accepts results for live leases.

local jobs = {}
jobs.__index = jobs

jobs.JOURNAL = "/var/jobs.tsv"
jobs.LEASE = 45
jobs.REOFFER = 20
jobs.RETRY = 3
jobs.TTL = 300
jobs.MAX_JOURNAL = 200

local STATES = { queued = true, granted = true, done = true, failed = true, canceled = true }

local ESCAPES = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }
local UNESCAPES = { ["\\"] = "\\", ["t"] = "\t", ["n"] = "\n", ["r"] = "\r" }

local function escapeField(value)
  return (tostring(value or ""):gsub("[\\\t\n\r]", ESCAPES))
end

local function unescapeField(value)
  return (value:gsub("\\(.)", UNESCAPES))
end

--- Parse the journal text into job tables. Broken lines are skipped; queued
-- and granted entries keep their attempts so a restart continues the count.
local function parseJournal(text)
  local list = {}
  if type(text) ~= "string" then
    return list
  end
  for line in text:gmatch("[^\r\n]+") do
    local id, task, args, state, attempts, worker, token, created, updated, result =
      line:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.*)$")
    if id and STATES[state] then
      list[#list + 1] = {
        id = id,
        task = task,
        args = unescapeField(args),
        state = state,
        attempts = tonumber(attempts) or 1,
        worker = worker ~= "" and worker or nil,
        token = token ~= "" and token or nil,
        created = tonumber(created) or 0,
        updated = tonumber(updated) or 0,
        result = unescapeField(result),
      }
    end
  end
  return list
end

local function journalLine(job)
  return table.concat({
    job.id,
    job.task,
    escapeField(job.args),
    job.state,
    tostring(job.attempts),
    job.worker or "",
    job.token or "",
    tostring(job.created),
    tostring(job.updated),
    escapeField(job.result),
  }, "\t")
end

--- Create a publisher. `env` holds:
--   id        publisher identity (the computer address)
--   vfs       kernel filesystem
--   log       optional logger
--   now       function returning seconds
--   send      function(address, verb, fields)
--   broadcast function(verb, fields)
function jobs.newPublisher(env)
  local self = setmetatable({}, jobs)
  self.id = tostring(env.id or "")
  self.vfs = env.vfs
  self.log = env.log
  self.now = env.now
  self.send = env.send
  self.broadcast = env.broadcast
  self.list = {}
  self.seq = 0
  return self
end

function jobs:load()
  if not self.vfs then
    return false
  end
  local text = self.vfs.read(jobs.JOURNAL)
  if type(text) ~= "string" then
    return false
  end
  local highest = 0
  for _, job in ipairs(parseJournal(text)) do
    if job.state == "granted" then
      -- A restart invalidates live leases: the worker answer is dropped as a
      -- stale token, so re-offer immediately.
      job.state = "queued"
      job.worker = nil
      job.token = nil
      job.updated = self.now()
    end
    self.list[#self.list + 1] = job
    local suffix = tonumber(job.id:match("%-(%d+)$"))
    if suffix and suffix > highest then
      highest = suffix
    end
  end
  self.seq = highest
  return #self.list > 0
end

function jobs:save()
  if not self.vfs then
    return false
  end
  -- Keep the newest entries; finished history is trimmed first.
  local live, finished = {}, {}
  for _, job in ipairs(self.list) do
    if job.state == "queued" or job.state == "granted" then
      live[#live + 1] = job
    else
      finished[#finished + 1] = job
    end
  end
  local keep = jobs.MAX_JOURNAL - #live
  while #finished > keep do
    table.remove(finished, 1)
  end
  local lines = {}
  for _, job in ipairs(live) do
    lines[#lines + 1] = journalLine(job)
  end
  for _, job in ipairs(finished) do
    lines[#lines + 1] = journalLine(job)
  end
  local ok = self.vfs.write(jobs.JOURNAL, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
  if not ok and self.log then
    self.log.warn("jobs: could not save the job journal")
  end
  return ok
end

--- Mint the next job id and attempt token.
function jobs:mint(attempt)
  self.seq = self.seq + 1
  local id = self.id:sub(1, 8) .. "-" .. tostring(self.seq)
  return id, id .. ":" .. tostring(attempt) .. ":" .. tostring(self.seq)
end

--- Publish a named task. Returns the job table, or nil and a reason.
function jobs:publish(task, args)
  task = tostring(task or ""):match("^%s*(.-)%s*$")
  if task == "" then
    return nil, "the task name is empty"
  end
  if #task > 24 or not task:match("^[%w%.%-]+$") then
    return nil, "the task name is invalid"
  end
  args = tostring(args or "")
  if #args > 600 then
    return nil, "the arguments are too long"
  end

  local id, token = self:mint(1)
  local now = self:now()
  local job = {
    id = id,
    task = task,
    args = args,
    state = "queued",
    attempts = 1,
    worker = nil,
    token = token,
    created = now,
    updated = now,
    result = "",
  }
  self.list[#self.list + 1] = job
  self:broadcastJob(job)
  self:save()
  return job
end

function jobs:broadcastJob(job)
  if not self.broadcast then
    return
  end
  local sent = self.broadcast("JOB", {
    id = job.id,
    pub = self.id,
    task = job.task,
    args = job.args,
    ttl = jobs.TTL,
    att = job.attempts,
  })
  if not sent and self.log then
    self.log.warn("jobs: could not offer " .. job.id .. " (no network yet)")
  end
  return sent
end

--- First live claim wins: the publisher unicasts GRANT with the lease token.
function jobs:handleClaim(fields, remoteAddress)
  local job = self:find(fields.id)
  if not job then
    return
  end
  local expired = job.state == "granted"
    and job.updated + jobs.LEASE <= self:now()
  if job.state ~= "queued" and not expired then
    return
  end
  local worker = tostring(fields.worker or "")
  if worker == "" or worker == self.id then
    return
  end

  job.state = "granted"
  job.worker = worker
  job.updated = self:now()
  if self.send then
    self.send(remoteAddress, "GRANT", {
      id = job.id,
      token = job.token,
      lease = jobs.LEASE,
    })
  end
  self:save()
end

--- A result only closes a live grant; stale tokens are dropped.
function jobs:handleResult(fields)
  local job = self:find(fields.id)
  if not job or job.state ~= "granted" then
    return
  end
  if tostring(fields.token or "") ~= job.token then
    return
  end
  local state = fields.state == "done" and "done" or "failed"
  job.state = state
  job.result = tostring(fields.out or ""):sub(1, 700)
  job.updated = self:now()
  self:save()
  if self.log then
    self.log(string.format(
      "Job %s (%s) %s%s",
      job.id,
      job.task,
      state,
      job.result ~= "" and ": " .. job.result or ""
    ))
  end
end

--- Cancel a queued or granted job and tell claimants to drop it.
function jobs:cancel(jobId)
  local job = self:find(jobId)
  if not job or job.state == "done" or job.state == "failed" or job.state == "canceled" then
    return nil, "the job is already closed"
  end
  job.state = "canceled"
  job.updated = self:now()
  if self.broadcast then
    self.broadcast("CANCEL", { id = job.id, pub = self.id })
  end
  self:save()
  return job
end

--- Advance leases, re-offers, and the job TTL by one step.
function jobs:tick()
  local now = self:now()
  local changed = false
  for _, job in ipairs(self.list) do
    if job.state == "queued" or job.state == "granted" then
      if now - job.created >= jobs.TTL then
        job.state = "failed"
        job.result = "expired"
        job.updated = now
        changed = true
      elseif now - job.updated >= (job.state == "granted" and jobs.LEASE or jobs.REOFFER) then
        if job.attempts >= jobs.RETRY then
          job.state = "failed"
          job.result = job.state == "granted" and "lost the worker" or "no claimant"
          job.updated = now
        else
          self.seq = self.seq + 1
          job.attempts = job.attempts + 1
          job.token = job.id .. ":" .. job.attempts .. ":" .. self.seq
          job.state = "queued"
          job.worker = nil
          job.updated = now
          self:broadcastJob(job)
        end
        changed = true
      end
    end
  end
  if changed then
    self:save()
  end
  return changed
end

function jobs:find(jobId)
  if jobId == nil then
    return nil
  end
  for _, job in ipairs(self.list) do
    if job.id == jobId then
      return job
    end
  end
  return nil
end

function jobs:list()
  return self.list
end

--- Counts by state, oldest first: `queued`, `granted`, `running` is
-- `granted`, and the rest are history.
function jobs:summary()
  local counts = { queued = 0, granted = 0, done = 0, failed = 0, canceled = 0 }
  for _, job in ipairs(self.list) do
    counts[job.state] = (counts[job.state] or 0) + 1
  end
  return counts
end

--- Start the publisher: load the journal so unfinished jobs re-offer.
function jobs:start()
  local loaded = self:load()
  if loaded and self.log then
    self:save()
  end
  return loaded
end

return jobs
