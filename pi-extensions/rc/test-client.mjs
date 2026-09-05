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
const CODE_PATTERN = /^[0-9a-f]{6}$/;

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

// TODO(group 1): Connection
//   - connect with valid code -> hello_ok + state + history
//   - connect with invalid code -> error {code:"bad_code"} + close
//   - 5 rapid bad codes from same IP -> error {code:"rate_limited"} + close
//   - wait 60s -> can connect again
//   - connect with wrong version -> error {code:"version_mismatch"} + close

// TODO(group 2): State & history
//   - get_state -> valid state shape (cwd, model, isStreaming)
//   - history non-empty after at least one exchange
//   - history pagination cursor when > 200 entries

// TODO(group 3): Prompt & steer
//   - prompt when idle -> agent starts processing (event stream)
//   - prompt when streaming -> error {code:"not_idle"}
//   - steer when streaming -> accepted, steer delivered via events

// TODO(group 4): Abort
//   - long prompt + abort -> turn ends (turn_end event)

// TODO(group 5): Questions
//   - ASK via test-project AGENTS.md -> question message received
//   - answer -> question_resolved received
//   - disconnect without answering -> reconnect -> question re-delivered
//   - two clients -> first answer wins -> second gets question_resolved

// TODO(group 6): Heartbeat
//   - ping -> pong
//   - no traffic > 90s -> server closes connection

// TODO(group 7): Multi-client
//   - two clients -> both receive events
//   - prompt from client A -> both see events

// TODO(group 8): Server lifecycle
//   - /rc -> server starts, status shown
//   - /rc again -> server stops, clients disconnected
//   - port busy: second pi + /rc -> error message about port 47800

// TODO(group 9): Session rebind
//   - /new -> clients get session_start + fresh state + history
//   - pre-rebind events tagged with old sessionId

// TODO(group 10): Streaming buffer
//   - connect mid-stream -> streaming_buffer with content
//   - buffer content matches streamed content so far

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
  const groupOrder = [0, ...Array.from({ length: 10 }, (_, i) => i + 1).filter((g) => opts.only === null || opts.only.includes(g))];

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
