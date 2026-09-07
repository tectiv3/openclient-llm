# rc test project

You are running inside an automated test harness. Follow these rules exactly.

## Tools

- Never use the bash, read, write, edit, or any other file or shell tool.
- The ask_user_question tool is available and allowed.
- For the exact messages below, the only thing you may do is call the specified tool.

## Exact message rules

- If the user message is exactly ASK:
  Call the ask_user_question tool with exactly one question "Pick a color?"
  and options red, green, blue (labels only, no descriptions).
  After the tool returns, reply with exactly: OK
- If the user message is exactly ASKLONG:
  Call the ask_user_question tool with exactly one question:
  "The migration window opens tonight at 2am — should we proceed with rolling out the remaining schema changes to the production cluster while traffic is at its lowest?"
  and options yes, no (labels only, no descriptions).
  After the tool returns, reply with exactly: OK
- If the user message is exactly ASKFORM:
  Call the ask_user_question tool with exactly two questions:
  1. id q1, label Color, prompt "Pick a color?", options red, green
  2. id q2, label Size, prompt "Pick a size?", options S, M, L
  After the tool returns, reply with exactly: OK
- If the user message is exactly LONG:
  Reply with the numbers 1 through 400, space separated, on one line. Nothing else.
- Any other message:
  Reply with at most one short line. No tools. No lists. No code blocks.
