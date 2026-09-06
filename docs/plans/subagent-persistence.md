# Subagent Persistence & Resume

Plan for extending `pi-extensions/subagent` (local fork of the pi coding-agent example,
byte-identical to upstream `main` as of 2026-09-06, pi v0.85.1).

## Problem

The extension spawns children with `pi --mode json -p --no-session`. All child messages
accumulate in extension process memory. On abort (Ctrl+C) the tool throws
`"Subagent was aborted"` with no tool result, so the parent model never sees partial work
and the transcript is unrecoverable. On crash, only stderr fragments survive.

## Decisions (agreed)

1. **Scope**: persist **and** first-class resume. No detached/background mode.
2. **Storage**: user-level dedicated dir `~/.pi/agent/subagents/` (kept out of every
   project's `/resume` picker; upstream's "hide headless sessions" PR #8951 was closed
   unmerged).
3. **Inspection**: new `subagent_inspect` tool for the main agent **plus** interactive
   `/subagents` command for the user. Both read the same on-disk state.
4. **Zombie guard**: extension writes `<id>.pid` lockfile at spawn, removes on exit.
   Resume refuses if the pid is alive (`kill(pid, 0)`). No auto-kill.
   (pi has no session in-use detection — upstream #8300.)
5. **Retention**: extension deletes the child session file on clean success (output is
   already in the parent's tool result). Aborted/failed/crashed runs keep their session
   until resumed+completed (success deletes it) or manually deleted via `/subagents`.
   No TTL, no count cap.
6. **Abort semantics**: abort no longer throws. The extension kills the child, then
   returns an **error tool result** containing partial output so far + subagent id +
   resume hint. Consistent with how chain/parallel already report per-task failures.
7. **Destination**: local fork, but structured generic and upstream-PR-ready.

## Design

### Spawn changes (`runSingleAgent`)

- Generate a subagent id (uuid) per invocation (per chain step / parallel task).
- Replace `--no-session` with:
  - `--session <path>` where path = `~/.pi/agent/subagents/<id>.jsonl`
    (explicit path, not `--session-id`, so it works regardless of child cwd).
  - `--name "subagent: <agentName> <id-short>"` for picker/human identification.
- Write `~/.pi/agent/subagents/<id>.pid` after spawn (pid of the child process);
  remove on `close`.
- On clean success (`exitCode === 0`, no error/aborted stopReason): delete
  `<id>.jsonl` and any leftover `<id>.pid`.
- On abort/failure: keep both files; include `subagentId` in the tool details.

### Tool result / details

- `SingleResult` gains `subagentId: string` and `sessionPath: string`.
- `SubagentDetails.results` therefore expose ids in every mode (single/parallel/chain).
- Error tool results (failed child, aborted child) include the id and a hint:
  "inspect with subagent_inspect, continue with subagent {agent, task, resume}".

### New `resume` parameter (subagent tool)

- `resume: Type.Optional(Type.String())` — a subagent id to continue.
- When set, child is spawned with `--resume <id>` (session file must exist under
  `~/.pi/agent/subagents/`; otherwise error listing available ids).
- `agent` must be provided and must match the agent of the original run (enforced via a
  small `<id>.meta` JSON sidecar written at spawn: `{ agent, task, model, startedAt }`);
  mismatch → error, to avoid resuming under a different system prompt/tool set.
- Zombie guard: if `<id>.pid` exists and the pid is alive → refuse with a clear message.
- The `task` text on resume is the continuation instruction appended to the existing
  conversation.

### New `subagent_inspect` tool

- Params: `{ id }` (required, exact or unique prefix), optional `limit` (messages to
  tail, default e.g. 20).
- Returns: status (`running` / `succeeded`-deleted / `aborted` / `failed` / `unknown`),
  agent name, task, model, usage stats, exit/stop reason if failed, and the last N
  assistant/tool-call entries rendered compactly (reuse `formatToolCall`), plus final
  output if present.
- Reads the JSONL session file directly (parse entries: `type: "message"` etc. — see
  pi docs/session-format.md); no pi process involved.
- A run that "succeeded" has no session file; inspect reports that and points to the
  parent tool result.

### New `/subagents` command

- Lists `~/.pi/agent/subagents/`: id (short), agent, status (alive via pid check /
  last-activity time), session file size, task preview.
- Interactive selection → `i` inspect (renders like `subagent_inspect` output),
  `d` delete session + sidecars, `a` delete all.

## Edge cases

- **Parent TUI crash/restart**: child may be orphaned but still running → lockfile
  catches it on resume/inspect; `/subagents` shows it as running.
- **Resume of completed run**: session file deleted on success → resume errors with
  "no such subagent (completed runs are cleaned up)".
- **Parallel/chain + abort**: each task already has its own result entry; each carries
  its own id. Chain stops at first failed/aborted step (existing behavior) and the
  reported error includes the id of the aborted step.
- **pid reuse**: low risk on darwin within the short window; acceptable. (Could store
  start time for a stronger check if needed.)
- **Session file while child running**: JSONL is appended incrementally by pi, so
  `subagent_inspect` can read a *running* child's transcript (tail of file) — useful for
  debugging a stuck subagent.

## Explicitly out of scope

- Detached/background subagents, fleet UI, cross-machine resume.
- Upstream PR (structure stays PR-ready, but no PR filed now).
- Adopting open PR #8250's other improvements (aggregate parallel output budget, usage
  reporting to parent) — our recoverable-abort behavior supersedes its abort-preservation
  piece.

## Implementation order

1. Spawn: session path + pid lockfile + meta sidecar + cleanup-on-success.
2. Abort/failure: recoverable error tool result with id + hint (single, then parallel/chain).
3. `resume` parameter with guards (exists, agent match, not running).
4. `subagent_inspect` tool.
5. `/subagents` command.
6. Update `pi-extensions/subagent/README.md` (persistence model, resume usage, cleanup).

Verification: manual runs — abort mid-run (Ctrl+C), then inspect + resume; kill -9 a
child to simulate crash; verify success path leaves no files; verify /resume picker is
unaffected.
