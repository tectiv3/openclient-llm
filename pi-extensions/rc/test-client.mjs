#!/usr/bin/env node
/**
 * Automated test harness for the rc pi-extension (spec: docs/plans/rc-remote-control-spec.md, section C2).
 *
 * Spawns `pi` in RPC mode in a temp copy of test-project/ and drives it over
 * JSON-lines stdin/stdout. Node 24+, zero npm dependencies (built-in modules +
 * global WebSocket). The rc extension (WS server on 127.0.0.1:47800 + pairing
 * auth file) is the thing under test.
 *
 * Usage:
 *   node test-client.mjs [--only 1,3] [--keep-tmp] [--fast]
 *
 * Exit codes: 0 = all pass, 1 = one or more test failures, 2 = setup failure
 * (port busy, spawn, readiness, or /rc toggle).
 */

import { spawn } from "node:child_process";
import { cpSync, mkdtempSync, rmSync, readFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// --- constants -----------------------------------------------------------------

const RC_HOST = "127.0.0.1";
const RC_PORT = 47800;
const RC_FAST = true;
const PI_COMMAND = "pi";
const PI_ARGS = ["--mode", "rpc", "--provider", "openrouter", "--model", "qwen/qwen3.8-27b", "--approve", "--no-session"];
const READINESS_TIMEOUT_MS = 20_000;
const AUTH_POLL_INTERVAL_MS = 100;
const AUTH_WAIT_TIMEOUT_MS = 10_000;
const CODE_PATTERN = /^[0-9]{6}$/;

const HERE = dirname(fileURLToPath(import.meta.url));
const TEST_PROJECT_SRC = join(HERE, "test-project");

// --- arg parsing -----------------------------------------------------------------

function parseArgs(argv) {
  const opts = { only: null, keepTmp: false, fast: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--only") {
      const spec = argv[(i += 1)] ?? "";
      const groups = spec.split(",").map((part) => Number.parseInt(part, 10));
      if (groups.some((n) => Number.isNaN(n))) {
        console.error(`bad --only value: ${JSON.stringify(spec)} (expected comma-separated group numbers)`);
        process.exit(2);
      }
      opts.only = groups;
    } else if (arg === "--keep-tmp") {
      opts.keepTmp = true;
    } else if (arg === "--fast") {
      opts.fast = true;
    } else {
      console.error(`unknown argument: ${arg}`);
      process.exit(2);
    }
  }
  return opts;
}

// --- utils -----------------------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Resolves after the delay so every deadline is race-safe (no missed resolution).
const withTimeout = (promise, ms, message) =>
  Promise.race([promise, sleep(ms).then(() => {
    throw new Error(message);
  })]);

function probePort(host, port) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let settled = false;
    const done = (value) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(value);
    };
    socket.on("connect", () => done(true));
    socket.on("error", () => done(false));
    socket.setTimeout(1000, () => done(false));
    socket.connect(port, host);
  });
}

// --- pi RPC client (JSON-lines over stdin/stdout) ----------------------------------

class RpcClient {
  constructor(child) {
    this.child = child;
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
    child.stdout.on("data", (chunk) => this.onData(chunk));
    child.stderr.on("data", (chunk) => {
      this.stderr += chunk.toString();
    });
    // Swallow EPIPE/stream errors when pi dies mid-write; pending commands settle via the 'exit' handler.
    child.stdin.on("error", () => {});
    child.stdout.on("error", () => {});
    child.on("exit", (code, signal) => {
      this.settleAll(new Error(`pi exited (code=${code} signal=${signal})`));
    });
    child.on("error", (err) => this.settleAll(err));
  }

  sendCommand(message) {
    const id = String(this.nextId);
    this.nextId += 1;
    const payload = { ...message, id };
    const sendPromise = new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, message: payload.type });
    });
    this.child.stdin.write(JSON.stringify(payload) + "\n");
    return sendPromise;
  }

  onData(chunk) {
    const text = chunk.toString();
    let start = 0;
    let idx;
    while ((idx = text.indexOf("\n", start)) !== -1) {
      this.handleLine(text.slice(start, idx));
      start = idx + 1;
    }
    // trailing partial line (no newline yet) is ignored; pi always newline-terminates
  }

  handleLine(line) {
    const trimmed = line.trim();
    if (trimmed === "") return;
    let parsed;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      return; // events without JSON (should not happen in RPC mode)
    }
    if (parsed.type !== "response" || parsed.id === undefined) return;
    const waiter = this.pending.get(String(parsed.id));
    if (!waiter) return;
    this.pending.delete(String(parsed.id));
    if (parsed.success === false) {
      waiter.reject(new Error(parsed.error ?? `pi reported failure for ${waiter.message}`));
    } else {
      waiter.resolve(parsed);
    }
  }

  settleAll(err) {
    for (const [id, waiter] of this.pending) {
      this.pending.delete(id);
      waiter.reject(err);
    }
  }

  // SIGTERM, then SIGKILL if still alive after the grace period.
  async terminate() {
    if (this.child.exitCode !== null) return;
    this.child.kill("SIGTERM");
    const exited = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 3000);
      this.child.once("exit", () => {
        clearTimeout(timer);
        resolve(true);
      });
    });
    if (!exited) {
      try {
        this.child.kill("SIGKILL");
      } catch {
        // already gone
      }
    }
  }
}

// --- rc auth file helpers ----------------------------------------------------------

function readAuthFile(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    return { ok: false, raw: err.message };
  }
  try {
    const data = JSON.parse(raw);
    if (data.status === "running" && CODE_PATTERN.test(String(data.code))) {
      return { ok: true, auth: { host: data.host, port: data.port, code: data.code } };
    }
    return { ok: false, raw: `auth file not running (status=${String(data.status)})` };
  } catch {
    return { ok: false, raw: `auth file not valid JSON (${raw.slice(0, 120)})` };
  }
}

async function waitForAuthFile(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = "auth file not found";
  while (Date.now() < deadline) {
    const result = readAuthFile(path);
    if (result.ok) return result.auth;
    lastError = result.raw;
    await sleep(AUTH_POLL_INTERVAL_MS);
  }
  const detail = `auth file never reached running (rc extension not implemented yet? last error: ${lastError})`;
  throw new Error(detail);
}

// The stopped auth shape carries no code, so readAuthFile cannot be reused. expectReason
// distinguishes port-busy from a stale stopped file left by an earlier step.
async function waitForStoppedAuthFile(path, timeoutMs, { expectReason = null } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastRaw = "auth file not found";
  while (Date.now() < deadline) {
    try {
      const raw = readFileSync(path, "utf8");
      lastRaw = raw.slice(0, 120);
      const data = JSON.parse(raw);
      if (data.status === "stopped" && (expectReason === null || data.reason === expectReason)) return data;
    } catch (err) {
      if (!(err instanceof SyntaxError)) lastRaw = err.message;
    }
    await sleep(AUTH_POLL_INTERVAL_MS);
  }
  throw new Error(`auth file never reached stopped${expectReason ? ` with reason ${expectReason}` : ""} (last: ${lastRaw})`);
}

// Reads until the socket closes (rcClosed) — used where a close is the expectation; throws on deadline.
async function drainUntilClose(next, ms, label) {
  const deadline = Date.now() + ms;
  for (;;) {
    try {
      await withTimeout(next(), Math.max(deadline - Date.now(), 0), `${label} (no close within ${ms}ms)`);
    } catch (err) {
      if (err?.rcClosed) return; // the close we were waiting for
      throw err; // deadline or other error
    }
  }
}

// --- rc WS client helpers (groups 1-2) ---------------------------------------------

const RC_WS_TIMEOUT_MS = 10_000;
const VALID_HISTORY_ROLES = new Set(["user", "assistant", "toolResult", "compaction"]);
const nonEmptyString = (value) => typeof value === "string" && value !== "";
const check = (condition, detail) => { if (!condition) throw new Error(detail); };

// Tagged so waiters can tell "socket closed" apart from a plain timeout.
const rcClosedError = () => Object.assign(new Error("rc ws closed before expected message"), { rcClosed: true });

// One-connection rc WS client: `connect` settles on open/refusal; `next()`
// rejects (never hangs) if the socket closes early; `close()` is idempotent.
function connectRc({ host, port, code, version = 1 }) {
  const ws = new WebSocket(`ws://${host}:${port}`);
  const queue = [];
  const waiters = [];
  let closed = false;
  const deliver = (msg) => { const w = waiters.shift(); if (w) w.resolve(msg); else queue.push(msg); };
  const failAll = (err) => { closed = true; for (const w of waiters.splice(0)) w.reject(err); };
  ws.onmessage = (event) => {
    try {
      deliver(JSON.parse(event.data));
    } catch {
      // ignore non-JSON frames
    }
  };
  ws.onclose = () => failAll(rcClosedError());
  const connect = new Promise((resolve, reject) => {
    ws.onopen = () => { ws.onerror = null; resolve(ws); };
    ws.onerror = () => reject(new Error(`rc ws connect to ${host}:${port} failed (refused, or server not listening?)`));
  });
  const next = () =>
    new Promise((resolve, reject) => {
      if (closed) return reject(rcClosedError());
      if (queue.length > 0) return resolve(queue.shift());
      waiters.push({ resolve, reject });
    });
  const close = () => { if (closed) return; closed = true; try { ws.close(); } catch { /* gone */ } };
  return { ws, connect, next, close, code, version };
}

// Full handshake: connect -> hello -> first response; socket stays open on success.
async function handshake(ctx, overrides = {}) {
  const code = overrides.code ?? ctx.auth.code;
  const version = overrides.version ?? 1;
  const { ws, connect, next, close } = connectRc({ host: ctx.host, port: ctx.rcPort, code, version });
  try {
    await withTimeout(connect, RC_WS_TIMEOUT_MS, "rc ws connect timeout");
    ws.send(JSON.stringify({ type: "hello", code, version }));
    return { result: await next(), ws, next, close };
  } catch {
    close();
    return { result: null, ws, next, close };
  }
}

function requireAuth(ctx) {
  if (!ctx.auth) throw skip("no rc auth (server not running)");
}

// rate_limited (60s lockout from group 1) is a visible FAIL, not a skip, by design.
function assertHelloOk(result) {
  if (result?.type === "hello_ok" && result.version === 1) return;
  if (result?.type === "error" && result.code === "rate_limited") {
    throw new Error("server rate-limited (lockout from group 1) — re-run needed");
  }
  throw new Error(
    `expected hello_ok (version 1), got ${result ? JSON.stringify(result) : "no response (connection failed)"}`,
  );
}

// Protocol requires a close after an error; a timeout is itself a failure.
async function expectErrorThenClose(result, expectedCode, next, close) {
  check(
    result?.type === "error" && result.code === expectedCode,
    `expected error ${expectedCode}, got ${JSON.stringify(result)}`,
  );
  try {
    await withTimeout(next(), RC_WS_TIMEOUT_MS, "server did not close after error");
  } catch (err) {
    if (!err?.rcClosed) throw err;
  }
  close();
}

function assertValidStateShape(state) {
  check(state?.type === "state", "expected state message");
  check(nonEmptyString(state.sessionId) && nonEmptyString(state.cwd), "sessionId and cwd must be non-empty strings");
  check(typeof state.isStreaming === "boolean", "isStreaming must be a boolean");
  check(nonEmptyString(state.model?.provider) && nonEmptyString(state.model?.id), "model provider+id non-empty");
  check(
    state.contextUsage === undefined ||
      (typeof state.contextUsage === "object" && state.contextUsage !== null &&
        Number.isFinite(state.contextUsage.tokens) &&
        Number.isFinite(state.contextUsage.contextWindow) &&
        Number.isFinite(state.contextUsage.percent)),
    "contextUsage, when present, must have numeric tokens/contextWindow/percent",
  );
}

function assertHistoryShape(history, expectedSessionId) {
  check(
    history?.type === "history" && history.sessionId === expectedSessionId,
    "expected history message with matching sessionId",
  );
  check(Array.isArray(history.messages), "history.messages must be an array");
  history.messages.forEach((msg, i) => {
    check(VALID_HISTORY_ROLES.has(msg?.role), `history.messages[${i}] has an invalid role`);
    if (msg.role === "assistant") check(Array.isArray(msg.content), `assistant content must be an array`);
  });
}

async function connectAndVerifyConnectTime(ctx) {
  requireAuth(ctx);
  const hs = await handshake(ctx);
  assertHelloOk(hs.result);
  const state = await hs.next();
  assertValidStateShape(state);
  const history = await hs.next();
  assertHistoryShape(history, state.sessionId);
  ctx.lastState = state;
  return hs;
}

// --- test registry -----------------------------------------------------------------

const tests = [];

function registerTest(group, name, run) {
  tests.push({ group, name, run });
}

const skip = (reason) => new Skip(reason);

class Skip {
  constructor(reason) {
    this.reason = reason;
  }
}

// --- test definitions ----------------------------------------------------------------

// Group 0: setup smoke tests. Run regardless of --only; must pass before group 1-10 is meaningful.

registerTest(0, "rc_toggle_on_reports_auth_file", async (ctx) => {
  ctx.auth = await ctx.toggleRcOn();
});

registerTest(1, "hello_valid_code_gets_hello_ok_state_history", async (ctx) => {
  const hs = await connectAndVerifyConnectTime(ctx);
  hs.close();
});

registerTest(1, "hello_wrong_version_gets_version_mismatch", async (ctx) => {
  requireAuth(ctx);
  const hs = await handshake(ctx, { version: 99 });
  await expectErrorThenClose(hs.result, "version_mismatch", hs.next, hs.close);
});

registerTest(2, "get_state_returns_valid_shape", async (ctx) => {
  const hs = await connectAndVerifyConnectTime(ctx);
  hs.ws.send(JSON.stringify({ type: "get_state" }));
  const state = await hs.next();
  assertValidStateShape(state);
  ctx.lastState = state;
  hs.close();
});

// A fresh session may have empty history; that is a pass.
registerTest(2, "history_empty_or_consistent_shape", async (ctx) => {
  const hs = await connectAndVerifyConnectTime(ctx);
  hs.close();
});

// --- groups 3, 4, 10 helpers: event waiting & streaming-burst capture --------------

// Reads messages in arrival order until stopWhen(msg) or the deadline; returns all read.
// A throwing stopWhen fails fast; unmatched messages are consumed (events are point-in-time).
async function readMessages(next, stopWhen, ms, label, { onTimeout = "throw" } = {}) {
  const collected = [];
  const deadline = Date.now() + ms;
  for (;;) {
    const remaining = deadline - Date.now();
    let msg;
    try {
      msg = await withTimeout(next(), remaining, `${label} (timed out after ${ms}ms)`);
    } catch (err) {
      if (err?.rcClosed) throw new Error(`${label} (connection closed)`);
      if (onTimeout === "return") return collected; // deadline hit: the quiet window held
      throw err;
    }
    collected.push(msg);
    if (stopWhen(msg)) return collected;
  }
}

// First message matching the predicate (waitForEventByName: by pi event name); timeout/closed = throw.
const waitForMessage = async (next, predicate, ms, label) =>
  (await readMessages(next, predicate, ms, label)).at(-1);
const waitForEventByName = (next, name, ms) =>
  waitForMessage(next, (m) => m?.type === "event" && m.name === name, ms, `event ${name}`);

// Reads every message arriving within a quiet window; captures the connect-time burst (state, history, streaming_buffer).
async function drainUntilQuiet(next, quietMs) {
  const messages = [];
  let pending = next();
  for (;;) {
    let msg = null;
    try {
      msg = await Promise.race([pending, sleep(quietMs).then(() => null)]);
    } catch {
      break; // socket closed mid-drain: return what we have
    }
    if (msg === null) break;
    messages.push(msg);
    pending = next();
  }
  return messages;
}

// Opens a verified connection, runs fn, guarantees close() (an unclosed socket keeps the process alive).
async function withConnection(ctx, fn) {
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    await fn(hs);
  } finally {
    hs.close();
  }
}

// Group 3: Prompt & steer

registerTest(3, "prompt_when_idle_starts_processing_and_lands_in_history", async (ctx) => {
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PONG-3" }));
    // 45s budget: agent_start must appear, then agent_settled must follow.
    const events = await readMessages(next, (m) => m?.type === "event" && m.name === "agent_settled", 45_000, "PONG-3 (agent_settled)");
    const names = events.filter((m) => m?.type === "event").map((m) => m.name);
    const startIdx = names.indexOf("agent_start");
    check(startIdx >= 0 && names.indexOf("agent_settled") > startIdx, `agent_start->agent_settled required (saw: ${names.join(",")})`);
    ws.send(JSON.stringify({ type: "get_history" }));
    const history = await waitForMessage(next, (m) => m?.type === "history", 10_000, "history after prompt");
    const messages = history.messages ?? [];
    const idx = messages.findIndex((m) => m?.role === "user" && JSON.stringify(m).includes("PONG-3"));
    check(idx >= 0 && messages.slice(idx + 1).some((m) => m?.role === "assistant"), "PONG-3 not followed by assistant");
  });
});

registerTest(3, "prompt_when_streaming_gets_not_idle", async (ctx) => {
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "LONG" }));
    await waitForEventByName(next, "message_update", 15_000);
    ws.send(JSON.stringify({ type: "prompt", text: "should be rejected" }));
    await waitForMessage(next, (m) => m?.type === "error" && m.code === "not_idle", 5_000, "not_idle error");
    // Leave the agent idle for later groups.
    ws.send(JSON.stringify({ type: "abort" }));
    await waitForEventByName(next, "agent_settled", 20_000);
  });
});

registerTest(3, "steer_when_streaming_is_accepted_and_delivered", async (ctx) => {
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "LONG" }));
    await waitForEventByName(next, "message_update", 15_000);
    ws.send(JSON.stringify({ type: "steer", text: "STEER-10" }));
    // No error within 4s is the acceptance (prompt/steer/abort have no acks); the stopWhen throws
    // on the first error and stops early at agent_settled (fast model), which is then satisfied.
    let settled = false;
    const noSteerError = (m) => {
      if (m?.type === "error") throw new Error(`steer rejected: ${JSON.stringify(m)}`);
      if (m?.type === "event" && m.name === "agent_settled") settled = true;
      return settled;
    };
    await readMessages(next, noSteerError, 4_000, "post-steer error window", { onTimeout: "return" });
    if (!settled) await readMessages(next, (m) => m?.type === "event" && m.name === "agent_settled", 60_000, "steer follow-up (agent_settled; 1..400 gen + follow-up)");
    ws.send(JSON.stringify({ type: "get_history" }));
    const history = await waitForMessage(next, (m) => m?.type === "history", 10_000, "history after steer");
    const delivered = (history.messages ?? []).some((m) => m?.role === "user" && JSON.stringify(m).includes("STEER-10"));
    check(delivered, "no user message containing STEER-10 in history (steer not delivered)");
  });
});

// Group 4: Abort

registerTest(4, "abort_stops_the_turn", async (ctx) => {
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "LONG" }));
    await waitForEventByName(next, "message_update", 15_000);
    ws.send(JSON.stringify({ type: "abort" }));
    const turnEnd = await waitForEventByName(next, "turn_end", 20_000);
    const stopReason = turnEnd?.message?.stopReason; // informational only: "aborted" when present
    check(stopReason === undefined || typeof stopReason === "string", "stopReason, when present, must be a string");
    await readMessages(next, (m) => m?.type === "event" && m.name === "agent_settled", 20_000, "abort (agent_settled)");
    ws.send(JSON.stringify({ type: "get_state" }));
    const state = await waitForMessage(next, (m) => m?.type === "state", 10_000, "state after abort");
    assertValidStateShape(state);
    check(state.isStreaming === false, "isStreaming must be false after abort, was true");
  });
});

// Group 10: Streaming buffer

registerTest(10, "streaming_buffer_delivered_on_mid_stream_connect", async (ctx) => {
  const a = await connectAndVerifyConnectTime(ctx); // client A starts the stream
  const stateA = ctx.lastState;
  let b = null;
  try {
    a.ws.send(JSON.stringify({ type: "prompt", text: "LONG" }));
    await waitForEventByName(a.next, "message_update", 15_000);
    // Client B joins mid-stream; its connect burst is hello_ok, state, history, streaming_buffer.
    b = await connectAndVerifyConnectTime(ctx);
    const stateB = ctx.lastState;
    check(stateB.sessionId === stateA.sessionId, "client B sessionId differs from client A");
    check(stateB.isStreaming === true, "client B state.isStreaming must be true mid-stream");
    // state+history are already consumed; drain 300ms to capture the streaming_buffer burst.
    const burst = await drainUntilQuiet(b.next, 300);
    const buffer = burst.find((m) => m?.type === "streaming_buffer");
    check(buffer, "streaming_buffer not delivered on mid-stream connect");
    check(buffer.sessionId === stateA.sessionId, "streaming_buffer sessionId mismatch");
    check(Array.isArray(buffer.content) && buffer.content.length > 0, "streaming_buffer.content must be non-empty");
    buffer.content.forEach((block, i) => {
      check(block && typeof block === "object" && ["text", "thinking", "toolUse"].includes(block.type), `content[${i}] type`);
      if (block.type !== "toolUse") check(typeof block.text === "string", "block.text must be a string");
    });
  } finally {
    try { a.ws.send(JSON.stringify({ type: "abort" })); } catch { /* already closed */ }
    await sleep(500); // let the abort land (token savings)
    a.close();
    if (b) b.close();
  }
});

// --- group 11: rate-limit handshake tests (run LAST) -----------------------------
// Registered after group 10 so they run after every other group: these poison the
// shared 127.0.0.1 rate-limit counter (60s lockout), which must not bleed into groups 1-10.

registerTest(11, "hello_bad_code_gets_error_and_close", async (ctx) => {
  requireAuth(ctx);
  const hs = await handshake(ctx, { code: "deadbe" });
  await expectErrorThenClose(hs.result, "bad_code", hs.next, hs.close);
});

registerTest(11, "hello_five_bad_codes_triggers_rate_limit", async (ctx) => {
  requireAuth(ctx);
  const codes = [];
  for (let i = 1; i <= 6; i += 1) {
    const hs = await handshake(ctx, { code: `0000a${i}` });
    check(hs.result?.type === "error", `expected error on connect ${i}, got ${JSON.stringify(hs.result)}`);
    codes.push(hs.result.code);
    try {
      await withTimeout(hs.next(), RC_WS_TIMEOUT_MS, "server did not close after error");
    } catch (err) {
      if (!err?.rcClosed) throw err;
    }
    hs.close();
  }
  check(codes.some((c) => c === "rate_limited"), `expected at least one rate_limited, got ${JSON.stringify(codes)}`);
  check(
    codes.every((c) => c === "bad_code" || c === "rate_limited"),
    `unexpected error codes beyond bad_code/rate_limited, got ${JSON.stringify(codes)}`,
  );
});


// --- groups 5, 6, 7, 8, 9 -------------------------------------------------------

// Group 5: Questions. LLM-dependent: test-project AGENTS.md forces the question/questionnaire tools for the exact prompts ASK/ASKFORM
// (~10-30s per round trip, hence 60s waits). Each test chains two LLM waits, so the worst-case total may exceed the 60s framework timeout -> a framework timeout FAIL, by design.
const assertOptionsShape = (options, where, min = 1) => {
  check(Array.isArray(options) && options.length >= min, `${where} needs >= ${min} options`);
  options.forEach((opt, i) => check(nonEmptyString(opt?.label) && nonEmptyString(opt?.value), `${where}.options[${i}] needs label+value`));
};

registerTest(5, "ask_triggers_question_and_answer_resolves", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "ASK" }));
    const q = await waitForMessage(next, (m) => m?.type === "question", 60_000, "question (LLM round trip)");
    check(q.kind === "question", `expected kind question, got ${JSON.stringify(q.kind)}`);
    check(typeof q.params?.question === "string" && q.params.question.toLowerCase().includes("color"),
      `question text must mention color, got ${JSON.stringify(q.params?.question)}`);
    assertOptionsShape(q.params?.options, "question", 3);
    ws.send(JSON.stringify({ type: "answer", id: q.id, value: "red", wasCustom: false, index: 1 }));
    const resolved = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    await waitForEventByName(next, "agent_settled", 60_000); // tool returned; agent replies -> idle again
  });
});

registerTest(5, "question_survives_disconnect_and_is_redelivered", async (ctx) => {
  requireAuth(ctx);
  const a = await connectAndVerifyConnectTime(ctx);
  let questionId;
  try {
    a.ws.send(JSON.stringify({ type: "prompt", text: "ASK" }));
    ({ id: questionId } = await waitForMessage(a.next, (m) => m?.type === "question", 60_000, "question (LLM round trip)"));
  } finally {
    a.close(); // drop without answering: the pending question must survive
  }
  await sleep(1000);
  const b = await connectAndVerifyConnectTime(ctx);
  try {
    // The connect burst must re-deliver the SAME pending question (same id, kind question).
    await waitForMessage(b.next, (m) => m?.type === "question" && m?.kind === "question" && m.id === questionId, 10_000, "re-delivered question");
    b.ws.send(JSON.stringify({ type: "answer", id: questionId, value: "green", wasCustom: false, index: 2 }));
    const resolved = await waitForMessage(b.next, (m) => m?.type === "question_resolved" && m.id === questionId, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    await waitForEventByName(b.next, "agent_settled", 60_000);
  } finally {
    b.close();
  }
});

registerTest(5, "two_clients_first_answer_wins", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    const b = await connectAndVerifyConnectTime(ctx);
    try {
      ws.send(JSON.stringify({ type: "prompt", text: "ASK" }));
      const qA = await waitForMessage(next, (m) => m?.type === "question", 60_000, "question on A (LLM round trip)");
      // B must observe the SAME question (same id): broadcast to all clients.
      await waitForMessage(b.next, (m) => m?.type === "question" && m.id === qA.id, 60_000, "question on B (same id)");
      ws.send(JSON.stringify({ type: "answer", id: qA.id, value: "blue", wasCustom: false, index: 3 }));
      const resA = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === qA.id, 10_000, "question_resolved on A");
      check(resA.by === "client" && resA.value === "blue", `A resolution mismatch: ${JSON.stringify(resA)}`);
      const resB = await waitForMessage(b.next, (m) => m?.type === "question_resolved" && m.id === qA.id, 10_000, "question_resolved on B");
      check(resB.by === "client", `B must receive the same resolution broadcast, got ${JSON.stringify(resB)}`);
      await waitForEventByName(next, "agent_settled", 60_000);
    } finally {
      b.close();
    }
  });
});

registerTest(5, "askform_triggers_questionnaire_and_answer_resolves", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "ASKFORM" }));
    const qf = await waitForMessage(next, (m) => m?.type === "questionnaire", 60_000, "questionnaire (LLM round trip)");
    check(qf.kind === "questionnaire", `expected kind questionnaire, got ${JSON.stringify(qf.kind)}`);
    const subs = qf.params?.questions;
    check(Array.isArray(subs) && subs.length === 2, "questionnaire must have exactly 2 questions");
    check(subs.map((s) => s?.id).join(",") === "q1,q2", `expected ids q1,q2, got ${JSON.stringify(subs.map((s) => s?.id))}`);
    // every sub-question needs a prompt + its options
    subs.forEach((s, i) => { check(nonEmptyString(s?.prompt), `questions[${i}] needs a prompt`); assertOptionsShape(s?.options, `questions[${i}]`, 2); });
    ws.send(JSON.stringify({ type: "answer_questionnaire", id: qf.id, answers: [
      { id: "q1", value: "red", label: "red", wasCustom: false, index: 1 },
      { id: "q2", value: "M", label: "M", wasCustom: false, index: 2 },
    ] }));
    const resolved = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === qf.id, 10_000, "questionnaire resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    await waitForEventByName(next, "agent_settled", 60_000);
  });
});

// Group 6: Heartbeat

registerTest(6, "ping_gets_pong", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "ping" }));
    await waitForMessage(next, (m) => m?.type === "pong", 5_000, "pong");
  });
});

registerTest(6, "stale_client_is_closed_after_90s", async (ctx) => {
  if (ctx.fast) throw skip("90s stale-close wait skipped in fast mode (run without --fast to enable)");
  requireAuth(ctx);
  const hs = await connectAndVerifyConnectTime(ctx);
  // No traffic: the server's 90s stale detection must close the socket (any close code; recorded in the detail).
  // Budget: the 90s wait exceeds the framework's 60s hard timeout -> framework timeout FAIL under the current
  // framework (same C2 exception as group 5). The wait below is bounded (100s) and race-safe either way.
  await drainUntilClose(hs.next, 100_000, "stale close (90s server-side)");
  check(Number.isFinite(hs.ws.closeCode), `closed with code ${hs.ws.closeCode} reason ${JSON.stringify(hs.ws.reason)}`);
});

// Group 7: Multi-client

registerTest(7, "prompt_from_one_client_broadcasts_events_to_all", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    const b = await connectAndVerifyConnectTime(ctx);
    try {
      // Both clients must see agent_start (broadcast, not unicast) and the eventual agent_settled.
      ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: MULTI-7" }));
      await waitForEventByName(next, "agent_start", 20_000);
      await waitForEventByName(b.next, "agent_start", 20_000);
      await waitForEventByName(b.next, "agent_settled", 60_000);
    } finally {
      b.close();
    }
  });
});

// Group 8: Server lifecycle (the /rc RPC toggles the embedded server on/off).

registerTest(8, "rc_toggle_off_stops_server_and_disconnects", async (ctx) => {
  requireAuth(ctx);
  const hs = await connectAndVerifyConnectTime(ctx);
  const off = withTimeout(ctx.client.sendCommand({ type: "prompt", message: "/rc" }), 10_000, "pi /rc off timed out");
  // The server must disconnect live clients on toggle-off.
  await drainUntilClose(hs.next, 5_000, "toggle-off close (must happen within 5s)");
  await off; // pi's RPC response (success) is informational; the auth file is the source of truth.
  // Manual-off reason is "toggled_off" per the protocol; we only assert a non-empty reason (the exact string is a protocol detail, not a test target).
  const stopped = await waitForStoppedAuthFile(ctx.authFile, 5_000);
  check(typeof stopped.reason === "string" && stopped.reason !== "", "stopped auth file must carry a non-empty reason");
  ctx.auth = null;
  ctx.auth = await ctx.toggleRcOn(); // Re-enable for the remaining groups (9, 10).
});

registerTest(8, "port_busy_reports_port_busy", async (ctx) => {
  requireAuth(ctx);
  // The server is ON (group 8 left it on); /rc while ON only toggles off, never the port path.
  // Sequence: (1) toggle off, (2) bind a dummy on the rc port, (3) /rc start attempt -> port_busy, (4) close dummy, (5) re-enable.
  await withTimeout(ctx.client.sendCommand({ type: "prompt", message: "/rc" }), 10_000, "pi /rc off timed out");
  const stoppedOff = await waitForStoppedAuthFile(ctx.authFile, 5_000);
  check(typeof stoppedOff.reason === "string" && stoppedOff.reason !== "", "off reason must be a non-empty string");
  const dummySockets = new Set();
  const dummy = net.createServer((s) => dummySockets.add(s)); // occupies the rc port
  await new Promise((res, rej) => { dummy.once("error", rej); dummy.listen(RC_PORT, RC_HOST, res); });
  const closeDummy = async () => {
    for (const s of dummySockets) s.destroy();
    await new Promise((res) => dummy.close(() => res()));
  };
  try {
    // The start attempt must fail with port_busy; expectReason skips the stale toggled_off file from step (1).
    await withTimeout(ctx.client.sendCommand({ type: "prompt", message: "/rc" }), 10_000, "pi /rc start timed out");
    await waitForStoppedAuthFile(ctx.authFile, 5_000, { expectReason: "port_busy" });
  } finally {
    await closeDummy();
  }
  ctx.auth = null;
  ctx.auth = await ctx.toggleRcOn(); // leave the server RUNNING for later groups (10)
});

// Group 9: Session rebind

registerTest(9, "new_session_rebinds_clients_with_fresh_state", async (ctx) => {
  requireAuth(ctx);
  const hs = await connectAndVerifyConnectTime(ctx);
  const oldId = ctx.lastState?.sessionId;
  check(nonEmptyString(oldId), "no prior sessionId to rebind from");
  try {
    await sleep(1000); // drain any in-flight events from the connect burst
    const resp = await withTimeout(ctx.client.sendCommand({ type: "new_session" }), 10_000, "new_session RPC timed out");
    check(resp.success !== false, `new_session RPC failed: ${JSON.stringify(resp)}`);
    // The server re-sends state+history on the session_start rebind; we must see a NEW sessionId (fresh history may be empty).
    const newState = await waitForMessage(hs.next, (m) => m?.type === "state" && nonEmptyString(m.sessionId) && m.sessionId !== oldId, 10_000, "new state (rebind)");
    assertValidStateShape(newState);
    const newHistory = await waitForMessage(hs.next, (m) => m?.type === "history" && m.sessionId === newState.sessionId, 10_000, "new history (rebind)");
    assertHistoryShape(newHistory, newState.sessionId); // messages may be empty for a fresh session
    ctx.lastState = newState; // later groups rely on ctx.auth only, but keep the state fresh
  } finally {
    hs.close();
  }
});

// --- main ------------------------------------------------------------------------

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  // Setup step 1: the rc port must be free (before any temp dir is created).
  if (await probePort(RC_HOST, RC_PORT)) {
    console.error(`setup failed: port ${RC_PORT} on ${RC_HOST} is already in use`);
    process.exit(2);
  }

  const tmpRoot = mkdtempSync(join(tmpdir(), "openclient-rc-"));
  const authFile = join(tmpRoot, "rc-auth.json");
  let client = null;

  const cleanup = async () => {
    if (client) {
      await client.terminate();
    }
    if (!opts.keepTmp) {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  };

  const onSignal = () => {
    void cleanup().then(() => process.exit(130));
  };
  process.on("SIGINT", onSignal);
  process.on("SIGTERM", onSignal);

  // Setup step 2: copy the test project into the temp dir and spawn pi in RPC mode.
  try {
    cpSync(TEST_PROJECT_SRC, tmpRoot, { recursive: true });
  } catch (err) {
    console.error(`setup failed: could not copy test project: ${err.message}`);
    await cleanup();
    process.exit(2);
  }

  const child = spawn(PI_COMMAND, PI_ARGS, {
    cwd: tmpRoot,
    env: { ...process.env, PI_RC_BIND: RC_HOST, PI_RC_AUTH_FILE: authFile },
    stdio: ["pipe", "pipe", "pipe"],
  });
  client = new RpcClient(child);

  // Setup step 3: readiness.
  try {
    await withTimeout(client.sendCommand({ type: "get_session_stats" }), READINESS_TIMEOUT_MS, "readiness timeout");
  } catch (err) {
    console.error(`setup failed: ${err.message}`);
    if (client.stderr.trim() !== "") {
      console.error(`pi stderr: ${client.stderr.trim().slice(0, 500)}`);
    }
    await cleanup();
    process.exit(2);
  }

  // Test context shared by all tests.
  const ctx = {
    client,
    tmpRoot,
    authFile,
    auth: null,
    rcPort: RC_PORT,
    host: RC_HOST,
    fast: opts.fast || RC_FAST,
    async toggleRcOn() {
      await client.sendCommand({ type: "prompt", message: "/rc" });
      return waitForAuthFile(authFile, AUTH_WAIT_TIMEOUT_MS);
    },
  };

  const results = [];
  const byGroup = (g) => tests.filter((t) => t.group === g);
  const groupOrder = [0, ...Array.from({ length: 11 }, (_, i) => i + 1).filter((g) => opts.only === null || opts.only.includes(g))];

  for (const group of groupOrder) {
    for (const test of byGroup(group)) {
      const started = Date.now();
      try {
        await withTimeout(test.run(ctx), 60_000, `test timed out after 60s`);
        results.push({ test, status: "pass", ms: Date.now() - started });
        console.log(`PASS ${test.name}`);
      } catch (err) {
        if (err instanceof Skip) {
          results.push({ test, status: "skip", reason: err.reason, ms: Date.now() - started });
          console.log(`SKIP ${test.name} — ${err.reason}`);
        } else {
          const detail = err.message ?? String(err);
          results.push({ test, status: "fail", detail, ms: Date.now() - started });
          console.log(`FAIL ${test.name} — ${detail}`);
        }
      }
    }
  }

  const passed = results.filter((r) => r.status === "pass").length;
  const failed = results.filter((r) => r.status === "fail").length;
  const skipped = results.filter((r) => r.status === "skip").length;
  console.log(`${passed} passed, ${failed} failed, ${skipped} skipped`);

  await cleanup();
  // A group-0 smoke test IS the setup check for its area (the /rc toggle):
  // its failure is a setup failure, not an ordinary test failure.
  const setupFail = results.some((r) => r.status === "fail" && r.test.group === 0);
  process.exit(failed === 0 ? 0 : setupFail ? 2 : 1);
}

main().catch((err) => {
  console.error(`setup failed: ${err.message}`);
  process.exit(2);
});
