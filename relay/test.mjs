#!/usr/bin/env node
//
// Tests for the relay. Run with:  node relay/test.mjs
//
// Two layers: unit tests over the stream-json interpreter, and one end-to-end
// test that runs the real server against a fake `claude` binary and asserts on
// the SSE frames a phone would receive.
//
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { buildArgs, interpret } from "./server.mjs";

const SERVER = fileURLToPath(new URL("./server.mjs", import.meta.url));
let failures = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL  ${name}\n      ${error.message}`);
  }
}

async function asyncTest(name, fn) {
  try {
    await fn();
    console.log(`  ok  ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL  ${name}\n      ${error.message}`);
  }
}

console.log("interpret()");

test("extracts a text delta", () => {
  const out = interpret(JSON.stringify({
    type: "stream_event",
    event: { delta: { type: "text_delta", text: "Hello" } },
  }));
  assert.deepEqual(out, { kind: "chunk", text: "Hello" });
});

test("ignores non-text deltas", () => {
  const out = interpret(JSON.stringify({
    type: "stream_event",
    event: { delta: { type: "input_json_delta", partial_json: "{\"a\":" } },
  }));
  assert.equal(out, null);
});

test("skips subagent output", () => {
  // Reading a research subagent's chatter aloud would be noise, not an answer.
  const out = interpret(JSON.stringify({
    type: "stream_event",
    parent_tool_use_id: "toolu_123",
    event: { delta: { type: "text_delta", text: "subagent thinking" } },
  }));
  assert.equal(out, null);
});

test("captures the session id from init", () => {
  const out = interpret(JSON.stringify({
    type: "system",
    subtype: "init",
    session_id: "session_abc",
  }));
  assert.deepEqual(out, { kind: "session", sessionId: "session_abc" });
});

test("surfaces tool names for the status line", () => {
  const out = interpret(JSON.stringify({
    type: "assistant",
    message: {
      content: [
        { type: "text", text: "Let me look" },
        { type: "tool_use", name: "Read", input: {} },
        { type: "tool_use", name: "Grep", input: {} },
      ],
    },
  }));
  assert.deepEqual(out, { kind: "tool", names: ["Read", "Grep"] });
});

test("assistant message with no tools yields nothing", () => {
  const out = interpret(JSON.stringify({
    type: "assistant",
    message: { content: [{ type: "text", text: "done" }] },
  }));
  assert.equal(out, null);
});

test("reports an api_retry as a status update", () => {
  const out = interpret(JSON.stringify({
    type: "system", subtype: "api_retry", error: "overloaded",
  }));
  assert.deepEqual(out, { kind: "status", text: "Retrying (overloaded)" });
});

test("result carries session id, cost and final text", () => {
  const out = interpret(JSON.stringify({
    type: "result",
    session_id: "session_xyz",
    total_cost_usd: 0.0123,
    is_error: false,
    result: "The hold lifecycle starts in holds.ts.",
  }));
  assert.deepEqual(out, {
    kind: "done",
    sessionId: "session_xyz",
    costUSD: 0.0123,
    isError: false,
    result: "The hold lifecycle starts in holds.ts.",
  });
});

test("tolerates a non-JSON line", () => {
  assert.equal(interpret("Warning: something on stdout"), null);
});

console.log("buildArgs()");

test("omits --resume when starting a new session", () => {
  const args = buildArgs({ text: "hi", sessionId: null });
  assert.ok(!args.includes("--resume"));
  assert.deepEqual(args.slice(0, 2), ["-p", "hi"]);
});

test("passes --resume to continue a session", () => {
  const args = buildArgs({ text: "and the tests?", sessionId: "session_abc" });
  const at = args.indexOf("--resume");
  assert.ok(at > -1, "--resume missing");
  assert.equal(args[at + 1], "session_abc");
});

test("always requests a streaming json transcript", () => {
  const args = buildArgs({ text: "hi", sessionId: null });
  for (const flag of ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]) {
    assert.ok(args.includes(flag), `missing ${flag}`);
  }
});

test("sets a non-interactive permission mode", () => {
  // Without this the CLI would block on an approval prompt no one can answer,
  // and the request would hang until the relay's timeout.
  const args = buildArgs({ text: "hi", sessionId: null });
  const at = args.indexOf("--permission-mode");
  assert.ok(at > -1, "--permission-mode missing");
  assert.equal(args[at + 1], "dontAsk");
});

console.log("end to end (fake claude)");

/** A stand-in for the CLI that replays a canned stream-json transcript. */
function writeFakeClaude(dir, { lines, exitCode = 0, stderr = "" }) {
  const path = join(dir, "fake-claude");
  const body = lines.map((line) => JSON.stringify(line)).join("\n");
  writeFileSync(
    path,
    `#!/usr/bin/env node
const out = ${JSON.stringify(body)};
// Emit in two writes so the server's line buffering is exercised on a split.
const half = Math.floor(out.length / 2);
process.stdout.write(out.slice(0, half));
process.stdout.write(out.slice(half) + "\\n");
${stderr ? `process.stderr.write(${JSON.stringify(stderr)});` : ""}
process.exit(${exitCode});
`,
    "utf8",
  );
  chmodSync(path, 0o755);
  return path;
}

function startServer(env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [SERVER], {
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    const onData = (data) => {
      out += data;
      if (out.includes("PocketClaude relay on")) resolve(child);
    };
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", onData);
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (d) => { out += d; });
    child.on("exit", (code) => reject(new Error(`server exited ${code}: ${out}`)));
    setTimeout(() => reject(new Error(`server did not start: ${out}`)), 5000);
  });
}

/** Collect SSE frames from a response body into [{event, data}]. */
async function readSSE(response) {
  const text = await response.text();
  return text
    .split("\n\n")
    .filter((block) => block.trim())
    .map((block) => {
      const event = /^event: (.*)$/m.exec(block)?.[1] ?? "";
      const data = /^data: (.*)$/m.exec(block)?.[1] ?? "{}";
      return { event, data: JSON.parse(data) };
    });
}

const dir = mkdtempSync(join(tmpdir(), "pocketclaude-relay-"));
const PORT = 8791;
const TOKEN = "test-token-that-is-long-enough";
const base = `http://127.0.0.1:${PORT}`;

const happyPath = writeFakeClaude(dir, {
  lines: [
    { type: "system", subtype: "init", session_id: "session_e2e" },
    { type: "stream_event", event: { delta: { type: "text_delta", text: "The hold " } } },
    { type: "assistant", message: { content: [{ type: "tool_use", name: "Read", input: {} }] } },
    { type: "stream_event", parent_tool_use_id: "toolu_x",
      event: { delta: { type: "text_delta", text: "SUBAGENT NOISE" } } },
    { type: "stream_event", event: { delta: { type: "text_delta", text: "lifecycle is in holds.ts." } } },
    { type: "result", session_id: "session_e2e", total_cost_usd: 0.02, is_error: false,
      result: "The hold lifecycle is in holds.ts." },
  ],
});

let server;
try {
  server = await startServer({
    RELAY_PORT: String(PORT),
    RELAY_HOST: "127.0.0.1",
    RELAY_TOKEN: TOKEN,
    RELAY_REPO: dir,
    RELAY_CLAUDE_BIN: happyPath,
  });

  await asyncTest("health check needs no auth", async () => {
    const response = await fetch(`${base}/health`);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).ok, true);
  });

  await asyncTest("rejects a missing token", async () => {
    const response = await fetch(`${base}/ask`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text: "hi" }),
    });
    assert.equal(response.status, 401);
  });

  await asyncTest("rejects a wrong token", async () => {
    const response = await fetch(`${base}/ask`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer nope" },
      body: JSON.stringify({ text: "hi" }),
    });
    assert.equal(response.status, 401);
  });

  await asyncTest("streams chunks, tools and a done frame", async () => {
    const response = await fetch(`${base}/ask`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ text: "what does the hold lifecycle do?" }),
    });
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") ?? "", /text\/event-stream/);

    const frames = await readSSE(response);
    const kinds = frames.map((f) => f.event);
    assert.deepEqual(kinds, ["session", "chunk", "tool", "chunk", "done"]);

    const spoken = frames.filter((f) => f.event === "chunk").map((f) => f.data.text).join("");
    assert.equal(spoken, "The hold lifecycle is in holds.ts.");
    assert.ok(!spoken.includes("SUBAGENT"), "subagent text leaked into speech");

    const done = frames.at(-1).data;
    assert.equal(done.sessionId, "session_e2e");
    assert.equal(done.costUSD, 0.02);
    assert.equal(done.isError, false);
  });

  await asyncTest("rejects an empty question", async () => {
    const response = await fetch(`${base}/ask`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ text: "   " }),
    });
    assert.equal(response.status, 400);
  });
} finally {
  server?.kill();
}

// A separate server instance for the failure path, so the fake binary differs.
const crashing = writeFakeClaude(dir, {
  lines: [{ type: "system", subtype: "init", session_id: "session_bad" }],
  exitCode: 1,
  stderr: "Error: not logged in. Run `claude auth login`.",
});

let failServer;
try {
  failServer = await startServer({
    RELAY_PORT: String(PORT + 1),
    RELAY_HOST: "127.0.0.1",
    RELAY_TOKEN: TOKEN,
    RELAY_REPO: dir,
    RELAY_CLAUDE_BIN: crashing,
  });

  await asyncTest("surfaces a CLI failure as an error frame", async () => {
    const response = await fetch(`http://127.0.0.1:${PORT + 1}/ask`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ text: "hi" }),
    });
    const frames = await readSSE(response);
    const last = frames.at(-1);
    assert.equal(last.event, "error");
    assert.match(last.data.message, /not logged in/);
  });
} finally {
  failServer?.kill();
}

console.log(failures === 0 ? "\nall relay tests passed" : `\n${failures} failing`);
process.exit(failures === 0 ? 0 : 1);
