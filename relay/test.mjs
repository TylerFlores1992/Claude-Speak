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

import {
  buildArgs,
  interpret,
  readHead,
  projects,
  resolveProject,
  cleanTitle,
  resolveSessionCwd,
  sessionFilePath,
  parseLiveIds,
  extractSessionURL,
  parseCloudSessionId,
  cloudSendArgs,
  teleportArgs,
} from "./server.mjs";

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
// The narrow token the Stop hook carries. Separate from TOKEN on purpose: it
// can deliver an answer and nothing else.
const ANSWER_TOKEN = "answer-token-that-is-long-enough";
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
    RELAY_ANSWER_TOKEN: ANSWER_TOKEN,
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

  // --- The cloud round trip ------------------------------------------------
  //
  // The half of the loop that did not exist. `claude -p --cloud` queues a
  // message into a real claude.ai session and exits without an answer; a Stop
  // hook running inside that session posts the answer back here. These tests
  // stand in for the cloud with the fake CLI and a direct POST, which is
  // exactly what the hook does over the wire.

  await asyncTest("an answer needs the answer token, not just any request", async () => {
    const response = await fetch(`${base}/cloud/answer`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ sessionId: "session_01ABC", text: "hi" }),
    });
    assert.equal(response.status, 401);
  });

  await asyncTest("the main token does not open the answer route", async () => {
    // This is the only route published to the public internet through Funnel,
    // so the credentials that open it are kept to the smallest set. RELAY_TOKEN
    // can run Claude Code on this machine; a leak of it should not also let a
    // stranger put words in someone's ear.
    const response = await fetch(`${base}/cloud/answer`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ sessionId: "session_01ABC", text: "hi" }),
    });
    assert.equal(response.status, 401);
  });

  await asyncTest("the narrow answer token is accepted", async () => {
    const response = await fetch(`${base}/cloud/answer`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${ANSWER_TOKEN}` },
      body: JSON.stringify({ sessionId: "session_01BUFFERED", text: "held for later" }),
    });
    assert.equal(response.status, 200);
    // Nobody was waiting, so it was buffered rather than handed over.
    assert.equal((await response.json()).claimed, false);
  });

  await asyncTest("a question is answered by the hook that fires after it", async () => {
    // The whole loop: ask, the cloud session finishes a turn, its Stop hook
    // posts the answer, the waiting request returns it.
    const asking = fetch(`${base}/cloud/ask`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ sessionId: "session_01LOOP", text: "what time is it", timeoutMs: 5000 }),
    });

    // The hook reports the session as cse_, the phone asked as session_. The
    // relay has to match them or an answer never finds its question.
    let delivered = false;
    for (let attempt = 0; attempt < 50 && !delivered; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 20));
      const response = await fetch(`${base}/cloud/answer`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${ANSWER_TOKEN}` },
        body: JSON.stringify({ sessionId: "cse_01LOOP", text: "It is 4:15 PM." }),
      });
      delivered = (await response.json()).claimed;
    }
    assert.ok(delivered, "the hook's answer was never claimed by the waiting request");

    const result = await (await asking).json();
    assert.equal(result.answer, "It is 4:15 PM.");
    assert.equal(result.sessionId, "session_01LOOP");
  });

  await asyncTest("a turn that never answers says so rather than hanging", async () => {
    const response = await fetch(`${base}/cloud/ask`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ sessionId: "session_01SILENT", text: "hello", timeoutMs: 300 }),
    });
    const result = await response.json();
    assert.equal(result.answer, null);
    assert.match(result.error, /Stop hook/);
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

// --- Model and effort ------------------------------------------------------
//
// Both arrive from the phone and become command-line arguments, so they are
// allowlisted rather than passed through.

test("the phone's model and effort win over the server default", () => {
  const args = buildArgs({ text: "hi", model: "claude-opus-5", effort: "high" });
  assert.ok(args.includes("--model"));
  assert.equal(args[args.indexOf("--model") + 1], "claude-opus-5");
  assert.equal(args[args.indexOf("--effort") + 1], "high");
});

test("a model or effort that is not on the list is ignored", () => {
  for (const attempt of [
    "opus --dangerously-skip-permissions",
    "--permission-mode",
    "; rm -rf /",
    "gpt-4",
    "",
  ]) {
    const args = buildArgs({ text: "hi", model: attempt, effort: attempt });
    const model = args.indexOf("--model");
    assert.ok(model === -1 || args[model + 1] !== attempt, `leaked model ${attempt}`);
    assert.equal(args.indexOf("--effort"), -1, `leaked effort ${attempt}`);
  }
});

test("aliases and full model names are both accepted", () => {
  for (const name of ["opus", "sonnet", "haiku", "claude-sonnet-5"]) {
    const args = buildArgs({ text: "hi", model: name });
    assert.equal(args[args.indexOf("--model") + 1], name, `rejected ${name}`);
  }
});

test("effort is only sent when asked for", () => {
  assert.equal(buildArgs({ text: "hi" }).indexOf("--effort"), -1);
});

// --- Resuming across repositories -------------------------------------------

test("an unknown session id resolves to no directory", () => {
  // The phone never supplies a path. An id that matches nothing on disk has to
  // resolve to nothing rather than to a default, or resuming a session that
  // does not exist would quietly run somewhere else.
  assert.equal(resolveSessionCwd("no-such-session-id"), null);
  assert.equal(resolveSessionCwd(""), null);
  assert.equal(resolveSessionCwd(null), null);
  assert.equal(resolveSessionCwd(undefined), null);
});

// --- Cloud sessions --------------------------------------------------------
//
// The session id arrives from the phone and is handed to the CLI as an
// argument, so the parser is a security boundary, not a convenience. Anything
// that is not plainly an id has to be refused before it can be read as a flag.

test("accepts a bare cloud session id", () => {
  assert.equal(
    parseCloudSessionId("session_01DiUkqY2kzbUbDmW1w96rfi"),
    "session_01DiUkqY2kzbUbDmW1w96rfi"
  );
  assert.equal(parseCloudSessionId("cse_01abcdef2345"), "cse_01abcdef2345");
  assert.equal(parseCloudSessionId("  session_01abcdef2345  "), "session_01abcdef2345");
});

test("pulls the id out of a claude.ai/code URL", () => {
  for (const url of [
    "https://claude.ai/code/session_01DiUkqY2kzbUbDmW1w96rfi",
    "https://claude.ai/code/session_01DiUkqY2kzbUbDmW1w96rfi?from=cli&m=0",
    "claude.ai/code/session_01DiUkqY2kzbUbDmW1w96rfi",
  ]) {
    assert.equal(parseCloudSessionId(url), "session_01DiUkqY2kzbUbDmW1w96rfi", `failed on ${url}`);
  }
});

test("refuses anything that could be read as a flag", () => {
  // The whole point: these would otherwise reach the CLI as arguments.
  for (const attempt of [
    "--dangerously-skip-permissions",
    "-p",
    "--cloud",
    "session_01 --resume other",
    "; rm -rf /",
    "../../etc/passwd",
    "session/01",
  ]) {
    assert.equal(parseCloudSessionId(attempt), null, `should refuse ${attempt}`);
  }
});

test("refuses empty, short, and non-string input", () => {
  for (const attempt of ["", "   ", "abc", null, undefined, 42, {}, []]) {
    assert.equal(parseCloudSessionId(attempt), null, `should refuse ${JSON.stringify(attempt)}`);
  }
});

test("builds the documented cloud and teleport commands", () => {
  // Order matters: the message is the value of -p, and --output-format json is
  // what makes the result parseable rather than prose.
  assert.deepEqual(
    cloudSendArgs("session_01abcdef2345", "run the tests"),
    ["-p", "run the tests", "--cloud", "session_01abcdef2345", "--output-format", "json"]
  );
  assert.deepEqual(teleportArgs("session_01abcdef2345"), ["--teleport", "session_01abcdef2345"]);
});

test("a message that looks like a flag is still a message", () => {
  // It sits after -p as its value, so it is never parsed as an option.
  const args = cloudSendArgs("session_01abcdef2345", "--help");
  assert.equal(args[0], "-p");
  assert.equal(args[1], "--help");
});

// --- Deleting sessions -----------------------------------------------------
//
// The id is phone-supplied and ends up naming a file to unlink, so the
// resolver is a security boundary: it matches ids against files that already
// exist under ~/.claude/projects and refuses anything shaped like a path.

test("a traversal attempt never resolves to a file", () => {
  for (const attempt of [
    "../../etc/passwd",
    "..\\..\\secrets",
    "a/b",
    "a\\b",
    "..",
    "",
    null,
    undefined,
  ]) {
    assert.equal(sessionFilePath(attempt), null, `resolved ${JSON.stringify(attempt)}`);
  }
});

test("an unknown id resolves to nothing rather than a guess", () => {
  assert.equal(sessionFilePath("00000000-0000-0000-0000-000000000000"), null);
});

// --- Live sessions ---------------------------------------------------------
//
// `claude agents --json` has no documented schema, so the parser reads
// defensively. Over-matching costs a wrong "live" dot; throwing would cost the
// whole session list.

test("live ids are found across plausible schemas", () => {
  assert.deepEqual([...parseLiveIds('[{"sessionId":"a"},{"id":"b"}]')], ["a", "b"]);
  assert.deepEqual([...parseLiveIds('{"agents":[{"session_id":"c"}]}')], ["c"]);
});

test("garbage output means nothing is live, not a crash", () => {
  for (const raw of ["", "not json", "42", "null", "{}", '[{"name":"x"}]']) {
    assert.equal(parseLiveIds(raw).size, 0, `failed on ${JSON.stringify(raw)}`);
  }
});

// --- Remote Control --------------------------------------------------------
//
// The server prints its session URL rather than returning it, so the relay has
// to read it out of the output. Worth testing because the surrounding text
// changes between versions and a wrong match would hand the phone a link to
// nothing.

test("finds the session URL in the server's output", () => {
  assert.equal(
    extractSessionURL("Remote Control active: https://claude.ai/code/session_01AbCd"),
    "https://claude.ai/code/session_01AbCd"
  );
  // Query strings are printed in some forms and are not part of the link.
  assert.equal(
    extractSessionURL("View: https://claude.ai/code/cse_01AbCd?from=cli&m=0"),
    "https://claude.ai/code/cse_01AbCd"
  );
});

test("returns null when there is no URL yet", () => {
  // Startup prints several lines before the URL; a false match here would show
  // a dead link on the phone.
  for (const line of ["", "Starting Remote Control...", "Signed in as tyler", "https://claude.ai/"]) {
    assert.equal(extractSessionURL(line), null, `matched ${JSON.stringify(line)}`);
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
