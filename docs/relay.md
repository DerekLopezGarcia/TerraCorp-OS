# Relay — decentralized work queue (0.3.2)

> Design goal: **no coordinator**. Any node can publish work and any worker
> can take it, so the network can grow without a central bottleneck. The
> publisher of a job is only the job's bookkeeper, not a broker: it broadcasts
> the job, grants the first claim, and keeps a disk-backed journal. Workers
> claim, run, and answer.

Transport: the existing `tc.net` frames on port `4200` (1 KB text frames,
ACK/retry on the modem, one reply per request). Jobs are **named tasks**, never
arbitrary code: a worker only runs tasks it knows.

## Roles

| Role | Runs | Holds |
|---|---|---|
| Publisher | any node (first: the master's apps) | the job journal for its jobs |
| Worker | `worker` (and `node`) role nodes | claim bookkeeping, running state |
| Storage | nothing extra in 0.3.2 | later: Vault results |

There is no queue owner. A publisher crash only affects its own jobs: the
journal lives in `/var/jobs.tsv`, survives a reboot, and re-offers queued or
granted jobs on boot (attempts continue). Adding workers to the bus adds
claimants; nothing else changes.

## Frames

| Message | Direction | Fields |
|---|---|---|
| `JOB` | publisher → broadcast | `id`, `pub` (publisher id), `task`, `args`, `ttl`, `att` (attempt, from 1) |
| `CLAIM` | worker → publisher | `id`, `worker` (node id), `jobs` (its running count) |
| `GRANT` | publisher → worker | `id`, `token` (lease token), `lease` (seconds) |
| `RESULT` | worker → publisher | `id`, `token`, `state` (`done`/`failed`), `out` (compact text) |
| `CANCEL` | publisher → broadcast | `id`, `pub` |
| `DRAIN` | master → node | `id`, `drain` (`true`/`false`) |

Field budget: `args` ≤ 600 bytes escaped, `out` ≤ 700 bytes. Larger outputs
wait for Vault (0.3.3) or are written to a file and referenced by name.

## Publisher (tc.jobs, master side first)

- `publish(task, args)` mints an id (`pub` prefix + counter), appends the
  journal as `queued`, and broadcasts `JOB`.
- The first `CLAIM` for the current attempt wins: the publisher unicasts
  `GRANT` with a lease token; later claims are ignored.
- When the lease expires without a `RESULT`, the job is re-offered
  (`att + 1`) up to a retry budget (default 3); after that it is marked
  `failed`.
- `RESULT` with the current token closes the job (`done`/`failed`); stale
  tokens (older attempts) are dropped.
- `CANCEL` marks the job canceled and broadcasts; a late result is discarded.
- On boot, queued/granted journal entries are re-offered automatically: a
  master restart does not lose the queue.

## Worker (node side)

- Advertises one concurrent slot in 0.3.2 (Tier 2 CPU); `STATUS` already
  carries `jobs`.
- On `JOB`: if the task is known, the slot is free, the node is not draining,
  and the TTL is sane, it sends `CLAIM`; the first `GRANT` with a matching
  token starts the task.
- Tasks are a registry of built-ins (`node.TASKS`): each is a named function
  `run(self, args) -> ok, out`. First set:
  - `fs.check` — integrity sweep of the node's own system paths (the boot
    check, reportable)
  - `disk.report` — system disk used/total for the node
  - `log.tail` — the last N lines of the node's own `/var/log/tc.log`
  - `comp.count` — component census by kind
  - `bench.ping` was dropped: measuring signal round-trips from inside the
    worker loop would consume the loop's own frames.
- A running task cannot be interrupted in 0.3.2 (tasks are short, seconds);
  `CANCEL` only prevents a queued claim from starting.
- Drain: a `DRAIN` frame persists the flag in the node config; a draining node
  stops claiming, finishes what it runs, and `STATUS` keeps reporting normally.

## Master UI (Nodes app)

- Header summary gains the queued/running job counts.
- A selected worker gets a **Drain**/**Undrain** action (persists on the node).
- `plant status` is the header + list: nodes, roles, states, running jobs,
  drained flags, queued journal jobs.

## Ordering and safety

- At-least-once delivery, idempotent results: the publisher dedups by job id
  and token; workers dedup by id (a granted id is never claimed twice).
- Tokens bind attempts to grants, so a slow claim from attempt 1 can never
  collide with attempt 2.
- No authentication in 0.3.x: the cluster is a local wired segment, as in the
  rest of the protocol.

## Phasing

1. **0.3.2a** — `tc.jobs` (publisher + worker), the six verbs, the journal,
   the first built-in tasks, the Nodes summary. Harness tests: claim wins,
   lease expiry re-offer, cancel, stale token, journal persistence across a
   master restart, drain stops claiming.
2. **0.3.2b** — `DRAIN` action and **plant status** polish; exit-criteria run
   in-game (batch job on a worker and back, drain without losing queued work,
   master restart keeps the queue).

Exit criteria live in [`roadmap.md`](roadmap.md).
