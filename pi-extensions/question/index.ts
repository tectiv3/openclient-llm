/**
 * Question Tool - Single question with options
 * Full custom UI: options list + inline editor for "Type something..."
 * Escape in editor returns to options, Escape in options cancels
 */

import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	Editor,
	type EditorTheme,
	Key,
	matchesKey,
	Text,
	visibleWidth,
	wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";

interface OptionWithDesc {
	label: string;
	description?: string;
}

type DisplayOption = OptionWithDesc & { isOther?: boolean };

interface QuestionDetails {
	question: string;
	options: string[];
	answer: string | null;
	wasCustom?: boolean;
}

// Remote-control access (see pi-extensions/rc). The structural type keeps the
// two extensions decoupled: rc is looked up on globalThis and checked, never imported.
interface RcRemote {
	isServing(): boolean;
	hasConnectedClients(): boolean;
	ask(opts: { kind: "question"; params: unknown }): Promise<{ value: string; wasCustom: boolean; index?: number } | null>;
}

const RC_KEY = Symbol.for("pi-rc");

function rcRemote(): RcRemote | undefined {
	const rc = (globalThis as unknown as Record<symbol, unknown>)[RC_KEY];
	return rc && typeof (rc as RcRemote).ask === "function" ? (rc as RcRemote) : undefined;
}

// Parent-relay access (see extensions/subagent). When running inside a pi
// subagent process (PI_SUBAGENT_RELAY=1), the question prompt is written to
// stdout as a JSON line and the answer is read back from stdin as a JSON line,
// so the parent session can relay it through its own UI.
interface RelayResponse {
	type: string;
	id?: string;
	answer?: unknown;
	cancelled?: boolean;
}

let relayStdinAttached = false;
let relayStdinBuffer = "";
const relayPending = new Map<string, (resp: RelayResponse | null) => void>();

function attachRelayStdin() {
	if (relayStdinAttached || !process.stdin.readable) return;
	relayStdinAttached = true;
	process.stdin.setEncoding("utf8");
	process.stdin.on("data", (chunk: string) => {
		relayStdinBuffer += chunk;
		const lines = relayStdinBuffer.split("\n");
		relayStdinBuffer = lines.pop() ?? "";
		for (const line of lines) {
			if (!line.trim()) continue;
			let resp: RelayResponse;
			try {
				resp = JSON.parse(line) as RelayResponse;
			} catch {
				continue;
			}
			if (resp.type !== "pi_subagent_question_response" || typeof resp.id !== "string") continue;
			const resolve = relayPending.get(resp.id);
			if (resolve) {
				relayPending.delete(resp.id);
				resolve(resp);
			}
		}
	});
	process.stdin.on("close", () => {
		for (const resolve of Array.from(relayPending.values())) resolve(null);
		relayPending.clear();
	});
}

function relayAsk(req: Record<string, unknown>): Promise<RelayResponse | null> {
	const id = randomUUID();
	process.stdout.write(JSON.stringify({ type: "pi_subagent_question", id, ...req }) + "\n");
	return new Promise((resolve) => {
		relayPending.set(id, resolve);
		attachRelayStdin();
		process.stdin.once("close", () => {
			const pending = relayPending.get(id);
			if (pending) {
				relayPending.delete(id);
				pending(null);
			}
		});
	});
}

// Options with labels and optional descriptions
const OptionSchema = Type.Object({
	label: Type.String({ description: "Display label for the option" }),
	description: Type.Optional(Type.String({ description: "Optional description shown below label" })),
});

const QuestionParams = Type.Object({
	question: Type.String({ description: "The question to ask the user" }),
	options: Type.Array(OptionSchema, { description: "Options for the user to choose from" }),
});

export default function question(pi: ExtensionAPI) {
	pi.registerTool({
		name: "question",
		label: "Question",
		description: "Ask the user a question and let them pick from options. Use when you need user input to proceed.",
		parameters: QuestionParams,
		executionMode: "sequential",

		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const rc = rcRemote();
			if (rc && rc.isServing() && rc.hasConnectedClients()) {
				const answer = await rc.ask({
					kind: "question",
					params: {
						question: params.question,
						options: params.options.map((o) => ({ label: o.label, value: o.label, description: o.description })),
						allowOther: true,
					},
				});
				const simpleOptions = params.options.map((o) => o.label);
				if (!answer) {
					return {
						content: [{ type: "text", text: "User cancelled the selection" }],
						details: { question: params.question, options: simpleOptions, answer: null } as QuestionDetails,
					};
				}
				if (answer.wasCustom) {
					return {
						content: [{ type: "text", text: `User wrote: ${answer.value}` }],
						details: { question: params.question, options: simpleOptions, answer: answer.value, wasCustom: true } as QuestionDetails,
					};
				}
				return {
					content: [{ type: "text", text: `User selected: ${answer.index ?? "?"}. ${answer.value}` }],
					details: { question: params.question, options: simpleOptions, answer: answer.value, wasCustom: false } as QuestionDetails,
				};
			}

			if (ctx.mode !== "tui") {
				if (process.env.PI_SUBAGENT_RELAY === "1") {
					const resp = await relayAsk({
						kind: "question",
						question: params.question,
						options: params.options.map((o) => ({ label: o.label, description: o.description })),
					});
					const simpleOptions = params.options.map((o) => o.label);
					const answer = resp ? (resp.answer as string | null) : null;
					if (!resp || resp.cancelled || answer === null || answer === undefined) {
						return {
							content: [{ type: "text", text: "Error: question relay was cancelled or closed" }],
							details: { question: params.question, options: simpleOptions, answer: null } as QuestionDetails,
						};
					}
					return {
						content: [{ type: "text", text: `User selected: ${answer}` }],
						details: { question: params.question, options: simpleOptions, answer, wasCustom: false } as QuestionDetails,
					};
				}
				return {
					content: [{ type: "text", text: "Error: UI not available (running in non-interactive mode)" }],
					details: {
						question: params.question,
						options: params.options.map((o) => o.label),
						answer: null,
					} as QuestionDetails,
				};
			}

			if (params.options.length === 0) {
				return {
					content: [{ type: "text", text: "Error: No options provided" }],
					details: { question: params.question, options: [], answer: null } as QuestionDetails,
				};
			}

			const allOptions: DisplayOption[] = [...params.options, { label: "Type something.", isOther: true }];

			const result = await ctx.ui.custom<{ answer: string; wasCustom: boolean; index?: number } | null>(
				(tui, theme, _kb, done) => {
					let optionIndex = 0;
					let editMode = false;
					let cachedLines: string[] | undefined;

					const editorTheme: EditorTheme = {
						borderColor: (s) => theme.fg("accent", s),
						selectList: {
							selectedPrefix: (t) => theme.fg("accent", t),
							selectedText: (t) => theme.fg("accent", t),
							description: (t) => theme.fg("muted", t),
							scrollInfo: (t) => theme.fg("dim", t),
							noMatch: (t) => theme.fg("warning", t),
						},
					};
					const editor = new Editor(tui, editorTheme);

					editor.onSubmit = (value) => {
						const trimmed = value.trim();
						if (trimmed) {
							done({ answer: trimmed, wasCustom: true });
						} else {
							editMode = false;
							editor.setText("");
							refresh();
						}
					};

					function refresh() {
						cachedLines = undefined;
						tui.requestRender();
					}

					function handleInput(data: string) {
						if (editMode) {
							if (matchesKey(data, Key.escape)) {
								editMode = false;
								editor.setText("");
								refresh();
								return;
							}
							editor.handleInput(data);
							refresh();
							return;
						}

						if (matchesKey(data, Key.up)) {
							optionIndex = Math.max(0, optionIndex - 1);
							refresh();
							return;
						}
						if (matchesKey(data, Key.down)) {
							optionIndex = Math.min(allOptions.length - 1, optionIndex + 1);
							refresh();
							return;
						}

						if (matchesKey(data, Key.enter)) {
							const selected = allOptions[optionIndex];
							if (selected.isOther) {
								editMode = true;
								refresh();
							} else {
								done({ answer: selected.label, wasCustom: false, index: optionIndex + 1 });
							}
							return;
						}

						if (matchesKey(data, Key.escape)) {
							done(null);
						}
					}

					function render(width: number): string[] {
						if (cachedLines) return cachedLines;

						const lines: string[] = [];
						const renderWidth = Math.max(1, width);

						function addWrapped(text: string) {
							lines.push(...wrapTextWithAnsi(text, renderWidth));
						}

						function addWrappedWithPrefix(prefix: string, text: string) {
							const prefixWidth = visibleWidth(prefix);
							if (prefixWidth >= renderWidth) {
								addWrapped(prefix + text);
								return;
							}
							const wrapped = wrapTextWithAnsi(text, renderWidth - prefixWidth);
							const continuationPrefix = " ".repeat(prefixWidth);
							for (let i = 0; i < wrapped.length; i++) {
								lines.push(`${i === 0 ? prefix : continuationPrefix}${wrapped[i]}`);
							}
						}

						lines.push(theme.fg("accent", "─".repeat(renderWidth)));
						addWrappedWithPrefix(" ", theme.fg("text", params.question));
						lines.push("");

						for (let i = 0; i < allOptions.length; i++) {
							const opt = allOptions[i];
							const selected = i === optionIndex;
							const isOther = opt.isOther === true;
							const prefix = selected ? theme.fg("accent", "> ") : "  ";
							const label = `${i + 1}. ${opt.label}${isOther && editMode ? " ✎" : ""}`;
							const color = selected || (isOther && editMode) ? "accent" : "text";

							addWrappedWithPrefix(prefix, theme.fg(color, label));

							// Show description if present
							if (opt.description) {
								addWrappedWithPrefix("     ", theme.fg("muted", opt.description));
							}
						}

						if (editMode) {
							lines.push("");
							addWrappedWithPrefix(" ", theme.fg("muted", "Your answer:"));
							for (const line of editor.render(Math.max(1, renderWidth - 2))) {
								lines.push(` ${line}`);
							}
						}

						lines.push("");
						if (editMode) {
							addWrappedWithPrefix(" ", theme.fg("dim", "Enter to submit • Esc to go back"));
						} else {
							addWrappedWithPrefix(" ", theme.fg("dim", "↑↓ navigate • Enter to select • Esc to cancel"));
						}
						lines.push(theme.fg("accent", "─".repeat(renderWidth)));

						cachedLines = lines;
						return lines;
					}

					return {
						render,
						invalidate: () => {
							cachedLines = undefined;
						},
						handleInput,
					};
				},
			);

			// Build simple options list for details
			const simpleOptions = params.options.map((o) => o.label);

			if (!result) {
				return {
					content: [{ type: "text", text: "User cancelled the selection" }],
					details: { question: params.question, options: simpleOptions, answer: null } as QuestionDetails,
				};
			}

			if (result.wasCustom) {
				return {
					content: [{ type: "text", text: `User wrote: ${result.answer}` }],
					details: {
						question: params.question,
						options: simpleOptions,
						answer: result.answer,
						wasCustom: true,
					} as QuestionDetails,
				};
			}
			return {
				content: [{ type: "text", text: `User selected: ${result.index}. ${result.answer}` }],
				details: {
					question: params.question,
					options: simpleOptions,
					answer: result.answer,
					wasCustom: false,
				} as QuestionDetails,
			};
		},

		renderCall(args, theme, _context) {
			let text = theme.fg("toolTitle", theme.bold("question ")) + theme.fg("muted", args.question);
			const opts = Array.isArray(args.options) ? args.options : [];
			if (opts.length) {
				const labels = opts.map((o: OptionWithDesc) => o.label);
				const numbered = [...labels, "Type something."].map((o, i) => `${i + 1}. ${o}`);
				text += `\n${theme.fg("dim", `  Options: ${numbered.join(", ")}`)}`;
			}
			return new Text(text, 0, 0);
		},

		renderResult(result, _options, theme, _context) {
			const details = result.details as QuestionDetails | undefined;
			if (!details) {
				const text = result.content[0];
				return new Text(text?.type === "text" ? text.text : "", 0, 0);
			}

			if (details.answer === null) {
				return new Text(theme.fg("warning", "Cancelled"), 0, 0);
			}

			if (details.wasCustom) {
				return new Text(
					theme.fg("success", "✓ ") + theme.fg("muted", "(wrote) ") + theme.fg("accent", details.answer),
					0,
					0,
				);
			}
			const idx = details.options.indexOf(details.answer) + 1;
			const display = idx > 0 ? `${idx}. ${details.answer}` : details.answer;
			return new Text(theme.fg("success", "✓ ") + theme.fg("accent", display), 0, 0);
		},
	});
}
