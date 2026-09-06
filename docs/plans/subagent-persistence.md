# Subagent Persistence & Resume

Plan for extending `pi-extensions/subagent` (local fork of the pi coding-agent example,
byte-identical to upstream `main` as of 2026-09-06, pi v0.85.1).
Revised after plan-critic review (see "Critic revisions" below for the delta).

## Problem

The extension spawns children with `pi --mode json -p --no-session`. All child messages
accumulate in extension process memory. On abort (Escape) the tool throws
`"Subagent was aborted"` with no tool result, so the parent model never sees partial work
and the transcript is unrecoverable. On crash, only stderr fragments survive.

Live-confirmed: a plan-critic subagent run was aborted by the user; the extension killed
the child, threw, and the `finally` block deleted the temp prompt — zero artifacts left.

**Recovery granularity (honest, verified by critic):** pi creates the session JSONL file
only at the first `message_end`, and the extension only ingests `message_end` /
`tool_result_end` events (no token streaming). Therefore partial recovery exists only for
content completed up to the last `message_end` before interruption. Aborting during the
child's very first message yields no persisted partial output — that is expected, not a
bug.

## Decisions (agreed)

1. **Scope**: persist **and** first-class resume. No detached/background mode.
2. **Storage**: user-level dedicated dir `~/.pi/agent/subagents/`, mode **0700** (session
   files contain full tool output, potentially secrets). Kept out of every project's
   `/resume` picker (picker lookup is keyed under `~/.pi/agent/sessions/<cwd>/`).
3. **Inspection**: new `subagent_inspect` tool for the main agent **plus** list-only
   `/subagents` command for the user (descaled from interactive after critique).
4. **Zombie guard**: extension writes `<id>.pid` at spawn, removes on close.
   - pid alive → refuse resume (pi has no session in-use detection, upstream #8300).
   - pidfile present but process dead → **stale**: treat as interrupted, clean up the
     pidfile, allow resume/inspect. (Without this, one crashed parent locks every
     unfinished subagent forever.)
5. **Retention**: extension deletes `<id>.jsonl` + sidecars on clean success (output is
   already in the parent's tool result). Aborted/failed/crashed runs keep their session
   until resumed+completed (success deletes it) or manually deleted
   (`rm ~/.pi/agent/subagents/<id>.*` / `/subagents` list). No TTL, no count cap.
6. **Abort semantics**: abort no longer throws. The extension kills the child, records
   outcome, then **returns an error tool result** with partial output (up to last
   `message_end`) + subagent id + resume hint. This is one change in shared
   `runSingleAgent` and covers single/parallel/chain uniformly (today the throw rejects
   the whole `Promise.all` in parallel mode and skips chain's error branch).
7. **Destination**: local fork, structured generic and upstream-PR-ready. Note the
   tension flagged by the critic: upstream PR #8250 (open) touches the same abort
   region; our behavior diverges by design (persistence vs. in-memory preservation),
   which adds future merge friction. Accepted.

## Design

### Spawn changes (`runSingleAgent`)

- Generate a subagent id (uuid) per invocation (per chain step / parallel task). This is
  the **filename** id, not the pi session id — pi generates its own header `id` inside
  the JSONL; the meta sidecar captures the header id (parsed from the `session` entry)
  for debugging.
- Replace `--no-session` with `--session <path>` where path =
  `~/.pi/agent/subagents/<id>.jsonl`. Explicit path so it works regardless of child cwd.
  (No `--name` — sessions outside the project session dir never appear in the picker;
  the flag buys nothing.)
- Write `<id>.pid` after spawn; remove on `close`.
- Write `<id>.meta` sidecar JSON: `{ agent, task, model, thinkingLevel, startedAt,
  promptHash }`, updated on child `close` with `{ status, stopReason, exitCode,
  sessionHeaderId }`. `status` is derived from `isFailedResult` + abort state.
  - `promptHash` (hash of the agent system prompt) lets inspect/resume detect that the
    agent definition changed since the original run (see limitation L2).
- On clean success: delete `<id>.jsonl`, `<id>.pid`, `<id>.meta`.

### Tool result / details

- `SingleResult` gains `subagentId: string` and `sessionPath: string`.
- Error tool results (failed/aborted child) include the id and hint:
  "inspect with subagent_inspect, continue with subagent {agent, task, resume}".

### `resume: "<id>"` parameter (subagent tool)

- When set, the child is spawned with `--session <same path>` (verified mechanism:
  `pi -p --session <path>` on an existing file **continues the conversation**).
  **Not `--resume`** — that is a boolean flag opening the interactive picker, unusable
  headless, and would parse the id as the prompt message.
- Guards, in order:
  1. `<id>.jsonl` must exist → else error listing available ids.
  2. pidfile: alive → refuse; dead → stale, clean up, proceed.
  3. `agent` must match meta → else error (different system prompt/toolset).
  4. `promptHash` mismatch → warn in the continuation prompt is overkill; instead refuse
     with a message that the agent definition changed, suggesting fresh delegation.
- **Resume must re-pass `--model <meta.model>` and `--thinking <meta.thinkingLevel>`**
  from the sidecar, or the child silently switches models mid-conversation.
- The `task` text is the continuation instruction appended to the existing conversation.
- **Known limitation (L1): resumed children inherit the original session's `cwd`**
  (pi reads it from the JSONL header, `session-manager.js`). Resuming from a different
  project runs the child in the original project's context. Documented, not solvable
  without forking the session.

### Known limitations

- **L1**: resume inherits original cwd (above).
- **L2**: the agent's system prompt is re-read from its markdown file at resume time
  (original temp prompt file is unlinked in `finally`). If the agent file changed, the
  resumed conversation runs under a different prompt; `promptHash` in meta detects and
  refuses this (guard 4).
- **L3**: partial recovery is per-`message_end` (see Problem section).

### New `subagent_inspect` tool

- Params: `{ id }` (required; exact filename id or unique prefix), optional `limit`
  (messages to tail, default ~20).
- Returns: status (`running` via pid check / `succeeded` [files deleted — points to
  parent tool result] / `aborted` / `failed` from meta sidecar / `unknown` [no sidecar]),
  agent, task, model, usage, stopReason/exitCode if failed, last N entries rendered
  compactly (reuse `formatToolCall`), final output if present.
- Parser requirements (verified against real files): skip unknown entry types
  (`model_change`, `thinking_level_change`, ...); tolerate a torn final line
  (kill -9 mid-append); handle "no file yet" (child died before first `message_end`).
- Can read a **running** child's transcript (JSONL is appended incrementally) — useful
  for debugging a stuck subagent.

### `/subagents` command (list-only, descaled)

- Lists `~/.pi/agent/subagents/`: short id, agent, status (alive via pid / last-activity
  time), session size, task preview.
- No interactive inspect/delete — `subagent_inspect` covers the model; `rm` covers the
  user. Re-add later if missed.

## Verification (ordered; step 0 first)

0. **Esc during a running subagent keeps the parent pi alive and the tool returns an
   error result to the model.** The whole decision #6 rests on this; confirm before
   building further on it. (Ctrl+C quits the session — that is what destroyed the
   critic run earlier; it is the wrong key for this test.)
1. Success path: child runs, completes, leaves **no** files in `~/.pi/agent/subagents/`.
2. Abort mid-run (Escape) after ≥2 child turns: error tool result carries partial output
   + id; session file exists; inspect shows it; then resume (same agent, continuation
   task) completes and files are cleaned up.
3. Abort during first turn: no session file, error result states no partial output
   available. Expected, not a bug.
4. `kill -9` the child (after session file exists): inspect shows stale/interrupted
   state; stale pidfile does not block resume.
5. Resume from a different parent cwd: confirm L1 (child runs in original cwd).
6. `/resume` picker in a project is unaffected by subagent dirs.
7. Resume with wrong agent name / changed agent file / missing session: each guard fires
   with a clear message.

## Explicitly out of scope

- Detached/background subagents, fleet UI, cross-machine resume.
- Upstream PR (structure stays PR-ready, but no PR filed now).
- Adopting open PR #8250's other improvements (aggregate parallel output budget, usage
  reporting to parent) — our recoverable-abort behavior diverges from its
  abort-preservation piece by design.

## Implementation order

1. Spawn: session path + pid lockfile + meta sidecar (incl. close-time status) +
   cleanup-on-success. Verify step 0 (Esc) and step 1 first.
2. Abort/failure: recoverable error tool result in `runSingleAgent` (one change, all
   modes) with id + hint. Verify step 2 (multi-turn) and 3.
3. `resume` parameter with guards (exists, stale-pid, agent match, promptHash) and
   model/thinking re-passing. Verify steps 4, 5, 7.
4. `subagent_inspect` tool.
5. List-only `/subagents` command.
6. Update `pi-extensions/subagent/README.md` (persistence model, resume usage, cleanup,
   limitations L1–L3, Esc vs Ctrl+C).

## Critic revisions applied (2026-09-06)

- `--resume <id>` → `--session <same path>` (critic issue 1; verified mechanism).
- Abort granularity stated honestly (issue 2); abort key is Escape not Ctrl+C (issue 3).
- Corrected false "per-task entries on abort" claim; throw→result is one shared change
  (issue 4).
- Meta sidecar records outcome on close (issue 5).
- Stale-pidfile semantics specified (issue 6).
- Resume re-passes model/thinking (issue 7); system-prompt-drift limitation + promptHash
  guard (issue 8).
- Filename id vs pi session header id clarified; original-cwd inheritance documented as
  L1 (issue 9).
- Inspector parser requirements (issue 10).
- `/subagents` descaled to list-only (user-accepted).
- Dropped `--name`; added 0700 dir perms.
- #8250 supersession claim downgraded to "diverges by design, merge-friction accepted".
