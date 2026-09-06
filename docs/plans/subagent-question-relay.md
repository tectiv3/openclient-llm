# Subagent question relay — state, plan, ideas

Status: PARKED (live breakage must be un-reverted first; APNs push is the active priority).
Date: 2026-09-06.

## Goal

Subagents (child pi processes spawned by the subagent extension) get the
`question`/`questionnaire` tools, but in a headless `--mode json` child there is
no TUI and usually no RC server — the tools are dead. This feature relays a
child's question to the **parent session's TUI** and returns the user's answer
to the child, so a subagent can ask the human mid-task.

## Current state (verified 2026-09-06)

### Live breakage (must fix before anything else)

- Live subagent extension: `~/.pi/agent/extensions/subagent/index.ts` is a
  **symlink** to `pi-mono/packages/coding-agent/examples/extensions/subagent/index.ts`.
  That working tree carries an **uncommitted** diff that spawns children with
  `stdio: ["pipe","pipe","pipe"]` + `env: { PI_SUBAGENT_RELAY: "1" }`.
- Root cause, verified against installed pi 0.85.1 (`dist/main.js`):
  `if (appMode !== "rpc") await readPipedStdin()`, and `readPipedStdin()`
  returns early only when `process.stdin.isTTY`; on a kept-open non-TTY pipe it
  blocks until EOF. Children run `--mode json -p --no-session` → they hang at
  startup, before any extension loads. **Every subagent invocation hangs.**
- The uncommitted pi-mono diff mixes TWO features:
  1. **Relay (the breakage)**: stdio pipe, `PI_SUBAGENT_RELAY=1`,
     `relaySubagentQuestion()` (`ctx.ui.select`/`input` → answer written to the
     child's stdin), and a `pi_subagent_question` branch in the parent's
     child-stdout NDJSON loop.
  2. **Model inheritance** (orthogonal, ALSO uncommitted — not in any pi-mono
     commit; last committed change to the extension is `8af7690c4`): child
     inherits the parent's active model unless frontmatter pins one.
- Child side, committed in openclient-llm as `5b59248`
  (`pi-extensions/question/index.ts`, `pi-extensions/questionnaire/index.ts`):
  path order RC → TUI → relay → error. Relay path (gated on
  `PI_SUBAGENT_RELAY=1`) writes `{"type":"pi_subagent_question", id, kind, ...}`
  to stdout and awaits a `{"type":"pi_subagent_question_response", id, answer,
  cancelled}` line on stdin; EOF → "cancelled or closed" error. Without the env
  var the child degrades gracefully to the plain "UI not available" error — so
  removing the parent env line alone makes the committed child code safe.
- Live `~/.pi/agent/extensions/{question,questionnaire}/index.ts` are **plain
  files** (not symlinks), currently byte-identical to the repo files.
- The parent's stdout parser swallows non-JSON lines (try/catch → skip), so
  stdout pollution was never the parsing risk — the fatal flaw is fd 0 only.

### Repo fork (in flight, per user)

The subagent extension will be forked from pi-mono into this repo
(`pi-extensions/subagent/`), and the live symlinks repointed here. That puts
all three extensions — question, questionnaire, subagent — under one repo, so
the relay protocol is fully ours to design (no pi core patching, no upstream
constraints). Fork copy should be the clean pre-relay version; the relay is
re-added separately with the socket design below; model inheritance is a
separate deliberate keep/drop decision.

## Why stdin cannot work

- pi's own startup reads piped stdin (all non-RPC modes); a response channel on
  fd 0 is mutually exclusive with that. Patching pi's `main.ts` to skip
  `readPipedStdin()` under an env flag is rejected: it means patching
  npx-managed `node_modules` that disappears on the next pi update (plus a
  duplicate patch in pi-mono).
- ⇒ Use a side channel: **Unix domain socket**, path passed via env
  (`PI_SUBAGENT_RELAY_SOCK`). Zero pi changes, no stdout protocol pollution,
  no fd 0 involvement.

## Proposed design (ideas — not final)

- **Parent (subagent extension)**: before each spawn, `fs.mkdtemp` in a tmpdir,
  `net.createServer()` on `sockPath`, spawn child with `stdio:
  ["ignore","pipe","pipe"]` + `env: { ..., PI_SUBAGENT_RELAY_SOCK: sockPath }`.
  On child connect: read NDJSON question, relay to `ctx.ui.select`/`input`
  (same mapping as the stdio draft), write one response frame back on the same
  connection, close. On child exit: close server, unlink socket + tmpdir.
- **Child (question/questionnaire extensions)**: relay path gated on
  `PI_SUBAGENT_RELAY_SOCK` being set. `net.connect(sockPath)` per question (no
  persistent-connection bookkeeping), send one JSON frame, await one response
  frame, close. Failure semantics: ECONNREFUSED / connect timeout (5 s) /
  response timeout (30 min) → resolve "cancelled or closed" error (subagent
  proceeds, never hangs).
- **Protocol**: 1:1 NDJSON request/response per connection —
  `{"type":"pi_subagent_question", id, kind, question?, options?|questions?}` →
  `{"type":"pi_subagent_question_response", id, answer, cancelled}`.
  `id` kept for correlation even though 1:1. No auth (per-user tmpdir, 0700).
- **Cancellation**: user Escape in the parent UI → `cancelled: true`. Parent
  session dead / no UI (`ctx.hasUI` false) → immediate `cancelled: true`
  (keeps the stdio draft's semantics).
- **v1 scope (open question)**: `question` only, or `question` + `questionnaire`
  (the stdio draft already maps both, including "Other…" free text).

## Open questions (decision log)

1. ~~Scope of immediate revert~~ — resolved by the fork: live file becomes the
   repo copy. Decision still needed: does the fork carry model inheritance
   (keep / drop / ship untested)?
2. v1 scope: question only vs question + questionnaire.
3. Response timeout value (30 min proposed) and whether per-question reconnect
   is acceptable (proposed: yes).
4. Where the fork lives (`pi-extensions/subagent/` proposed) and how live
   question/questionnaire stay synced (plain-file copies today — repoint them
   to symlinks like subagent/rc, or keep manual copy steps?).

## Parking lot

- Model inheritance for subagents (separate feature, uncommitted in pi-mono).
- Deep links for relayed answers (out of scope: answer goes back to the child,
  nothing else).
- Relay for `handoff`/`wait-what` style extensions — none needed today.
