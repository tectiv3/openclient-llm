# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Start Here

Read [AGENTS.md](AGENTS.md) first — it is the project-wide operating guide covering architecture, concurrency, build/test commands, conventions, git workflow, and the spec table. This file adds only what AGENTS.md does not cover.

## CLI Build Workarounds

xcodebuild from CLI (Claude Code, CI) requires SPM sandbox workarounds. Always add these flags:

```bash
-skipPackageUpdates -skipMacroValidation \
OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

See AGENTS.md for full build and test command templates. Append the flags above to those commands when running from CLI.

## XcodeBuildMCP

VS Code integration configured at `.xcodebuildmcp/config.yaml`. Default scheme: `openclient-llm`, simulator: `iPhone 17 Pro Max`.
