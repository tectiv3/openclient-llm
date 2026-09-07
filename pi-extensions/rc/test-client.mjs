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
 *   node test-client.mjs [--only 1,3|name-substr] [--list] [--keep-tmp] [--fast] [--no-apns]
 *
 * Caveat: tests share singleton state (tokens, lockout), so filtering out
 * prerequisite tests can make state-dependent tests fail — filtering is a
 * debugging tool.
 *
 * Groups 0-11 cover the rc WS protocol (spec: rc-remote-control-spec.md, C2).
 * Group 12 covers APNs push (spec: docs/plans/rc-push-notifications-spec.md,
 * verification plan 1) against a fake local APNs endpoint. --no-apns spawns
 * the child without the PI_RC_APNS_* env and re-runs group 12 as the
 * "push disabled" case (zero push traffic, all other RC behavior intact).
 * Group 12 waits out group 11's 60 s rate-limit lockout before connecting.
 *
 * Exit codes: 0 = all pass, 1 = one or more test failures, 2 = setup failure
 * (port busy, spawn, readiness, or /rc toggle).
 */

import { execFileSync, spawn } from "node:child_process";
import { cpSync, mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import http2 from "node:http2";
import crypto from "node:crypto";
import net from "node:net";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// --- constants -----------------------------------------------------------------

const RC_HOST = "127.0.0.1";
const RC_PORT = 47800;
const RC_FAST = true;
const PI_COMMAND = "pi";
// Cheap fast model (zai coding subscription): the harness only needs
// exact-instruction following (test-project/AGENTS.md contracts), not
// reasoning quality.
const PI_ARGS = ["--mode", "rpc", "--provider", "zai", "--model", "glm-5.3-flash", "--approve", "--no-session"];
const READINESS_TIMEOUT_MS = 20_000;
const AUTH_POLL_INTERVAL_MS = 100;
const AUTH_WAIT_TIMEOUT_MS = 10_000;
const CODE_PATTERN = /^[0-9]{6}$/;

// --- group 12 (push) constants ----------------------------------------------------
const APNS_TEAM_ID = "TEAMTEST1234";
const APNS_KEY_ID = "KEYTEST9876";
// Must match apns.ts's DEFAULT_TOPIC (apns-topic is asserted against it).
const APNS_TOPIC = "com.kinchaku.openclient-llm";
// Mirrors RATE_LIMIT_LOCK_MS in index.ts: group 11's bad-code hellos lock out
// 127.0.0.1 for 60 s from the 5th failure, so group 12's own connect must wait.
const LOCKOUT_MS = 60_000;
const LOCKOUT_POLL_MS = 5_000;
const LOCKOUT_DEADLINE_MS = 90_000;
// Mirrors SEND_TIMEOUT_MS in apns.ts: a request that reaches the fake endpoint
// but never completes within this budget counts as a defect, not a quiet no-op.
const APNS_PUSH_TIMEOUT_MS = 15_000;
const APNS_BAD_TOKEN_63 = "a".repeat(63); // 63 chars: valid hex, wrong length
// The dummy key the child's shortening LLM authenticates with (never the real
// OPENROUTER_API_KEY — asserted by the long-question mock test).
const OPENROUTER_DUMMY_KEY = "dummy-harness-key";

const HERE = dirname(fileURLToPath(import.meta.url));
const TEST_PROJECT_SRC = join(HERE, "test-project");

// --- arg parsing -----------------------------------------------------------------

function parseArgs(argv) {
  // --list short-circuits before any --only validation: it only needs the registry.
  if (argv.includes("--list")) {
    for (const test of [...tests].sort((a, b) => a.group - b.group)) {
      console.log(`group ${test.group} — ${test.name}`);
    }
    process.exit(0);
  }
  const opts = { only: null, keepTmp: false, fast: false, noApns: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--only") {
      const spec = argv[(i += 1)] ?? "";
      const parts = spec.split(",");
      if (parts.some((part) => part === "")) {
        console.error(`bad --only value: ${JSON.stringify(spec)} (expected comma-separated group numbers or test-name substrings)`);
        process.exit(2);
      }
      const groups = new Set();
      const names = [];
      for (const part of parts) {
        if (/^\d+$/.test(part)) groups.add(Number.parseInt(part, 10));
        else names.push(part.toLowerCase()); // substring match is case-insensitive
      }
      opts.only = { groups, names };
    } else if (arg === "--keep-tmp") {
      opts.keepTmp = true;
    } else if (arg === "--fast") {
      opts.fast = true;
    } else if (arg === "--no-apns") {
      opts.noApns = true;
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
    this.notifications = []; // every non-response JSON line (pi RPC event stream)
    this.notificationWaiters = [];
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
    if (parsed.type !== "response" || parsed.id === undefined) {
      this.deliverNotification(parsed);
      return;
    }
    const waiter = this.pending.get(String(parsed.id));
    if (!waiter) return;
    this.pending.delete(String(parsed.id));
    if (parsed.success === false) {
      waiter.reject(new Error(parsed.error ?? `pi reported failure for ${waiter.message}`));
    } else {
      waiter.resolve(parsed);
    }
  }

  // pi RPC streams agent events (agent_start, agent_settled, ...) as
  // notification lines with no id. They are recorded (indexed in arrival
  // order) and can be awaited — the only completion signal that works while
  // ZERO rc WS clients are connected, where connecting one to observe the
  // turn would itself change what is under test (hasConnectedClients).
  deliverNotification(msg) {
    this.notifications.push(msg);
    const index = this.notifications.length - 1;
    this.notificationWaiters = this.notificationWaiters.filter((w) => {
      if (w.predicate(msg, index)) {
        w.resolve(msg);
        return false;
      }
      return true;
    });
  }

  // First notification matching predicate(msg, index). The recorded stream is
  // scanned first, so a late subscriber still catches up; tests that must not
  // see older events capture an index cursor before triggering the turn.
  waitForNotification(predicate, ms, label) {
    const seen = this.notifications.findIndex((m, i) => predicate(m, i));
    if (seen !== -1) return Promise.resolve(this.notifications[seen]);
    return withTimeout(
      new Promise((resolve) => {
        this.notificationWaiters.push({ predicate, resolve });
      }),
      ms,
      label,
    );
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
    const hello = { type: "hello", code, version };
    if (overrides.token !== undefined) hello.token = overrides.token;
    ws.send(JSON.stringify(hello));
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

// Group 0: setup smoke tests. Subject to --only like every other group; must pass before group 1-10 is meaningful.

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

// --- group 12: APNs push (fake endpoint) ----------------------------------------
// Spec: docs/plans/rc-push-notifications-spec.md, verification plan item 1.
//
// A local HTTP/2-over-TLS server stands in for APNs. The spawned pi process is
// pointed at it via PI_RC_APNS_HOST and trusts its self-signed cert via
// NODE_EXTRA_CA_CERTS — the harness owns the child environment, so no CA
// configuration is invented in the extension. The throwaway P-256 key is the
// same key the extension signs its per-send JWTs with, so the harness can
// verify every Bearer token end to end.
//
// Ordering (spec-mandated):
//   - runs AFTER group 11, whose bad-code hellos lock out 127.0.0.1 for 60 s;
//   - the endpoint is up and the push token is registered BEFORE the first
//     LLM-driven wait, so no finished/question push can slip past observation.
//
// The child's singleton pushToken persists across tests, so the tests are
// registered in token-state order: (c) null, (d) invalid/ignored, (a) first
// valid registration, (b) question push on the same token, (b-mock)/(b-unreachable)
// question-body shortening via the mock OpenRouter / an unreachable LLM, (e)
// persists across disconnect + replaced by a second registration, (f) dropped
// on 410, then the zero-client ask-routing gate (askAvailable = serving AND
// (clients OR push-sendable)): (h) not push-ready → local fallback with zero
// push traffic, (i) locked-phone — the question push fires with 0 clients and
// the pending question is redelivered on reconnect (push-enabled spawn only),
// (j) token registered but creds missing → local fallback (--no-apns spawn).
//
// Push bodies (2026-09-07 decision): finished pushes identify the session
// (name → cwd basename → fixed fallback), question pushes carry the first
// question's prompt (verbatim ≤80 chars; LLM-shortened via the mock when
// longer, with deterministic hard truncation when the LLM is unreachable).
//
// With --no-apns the child is spawned WITHOUT the PI_RC_APNS_* env; the
// endpoint still runs as a traffic observer and every test asserts zero push
// traffic while the surrounding RC behavior (settles, questions, get_state)
// must keep working. (The child's rc-push.json is isolated via
// PI_RC_APNS_CONFIG, so file creds can never resolve in a run.)

// The two registered tokens: token A is registered by the settled-turn test
// and (unless dropped) persists into the persistence/replace test; token B
// replaces it (last write wins).
const APNS_TOKEN_A = "1111111111111111111111111111111111111111111111111111111111111111";
const APNS_TOKEN_B = "2222222222222222222222222222222222222222222222222222222222222222";

// Polls predicate() every 50 ms until true or the deadline (which throws).
// The fake endpoint's request list is the observation point; a push that is
// fired but never lands within APNS_PUSH_TIMEOUT_MS is a defect, not quiet.
const waitUntil = (predicate, ms, label) =>
  new Promise((resolve, reject) => {
    const deadline = Date.now() + ms;
    const timer = setInterval(() => {
      if (predicate()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() >= deadline) {
        clearInterval(timer);
        reject(new Error(`${label} (no request within ${ms}ms)`));
      }
    }, 50);
  });

// Waits until the request count stays constant for quietMs — drains a push that
// was fired by the PREVIOUS test's settle before this test snapshots `before`
// (the push lands a few ms after the agent_settled the previous test waited on).
async function drainPushQuiet(apns, quietMs = 500) {
  let count = apns.requests.length;
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    await sleep(quietMs);
    if (apns.requests.length === count) return;
    count = apns.requests.length;
  }
  throw new Error("push traffic never settled within 5s of quiet windows");
}

// Throwaway P-256 APNs key (.p8) + self-signed 127.0.0.1 TLS cert (temp files
// in tmpRoot, removed with it). Node has no in-process X.509 issuer, so the
// server cert is minted with openssl — the same throwaway recipe as the
// /tmp/push-e2e.mjs reference. The APNs signing key (apns-key.p8) and the TLS
// server key are deliberately independent, as on real APNs.
function generateApnsMaterial(dir) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
  const keyPath = join(dir, "apns-key.p8");
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }));
  const serverKeyPath = join(dir, "apns-server.key");
  const certPath = join(dir, "apns-cert.pem");
  execFileSync("openssl", [
    "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
    "-keyout", serverKeyPath, "-out", certPath, "-days", "1", "-nodes",
    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
  ]);
  return { keyPath, serverKeyPath, certPath, publicKey };
}

class FakeApns {
  constructor(dir) {
    this.dir = dir;
    this.teamId = APNS_TEAM_ID;
    this.keyId = APNS_KEY_ID;
    this.topic = APNS_TOPIC;
    this.requests = []; // every completed request: { path, headers, body }
    this.status = 200;
    this.reason = null; // sent as the apns-reason response header when status is 410
    this.server = null;
    this.port = null;
    this.publicKey = null;
  }

  async start() {
    const material = generateApnsMaterial(this.dir);
    this.publicKey = material.publicKey;
    this.server = http2.createSecureServer({
      key: readFileSync(material.serverKeyPath),
      cert: readFileSync(material.certPath),
      ALPNProtocols: ["h2"],
    });
    this.server.on("stream", (stream, req) => {
      let body = "";
      stream.on("data", (chunk) => {
        body += chunk;
      });
      stream.on("end", () => {
        this.requests.push({ path: req[":path"], headers: req, body });
        const headers = { ":status": this.status };
        if (this.status === 410) headers["apns-reason"] = this.reason ?? "Unregistered";
        stream.respond(headers);
        stream.end(this.status === 200 ? "Accepted" : JSON.stringify({ reason: headers["apns-reason"] }));
      });
    });
    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(0, "127.0.0.1", resolve);
    });
    this.port = this.server.address().port;
  }

  close() {
    if (!this.server) return;
    this.server.close();
  }
}

// Mock OpenRouter /chat/completions endpoint for the push-title shortening
// LLM (rc/title.ts): records every request and answers with a canned short
// completion. The child is pointed here by default via PI_RC_OPENROUTER_URL,
// which both prevents any egress to the real OpenRouter from a test run and
// makes "the LLM was (not) called" directly observable.
class MockOpenRouter {
  constructor() {
    this.requests = []; // every completed request: { path, auth, body }
    this.content = "Proceed with tonight's production rollout?"; // canned completion
    this.server = null;
    this.port = null;
  }

  async start() {
    this.server = http.createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => {
        body += chunk;
      });
      req.on("end", () => {
        this.requests.push({ path: req.url, auth: req.headers.authorization, body });
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ choices: [{ message: { content: this.content } }] }));
      });
    });
    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(0, "127.0.0.1", resolve);
    });
    this.port = this.server.address().port;
  }

  close() {
    if (!this.server) return;
    this.server.close();
  }
}

const apnsB64u = (part) => Buffer.from(part, "base64url").toString("utf8");

// Full JWT assertions for one request: 3 parts, header {alg,kid}, claims
// {iss,sub,aud,iat,exp} with a 3000 s TTL (Apple caps exp at 60 min and
// wants token updates no more than once per 20 min), and an ES256
// (IEEE P-1363) signature that verifies against the generated P-256 key.
function checkApnsJwt(apns, request, label) {
  const auth = String(request.headers.authorization ?? "");
  check(auth.startsWith("Bearer "), `${label}: no Bearer authorization`);
  const jwt = auth.slice("Bearer ".length);
  const parts = jwt.split(".");
  check(parts.length === 3, `${label}: JWT must have 3 parts`);
  const header = JSON.parse(apnsB64u(parts[0]));
  const claims = JSON.parse(apnsB64u(parts[1]));
  check(header.alg === "ES256" && header.kid === apns.keyId, `${label}: jwt header {alg:ES256, kid:keyId}`);
  check(
    claims.iss === apns.teamId && claims.sub === apns.keyId && claims.aud === "apns",
    `${label}: jwt claims iss/sub/aud`,
  );
  check(
    Number.isInteger(claims.iat) && Number.isInteger(claims.exp) && claims.exp - claims.iat === 3000,
    `${label}: jwt iat/exp (exp-iat=3000)`,
  );
  const signingInput = Buffer.from(jwt.slice(0, jwt.lastIndexOf(".")), "utf8");
  check(
    crypto.verify("sha256", signingInput, { key: apns.publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(parts[2], "base64url")),
    `${label}: ES256 signature (ieee-p1363) must verify against the generated P-256 key`,
  );
}

// apns-topic/push-type/priority/timestamp are common to every push type.
function checkApnsCommonHeaders(apns, request, label) {
  check(request.headers["apns-topic"] === apns.topic, `${label}: apns-topic`);
  check(request.headers["apns-push-type"] === "alert", `${label}: apns-push-type must be alert`);
  check(request.headers["apns-priority"] === "5", `${label}: apns-priority must be 5`);
  check(
    Number.isFinite(Number(request.headers["apns-timestamp"])) &&
      Number(request.headers["apns-timestamp"]) > 0,
    `${label}: apns-timestamp must be numeric`,
  );
}

// Group 12: Push notifications (fake APNs endpoint)

// (c) Client connected WITHOUT a push_token: the settled turn must be served
// normally and the fake endpoint must see nothing. Runs first, while the
// singleton pushToken is still null.
registerTest(12, "push_no_token_registered_settled_turn_makes_zero_requests", async (ctx) => {
  const apns = ctx.apns;
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    check(apns.requests.length === 0, `expected no prior push traffic, saw ${apns.requests.length}`);
    hs.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PONG-12C" }));
    await waitForEventByName(hs.next, "agent_settled", 60_000);
    await sleep(1_000); // quiet window: a (buggy) push would land here
    check(apns.requests.length === 0, `no push_token registered, expected zero APNs requests, got ${apns.requests.length}`);
  } finally {
    hs.close();
  }
});

// (d) Invalid tokens must be ignored silently: no error frame, no close, the
// connection keeps serving, and no push is ever attempted with a bad token.
registerTest(12, "push_invalid_tokens_ignored_and_still_served", async (ctx) => {
  const apns = ctx.apns;
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    for (const payload of [
      { type: "push_token", token: "nothex" },
      { type: "push_token", token: APNS_BAD_TOKEN_63 },
      { type: "push_token", token: 12345 },
      { type: "push_token" },
    ]) {
      hs.ws.send(JSON.stringify(payload));
    }
    // The invalid frames must not produce an error frame: a get_state on the
    // same socket is still served with a valid state (connection still open).
    hs.ws.send(JSON.stringify({ type: "get_state" }));
    const state = await waitForMessage(hs.next, (m) => m?.type === "state", 10_000, "state after invalid push_token");
    assertValidStateShape(state);
    hs.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PONG-12D" }));
    await waitForEventByName(hs.next, "agent_settled", 60_000);
    await sleep(1_000);
    check(apns.requests.length === 0, `no valid token was ever registered, expected zero APNs requests, got ${apns.requests.length}`);
  } finally {
    hs.close();
  }
});

// (a) First valid registration: the settled turn must produce exactly one POST
// with the full APNs header/JWT contract and the fixed finished payload.
// (--no-apns: the same flow must produce zero requests while the turn is served.)
registerTest(12, "push_agent_settled_sends_one_valid_request", async (ctx) => {
  const apns = ctx.apns;
  const hs = await connectAndVerifyConnectTime(ctx);
  const sessionId = ctx.lastState.sessionId; // set by the connect burst above
  try {
    hs.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_A }));
    await sleep(500); // register before the LLM round trip starts
    const before = apns.requests.length;
    hs.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PONG-12A" }));
    await waitForEventByName(hs.next, "agent_settled", 60_000);
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "finished push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "finished push request (deadline)",
      );
    }
    await sleep(1_000); // quiet window: at most ONE push per settled turn
    const requests = apns.requests.slice(before);
    if (!ctx.pushEnabled) {
      check(requests.length === 0, `push disabled (no PI_RC_APNS_* env), expected zero requests, got ${requests.length}`);
      return;
    }
    check(requests.length === 1, `expected exactly one APNs request on agent_settled, got ${requests.length}`);
    const [req] = requests;
    check(req.path === `/3/device/${APNS_TOKEN_A}`, `path must be /3/device/<token>, got ${req.path}`);
    check(req.headers["apns-collapse-id"] === "rc-finished", `apns-collapse-id must be rc-finished`);
    checkApnsCommonHeaders(apns, req, "finished push");
    checkApnsJwt(apns, req, "finished push");
    const body = JSON.parse(req.body);
    // Finished body = the finished-identity chain (session name → cwd
    // basename). The harness never names the session, so the expected body is
    // basename(tmpRoot) — the child is spawned with cwd = tmpRoot — unless a
    // sessionName arrived in the connect state (self-checks the chain either
    // way). Never agent text.
    const expectedBody =
      (typeof ctx.lastState.sessionName === "string" && ctx.lastState.sessionName.trim() !== "" && ctx.lastState.sessionName) ||
      basename(ctx.tmpRoot);
    check(
      body.aps?.alert?.title === "Agent finished" && body.aps?.alert?.body === expectedBody,
      `finished push must identify the session (expected body ${JSON.stringify(expectedBody)}), got ${JSON.stringify(body.aps?.alert)}`,
    );
    check(body.aps?.sound === "default", `finished push must carry sound default`);
    check(body.aps?.["thread-id"] === sessionId, `thread-id must be the session id, got ${body.aps?.["thread-id"]}`);
    check(!JSON.stringify(body).includes("PONG-12A"), `push payload must not contain prompt text`);
  } finally {
    hs.close();
  }
});

// (a-abort) THE abort-gate pin: with a token registered (test (a) just
// registered APNS_TOKEN_A) and push enabled, an aborted turn must fire NO
// finished push. The natural-settle conversions in the other group-12 tests
// are accommodations for the gate, not coverage of it — this test is the pin.
// If the gate's message_end/stopReason tracking (index.ts trackEvent) is
// dropped or reordered, this zero-assertion must fail.
// (--no-apns: mirror the !ctx.pushEnabled branches — zero requests overall.)
registerTest(12, "push_aborted_turn_sends_no_finished_request", async (ctx) => {
  const apns = ctx.apns;
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    const before = apns.requests.length;
    hs.ws.send(JSON.stringify({ type: "prompt", text: "LONG" }));
    await waitForEventByName(hs.next, "message_update", 15_000);
    hs.ws.send(JSON.stringify({ type: "abort" }));
    await waitForEventByName(hs.next, "agent_settled", 20_000);
    await sleep(1_500); // quiet window: a (buggy) push would land here
    const finished = apns.requests.slice(before).filter((r) => r.headers["apns-collapse-id"] === "rc-finished");
    if (!ctx.pushEnabled) {
      check(apns.requests.length === before, `push disabled, expected zero requests overall, got ${apns.requests.length - before}`);
    } else {
      check(finished.length === 0, `aborted turn must not push (abort gate), got ${finished.length} rc-finished requests`);
    }
  } finally {
    hs.close();
  }
});

// (b) A remote ask (ask_user_question via the ask extension, triggered the
// same way as group 5's ASK flow) must produce one request with the question
// collapse id, timeSensitive, and the first question's prompt as the body
// (short text ships verbatim — the shortening LLM must never be called for it).
// Token A from test (a) is still registered (singleton-persistent).
// (--no-apns: the question still fires and is answerable; zero requests.)
registerTest(12, "push_question_triggers_time_sensitive_request", async (ctx) => {
  const apns = ctx.apns;
  const mockLlm = ctx.mockLlm;
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    const before = apns.requests.length;
    const mockBefore = mockLlm.requests.length;
    hs.ws.send(JSON.stringify({ type: "prompt", text: "ASK" }));
    const q = await waitForMessage(hs.next, (m) => m?.type === "question", 60_000, "question (LLM round trip)");
    check(q.kind === "ask_user_question", `expected kind ask_user_question, got ${JSON.stringify(q.kind)}`);
    const questions = q.params?.questions;
    check(Array.isArray(questions) && questions.length === 1, `single-question ask must carry exactly 1 question, got ${JSON.stringify(questions)}`);
    const question = questions[0];
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "question push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "question push request (deadline)",
      );
    }
    await sleep(1_000); // quiet window: at most one question push
    const requests = apns.requests.slice(before);
    if (!ctx.pushEnabled) {
      check(requests.length === 0, `push disabled (no PI_RC_APNS_* env), expected zero requests, got ${requests.length}`);
    } else {
      check(requests.length === 1, `expected exactly one APNs request on ask(), got ${requests.length}`);
      const [req] = requests;
      check(req.path === `/3/device/${APNS_TOKEN_A}`, `question push must use the registered token, got ${req.path}`);
      check(req.headers["apns-collapse-id"] === "rc-question", `apns-collapse-id must be rc-question`);
      checkApnsCommonHeaders(apns, req, "question push");
      checkApnsJwt(apns, req, "question push");
      const body = JSON.parse(req.body);
      check(body.aps?.timeSensitive === true, `question push must set aps.timeSensitive`);
      check(
        body.aps?.alert?.title === "Agent has a question" && body.aps?.alert?.body === question.prompt,
        `short question push must carry the first question's prompt verbatim, got ${JSON.stringify(body.aps?.alert)}`,
      );
      check(body.aps?.sound === "default", `question push must carry sound default`);
    }
    // ≤80-char question text ships verbatim: the shortening LLM (pointed at
    // the recording mock by the spawn env) must never be called for it.
    check(
      mockLlm.requests.length === mockBefore,
      `short question must not call the shortening LLM, got ${mockLlm.requests.length - mockBefore} calls`,
    );
    // Answer it so the agent settles and later tests start idle.
    hs.ws.send(JSON.stringify(answerFrame(q, question, question.options[0], 1)));
    const resolved = await waitForMessage(hs.next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    check(resolved.value === question.options[0].value, `single-question resolution must carry the answer value, got ${JSON.stringify(resolved.value)}`);
    await waitForEventByName(hs.next, "agent_settled", 60_000);
  } finally {
    hs.close();
  }
});

// (b-mock) Long question (>80 chars) with a healthy shortening LLM: the body
// is the canned shortened completion, and exactly one /chat/completions call
// reaches the mock with the expected request shape (model, messages,
// max_tokens, Bearer dummy key). The expected truncation is computed from the
// question text as received on the wire, so model paraphrasing cannot make
// this flaky.
registerTest(12, "push_long_question_body_llm_shortened", async (ctx) => {
  const apns = ctx.apns;
  const mockLlm = ctx.mockLlm;
  await drainPushQuiet(apns); // the previous test's settle push may still be in flight
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    const before = apns.requests.length;
    const mockBefore = mockLlm.requests.length;
    hs.ws.send(JSON.stringify({ type: "prompt", text: "ASKLONG" }));
    const q = await waitForMessage(hs.next, (m) => m?.type === "question", 60_000, "long question (LLM round trip)");
    check(q.kind === "ask_user_question", `expected kind ask_user_question, got ${JSON.stringify(q.kind)}`);
    const questionText = String(q.params?.questions?.[0]?.prompt ?? "");
    check(questionText.length > 100, `ASKLONG question must exceed 100 chars, got ${questionText.length}`);
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "long-question push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "long-question push request (deadline)",
      );
    }
    await sleep(1_000); // quiet window: at most one question push
    const requests = apns.requests.slice(before).filter((r) => r.headers["apns-collapse-id"] === "rc-question");
    if (!ctx.pushEnabled) {
      check(requests.length === 0, `push disabled, expected zero question requests, got ${requests.length}`);
    } else {
      check(requests.length === 1, `expected exactly one question APNs request, got ${requests.length}`);
      const body = JSON.parse(requests[0].body);
      check(body.aps?.alert?.title === "Agent has a question", `question push title, got ${JSON.stringify(body.aps?.alert)}`);
      check(
        body.aps?.alert?.body === mockLlm.content,
        `long question push must carry the LLM-shortened body, got ${JSON.stringify(body.aps?.alert)}`,
      );
      check(body.aps?.timeSensitive === true, `question push must set aps.timeSensitive`);
    }
    // The shortening LLM: called exactly once (in both spawn modes — the
    // token is registered either way), with the sanitized question text.
    check(
      mockLlm.requests.length === mockBefore + 1,
      `expected exactly one shortening LLM call, got ${mockLlm.requests.length - mockBefore}`,
    );
    const [llm] = mockLlm.requests.slice(mockBefore);
    check(llm.path === "/chat/completions", `shortening LLM path must be /chat/completions, got ${llm.path}`);
    check(
      llm.auth === `Bearer ${OPENROUTER_DUMMY_KEY}`,
      `the child must use the dummy OPENROUTER_API_KEY, got ${JSON.stringify(llm.auth)}`,
    );
    const llmBody = JSON.parse(llm.body);
    check(llmBody.model === "minimax/minimax-m3:free", `shortening model, got ${JSON.stringify(llmBody.model)}`);
    check(llmBody.max_tokens === 40, `max_tokens must be 40, got ${JSON.stringify(llmBody.max_tokens)}`);
    check(
      Array.isArray(llmBody.messages) &&
        llmBody.messages.length === 2 &&
        llmBody.messages[0]?.role === "system" &&
        llmBody.messages[1]?.role === "user" &&
        llmBody.messages[1]?.content === questionText.replace(/\s+/g, " ").trim(),
      `LLM user message must be the sanitized question text, got ${JSON.stringify(llmBody.messages?.[1]?.content)}`,
    );
    // Answer it so the agent settles and later tests start idle.
    hs.ws.send(JSON.stringify(answerFrame(q, q.params.questions[0], q.params.questions[0].options[0], 1)));
    const resolved = await waitForMessage(hs.next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    await waitForEventByName(hs.next, "agent_settled", 60_000);
  } finally {
    hs.close();
  }
});

// (b-unreachable) Long question with the shortening LLM unreachable (probe
// flips PI_RC_OPENROUTER_URL to a dead 127.0.0.1 port with a tiny timeout):
// the body must fall back to deterministic hard truncation of the question
// text (100-char cap incl. the ellipsis, single spaces).
registerTest(12, "push_long_question_body_llm_failure_truncates", async (ctx) => {
  const apns = ctx.apns;
  const mockLlm = ctx.mockLlm;
  await drainPushQuiet(apns); // the previous test's settle push may still be in flight
  const hs = await connectAndVerifyConnectTime(ctx);
  let flipped = false;
  try {
    await withTimeout(
      ctx.client.sendCommand({ type: "prompt", message: "/rctitle off" }),
      10_000,
      "pi /rctitle off timed out",
    );
    flipped = true;
    const mockBefore = mockLlm.requests.length;
    const before = apns.requests.length;
    hs.ws.send(JSON.stringify({ type: "prompt", text: "ASKLONG" }));
    const q = await waitForMessage(hs.next, (m) => m?.type === "question", 60_000, "long question (LLM round trip)");
    check(q.kind === "ask_user_question", `expected kind ask_user_question, got ${JSON.stringify(q.kind)}`);
    const clean = String(q.params?.questions?.[0]?.prompt ?? "").replace(/\s+/g, " ").trim();
    check(clean.length > 100, `ASKLONG question must exceed 100 chars, got ${clean.length}`);
    const expected = clean.length <= 100 ? clean : `${clean.slice(0, 99)}…`;
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "truncated push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "truncated push request (deadline)",
      );
    }
    await sleep(1_000); // quiet window: at most one question push
    const requests = apns.requests.slice(before).filter((r) => r.headers["apns-collapse-id"] === "rc-question");
    if (!ctx.pushEnabled) {
      check(requests.length === 0, `push disabled, expected zero question requests, got ${requests.length}`);
    } else {
      check(requests.length === 1, `expected exactly one question APNs request, got ${requests.length}`);
      const body = JSON.parse(requests[0].body);
      check(
        body.aps?.alert?.title === "Agent has a question" && body.aps?.alert?.body === expected,
        `unreachable LLM must fall back to hard truncation (expected ${JSON.stringify(expected)}), got ${JSON.stringify(body.aps?.alert)}`,
      );
      check(!/ {2,}/.test(body.aps?.alert?.body ?? ""), `truncated body must have single spaces only, got ${JSON.stringify(body.aps?.alert?.body)}`);
    }
    // The dead LLM was never reached (no mock traffic either: the probe
    // repointed the URL away from it).
    check(mockLlm.requests.length === mockBefore, `unreachable LLM test must make no mock calls, got ${mockLlm.requests.length - mockBefore}`);
    // Answer it so the agent settles and later tests start idle.
    hs.ws.send(JSON.stringify(answerFrame(q, q.params.questions[0], q.params.questions[0].options[0], 1)));
    const resolved = await waitForMessage(hs.next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    await waitForEventByName(hs.next, "agent_settled", 60_000);
  } finally {
    // Restore the spawn-default (mock) URL so later question pushes keep the
    // no-real-egress guarantee. Best-effort: never mask a test failure.
    if (flipped) {
      ctx.client.sendCommand({ type: "prompt", message: `/rctitle url http://127.0.0.1:${ctx.mockLlm.port}` }).catch(() => {});
    }
    hs.close();
  }
});

// (e) The token is singleton-persistent: it survives a client disconnect/
// reconnect (the settled turn still pushes without re-registration), and a
// second registration replaces it (last write wins — the next push path uses
// the new token).
registerTest(12, "push_token_persists_across_reconnect_and_second_registration_replaces", async (ctx) => {
  const apns = ctx.apns;
  // (e1) Reconnect WITHOUT re-registering: the stored token (A) must still push.
  const a = await connectAndVerifyConnectTime(ctx);
  a.close(); // disconnect: the token must survive (singleton, not per-connection)
  const b = await connectAndVerifyConnectTime(ctx);
  try {
    await drainPushQuiet(apns); // the previous test's settle push may still be in flight
    const before = apns.requests.length;
    // Natural settle (2026-09-07 abort gate): aborted turns no longer fire
    // the finished push, so token-persistence pushes must come from a real
    // settle (fast model — test (a) already budgets one LLM round trip).
    b.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PING-E1" }));
    await waitForEventByName(b.next, "agent_settled", 60_000);
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "post-reconnect push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "post-reconnect push request (deadline)",
      );
    }
    await sleep(1_000);
    const requests = apns.requests.slice(before);
    if (ctx.pushEnabled) {
      check(requests.length === 1, `expected one push after reconnect (token persisted), got ${requests.length}`);
      check(
        requests[0].path === `/3/device/${APNS_TOKEN_A}`,
        `push after reconnect must use the persisted token A, got ${requests[0].path}`,
      );
    } else {
      check(requests.length === 0, `push disabled, expected zero requests, got ${requests.length}`);
    }
    // (e2) A second push_token replaces the stored one (last write wins).
    b.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_B }));
    await sleep(500); // register before the next settle trigger
    const before2 = apns.requests.length;
    b.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PING-E2" }));
    await waitForEventByName(b.next, "agent_settled", 60_000);
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before2, APNS_PUSH_TIMEOUT_MS, "post-replace push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "post-replace push request (deadline)",
      );
    }
    await sleep(1_000);
    const requests2 = apns.requests.slice(before2);
    if (ctx.pushEnabled) {
      check(requests2.length === 1, `expected one push after re-registration, got ${requests2.length}`);
      check(
        requests2[0].path === `/3/device/${APNS_TOKEN_B}`,
        `second registration must replace the token (last write wins), got ${requests2[0].path}`,
      );
    } else {
      check(requests2.length === 0, `push disabled, expected zero requests, got ${requests2.length}`);
    }
  } finally {
    b.close();
  }
});

// (f) A 410 (BadDeviceToken) from the fake endpoint must drop the stored
// token: the next trigger produces no new request, and RC keeps serving.
registerTest(12, "push_410_drops_token_and_rc_still_serves", async (ctx) => {
  const apns = ctx.apns;
  apns.status = 410;
  apns.reason = "Unregistered";
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    // Natural settles (2026-09-07 abort gate): aborted turns no longer fire
    // the finished push, so the 410 drop and its aftermath must be observed
    // on real settles (fast model round trips, budgeted like test (a)).
    // Trigger 1: a settle while the endpoint answers 410: the token is dropped.
    const before = apns.requests.length;
    hs.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PING-F1" }));
    await waitForEventByName(hs.next, "agent_settled", 60_000);
    if (ctx.pushEnabled) {
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "410 push request"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "410 push request (deadline)",
      );
      const [req] = apns.requests.slice(before);
      check(req.headers["apns-collapse-id"] === "rc-finished", `410 request must still be a finished push`);
      // The token is now dropped: a subsequent trigger must produce NO request.
      await sleep(1_000); // let the outcome handler run (token drop is async)
      const before2 = apns.requests.length;
      // A natural settle must produce NO request now that the token is dropped
      // (natural, so the zero proves the drop — not the abort gate).
      hs.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PING-F2" }));
      await waitForEventByName(hs.next, "agent_settled", 60_000);
      await sleep(1_500); // quiet window: no push expected (token dropped)
      check(
        apns.requests.length === before2,
        `after a 410 the token must be dropped (no further requests), got ${apns.requests.length - before2} more`,
      );
    } else {
      check(apns.requests.length === before, `push disabled, expected zero requests, got ${apns.requests.length - before}`);
    }
    // RC must keep serving after the drop (or, in disabled mode, at all).
    hs.ws.send(JSON.stringify({ type: "get_state" }));
    const state = await waitForMessage(hs.next, (m) => m?.type === "state", 10_000, "state after 410 drop");
    assertValidStateShape(state);
    check(state.isStreaming === false, "isStreaming must be false after the aborted turn");
  } finally {
    apns.status = 200;
    apns.reason = null;
    hs.close();
  }
});

// (g) The "APNs env NOT set" case is the whole group re-run with --no-apns:
// the child is spawned without the PI_RC_APNS_* env, the fake endpoint still
// runs as a traffic observer, and every test above takes its !ctx.pushEnabled
// branch (zero requests while settles/questions/get_state keep working).

// A failed earlier test can leave the agent busy (blocked on an unanswered
// pending ask, or still streaming), which would make the RPC prompt below
// reject with "Agent is already processing". Connect once, answer any
// redelivered pending ask, abort any streaming turn, and wait for idle —
// cheap (~2 s) on a green run, and it isolates the zero-client tests from
// upstream flakes instead of cascading them.
// True when the agent turn that started last has not settled yet, judged
// over the recorded RPC notification prefix [0, until). A pending ask keeps
// its turn open, so "busy" covers both the streaming and the ask-blocked
// case.
function agentBusySince(client, until) {
  let lastStart = -1;
  let lastSettled = -1;
  for (let i = 0; i < until; i += 1) {
    const type = client.notifications[i]?.type;
    if (type === "agent_start") lastStart = i;
    else if (type === "agent_settled") lastSettled = i;
  }
  return lastStart > lastSettled;
}

// A failed earlier test can leave the agent busy (blocked on an unanswered
// pending ask, or still streaming), which would make the RPC prompt below
// reject with "Agent is already processing". If busy: connect once, either
// answer the redelivered pending ask or abort the streaming turn, and close
// the socket immediately — completion is awaited on the RPC notification
// stream, because a WS read after the burst drain would race the drained
// connection's abandoned waiter (which swallows one frame). Cheap (~1 s) on
// a green run, and it isolates the zero-client tests from upstream flakes
// instead of cascading them.
async function ensureAgentIdle(ctx) {
  const since = ctx.client.notifications.length;
  if (!agentBusySince(ctx.client, since)) return;
  const probe = await connectAndVerifyConnectTime(ctx); // consumed hello_ok/state/history
  try {
    const burst = await drainUntilQuiet(probe.next, 700); // last read on this socket
    const pending = burst.find((m) => m?.type === "question");
    if (pending) {
      // Unified ask: one answer frame with a row per pending question, each
      // row answering with the question's first option (cleanup path — the
      // value just needs to be valid per the wire contract).
      const subs = Array.isArray(pending.params?.questions) ? pending.params.questions : [];
      probe.ws.send(JSON.stringify({
        type: "answer",
        id: pending.id,
        answers: subs.map((q) => ({
          id: q.id,
          value: q.options?.[0]?.value ?? "yes",
          label: q.options?.[0]?.label ?? "yes",
          wasCustom: false,
          index: 1,
        })),
      }));
    } else {
      probe.ws.send(JSON.stringify({ type: "abort" })); // no-op per server if already idle
    }
  } finally {
    probe.close();
  }
  await withTimeout(
    ctx.client.waitForNotification(
      (m, idx) => idx >= since && m?.type === "agent_settled",
      45_000,
      "idle cleanup settle (LLM round trip)",
    ),
    50_000,
    "idle cleanup settle (deadline)",
  );
}

// Shared body for the zero-client ask-routing negatives ((h) not push-ready,
// (j) token registered but creds missing): drives ASK over the RPC channel
// with no WS client anywhere in the flow — connecting one to observe the turn
// would itself flip hasConnectedClients() and route the ask remote — so the
// turn's completion is observed on the RPC notification stream instead. The
// ask_user_question tool must fall back locally: its "UI not available" error result
// lands in history (the agent settles without any answer) and zero push
// traffic reaches the endpoint.
async function assertAskFallsBackWithZeroClients(ctx) {
  const apns = ctx.apns;
  await ensureAgentIdle(ctx);
  const before = apns.requests.length;
  const since = ctx.client.notifications.length;
  await withTimeout(ctx.client.sendCommand({ type: "prompt", message: "ASK" }), 10_000, "pi ASK prompt RPC");
  await withTimeout(
    ctx.client.waitForNotification(
      (m, idx) => idx >= since && m?.type === "agent_settled",
      45_000,
      "agent_settled over RPC (LLM round trip)",
    ),
    50_000,
    "agent_settled over RPC (deadline)",
  );
  await sleep(1_000); // quiet window: a (buggy) push would land here
  check(
    apns.requests.length === before,
    `ask() with zero clients must not push when push is not sendable, got ${apns.requests.length - before} requests`,
  );
  const hs = await connectAndVerifyConnectTime(ctx);
  try {
    hs.ws.send(JSON.stringify({ type: "get_history" }));
    const history = await waitForMessage(hs.next, (m) => m?.type === "history", 10_000, "history after zero-client ask");
    const messages = history.messages ?? [];
    check(
      messages.some((m) => m?.role === "toolResult" && String(m.output ?? "").includes("UI not available")),
      `ask_user_question tool must fall back locally with zero clients (no "UI not available" tool result in history; tail: ${JSON.stringify(messages.slice(-4)).slice(0, 400)})`,
    );
  } finally {
    hs.close();
  }
}

// (h) Zero clients + push not sendable: ask() must NOT route remote — the
// local fallback runs, the agent settles without an answer, and no push is
// attempted. In the push-enabled spawn the not-sendable state is forced
// deterministically here (register a token, settle against a 410-ing
// endpoint → the drop clears the token and the persisted file) instead of
// relying on (f) having run its drop — an earlier failure upstream must not
// break this test's premise. In the --no-apns spawn the not-sendable state is
// guaranteed by the harness: the child's PI_RC_APNS_CONFIG points at an
// isolated temp file, so file creds can never be present and push is never
// sendable for the child.
registerTest(12, "ask_zero_clients_not_push_ready_falls_back_without_push", async (ctx) => {
  if (ctx.pushEnabled) {
    const apns = ctx.apns;
    await ensureAgentIdle(ctx);
    apns.status = 410;
    apns.reason = "Unregistered";
    let dropper = null;
    try {
      const before = apns.requests.length;
      dropper = await connectAndVerifyConnectTime(ctx);
      dropper.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_A }));
      await sleep(500); // register before the settle
      // Natural settle: the 2026-09-07 abort gate skips aborted turns' pushes,
      // and this settle's push IS the point — it takes the 410 that drops
      // the token.
      dropper.ws.send(JSON.stringify({ type: "prompt", text: "Reply with exactly: PING-H1" }));
      await waitForEventByName(dropper.next, "agent_settled", 60_000);
      await withTimeout(
        waitUntil(() => apns.requests.length > before, APNS_PUSH_TIMEOUT_MS, "410 drop push"),
        APNS_PUSH_TIMEOUT_MS + 5_000,
        "410 drop push (deadline)",
      );
      await sleep(1_000); // let the (async) drop handler clear the token
    } finally {
      apns.status = 200;
      apns.reason = null;
      dropper?.close();
    }
  }
  await assertAskFallsBackWithZeroClients(ctx);
});

// (i) The locked-phone case: token registered, WS dead, creds configured.
// ask() must route remote with ZERO clients, fire the rc-question push, and
// keep the pending ask; a reconnecting client gets the question redelivered
// after the connect burst and the ask resolves from that fresh client.
// (--no-apns: push is never sendable — the child's PI_RC_APNS_CONFIG points
// at an isolated temp file, so file creds can never resolve in any spawn
// mode — so the case runs only in the push-enabled spawn.)
registerTest(12, "ask_locked_phone_zero_clients_pushes_and_redelivers", async (ctx) => {
  if (!ctx.pushEnabled) throw skip("needs the env-pointed fake APNs endpoint (push-enabled spawn)");
  const apns = ctx.apns;
  await ensureAgentIdle(ctx);
  await drainPushQuiet(apns); // earlier tests' settle pushes must not pollute the window
  const a = await connectAndVerifyConnectTime(ctx);
  a.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_A }));
  await sleep(500); // register before the disconnect
  a.close(); // the locked phone: dead WS, token kept on the singleton
  await sleep(500); // let the server-side close land before the ask gate is evaluated
  const before = apns.requests.length;
  await withTimeout(ctx.client.sendCommand({ type: "prompt", message: "ASK" }), 10_000, "pi ASK prompt RPC");
  await withTimeout(
    waitUntil(
      () => apns.requests.slice(before).some((r) => r.headers["apns-collapse-id"] === "rc-question"),
      40_000,
      "question push with zero clients",
    ),
    45_000,
    "question push with zero clients (deadline)",
  );
  await sleep(1_000); // quiet window: at most one question push per ask
  const pushes = apns.requests.slice(before).filter((r) => r.headers["apns-collapse-id"] === "rc-question");
  check(pushes.length === 1, `expected exactly one question push with zero clients, got ${pushes.length}`);
  const [req] = pushes;
  check(req.path === `/3/device/${APNS_TOKEN_A}`, `locked-phone push must use the registered token, got ${req.path}`);
  checkApnsCommonHeaders(apns, req, "locked-phone question push");
  // The JWT contract itself is asserted by tests (a)/(b); this test owns the
  // zero-client routing, redelivery, and resolution behavior.
  const pushBody = JSON.parse(req.body);
  check(pushBody.aps?.timeSensitive === true, `locked-phone push must set aps.timeSensitive, got ${JSON.stringify(pushBody.aps)}`);
  // The unlocked phone reconnects: the pending question is redelivered right
  // after hello_ok + the connect burst, and answering it resolves the ask.
  const b = await connectAndVerifyConnectTime(ctx); // consumed hello_ok/state/history
  try {
    const q = await waitForMessage(
      b.next,
      (m) => m?.type === "question" && m?.kind === "ask_user_question",
      10_000,
      "redelivered question after reconnect",
    );
    const question = q.params?.questions?.[0];
    check(
      typeof question?.prompt === "string" && question.prompt.toLowerCase().includes("color"),
      `question text must mention color, got ${JSON.stringify(question?.prompt)}`,
    );
    assertOptionsShape(question?.options, "question", 3);
    b.ws.send(JSON.stringify(answerFrame(q, question, question.options[0], 1)));
    const resolved = await waitForMessage(b.next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    check(resolved.value === question.options[0].value, `single-question resolution must carry the answer value, got ${JSON.stringify(resolved.value)}`);
    await waitForEventByName(b.next, "agent_settled", 45_000);
  } finally {
    b.close();
  }
});

// (j) The token-alone trap: token registered but APNs creds UNSET must NOT
// route remote with 0 clients — with no sendable push the question would
// silently wait forever, so the local fallback runs instead. Reachable only
// in a --no-apns spawn whose config file carries no creds (a token-only file
// still resolves no creds; a full file makes the case (i) against the real
// host, which the harness must not push to).
registerTest(12, "ask_zero_clients_token_without_creds_stays_local", async (ctx) => {
  if (ctx.pushEnabled) throw skip("creds are present in this spawn (case runs under --no-apns)");
  const a = await connectAndVerifyConnectTime(ctx);
  a.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_A }));
  await sleep(500); // register before the disconnect
  a.close();
  await assertAskFallsBackWithZeroClients(ctx);
});

// (k) Auto-auth: presenting the currently registered push token authenticates
// without a fresh 6-digit code (the code is re-randomized every pi session,
// so without this every session would force re-pairing of an already-paired
// device). Token A was registered earlier in this group and is still the
// registered token here in both spawn modes. The wrong-token hello below is
// the group's only bad hello and runs after the lockout wait, so it cannot
// trip the rate limiter (and does not expect to).
registerTest(12, "hello_auto_auth_registered_token_no_fresh_code", async (ctx) => {
  requireAuth(ctx);
  // Register the token first — via a code-authenticated client, the only way
  // a token becomes "the registered token" — so the test is self-contained
  // regardless of which earlier tests left the token slot in what state.
  const reg = await connectAndVerifyConnectTime(ctx);
  reg.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_A }));
  await sleep(500); // register before the disconnect
  reg.close();
  const a = await handshake(ctx, { code: "deadbe", token: APNS_TOKEN_A });
  check(a.result?.type === "hello_ok", `expected auto-auth hello_ok with the registered token, got ${JSON.stringify(a.result)}`);
  a.close();
  // An unregistered token authenticates nothing: wrong code + wrong token
  // must still be bad_code (and counts as a failed hello, like any bad code).
  const b = await handshake(ctx, { code: "deadbe", token: "0".repeat(64) });
  await expectErrorThenClose(b.result, "bad_code", b.next, b.close);
});

// push_token accepts 64-hex case-insensitively, but storage and the
// case-sensitive hello compare must agree: an UPPER-case registration must
// auto-authenticate when the client presents the same token lower-cased
// (Swift always presents lowercase, so the stored form is what must match).
const APNS_TOKEN_HEX = ("abcdef0123456789".repeat(4));
registerTest(12, "push_token_uppercase_registration_auto_auths_lowercase", async (ctx) => {
  requireAuth(ctx);
  const reg = await connectAndVerifyConnectTime(ctx);
  reg.ws.send(JSON.stringify({ type: "push_token", token: APNS_TOKEN_HEX.toUpperCase() }));
  await sleep(500); // register before the disconnect
  reg.close();
  const a = await handshake(ctx, { code: "deadbe", token: APNS_TOKEN_HEX });
  check(
    a.result?.type === "hello_ok",
    `expected auto-auth after uppercase registration (stored form must be lowercase), got ${JSON.stringify(a.result)}`
  );
  a.close();
});

// --- groups 5, 6, 7, 8, 9 -------------------------------------------------------

// Group 5: Questions. LLM-dependent: test-project AGENTS.md forces the ask_user_question tool for the exact prompts ASK/ASKFORM
// (~10-30s per round trip, hence 60s waits). Each test chains two LLM waits, so the worst-case total may exceed the 60s framework timeout -> a framework timeout FAIL, by design.
// The unified wire (2026-09-07 protocol collapse): ONE pending frame type `question` with kind
// `ask_user_question` and params { questions: [...] } for 1..N questions, answered with ONE frame
// type `answer` carrying an `answers` array. question_resolved carries `value` only for
// single-question asks.
const assertOptionsShape = (options, where, min = 1) => {
  check(Array.isArray(options) && options.length >= min, `${where} needs >= ${min} options`);
  options.forEach((opt, i) => check(nonEmptyString(opt?.label) && nonEmptyString(opt?.value), `${where}.options[${i}] needs label+value`));
};

// Unified answer frame (2026-09-07 protocol collapse): the client answers any
// ask — single or multi-question — with ONE `answer` frame whose `answers`
// array carries a row per question; the row echoes the question id and the
// chosen option's value/label. `frame` is the pending `question` frame; the
// harness always answers from the wire values, never from assumed literals.
const answerFrame = (frame, question, option, index = 1) => ({
  type: "answer",
  id: frame.id,
  answers: [
    {
      id: question.id,
      value: option.value,
      label: option.label,
      wasCustom: false,
      index,
    },
  ],
});

registerTest(5, "ask_triggers_question_and_answer_resolves", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "ASK" }));
    const q = await waitForMessage(next, (m) => m?.type === "question", 60_000, "question (LLM round trip)");
    check(q.kind === "ask_user_question", `expected kind ask_user_question, got ${JSON.stringify(q.kind)}`);
    const questions = q.params?.questions;
    check(Array.isArray(questions) && questions.length === 1, `single-question ask must carry exactly 1 question, got ${JSON.stringify(questions)}`);
    const question = questions[0];
    check(typeof question?.prompt === "string" && question.prompt.toLowerCase().includes("color"),
      `question text must mention color, got ${JSON.stringify(question?.prompt)}`);
    assertOptionsShape(question?.options, "question", 3);
    ws.send(JSON.stringify(answerFrame(q, question, question.options[0], 1)));
    const resolved = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    check(resolved.value === question.options[0].value, `single-question resolution must carry the answer value, got ${JSON.stringify(resolved.value)}`);
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
    // The connect burst must re-deliver the SAME pending question (same id, kind ask_user_question).
    const q = await waitForMessage(b.next, (m) => m?.type === "question" && m?.kind === "ask_user_question" && m.id === questionId, 10_000, "re-delivered question");
    b.ws.send(JSON.stringify(answerFrame(q, q.params.questions[0], q.params.questions[0].options[1], 2)));
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
      const question = qA.params?.questions?.[0];
      ws.send(JSON.stringify(answerFrame(qA, question, question.options[2], 3)));
      const resA = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === qA.id, 10_000, "question_resolved on A");
      check(resA.by === "client" && resA.value === question.options[2].value, `A resolution mismatch: ${JSON.stringify(resA)}`);
      const resB = await waitForMessage(b.next, (m) => m?.type === "question_resolved" && m.id === qA.id, 10_000, "question_resolved on B");
      check(resB.by === "client", `B must receive the same resolution broadcast, got ${JSON.stringify(resB)}`);
      await waitForEventByName(next, "agent_settled", 60_000);
    } finally {
      b.close();
    }
  });
});

registerTest(5, "askform_triggers_multi_question_ask_and_answers_resolve", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    ws.send(JSON.stringify({ type: "prompt", text: "ASKFORM" }));
    const qf = await waitForMessage(next, (m) => m?.type === "question" && m?.kind === "ask_user_question", 60_000, "multi-question ask (LLM round trip)");
    const subs = qf.params?.questions;
    check(Array.isArray(subs) && subs.length === 2, "multi-question ask must have exactly 2 questions");
    check(subs.map((s) => s?.id).join(",") === "q1,q2", `expected ids q1,q2, got ${JSON.stringify(subs.map((s) => s?.id))}`);
    // every sub-question needs a prompt + its options
    subs.forEach((s, i) => { check(nonEmptyString(s?.prompt), `questions[${i}] needs a prompt`); assertOptionsShape(s?.options, `questions[${i}]`, 2); });
    // ONE unified answer frame: a row per sub-question, echoing each id and the
    // chosen option's value/label (wire values, not assumed literals).
    const [q1, q2] = subs;
    ws.send(JSON.stringify({
      type: "answer",
      id: qf.id,
      answers: [
        { id: q1.id, value: q1.options[0].value, label: q1.options[0].label, wasCustom: false, index: 1 },
        { id: q2.id, value: q2.options[1].value, label: q2.options[1].label, wasCustom: false, index: 2 },
      ],
    }));
    const resolved = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === qf.id, 10_000, "multi-question resolved");
    check(resolved.by === "client", `expected by client, got ${JSON.stringify(resolved.by)}`);
    check(resolved.value === undefined, `multi-question resolution must NOT carry a value, got ${JSON.stringify(resolved.value)}`);
    await waitForEventByName(next, "agent_settled", 60_000);
  });
});

// Group 5b: the ask() signal path (the TUI esc-hatch's abort mechanism,
// covered at the singleton level). The esc hatch itself cannot be exercised
// in this spawn (ctx.mode is "rpc" and ctx.ui.custom() returns undefined),
// so the probe extension (test-project/rc-signal-probe.ts, loaded via
// --extension) drives rc.ask() with an AbortSignal. Assertions are
// protocol-level: the question broadcast, the question_resolved
// by:cancelled, and the unknown_question rejection of a late answer.
registerTest(5, "ask_signal_already_aborted_resolves_null_and_broadcasts_cancelled", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    await withTimeout(
      ctx.client.sendCommand({ type: "prompt", message: "/rcsignal aborted" }),
      10_000,
      "pi /rcsignal aborted timed out",
    );
    const q = await waitForMessage(
      next,
      (m) => m?.type === "question" && m?.kind === "ask_user_question" && m?.params?.questions?.[0]?.prompt === "rc signal probe",
      10_000,
      "probe question",
    );
    const resolved = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === q.id, 10_000, "question_resolved");
    check(resolved.by === "cancelled", `expected by cancelled, got ${JSON.stringify(resolved.by)}`);
  });
});

registerTest(5, "ask_signal_aborted_mid_wait_resolves_null_and_late_answer_is_unknown", async (ctx) => {
  requireAuth(ctx);
  await withConnection(ctx, async ({ ws, next }) => {
    await withTimeout(
      ctx.client.sendCommand({ type: "prompt", message: "/rcsignal pend" }),
      10_000,
      "pi /rcsignal pend timed out",
    );
    const q = await waitForMessage(
      next,
      (m) => m?.type === "question" && m?.kind === "ask_user_question" && m?.params?.questions?.[0]?.prompt === "rc signal probe",
      15_000,
      "probe question",
    );
    const question = q.params?.questions?.[0];
    const resolved = await waitForMessage(next, (m) => m?.type === "question_resolved" && m.id === q.id, 15_000, "question_resolved");
    check(resolved.by === "cancelled", `expected by cancelled, got ${JSON.stringify(resolved.by)}`);
    // The pending ask is gone: an answer for the cancelled id must be
    // rejected with unknown_question (and the connection stays open).
    ws.send(JSON.stringify(answerFrame(q, question, question.options[0], 1)));
    const err = await waitForMessage(
      next,
      (m) => m?.type === "error" && m.code === "unknown_question",
      10_000,
      "unknown_question after cancel",
    );
    check(err.code === "unknown_question", `expected unknown_question, got ${JSON.stringify(err)}`);
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

// Group 11's bad-code hellos lock out this host for 60 s (RATE_LIMIT_LOCK_MS in
// index.ts), so group 12's own connects would be rate_limited. Called from the
// runner BEFORE group 12 (outside the per-test budget): poll a real-code
// handshake until the lockout clears; the successful hello_ok is closed
// immediately (it also proves the connect path group 12 relies on).
async function waitForLockoutClear(ctx) {
  requireAuth(ctx);
  const deadline = Date.now() + (ctx.pushLockoutSince ? LOCKOUT_MS + 30_000 : LOCKOUT_DEADLINE_MS);
  for (;;) {
    const hs = await handshake(ctx);
    if (hs.result?.type === "hello_ok") {
      hs.close();
      return;
    }
    if (hs.result?.type === "error" && hs.result.code !== "rate_limited") {
      throw new Error(`unexpected error while waiting for lockout clear: ${JSON.stringify(hs.result)}`);
    }
    if (Date.now() >= deadline) throw new Error("rate-limit lockout did not clear within the deadline");
    await sleep(LOCKOUT_POLL_MS);
  }
}

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

  const apns = new FakeApns(tmpRoot);
  const mockLlm = new MockOpenRouter();

  const cleanup = async () => {
    if (client) {
      await client.terminate();
    }
    apns.server?.closeAllConnections?.();
    apns.close();
    mockLlm.close();
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
    // Fake APNs endpoint (group 12): throwaway P-256 key + self-signed cert in
    // tmpRoot, listening on an OS-assigned 127.0.0.1 port BEFORE the spawn so
    // the port can go into the child's env. Up in BOTH modes: with --no-apns it
    // is a pure traffic observer (the push-disabled case must show zero hits).
    // The mock OpenRouter (title-shortening LLM) runs in both modes for the
    // same reason: no real egress, observable call counts.
    await apns.start();
    await mockLlm.start();
  } catch (err) {
    console.error(`setup failed: ${err.message}`);
    await cleanup();
    process.exit(2);
  }

  // PI_RC_APNS_CONFIG is the extension's config-path test seam: point the
  // child at an (initially absent) file in the temp root so the user's real
  // ~/.pi/agent/rc-push.json — including its persisted device token — can
  // never leak into a run. Tests that need a file write one here explicitly.
  const childEnv = {
    ...process.env,
    PI_RC_BIND: RC_HOST,
    PI_RC_AUTH_FILE: authFile,
    PI_RC_APNS_CONFIG: join(tmpRoot, "rc-push.json"),
    // The push-title shortening LLM (rc/title.ts) must never reach the real
    // OpenRouter account from a test run: the key is a dummy and the URL
    // defaults to the harness's recording mock. The unreachable-LLM case is
    // flipped inside the child via /rctitle (probe extension); title.ts reads
    // these vars per call.
    OPENROUTER_API_KEY: OPENROUTER_DUMMY_KEY,
    PI_RC_OPENROUTER_URL: `http://127.0.0.1:${mockLlm.port}`,
  };
  if (!opts.noApns) {
    // The harness owns the child environment: point the extension at the fake
    // endpoint and make its TLS layer trust the self-signed cert (no CA config
    // option is invented in the extension; NODE_EXTRA_CA_CERTS is standard).
    childEnv.NODE_EXTRA_CA_CERTS = join(tmpRoot, "apns-cert.pem");
    childEnv.PI_RC_APNS_HOST = `127.0.0.1:${apns.port}`;
    childEnv.PI_RC_APNS_TEAM_ID = APNS_TEAM_ID;
    childEnv.PI_RC_APNS_KEY_ID = APNS_KEY_ID;
    childEnv.PI_RC_APNS_KEY_FILE = join(tmpRoot, "apns-key.p8");
  }

  // The signal probe is a test-only extension loaded into the child (see the
  // group-5b tests); it is copied with the test project into tmpRoot.
  const childArgs = [...PI_ARGS, "--extension", join(tmpRoot, "rc-signal-probe.ts")];
  const child = spawn(PI_COMMAND, childArgs, {
    cwd: tmpRoot,
    env: childEnv,
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
    apns,
    mockLlm,
    pushEnabled: !opts.noApns,
    pushLockoutSince: null, // set when group 11 completes; group 12 waits it out
    async toggleRcOn() {
      await client.sendCommand({ type: "prompt", message: "/rc" });
      return waitForAuthFile(authFile, AUTH_WAIT_TIMEOUT_MS);
    },
  };

  const results = [];
  // Single filter predicate shared by group selection and the per-test loop: a
  // test runs iff no filter is active, its group is selected, or its name
  // matches a --only substring (case-insensitive).
  const matches = (test) =>
    opts.only === null ||
    opts.only.groups.has(test.group) ||
    opts.only.names.some((name) => test.name.toLowerCase().includes(name));
  const byGroup = (g) => tests.filter((t) => t.group === g && matches(t));
  const groupOrder = [...new Set(tests.filter(matches).map((t) => t.group))].sort((a, b) => a - b);

  for (const group of groupOrder) {
    // Group 11's bad-code hellos lock out this host for 60 s (RATE_LIMIT_LOCK_MS),
    // so group 12's own connects would be rate_limited. This is a harness setup
    // step, deliberately OUTSIDE the per-test 60 s budget: poll a real-code
    // handshake until the lockout clears; the successful hello_ok is closed
    // immediately (it also proves the connect path group 12 relies on).
    if (group === 12) await waitForLockoutClear(ctx);
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
    if (group === 11) ctx.pushLockoutSince = Date.now(); // group 12 waits the lockout out
  }

  const passed = results.filter((r) => r.status === "pass").length;
  const failed = results.filter((r) => r.status === "fail").length;
  const skipped = results.filter((r) => r.status === "skip").length;
  // Filtered-out tests never run, so they affect neither results nor the exit code.
  const filtered = opts.only === null ? "" : `, ${tests.filter((t) => !matches(t)).length} filtered`;
  console.log(`${passed} passed, ${failed} failed, ${skipped} skipped${filtered}`);

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
