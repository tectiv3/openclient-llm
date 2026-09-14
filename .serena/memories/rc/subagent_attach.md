# rc subagent attach + stop UX (implemented 2026-09-14)

Spec: `docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md` (owner-approved,
3 critic rounds). Three features sharing the rc wire protocol + `Features/Code`
UI, shipped as:

- **Feature A — snapshot/live convergence.** Server: T1 `cfb9726` prunes the
  snapshot streaming buffer to the branch tail (`turnBuffer.ts`, toolResult
  tails included — M1). Client: T2 `8ccfb6a` merges `streaming_buffer` blocks
  through the existing groupers (`CodeViewModel+BufferMerge.swift`,
  `mergeBufferIntoItems` = thin fn + `bufferTextBlocks` +
  `mergeBufferToolUseBlocks`), text dedup tail-to-tail, tools by toolCallId.
- **Feature B — subagent attach (v1 = attach only).** Cross-repo T3 `022393a`
  (in `~/code/pi-extensions`, NOT this repo): subagent ext writes
  `toolCallId` into the run's `.meta` sidecar at spawn — the only link between
  a transcript tool step and a run. rc: T4a `9946375` (pure module
  `pi-extensions/rc/subagents.ts`: scan/resolve/bus-map/settle/snapshot) +
  T4b `c3df3ea` (index.ts wiring: bus tap on `subagent:event`, per-run
  `subagentRunState` buffers, `subagents`/snapshot/event/settled frames,
  settle polling keyed on `.meta` presence with pid-alive deadline extension).
  Swift client: T5 `ded0307` (frames + VM attach state; the five stream
  reducers in `+Messages.swift` re-signed to `in items: inout
  [CodeTranscriptItem]` so the attach transcript reuses the main grouping
  path — m3). UI: T6 `fbe8bcd` (`CodeSubagentAttachView` fullScreenCover/sheet
  via `AttachCoverModifier`; pulsing "Live" chip on running subagent tool
  steps; per-row match by toolCallId).
- **Feature C — stop UX.** T7 `e533064`: input-bar Stop button deleted
  (bar is send/steer-only in all states; `onStop` gone from the API, steer
  routing unchanged). Abort = tap the pulsing toolbar status dot
  (`StatusDotView`: 8pt visual, 44pt tap region, scale/opacity pulse, static
  under reduce motion, `.abort` + medium haptic, a11y "Stop"/hint while
  streaming).

Load-bearing invariants:
- rc frames are scoped to the client's **effective session**
  (`selectedId ?? entryId`); attach state lives on `RcClient`
  (`attachedSubagentId`), cleared on session switch/rebind.
- `hello_ok` advertises `features: ["subagents"]`; the Swift client gates
  attach behind it (M4) — old servers degrade gracefully (no chip, no frames).
- `subagent_settled` is derived by file-state polling (`.meta` removed =
  success; deadline 2000 ms, extended while pid alive), NOT by a bus exit
  event (the bus has no exit).
- Subagent runs live in the GLOBAL `~/.pi/agent/subagents` (not per-session);
  scoping is purely the `parentSessionId` filter.
- `CodeViewModel.swift` is pinned at the 650-line file_length error limit —
  additions go to `+` extension files. `CodeSessionView.swift` body was
  refactored (`mainContent`, `mainToolbar`, sheet/toolbar props) because the
  Swift type-checker rejects the full expression — keep it that way.
- T6 m6 fallback: if the nav bar clips the 44pt dot region at runtime,
  relocate the dot out of the toolbar into a custom header row (not done;
  build-verify only).

Loose ends:
- iOS unit tests confirmed green by the owner 2026-09-14
  (`CodeViewModelTests` incl. the T2 BufferMerge + T5 subagent suites).
  (Could not run from the agent's process tree — pty sandboxed in that env.)
- Runtime UI smoke (chip tap, attach view streaming, dot abort, post-settle
  banner) not performed — phone-side feature.
- Accepted v1 limits (spec "Open items"): phone attach is read-only (no stop
  from phone; TUI `/subagents abort` remains); pre-T3 runs have no
  toolCallId → their steps are not tappable (graceful); a child killed without
  `agent_settled` leaves the attach view "running" until closed/re-attached.
- T3 `022393a` lives in the SEPARATE `tectiv3/pi-extensions` repo
  (`~/code/pi-extensions` — source of truth for the subagent ext; not pushed
  per policy — the owner pushes when convenient).
