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
import { execFileSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { existsSync, readdirSync, realpathSync, openSync, readSync, closeSync, statSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { mkdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.RELAY_PORT ?? 8787);
const HOST = process.env.RELAY_HOST ?? "0.0.0.0";
const TOKEN = process.env.RELAY_TOKEN ?? "";
const REPO = process.env.RELAY_REPO ?? process.cwd();
const CLAUDE_BIN = process.env.RELAY_CLAUDE_BIN ?? "claude";
// Naming sessions costs a small model call each, once per session, cached
// forever. Set to "0" to keep the raw first question as the title instead.
const AUTO_TITLE = (process.env.RELAY_AUTO_TITLE ?? "1") !== "0";
// How many unnamed sessions to name per /sessions request. Bounded because
// each one spawns a process: naming sixty at once on the first refresh would
// be indistinguishable from a fork bomb.
const TITLES_PER_REFRESH = Number(process.env.RELAY_TITLES_PER_REFRESH ?? 5);
// Set by run.ps1. The relay cannot restart itself: exiting is only a restart if
// something is watching for the exit. Without this flag it exits into nothing
// after an update and simply looks dead, which is exactly what happened.
const SUPERVISED = process.env.RELAY_SUPERVISED === "1";
const MODEL = process.env.RELAY_MODEL ?? "";
const TIMEOUT_MS = Number(process.env.RELAY_TIMEOUT_MS ?? 300_000);

// `dontAsk` denies anything outside Claude Code's read-only command set unless
// you have explicit allow rules. That is the right default here: there is no
// human at a keyboard to approve a prompt, so a permissive mode would let the
// agent change files unattended, and a prompting mode would simply hang until
// the timeout. Widen it deliberately with RELAY_ALLOWED_TOOLS.
const PERMISSION_MODE = process.env.RELAY_PERMISSION_MODE ?? "dontAsk";
const ALLOWED_TOOLS = process.env.RELAY_ALLOWED_TOOLS ?? "";

// Extra places a session can run, as "name=path" pairs separated by commas:
//     RELAY_PROJECTS="camphawk=C:\\code\\campsite-finder,notes=C:\\code\\notes"
const EXTRA_PROJECTS = process.env.RELAY_PROJECTS ?? "";
// A directory with no code in it, for thinking out loud rather than asking
// about a repository. `claude -p` runs anywhere; it only reads code if there
// is code to read, so an empty directory is all a general conversation needs.
// The relay's own checkout — one level up from this file — so `git pull`
// updates the relay rather than whatever repository it happens to be answering
// questions about.
const RELAY_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCRATCH = process.env.RELAY_SCRATCH ?? join(homedir(), "pocketclaude-chat");

/// True only when this file is the program being run, so `import` from the test
/// suite gets the functions without starting a listener or exiting on config.
/**
 * Where a session may run. An allowlist rather than a path from the request:
 * the token is the only thing between the internet and this process, and
 * "spawn a CLI in any directory you name" is not a thing to hand out on the
 * strength of one bearer token.
 */
function projects() {
  const list = [
    { name: basename(REPO) || "repo", path: REPO, kind: "code" },
    { name: "Chat", path: SCRATCH, kind: "scratch" },
  ];
  for (const pair of EXTRA_PROJECTS.split(",")) {
    const [name, path] = pair.split("=").map((part) => part?.trim());
    if (name && path) list.push({ name, path, kind: "code" });
  }
  // First definition of a name wins, so RELAY_REPO can't be shadowed.
  const seen = new Set();
  return list.filter((entry) => {
    const key = entry.name.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** The directory for a requested project name, or null if it isn't allowed. */
function resolveProject(name) {
  if (!name) return REPO;
  const match = projects().find((p) => p.name.toLowerCase() === String(name).toLowerCase());
  if (!match) return null;
  // Created on demand: asking for the scratch workspace shouldn't require
  // having made a folder first.
  if (match.kind === "scratch" && !existsSync(match.path)) {
    try {
      mkdirSync(match.path, { recursive: true });
    } catch {
      return null;
    }
  }
  return existsSync(match.path) ? match.path : null;
}

/**
 * The directory a known local session was recorded in.
 *
 * Resuming needs this because the dashboard lists every session on the machine,
 * including ones in repositories that are not in the allowlist - and refusing
 * to open something you just listed is not a policy, it is a bug. Asking for a
 * session in Claude-Speak failed with "unknown project: Claude-Speak" for
 * exactly that reason.
 *
 * This is not a hole in the allowlist. The path is not supplied by the phone;
 * it comes from the session's own recorded cwd, found by matching an id against
 * sessions already on disk. An id that matches nothing resolves to nothing.
 */
function resolveSessionCwd(sessionId) {
  if (!sessionId) return null;
  const match = listSessions({ limit: 500 }).find((s) => s.id === sessionId);
  if (!match?.projectPath) return null;
  return existsSync(match.projectPath) ? match.projectPath : null;
}

/** Short commit of the relay checkout, or null outside a git working tree. */
function version() {
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], {
      cwd: RELAY_ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

/**
 * `git pull` in the relay's own checkout, then exit so the supervisor starts
 * the new code.
 *
 * Exit code 42 is the signal: relay/run.ps1 restarts on 42 and stops on
 * anything else, so a crash still stops rather than looping forever. Pulling
 * without restarting would leave the old code running and the new code on
 * disk, which is the confusing half-state this exists to avoid.
 */
function selfUpdate() {
  const before = version();
  const output = execFileSync("git", ["pull", "--ff-only"], {
    cwd: RELAY_ROOT,
    encoding: "utf8",
  }).trim();
  const after = version();
  return { output, before, after, changed: before !== after };
}

/** This machine's Tailscale address, so the printed link works from anywhere. */
function tailscaleAddress() {
  for (const candidate of [
    "tailscale",
    "C:\\Program Files\\Tailscale\\tailscale.exe",
    "/usr/bin/tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  ]) {
    try {
      const out = execFileSync(candidate, ["ip", "-4"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      const ip = out.trim().split("\n")[0]?.trim();
      if (ip) return ip;
    } catch {
      // Not installed at this path, or not connected — try the next one.
    }
  }
  return null;
}

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

// What the phone is allowed to ask for. Allowlists rather than pass-through:
// both values become command-line arguments, and "opus --dangerously-skip-
// permissions" must not be reachable by typing it into a picker.
const ALLOWED_MODELS = new Set([
  "opus", "sonnet", "haiku", "fable",
  "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
]);
const ALLOWED_EFFORTS = new Set(["low", "medium", "high", "xhigh", "max"]);

/** The requested value if it is one we permit, otherwise null. */
function allowedOrNull(value, permitted) {
  if (typeof value !== "string") return null;
  const cleaned = value.trim().toLowerCase();
  return permitted.has(cleaned) ? cleaned : null;
}

function buildArgs({ text, sessionId, model, effort }) {
  const args = ["-p", text];
  // --resume keeps the conversation going across questions. Claude Code finds
  // the session by ID in any project on the machine.
  if (sessionId) args.push("--resume", sessionId);
  args.push("--output-format", "stream-json", "--verbose", "--include-partial-messages");
  args.push("--permission-mode", PERMISSION_MODE);
  if (ALLOWED_TOOLS) args.push("--allowedTools", ALLOWED_TOOLS);

  // The phone's choice wins over the server default, because the phone is
  // where the chip that claims to control it lives. Until now that chip said
  // "Opus 5 High" while the relay ran whatever RELAY_MODEL happened to be -
  // usually sonnet, since setup.ps1 sets it. A control that does nothing is
  // worse than no control.
  const requestedModel = allowedOrNull(model, ALLOWED_MODELS);
  const requestedEffort = allowedOrNull(effort, ALLOWED_EFFORTS);
  if (requestedModel ?? MODEL) args.push("--model", requestedModel ?? MODEL);
  if (requestedEffort) args.push("--effort", requestedEffort);
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
  const project = typeof payload.project === "string" ? payload.project.trim() : "";
  const sessionId = typeof payload.sessionId === "string" && payload.sessionId
    ? payload.sessionId
    : null;
  const model = typeof payload.model === "string" ? payload.model : "";
  const effort = typeof payload.effort === "string" ? payload.effort : "";

  if (!text) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "text is required" }));
    return;
  }

  // Resuming runs where the session already lives. An explicit project still
  // wins, so moving a session somewhere is possible, but the ordinary case -
  // tap a session in the list, ask it something - no longer depends on that
  // session's repository being one the allowlist happens to name.
  const resumedIn = sessionId && !project ? resolveSessionCwd(sessionId) : null;

  // Rejected before the stream opens, so a bad project name is an ordinary
  // HTTP error rather than an error frame the phone has to unpick.
  const workingDirectory = resumedIn ?? resolveProject(project);
  if (!workingDirectory) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: `unknown project: ${project}` }));
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

  const child = spawn(CLAUDE_BIN, buildArgs({ text, sessionId, model, effort }), {
    cwd: workingDirectory,
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


/**
 * Every Claude Code session on this machine, newest first.
 *
 * Claude Code writes one JSONL file per session under
 * `~/.claude/projects/<cwd-with-slashes-as-dashes>/<session-id>.jsonl`. That is
 * the same store the CLI resumes from, so anything listed here can be picked up
 * with `--resume` — including sessions started at the keyboard rather than from
 * the phone. That is the whole point: walking away from the desk shouldn't mean
 * leaving the conversation behind.
 *
 * Only the head of each file is read. They reach tens of megabytes, and
 * everything needed for a list — the title and the project — is at the top.
 */
function listSessions({ limit = 60 } = {}) {
  const root = join(homedir(), ".claude", "projects");
  if (!existsSync(root)) return [];

  const cached = loadTitles();
  // Older local copies of a cloud session that has since been re-teleported.
  // Without this every refresh leaves another row behind, all titled the same.
  const superseded = supersededLocalIds();
  const archived = loadArchived();
  const found = [];
  for (const projectDir of readdirSync(root, { withFileTypes: true })) {
    if (!projectDir.isDirectory()) continue;
    const dir = join(root, projectDir.name);
    for (const entry of readdirSync(dir)) {
      if (!entry.endsWith(".jsonl")) continue;
      const path = join(dir, entry);
      let stat;
      try {
        stat = statSync(path);
      } catch {
        continue;
      }
      const head = readHead(path);
      const cwd = head.cwd ?? "";
      // Sessions the titler created before it learned not to. They are real
      // files with real ids, so they cannot be un-created from here, but they
      // are noise in every list and nobody wants to resume one.
      if (head.firstMessage && head.firstMessage.startsWith(TITLE_PROMPT_PREFIX)) continue;
      if (superseded.has(entry.replace(/\.jsonl$/, ""))) continue;
      if (archived.has(entry.replace(/\.jsonl$/, ""))) continue;
      found.push({
        id: entry.replace(/\.jsonl$/, ""),
        // From the `cwd` the session itself records. Deriving it from the
        // directory name instead is lossy: separators are encoded as dashes,
        // so "Claude-Speak" and "Claude/Speak" become the same string, and a
        // repository with a dash in its name reads back wrong.
        project: cwd ? cwd.split(/[\\/]/).filter(Boolean).pop() : projectDir.name,
        projectPath: cwd || projectDir.name,
        updatedAt: stat.mtime.toISOString(),
        bytes: stat.size,
        // Order matters: a title you set by hand outranks a generated one,
        // which outranks the raw first question.
        title: head.hasExplicitTitle
          ? head.title
          : cached[entry.replace(/\.jsonl$/, "")] ?? head.title,
        hasExplicitTitle: head.hasExplicitTitle,
        firstMessage: head.firstMessage,
      });
    }
  }

  found.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
  return found.slice(0, limit);
}

/** Title and working directory, from one bounded read of the file's head. */
function readHead(path, maxBytes = 64 * 1024) {
  let fd;
  try {
    fd = openSync(path, "r");
    const buffer = Buffer.alloc(maxBytes);
    const read = readSync(fd, buffer, 0, maxBytes, 0);
    const head = buffer.subarray(0, read).toString("utf8");

    let title = null;
    let cwd = null;
    let firstMessage = null;
    let hasExplicitTitle = false;
    for (const line of head.split("\n")) {
      if (!line.trim()) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue; // The last line of a bounded read is usually a partial one.
      }
      if (!cwd && typeof event.cwd === "string") cwd = event.cwd;
      // An explicit title wins over a guess from the first question.
      if (event.type === "custom-title" && event.customTitle) {
        title = event.customTitle;
        hasExplicitTitle = true;
      } else if (!title) {
        const content =
          typeof event.content === "string"
            ? event.content
            : typeof event.message?.content === "string"
              ? event.message.content
              : Array.isArray(event.message?.content)
                ? event.message.content.find((b) => b?.type === "text")?.text
                : null;
        if (content) {
          title = firstLine(content);
          // Kept untruncated for the namer: five words summarising eighty
          // characters of a question is a worse title than five words
          // summarising the question.
          firstMessage = content.slice(0, 500);
        }
      }
      if (title && cwd) break;
    }
    return { title: title ?? "Untitled session", cwd, firstMessage, hasExplicitTitle };
  } catch {
    return { title: "Untitled session", cwd: null, firstMessage: null, hasExplicitTitle: false };
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

/** The last few useful lines of a failed CLI run. */
function teleportError(error) {
  return (error.stderr || error.stdout || error.message || "")
    .split("\n")
    .filter(Boolean)
    .slice(-4)
    .join(" ")
    .trim();
}

/** JSON response in one line, since the cloud endpoints send several. */
function respond(res, status, payload) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload));
}

/** Reads and parses a JSON request body. */
async function readJSON(req) {
  const raw = await readBody(req);
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`bad request: ${error.message}`);
  }
}

// --- Cloud sessions --------------------------------------------------------
//
// The sessions in the Claude app's Code tab run on Anthropic's infrastructure,
// not this machine, so they are not in ~/.claude/projects and nothing here can
// read them. There is no public API to list them either.
//
// There are two supported ways to reach one, both through the CLI:
//
//   claude -p "<text>" --cloud <id>   queues a message into the cloud session
//                                     and exits. It does not wait for a reply.
//   claude --teleport <id>            pulls the session's branch and full
//                                     conversation history onto this machine,
//                                     where it becomes an ordinary local
//                                     session that /sessions already lists and
//                                     /ask can already resume.
//
// Teleport is the one that gives a phone the whole loop, because after it runs
// there is nothing special about the session any more.

// Remote Control.
//
// The closest thing to "two machines on one session". `claude -p`, which is how
// every question here is answered, is one-shot: it runs, streams, and exits, so
// there is nothing for another device to watch. `claude remote-control` is a
// server that keeps sessions alive and serves them to claude.ai/code and the
// Claude app, which is what makes a session watchable step by step from
// somewhere else while this relay drives it.
//
// This is deliberately not `claude --cloud <id>` attach. That does attach a
// terminal to a running cloud session, but it is gated on a gradual rollout and
// the docs state plainly that --output-format stream-json is not supported with
// it - so the relay could attach and then have no way to stream anything to a
// phone. A feature that cannot report what it is doing is not one this app can
// use.

let remoteControl = null; // { child, url, startedAt }

/** The claude.ai session URL, once the server prints one. */
function extractSessionURL(text) {
  const match = String(text).match(/https:\/\/claude\.ai\/code\/[A-Za-z0-9_-]+/);
  return match ? match[0] : null;
}

function startRemoteControl(cwd) {
  if (remoteControl?.child && remoteControl.child.exitCode === null) {
    return remoteControl;
  }

  const child = spawn(CLAUDE_BIN, ["remote-control"], {
    cwd,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });

  remoteControl = { child, url: null, startedAt: new Date().toISOString(), error: null };

  // The URL is printed, not returned, so it has to be read out of the output.
  const read = (chunk) => {
    const text = chunk.toString();
    const url = extractSessionURL(text);
    if (url && remoteControl) remoteControl.url = url;
  };
  child.stdout.on("data", read);
  child.stderr.on("data", (chunk) => {
    read(chunk);
    // Eligibility failures land here, and they are the common case: Remote
    // Control is a research preview behind a feature flag. Keeping the text
    // means the phone can show the real reason instead of "it didn't work".
    if (remoteControl) {
      remoteControl.error = (remoteControl.error ?? "") + chunk.toString();
    }
  });
  child.on("exit", (code) => {
    if (remoteControl?.child === child) remoteControl.exited = code;
  });

  return remoteControl;
}

function remoteControlStatus() {
  if (!remoteControl) return { running: false };
  const running = remoteControl.child && remoteControl.child.exitCode === null;
  return {
    running: Boolean(running),
    url: remoteControl.url,
    startedAt: remoteControl.startedAt,
    exited: remoteControl.exited ?? null,
    // Last few lines only: the whole stderr of a failed launch is a wall.
    error: (remoteControl.error ?? "").split("\n").filter(Boolean).slice(-4).join(" ").trim() || null,
  };
}

function stopRemoteControl() {
  if (remoteControl?.child && remoteControl.child.exitCode === null) {
    remoteControl.child.kill();
  }
  remoteControl = null;
  return { running: false };
}

// Remembered cloud sessions.
//
// There is no way to list cloud sessions - `claude agents --json` covers local
// background sessions only, and the teleport picker is interactive - so the
// relay remembers the ones you have pulled before and can re-pull those. That
// is the difference between "one click to update" and "paste every link again".
//
// Each teleport makes a *new* local copy rather than updating the old one, so
// the previous copies are recorded and filtered out of the session list. Left
// alone they would pile up: one extra row per refresh, all with the same title.

const CLOUD_PATH = join(homedir(), ".pocketclaude", "cloud.json");

function loadCloud() {
  try {
    const parsed = JSON.parse(readFileSync(CLOUD_PATH, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveCloud(state) {
  try {
    mkdirSync(dirname(CLOUD_PATH), { recursive: true });
    writeFileSync(CLOUD_PATH, JSON.stringify(state, null, 2));
  } catch {
    // Losing this costs a re-paste, not correctness.
  }
}

/** Every local session id superseded by a later teleport of the same session. */
function supersededLocalIds() {
  const ids = new Set();
  for (const entry of Object.values(loadCloud())) {
    for (const id of entry.previousIds ?? []) ids.add(id);
  }
  return ids;
}

/**
 * Teleports one cloud session and records where it landed.
 *
 * The landing spot is found by diffing the local session list either side of
 * the run, because the CLI does not report the local id it created. A diff is
 * imprecise if something else writes a session at the same moment; the cost of
 * being wrong is one stale row left visible, so it is not worth more than this.
 */
function teleportAndRecord(sessionId, cwd) {
  const before = new Set(listSessions({ limit: 500 }).map((s) => s.id));

  execFileSync(CLAUDE_BIN, teleportArgs(sessionId), {
    cwd,
    encoding: "utf8",
    timeout: 180_000,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const after = listSessions({ limit: 500 });
  const fresh = after.find((s) => !before.has(s.id));

  const state = loadCloud();
  const existing = state[sessionId] ?? { previousIds: [] };
  const previousIds = existing.previousIds ?? [];
  // The copy this refresh replaces becomes a previous one.
  if (existing.localId && existing.localId !== fresh?.id) {
    previousIds.push(existing.localId);
  }
  state[sessionId] = {
    localId: fresh?.id ?? existing.localId ?? null,
    project: fresh?.project ?? existing.project ?? null,
    title: fresh?.title ?? existing.title ?? null,
    cwd,
    previousIds,
    updatedAt: new Date().toISOString(),
  };
  saveCloud(state);
  return state[sessionId];
}

/**
 * Extracts a cloud session id from a bare id or a claude.ai/code URL.
 *
 * This value arrives from the phone and becomes a command-line argument, so it
 * is validated rather than trusted: without the character check, an "id" of
 * "--dangerously-skip-permissions" would be passed straight to the CLI as a
 * flag. Returns null for anything that is not plainly an id.
 */
function parseCloudSessionId(input) {
  if (typeof input !== "string") return null;
  let text = input.trim();
  if (!text) return null;

  // Accept the URL people actually copy out of the address bar.
  const match = text.match(/claude\.ai\/code\/([^/?#\s]+)/i);
  if (match) text = match[1];

  // Ids look like session_01... or cse_.... Anything with a slash, a space, or
  // a leading dash is not one.
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(text)) return null;
  if (text.startsWith("-")) return null;
  return text;
}

/** Arguments for queueing a message into a cloud session. */
function cloudSendArgs(sessionId, text) {
  return ["-p", text, "--cloud", sessionId, "--output-format", "json"];
}

/** Arguments for pulling a cloud session onto this machine. */
function teleportArgs(sessionId) {
  return ["--teleport", sessionId];
}

// --- Session titles --------------------------------------------------------
//
// A session's title is otherwise its first question verbatim, which is how a
// list ends up showing six rows of "What does this proje...". Claude Code only
// writes a `custom-title` event when you set one by hand, so nothing names
// these on its own.
//
// Titles are generated once by a small model and cached on disk forever. The
// cache is keyed by session id, so a session that grows never gets renamed and
// never costs a second call.

const TITLES_PATH = join(homedir(), ".pocketclaude", "titles.json");

// Live sessions.
//
// `claude agents --json` lists the sessions currently running on this machine,
// which includes everything the Remote Control server is serving to claude.ai
// and the Claude app. Marking those rows lets the phone say "this one is live
// on claude.ai right now" - the difference between resuming a transcript and
// walking into a running conversation.

/**
 * Session ids from `claude agents --json` output.
 *
 * The schema is not documented, so this reads defensively: any string field
 * named like a session id, on any entry, in an array found at the top level or
 * one level down. Over-matching costs a wrong "live" dot; throwing costs the
 * whole session list.
 */
function parseLiveIds(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return new Set();
  }
  const entries = Array.isArray(parsed)
    ? parsed
    : Object.values(parsed ?? {}).find(Array.isArray) ?? [];
  const ids = new Set();
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    for (const key of ["sessionId", "session_id", "id"]) {
      if (typeof entry[key] === "string" && entry[key]) {
        ids.add(entry[key]);
        break;
      }
    }
  }
  return ids;
}

function liveSessionIds() {
  try {
    const out = execFileSync(CLAUDE_BIN, ["agents", "--json"], {
      encoding: "utf8",
      timeout: 10_000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return parseLiveIds(out);
  } catch {
    // Older CLI, or none running. Either way: nothing is live.
    return new Set();
  }
}

// Archived sessions.
//
// Claude Code has no archive of its own - a session is a transcript file that
// exists or does not - so archiving is this relay hiding ids from the listing.
// The transcript stays on disk and `claude --resume <id>` still works from a
// keyboard; the session has only left the phone's list. Deleting, by contrast,
// removes the transcript file itself and is not undoable.

const ARCHIVE_PATH = join(homedir(), ".pocketclaude", "archived.json");

function loadArchived() {
  try {
    const parsed = JSON.parse(readFileSync(ARCHIVE_PATH, "utf8"));
    return Array.isArray(parsed) ? new Set(parsed) : new Set();
  } catch {
    return new Set();
  }
}

function saveArchived(ids) {
  try {
    mkdirSync(dirname(ARCHIVE_PATH), { recursive: true });
    writeFileSync(ARCHIVE_PATH, JSON.stringify([...ids], null, 2));
  } catch {
    // Losing this un-hides sessions; it never loses data.
  }
}

/**
 * The transcript file for a session id, or null.
 *
 * Resolved by matching the id against files already on disk, never by building
 * a path from the request - the id is phone-supplied, and "delete the file I
 * name" is not something to hand a bearer token.
 */
function sessionFilePath(sessionId) {
  if (typeof sessionId !== "string" || !sessionId) return null;
  // The id has to be a plain filename: ".." or a slash would escape the
  // projects directory even though the path is assembled here, not received.
  if (/[\\/]|\.\./.test(sessionId)) return null;
  const root = join(homedir(), ".claude", "projects");
  if (!existsSync(root)) return null;
  for (const projectDir of readdirSync(root, { withFileTypes: true })) {
    if (!projectDir.isDirectory()) continue;
    const candidate = join(root, projectDir.name, `${sessionId}.jsonl`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

// Shared by the prompt and by the filter that hides sessions the titler created
// before it stopped creating them. Keeping one constant means the two cannot
// drift apart and start missing each other.
const TITLE_PROMPT_PREFIX =
  "Give a title of at most five words for a coding session that began with " +
  "the message below. Reply with the title alone: no quotes, no punctuation " +
  "at the end, no explanation.\n\n";

function loadTitles() {
  try {
    const parsed = JSON.parse(readFileSync(TITLES_PATH, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    // Missing, unreadable, or corrupt all mean the same thing here: no titles
    // yet. A cache that throws would take the whole session list down with it.
    return {};
  }
}

function saveTitles(titles) {
  try {
    mkdirSync(dirname(TITLES_PATH), { recursive: true });
    writeFileSync(TITLES_PATH, JSON.stringify(titles, null, 2));
  } catch {
    // Losing the cache costs a regenerated title, not correctness.
  }
}

/**
 * Trims a model's answer down to something that fits in a list row.
 *
 * Separate from the spawn so it can be tested: a model asked for four words
 * will sometimes return a sentence, quotes, a trailing full stop, or a polite
 * preamble, and all of those look like bugs in the UI rather than in the
 * prompt.
 */
function cleanTitle(raw) {
  if (typeof raw !== "string") return null;
  let text = raw.trim();
  if (!text) return null;

  // Models like to answer in prose. Take the last non-empty line, which is
  // where the actual answer lands when one does.
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return null;
  text = lines[lines.length - 1];

  text = text.replace(/^["'`]+|["'`]+$/g, "");
  text = text.replace(/^(title|session)\s*[:\-]\s*/i, "");
  text = text.replace(/[.]+$/, "");
  text = text.replace(/\s+/g, " ").trim();

  if (!text) return null;
  // A "title" that is really a paragraph means the model ignored the prompt;
  // the raw first question is a better fallback than a wall of text.
  if (text.length > 60) return null;
  return text;
}

/** Asks a small model for a few words. Returns null on any failure. */
function nameSession(text) {
  const prompt = TITLE_PROMPT_PREFIX + text.slice(0, 500);

  try {
    // --no-session-persistence, or naming a session creates a session. Every
    // title written one more row into the dashboard, whose first message was
    // the titling prompt itself - visible in the app as "Continuing 'Give a
    // title of at most five words...'". The titler was polluting the list it
    // exists to tidy.
    const args = ["-p", prompt, "--model", "haiku", "--no-session-persistence"];
    const out = execFileSync(CLAUDE_BIN, args, {
      encoding: "utf8",
      timeout: 30_000,
      // Inherit nothing on stdin: without this the CLI can wait on a tty that
      // is not there and hang until the timeout.
      stdio: ["ignore", "pipe", "ignore"],
    });
    return cleanTitle(out);
  } catch {
    return null;
  }
}

/**
 * Names up to TITLES_PER_REFRESH sessions that do not have a title yet.
 *
 * Called after the response has been sent, so a slow model never delays the
 * list. Newest first, because those are the ones being looked at; over a few
 * refreshes the backlog drains.
 */
function fillMissingTitles(sessions) {
  if (!AUTO_TITLE) return;
  const titles = loadTitles();
  const pending = sessions
    .filter((s) => !titles[s.id] && !s.hasExplicitTitle && s.firstMessage)
    .slice(0, TITLES_PER_REFRESH);
  if (!pending.length) return;

  let changed = false;
  for (const session of pending) {
    const title = nameSession(session.firstMessage);
    if (title) {
      titles[session.id] = title;
      changed = true;
    }
  }
  if (changed) saveTitles(titles);
}

function firstLine(text) {
  const line = text.split("\n").map((l) => l.trim()).find(Boolean) ?? "";
  return line.length > 80 ? line.slice(0, 80) + "…" : line || "Untitled session";
}

const server = createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, repo: REPO, version: version(), supervised: SUPERVISED }));
    return;
  }

  if (!authorized(req)) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  if (req.method === "POST" && req.url === "/update") {
    let result;
    try {
      result = selfUpdate();
    } catch (error) {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: error.message.split("\n").slice(-3).join(" ") }));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ...result, supervised: SUPERVISED }));

    if (result.changed && SUPERVISED) {
      // After the response is flushed, so the phone hears the outcome before
      // the process goes away.
      res.on("finish", () => setTimeout(() => process.exit(42), 250));
    } else if (result.changed) {
      // Unsupervised: keep running the old code rather than exiting into
      // nothing. Still the old code, and said out loud in both places, because
      // a relay that vanishes mid-conversation is worse than one that is
      // honestly out of date.
      console.log(
        `\nUpdated ${result.before} -> ${result.after}, but this relay was not started by run.ps1,\n` +
        `so it cannot restart itself. It is still running the old code.\n` +
        `Stop it and run:  .\\relay\\run.ps1\n`
      );
    }
    return;
  }

  if (req.method === "POST" && req.url === "/cloud/send") {
    readJSON(req)
      .then((body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        const text = typeof body.text === "string" ? body.text.trim() : "";
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        if (!text) return respond(res, 400, { error: "Nothing to send." });

        let output;
        try {
          output = execFileSync(CLAUDE_BIN, cloudSendArgs(sessionId, text), {
            encoding: "utf8",
            timeout: 60_000,
            stdio: ["ignore", "pipe", "pipe"],
          });
        } catch (error) {
          return respond(res, 502, {
            error: (error.stderr || error.message || "").split("\n").slice(-3).join(" ").trim(),
          });
        }
        const parsed = (() => {
          try {
            return JSON.parse(output);
          } catch {
            return null;
          }
        })();
        // Queue-and-exit: the CLI confirms delivery, not an answer. Saying so
        // here keeps the phone from waiting for a reply that never comes.
        respond(res, 200, {
          queued: parsed?.ok !== false,
          sessionId: parsed?.session_id ?? sessionId,
          url: parsed?.url ?? null,
          error: parsed?.error ?? null,
        });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/teleport") {
    readJSON(req)
      .then((body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });

        const cwd = resolveProject(typeof body.project === "string" ? body.project : "");
        if (!cwd) return respond(res, 400, { error: "Unknown workspace." });

        try {
          // No stdin anywhere below: teleport prompts to stash uncommitted
          // changes, and a prompt nobody can answer would hang until the
          // timeout. Closing stdin makes it fail fast, and the message says why.
          const record = teleportAndRecord(sessionId, cwd);
          respond(res, 200, { ok: true, sessionId, ...record });
        } catch (error) {
          respond(res, 502, { error: teleportError(error) });
        }
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/sessions/archive") {
    readJSON(req)
      .then((body) => {
        // Archiving does not require the file to exist: hiding a row that has
        // already been cleaned up by Claude Code's 30-day retention is fine.
        const id = typeof body.id === "string" ? body.id.trim() : "";
        if (!id || /[\\/]|\.\./.test(id)) {
          return respond(res, 400, { error: "That doesn't look like a session id." });
        }
        const ids = loadArchived();
        ids.add(id);
        saveArchived(ids);
        respond(res, 200, { ok: true, archived: id });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/sessions/delete") {
    readJSON(req)
      .then((body) => {
        const id = typeof body.id === "string" ? body.id.trim() : "";
        const path = sessionFilePath(id);
        if (!path) {
          return respond(res, 404, { error: "No session with that id on this machine." });
        }
        try {
          unlinkSync(path);
        } catch (error) {
          return respond(res, 500, { error: `Couldn't delete it: ${error.message}` });
        }
        // Tidy the caches so the id doesn't linger as a hidden entry.
        const ids = loadArchived();
        if (ids.delete(id)) saveArchived(ids);
        const titles = loadTitles();
        if (titles[id]) {
          delete titles[id];
          saveTitles(titles);
        }
        respond(res, 200, { ok: true, deleted: id });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "GET" && req.url === "/remote-control") {
    respond(res, 200, remoteControlStatus());
    return;
  }

  if (req.method === "POST" && req.url === "/remote-control") {
    readJSON(req)
      .then((body) => {
        const cwd = resolveProject(typeof body.project === "string" ? body.project : "");
        if (!cwd) return respond(res, 400, { error: "Unknown workspace." });
        startRemoteControl(cwd);
        // The URL arrives on stdout a moment after launch, so the first status
        // often has none. Reported as-is rather than waited for: a request that
        // blocks on a subprocess printing something is a request that hangs
        // when it does not.
        setTimeout(() => {}, 0);
        respond(res, 200, remoteControlStatus());
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/remote-control/stop") {
    respond(res, 200, stopRemoteControl());
    return;
  }

  if (req.method === "GET" && req.url === "/cloud") {
    const state = loadCloud();
    respond(res, 200, {
      sessions: Object.entries(state).map(([cloudId, entry]) => ({
        cloudId,
        localId: entry.localId ?? null,
        title: entry.title ?? null,
        project: entry.project ?? null,
        updatedAt: entry.updatedAt ?? null,
      })),
    });
    return;
  }

  if (req.method === "POST" && req.url === "/cloud/refresh") {
    readJSON(req)
      .then((body) => {
        const state = loadCloud();
        // One named session, or every remembered one. Refreshing all is the
        // "one click" case and is why this is a list rather than a flag.
        const only = body.sessionId ? parseCloudSessionId(body.sessionId) : null;
        if (body.sessionId && !only) {
          return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        }
        const targets = only ? [only] : Object.keys(state);
        if (!targets.length) {
          return respond(res, 200, { results: [], note: "No cloud sessions have been brought here yet." });
        }

        // Reported per session, never as one pass/fail: a repository with
        // uncommitted changes fails teleport, and one such repository should
        // not hide the others that refreshed cleanly.
        const results = targets.map((cloudId) => {
          const cwd = state[cloudId]?.cwd ?? REPO;
          try {
            const record = teleportAndRecord(cloudId, cwd);
            return { cloudId, ok: true, localId: record.localId, title: record.title };
          } catch (error) {
            return { cloudId, ok: false, error: teleportError(error) };
          }
        });
        respond(res, 200, { results });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "GET" && req.url === "/projects") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      projects: projects().map((p) => ({ ...p, available: existsSync(p.path) || p.kind === "scratch" })),
    }));
    return;
  }

  if (req.method === "GET" && req.url === "/sessions") {
    try {
      const sessions = listSessions();
      const live = liveSessionIds();
      for (const session of sessions) session.live = live.has(session.id);
      res.writeHead(200, { "content-type": "application/json" });
      // firstMessage is only here to feed the namer; sending a phone 60 copies
      // of a 500-character question to render 60 one-line rows is waste.
      res.end(
        JSON.stringify({
          sessions: sessions.map(({ firstMessage, hasExplicitTitle, ...rest }) => rest),
        })
      );
      // After the response, never before: naming spawns a process per session
      // and the list should never wait on it. New titles appear on the next
      // pull-to-refresh.
      setImmediate(() => fillMissingTitles(sessions));
    } catch (error) {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: error.message }));
    }
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
    console.log(`  version:     ${version() ?? "(not a git checkout)"}`);
    // Said at startup rather than discovered when an update fails. There is no
    // way to tell from the outside how the relay was launched, and the answer
    // decides whether the app's update button can restart it.
    console.log(
      `  updates:     ${
        SUPERVISED
          ? "will restart (started by run.ps1)"
          : "will NOT restart - start with .\\relay\\run.ps1 for that"
      }`
    );

    // Pairing link. Typing a 64-character token into a phone is the worst part
    // of setting this up, and it is what makes a short guessable token
    // tempting. Send this line to yourself and tap it.
    const address = tailscaleAddress() ?? HOST;
    console.log("");
    console.log("  Pair the phone by sending yourself this line and tapping it:");
    console.log(`    pocketclaude://pair?url=${encodeURIComponent(`http://${address}:${PORT}`)}&token=${encodeURIComponent(TOKEN)}`);
    console.log("");
  });
}

// Exported for the test script; importing this file starts nothing.
export {
  interpret,
  buildArgs,
  readHead,
  listSessions,
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
};
