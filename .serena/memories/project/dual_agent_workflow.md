# Dual-agent workflow on branch code-rc

Two agents work the SAME branch concurrently. File ownership:

| Agent | Owns |
|---|---|
| This agent (pi/extensions side) | `pi-extensions/rc/**`, `pi-extensions/question/**`, `pi-extensions/questionnaire/**`, `docs/plans/rc-remote-control-spec.md`, `openclient-llm-test/Features/Code/CodeEndToEndTests.swift` + `RcE2eServer.swift` + `MockModelServer.swift` + `PosixProcessHandle.swift` + `EventCollector.swift` |
| Other agent (Swift side) | everything under `openclient-llm/` (app target incl. `Shared/Features/Code/`), their Code feature unit tests, `Localizable.xcstrings` |

## Hazards (observed, real)
- The other agent **amends/rewrites commits** and **sweeps uncommitted working-tree changes into their own commits**. Mitigation: commit promptly after every sub-task; stage ONLY your specific files (`git add <paths>`, never `git add -A`); check `git status` before committing.
- They fix build errors app-wide; a broken test fixture of theirs (`CodeServerClientTests` contextUsage shape) was silently breaking the test target compile — repairing shared-target test files is acceptable, report it.
- Never `git push` (hard rule). Never commit the other agent's dirty files.

## Conventions
- Commit after each completed sub-task, imperative subject, describe verification in body.
- Sub-agents must NOT commit; main agent commits. Sub-agents stay in their brief's file list.
- When the other agent's work depends on protocol changes, cross-check `CodeModels.swift`/`CodeEvent.swift` first — the wire format is the contract.
