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
import { chmodSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { buildArgs, interpret, readHead, projects, resolveProject, cleanTitle } from "./server.mjs";

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

// --- Session listing -------------------------------------------------------
// The dashboard lists every Claude Code session on the machine, including ones
// started at the keyboard. Titles and project names come from the session file
// itself, so these check the parsing rather than the filesystem walk.

test("reads an explicit session title", () => {
  const dir = mkdtempSync(join(tmpdir(), "pc-sessions-"));
  const file = join(dir, "abc.jsonl");
  writeFileSync(file, [
    JSON.stringify({ type: "custom-title", customTitle: "CampHawk polling" }),
    JSON.stringify({ type: "user", cwd: "/home/tyler/campsite-finder", message: { content: "hi" } }),
  ].join("\n"));

  const head = readHead(file);
  assert.equal(head.title, "CampHawk polling");
  assert.equal(head.cwd, "/home/tyler/campsite-finder");
});

test("falls back to the first question when there is no title", () => {
  const dir = mkdtempSync(join(tmpdir(), "pc-sessions-"));
  const file = join(dir, "def.jsonl");
  writeFileSync(file, JSON.stringify({
    type: "user",
    cwd: "/home/tyler/repo",
    message: { content: [{ type: "text", text: "Why does the poller retry?\nSecond line" }] },
  }));

  assert.equal(readHead(file).title, "Why does the poller retry?");
});

test("survives a truncated final line", () => {
  // Only the head of each file is read, so the last line is usually partial.
  const dir = mkdtempSync(join(tmpdir(), "pc-sessions-"));
  const file = join(dir, "ghi.jsonl");
  writeFileSync(file, JSON.stringify({ type: "custom-title", customTitle: "Fine" }) + "\n{\"type\":\"user\",\"mess");

  assert.equal(readHead(file).title, "Fine");
});

test("an unreadable file is listed rather than crashing the endpoint", () => {
  const head = readHead(join(tmpdir(), "definitely-not-here-", String(Date.now()), "x.jsonl"));
  assert.equal(head.title, "Untitled session");
  assert.equal(head.cwd, null);
});

// --- Workspaces ------------------------------------------------------------
// A session can run somewhere other than the configured repository — including
// a scratch directory, for thinking out loud rather than asking about code.
// The set of places is an allowlist, not a path from the request.

test("the configured repo and a scratch workspace are always offered", () => {
  const names = projects().map((p) => p.name.toLowerCase());
  assert.ok(names.includes("chat"), "expected a scratch workspace");
  assert.equal(new Set(names).size, names.length, "names must be unique");
});

test("an unknown project is refused", () => {
  assert.equal(resolveProject("no-such-project"), null);
});

test("a path cannot be smuggled in as a project name", () => {
  // The request names a workspace; it never supplies a directory.
  for (const attempt of ["../../etc", "/etc", "C:\\Windows", "..\\..\\secrets"]) {
    assert.equal(resolveProject(attempt), null, `should refuse ${attempt}`);
  }
});

test("no project means the configured repository", () => {
  assert.equal(resolveProject(""), process.env.RELAY_REPO ?? process.cwd());
});

// --- Session titles --------------------------------------------------------
//
// A model asked for four words will sometimes answer in a sentence, in quotes,
// with a "Title:" prefix, or with a paragraph. Each of those looks like a bug
// in the list rather than in the prompt, so the cleaner is what stands between
// the model and the UI.

test("a plain title passes through", () => {
  assert.equal(cleanTitle("Fix the campsite alert emails"), "Fix the campsite alert emails");
});

test("surrounding quotes and trailing stops are removed", () => {
  assert.equal(cleanTitle('"Refactor the booking parser."'), "Refactor the booking parser");
  assert.equal(cleanTitle("'Add Stripe webhooks'"), "Add Stripe webhooks");
  assert.equal(cleanTitle("`Debug the cron job`"), "Debug the cron job");
});

test("a Title: prefix is removed", () => {
  assert.equal(cleanTitle("Title: Rework the search index"), "Rework the search index");
  assert.equal(cleanTitle("Session - Rework the search index"), "Rework the search index");
});

test("a preamble line is discarded in favour of the answer", () => {
  // Models that explain themselves put the answer last.
  assert.equal(
    cleanTitle("Sure, here is a title:\n\nCampsite availability polling"),
    "Campsite availability polling"
  );
});

test("whitespace is collapsed", () => {
  assert.equal(cleanTitle("  Fix   the   parser  "), "Fix the parser");
});

test("a paragraph is refused rather than shown", () => {
  // Better to fall back to the raw first question than to put an essay in a
  // one-line row.
  const essay =
    "This session appears to be about fixing the campsite finder application " +
    "and its notification pipeline in some detail";
  assert.equal(cleanTitle(essay), null);
});

test("empty and non-string input yield null", () => {
  for (const input of ["", "   ", "\n\n", null, undefined, 42, {}]) {
    assert.equal(cleanTitle(input), null, `should refuse ${JSON.stringify(input)}`);
  }
});

// --- The PowerShell scripts ------------------------------------------------
//
// CI has no PowerShell runner, so these scripts cannot be executed here. This
// checks the one property that broke them in practice and costs nothing to
// verify from Node.
//
// Windows PowerShell 5.1 reads a .ps1 file with no byte-order mark as
// Windows-1252, not UTF-8. An em dash is E2 80 94 in UTF-8, and cp1252 decodes
// that last byte as U+201D, a smart closing quote -- which PowerShell honours
// as a string delimiter. Inside a comment that is harmless. Inside a
// double-quoted string it terminates the string early, and every brace and
// quote after it is mismatched, so the file fails to parse with errors that
// point at lines nowhere near the real one.
//
// Keeping these files pure ASCII sidesteps the encoding question entirely.

test("the PowerShell scripts are pure ASCII", () => {
  const dir = fileURLToPath(new URL(".", import.meta.url));
  const scripts = readdirSync(dir).filter((name) => name.endsWith(".ps1"));
  assert.ok(scripts.length > 0, "expected at least one .ps1 file to check");

  for (const name of scripts) {
    const bytes = readFileSync(join(dir, name));
    const at = bytes.findIndex((byte) => byte > 0x7f);
    if (at !== -1) {
      // Report the line, since a byte offset is not something you can act on.
      const line = bytes.subarray(0, at).toString("utf8").split("\n").length;
      assert.fail(
        `${name} line ${line}: non-ASCII byte 0x${bytes[at].toString(16)}. ` +
          "Windows PowerShell reads these files as cp1252, where multi-byte " +
          "UTF-8 can decode into quote characters and break parsing."
      );
    }
  }
});

console.log(failures === 0 ? "\nall relay tests passed" : `\n${failures} failing`);
process.exit(failures === 0 ? 0 : 1);
