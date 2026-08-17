#!/usr/bin/env node
//
// PocketClaude relay — turns one `claude -p` run into an SSE stream the phone
// can speak as it arrives.
//
// Runs on any always-on machine that has the Claude Code CLI logged in to your
// Claude account (`claude auth login`). Because the CLI uses your subscription
// login, nothing here touches the Anthropic API billing — see relay/README.md.
//
// Node 18+, zero dependencies. Start it with:
//     RELAY_TOKEN=... RELAY_REPO=~/code/camphawk node relay/server.mjs
//
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.RELAY_PORT ?? 8787);
const HOST = process.env.RELAY_HOST ?? "0.0.0.0";
const TOKEN = process.env.RELAY_TOKEN ?? "";
const REPO = process.env.RELAY_REPO ?? process.cwd();
const CLAUDE_BIN = process.env.RELAY_CLAUDE_BIN ?? "claude";
const MODEL = process.env.RELAY_MODEL ?? "";
const TIMEOUT_MS = Number(process.env.RELAY_TIMEOUT_MS ?? 300_000);

// `dontAsk` denies anything outside Claude Code's read-only command set unless
// you have explicit allow rules. That is the right default here: there is no
// human at a keyboard to approve a prompt, so a permissive mode would let the
// agent change files unattended, and a prompting mode would simply hang until
// the timeout. Widen it deliberately with RELAY_ALLOWED_TOOLS.
const PERMISSION_MODE = process.env.RELAY_PERMISSION_MODE ?? "dontAsk";
const ALLOWED_TOOLS = process.env.RELAY_ALLOWED_TOOLS ?? "";

/// True only when this file is the program being run, so `import` from the test
/// suite gets the functions without starting a listener or exiting on config.
function isEntryPoint() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

/** Constant-time bearer check, so the token can't be guessed a byte at a time. */
function authorized(req) {
  const header = req.headers.authorization ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  const a = Buffer.from(presented);
  const b = Buffer.from(TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

function readBody(req, limitBytes = 256 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const parts = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(new Error("request body too large"));
        req.destroy();
        return;
      }
      parts.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(parts).toString("utf8")));
    req.on("error", reject);
  });
}

/** One SSE frame. The phone matches on `event:` and JSON-decodes `data:`. */
function sse(res, event, payload) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
}

function buildArgs({ text, sessionId }) {
  const args = ["-p", text];
  // --resume keeps the conversation going across questions. Claude Code finds
  // the session by ID in any project on the machine.
  if (sessionId) args.push("--resume", sessionId);
  args.push("--output-format", "stream-json", "--verbose", "--include-partial-messages");
  args.push("--permission-mode", PERMISSION_MODE);
  if (ALLOWED_TOOLS) args.push("--allowedTools", ALLOWED_TOOLS);
  if (MODEL) args.push("--model", MODEL);
  return args;
}

/**
 * Pull the pieces the phone cares about out of one stream-json line.
 *
 * Returns null for the many event types a voice client has no use for. Text
 * from subagents is skipped: those carry a non-null `parent_tool_use_id`, and
 * reading a research subagent's chatter aloud is noise, not an answer.
 */
function interpret(line) {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return null; // A partial line, or CLI chatter that isn't JSON.
  }

  if (event.parent_tool_use_id) return null;

  if (event.type === "stream_event") {
    const delta = event.event?.delta;
    if (delta?.type === "text_delta" && delta.text) {
      return { kind: "chunk", text: delta.text };
    }
    return null;
  }

  if (event.type === "system" && event.subtype === "init") {
    return { kind: "session", sessionId: event.session_id ?? null };
  }

  if (event.type === "system" && event.subtype === "api_retry") {
    return { kind: "status", text: `Retrying (${event.error ?? "error"})` };
  }

  if (event.type === "assistant") {
    // Surface tool names so the phone's status line can show progress. The
    // text itself already arrived as deltas, so it is not repeated here.
    const blocks = event.message?.content ?? [];
    const names = blocks.filter((b) => b?.type === "tool_use").map((b) => b.name);
    if (names.length > 0) return { kind: "tool", names };
    return null;
  }

  if (event.type === "result") {
    return {
      kind: "done",
      sessionId: event.session_id ?? null,
      // Present even on a subscription run; it is a client-side estimate of
      // what the same work would have cost on the API, not a charge.
      costUSD: event.total_cost_usd ?? null,
      isError: event.is_error === true,
      // The complete answer, used to reconcile against the streamed chunks.
      result: typeof event.result === "string" ? event.result : null,
    };
  }

  return null;
}

async function handleAsk(req, res) {
  let payload;
  try {
    payload = JSON.parse(await readBody(req));
  } catch (error) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: `bad request: ${error.message}` }));
    return;
  }

  const text = typeof payload.text === "string" ? payload.text.trim() : "";
  const sessionId = typeof payload.sessionId === "string" && payload.sessionId
    ? payload.sessionId
    : null;

  if (!text) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "text is required" }));
    return;
  }

  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
    // The phone reads this stream token by token; buffering it defeats the
    // whole point of speaking as the answer arrives.
    "x-accel-buffering": "no",
  });

  const child = spawn(CLAUDE_BIN, buildArgs({ text, sessionId }), {
    cwd: REPO,
    // Inherit the environment so the CLI finds your logged-in credentials.
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const startedAt = Date.now();
  let settled = false;
  let stderr = "";
  let buffer = "";

  const finish = (event, payload) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    sse(res, event, payload);
    res.end();
  };

  const timer = setTimeout(() => {
    child.kill("SIGTERM");
    finish("error", { message: `Timed out after ${Math.round(TIMEOUT_MS / 1000)}s` });
  }, TIMEOUT_MS);

  // If the phone hangs up (app backgrounded, network dropped), don't leave a
  // claude process running against the repo.
  res.on("close", () => {
    if (!settled) {
      settled = true;
      clearTimeout(timer);
      child.kill("SIGTERM");
    }
  });

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (data) => {
    buffer += data;
    // stream-json is newline-delimited; the last piece may be incomplete.
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      const message = interpret(line);
      if (!message) continue;
      if (message.kind === "done") {
        finish("done", message);
      } else {
        sse(res, message.kind, message);
      }
    }
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (data) => {
    stderr += data;
    if (stderr.length > 8192) stderr = stderr.slice(-8192);
  });

  child.on("error", (error) => {
    finish("error", {
      message: error.code === "ENOENT"
        ? `Could not run "${CLAUDE_BIN}" — is the Claude Code CLI installed and on PATH?`
        : error.message,
    });
  });

  child.on("close", (code) => {
    const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
    console.log(`ask: ${seconds}s exit=${code} session=${sessionId ?? "new"}`);
    // A clean exit normally emits a `result` event, which already finished the
    // stream. Reaching here unsettled means the run died without one.
    finish("error", {
      message: stderr.trim().split("\n").slice(-3).join(" ")
        || `claude exited with code ${code}`,
    });
  });
}

const server = createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, repo: REPO }));
    return;
  }

  if (!authorized(req)) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  if (req.method === "POST" && req.url === "/ask") {
    handleAsk(req, res).catch((error) => {
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: error.message }));
      } else {
        res.end();
      }
    });
    return;
  }

  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
});

if (isEntryPoint()) {
  if (!TOKEN) {
    console.error("RELAY_TOKEN is required. Generate one with:  openssl rand -hex 32");
    process.exit(1);
  }
  if (TOKEN.length < 16) {
    console.error("RELAY_TOKEN is too short — use at least 16 characters.");
    process.exit(1);
  }
  if (!existsSync(REPO)) {
    console.error(`RELAY_REPO does not exist: ${REPO}`);
    process.exit(1);
  }

  server.listen(PORT, HOST, () => {
    console.log(`PocketClaude relay on http://${HOST}:${PORT}`);
    console.log(`  repo:        ${REPO}`);
    console.log(`  permissions: ${PERMISSION_MODE}${ALLOWED_TOOLS ? ` + ${ALLOWED_TOOLS}` : ""}`);
    console.log(`  model:       ${MODEL || "(Claude Code default)"}`);
  });
}

// Exported for the test script; importing this file starts nothing.
export { interpret, buildArgs };
