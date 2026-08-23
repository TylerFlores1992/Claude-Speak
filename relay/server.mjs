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
// A second, narrower token, used only by the Stop hook running inside a cloud
// session to hand an answer back. Kept separate from RELAY_TOKEN on purpose:
// that one can run Claude Code on this machine, and it would have to be pasted
// into a cloud environment variable, which the docs say is readable by anyone
// using that environment and is not a secrets store. This one can do exactly
// one thing - deliver an answer - so leaking it costs far less.
const ANSWER_TOKEN = process.env.RELAY_ANSWER_TOKEN ?? "";
// Accept answers from every session in the repository, not only the ones this
// relay asked. Off by default: a Stop hook fires on every turn, so leaving it
// on sends work done at a keyboard out of the VM as well.
const ANSWER_ALL = process.env.RELAY_ANSWER_ALL === "1";
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
  "claude-fable-5", "claude-opus-5", "claude-opus-4-8",
  "claude-sonnet-5", "claude-haiku-4-5",
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
  const names = loadNames();
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
        // Order matters: a name set from the phone outranks a title set with
        // /rename in the session, which outranks a generated one, which
        // outranks the raw first question.
        title: names[entry.replace(/\.jsonl$/, "")]
          ?? (head.hasExplicitTitle
            ? head.title
            : cached[entry.replace(/\.jsonl$/, "")] ?? head.title),
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

// Answers coming back from cloud sessions.
//
// This is the half of the loop that did not exist. Sending into a real
// claude.ai session is easy - `claude -p "..." --cloud <id>` queues a message
// and exits - but it exits without an answer, so nothing could be spoken into
// an ear. A Stop hook committed to the repository runs inside the cloud session
// when Claude finishes a turn, receives the final text as `last_assistant_message`,
// and POSTs it here.
//
// The result is a loop that runs entirely in Anthropic's cloud, in the same
// session visible in the Claude app, with this machine acting only as courier.

/**
 * One id shape for both ends.
 *
 * A cloud session is `session_01ABC` in a claude.ai URL and in the JSON that
 * `--cloud` prints, but the session reads its own id from
 * CLAUDE_CODE_REMOTE_SESSION_ID as `cse_01ABC`. Same session, two spellings;
 * matching them literally would mean an answer never finds its question.
 */
function normalizeCloudId(id) {
  if (typeof id !== "string") return "";
  const trimmed = id.trim();
  if (!trimmed) return "";
  return trimmed.startsWith("cse_") ? `session_${trimmed.slice(4)}` : trimmed;
}

// Answers that arrived before anyone asked for them, and callers waiting for
// one. A turn can finish before the asking request gets around to waiting, and
// a hook can fire for a turn nobody here started.
const answerInbox = new Map(); // id -> { text, at }
const answerWaiters = new Map(); // id -> [resolve]
const ANSWER_TTL_MS = 30 * 60 * 1000;

// Cloud sessions this relay has asked something. A Stop hook fires at the end
// of *every* turn in the repository it is committed to, so without this the
// answer to work done at a keyboard, by a teammate, or by an unrelated cloud
// session all leave the VM and arrive here. Nobody asked for that, and it is a
// surprising amount of text to be moving on the strength of a feature nobody
// switched on.
//
// The relay records the sessions it asked, and the hook checks before sending.
// Sessions age out: the marker exists to cover one question and its answer.
const askedSessions = new Map(); // id -> asked at
const ASKED_TTL_MS = 60 * 60 * 1000;

function markAsked(id) {
  const key = normalizeCloudId(id);
  if (!key) return;
  const cutoff = Date.now() - ASKED_TTL_MS;
  for (const [existing, at] of askedSessions) {
    if (at < cutoff) askedSessions.delete(existing);
  }
  askedSessions.set(key, Date.now());
}

function wasAsked(id) {
  const key = normalizeCloudId(id);
  if (!key) return false;
  const at = askedSessions.get(key);
  if (at === undefined) return false;
  if (Date.now() - at > ASKED_TTL_MS) {
    askedSessions.delete(key);
    return false;
  }
  return true;
}

// Sessions that have been asked for their history.
//
// The relay cannot read a cloud session's past: there is no API for it, and
// --teleport only resumes a teleport session, not an arbitrary cloud one. But
// the Stop hook runs *inside* that session's VM, and the payload it receives
// carries `transcript_path` -- the conversation, on disk, next to the hook.
//
// So asking for history means leaving a note for the hook to find. The next
// time that session finishes a turn, it reads its own transcript and posts it
// back. A pull therefore sends no message and forces no turn of its own; it
// rides along with the session's next reply, which is almost always the very
// next thing to happen, because the next thing you do is talk to it.
const historyWanted = new Set();

function requestHistory(id) {
  const key = normalizeCloudId(id);
  if (!key) return false;
  historyWanted.add(key);
  // A pull is also a reason to want this session's answers: the hook checks
  // that before it sends anything at all, so without this the note would sit
  // unread behind the very gate it is waiting on.
  markAsked(key);
  return true;
}

function wantsHistory(id) {
  const key = normalizeCloudId(id);
  return key ? historyWanted.has(key) : false;
}

function clearHistoryWant(id) {
  const key = normalizeCloudId(id);
  if (key) historyWanted.delete(key);
}

/**
 * The public URL the hook should post to, read out of Tailscale Funnel.
 *
 * The two values a cloud environment needs are both knowable here -- the token
 * is this relay's own, and the URL is whatever the funnel publishes -- so the
 * phone can hand them over ready to paste instead of asking someone to
 * reconstruct a hostname from memory.
 *
 * Parsed rather than assumed: the funnel is mounted on a path, and which path
 * is a choice the person setting it up made. Guessing "/answer" would be right
 * for the documented setup and wrong for anyone who chose otherwise, and wrong
 * silently -- the hook would post into a 404 and the session would look like it
 * had no hook at all.
 */
function parseFunnelURL(output, port) {
  const text = String(output ?? "");
  // The base appears on its own line; take the first https://...ts.net.
  const base = text.match(/https:\/\/[A-Za-z0-9._-]+\.ts\.net/)?.[0];
  if (!base) return null;

  // Then the mount that forwards to this relay's answer route. Tailscale
  // prints these as "/path proxy http://127.0.0.1:PORT/cloud/answer".
  const mount = new RegExp(
    `(/[^\\s]*)\\s+proxy\\s+https?://[^\\s]*:${port}/cloud/answer`
  ).exec(text);
  if (!mount) return null;

  const path = mount[1] === "/" ? "" : mount[1];
  return `${base}${path}`;
}

function funnelURL() {
  try {
    const output = execFileSync("tailscale", ["funnel", "status"], {
      encoding: "utf8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return parseFunnelURL(output, PORT);
  } catch {
    // Tailscale missing, not running, or no funnel up. All the same answer.
    return null;
  }
}

// Sessions whose hook has reported in.
//
// The hook probes before it sends anything, so a session that has never probed
// has never run the hook. That is the difference between "the turn is still
// going" and "nothing is installed to answer you", and without it a missing
// hook fails the same way a slow turn does: silence until a timeout.
//
// Persisted, because it is used to make a claim. In memory alone, a relay
// restart would forget every session it had ever heard from and start telling
// people their hook was missing when it was not.
function probesPath() {
  return join(stateDir(), "probes.json");
}

function loadProbes() {
  try {
    const parsed = JSON.parse(readFileSync(probesPath(), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

/** Records that this session's hook exists and can reach us. */
function rememberProbe(id) {
  const key = normalizeCloudId(id);
  if (!key) return;
  const probes = loadProbes();
  probes[key] = new Date().toISOString();
  try {
    mkdirSync(dirname(probesPath()), { recursive: true });
    writeFileSync(probesPath(), JSON.stringify(probes, null, 2));
  } catch {
    // Losing this costs a worse error message, never an answer.
  }
}

function hasProbed(id) {
  const key = normalizeCloudId(id);
  return key ? Boolean(loadProbes()[key]) : false;
}

/**
 * Why a session did not answer, when it did not.
 *
 * A session that has never probed has never run the hook -- or has run it with
 * a token this relay rejects, which never reaches the code that records a
 * probe. Both are setup, and saying so beats another timeout with no reason
 * attached. A session that *has* probed before is simply still working.
 */
function silenceReason(id) {
  if (hasProbed(id)) {
    return "The message was delivered but no answer came back in time. The turn is probably still running -- ask again and the answer will be waiting.";
  }
  return (
    "The message was delivered, but this session has never reported back to the relay. " +
    "Either its repository has no Stop hook on the branch it is running, or RELAY_ANSWER_TOKEN " +
    "does not match this relay's. See relay/hooks/README.md."
  );
}

/**
 * Throws away an answer nobody collected.
 *
 * The inbox exists so an answer that arrives with no listener is not lost. But
 * a *new* question makes an old uncollected answer worse than nothing: the
 * next wait drains the inbox first, so the previous turn's answer comes back
 * instantly, apparently answering something it has never seen.
 */
function discardBufferedAnswer(id) {
  const key = normalizeCloudId(id);
  if (!key) return false;
  return answerInbox.delete(key);
}

/** Hands an answer to whoever is waiting, or holds it for whoever asks next. */
function deliverAnswer(id, text) {
  const key = normalizeCloudId(id);
  if (!key || typeof text !== "string" || !text.trim()) return false;

  const waiting = answerWaiters.get(key);
  if (waiting?.length) {
    answerWaiters.delete(key);
    for (const resolve of waiting) resolve(text);
    return true;
  }

  // Prune on write rather than on a timer, so an idle relay holds nothing and
  // there is no interval to leak.
  const cutoff = Date.now() - ANSWER_TTL_MS;
  for (const [existing, entry] of answerInbox) {
    if (entry.at < cutoff) answerInbox.delete(existing);
  }
  answerInbox.set(key, { text, at: Date.now() });
  return false;
}

/** Resolves with the answer text, or null when nothing arrives in time. */
function awaitAnswer(id, timeoutMs) {
  const key = normalizeCloudId(id);
  if (!key) return Promise.resolve(null);

  const buffered = answerInbox.get(key);
  if (buffered) {
    answerInbox.delete(key);
    return Promise.resolve(buffered.text);
  }

  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };

    const list = answerWaiters.get(key) ?? [];
    list.push(finish);
    answerWaiters.set(key, list);

    const timer = setTimeout(() => {
      const current = answerWaiters.get(key);
      if (current) {
        const remaining = current.filter((fn) => fn !== finish);
        if (remaining.length) answerWaiters.set(key, remaining);
        else answerWaiters.delete(key);
      }
      finish(null);
    }, timeoutMs);
    // Do not hold the process open for a waiter.
    timer.unref?.();
  });
}

/**
 * True when the request carries the answer token.
 *
 * The answer token and nothing else -- deliberately not RELAY_TOKEN as well,
 * which it briefly accepted for convenience. This is the one route published to
 * the public internet through Tailscale Funnel, so the set of credentials that
 * open it should be the smallest possible, and RELAY_TOKEN is the one that can
 * run Claude Code on this machine. Accepting it here would mean a leak of the
 * powerful token also lets a stranger put words in your ear.
 */
function authorizedForAnswer(req) {
  if (!ANSWER_TOKEN) return false;
  const header = req.headers.authorization ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!presented) return false;
  const a = Buffer.from(presented);
  const b = Buffer.from(ANSWER_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

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

function cloudPath() {
  return join(stateDir(), "cloud.json");
}

function loadCloud() {
  try {
    const parsed = JSON.parse(readFileSync(cloudPath(), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveCloud(state) {
  try {
    mkdirSync(dirname(cloudPath()), { recursive: true });
    writeFileSync(cloudPath(), JSON.stringify(state, null, 2));
  } catch {
    // Losing this costs a re-paste, not correctness.
  }
}

// Cloud session transcripts.
//
// There is no API that returns a cloud session's messages, and --teleport --
// the only thing that can fetch its history -- checks out its branch and makes
// a diverging copy, which is far too much for "show me what we said".
//
// So the relay keeps its own record instead: every question it sends and every
// answer the hook returns. Exact for everything from the moment a session joins
// the list, and silent about anything said before that. Honest and cheap beats
// complete and invasive.

function transcriptDir() {
  return join(stateDir(), "transcripts");
}
// Enough to scroll back through a working session, few enough that a file
// stays small and a phone can render it.
const TRANSCRIPT_LIMIT = 200;

function transcriptPath(id) {
  const key = normalizeCloudId(id);
  // The id is validated before it ever reaches here, but this builds a path
  // from it, so it is checked again rather than trusted twice removed.
  if (!key || /[\\/]|\.\./.test(key)) return null;
  return join(transcriptDir(), `${key}.json`);
}

function loadTranscript(id) {
  const path = transcriptPath(id);
  if (!path) return [];
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function appendTranscript(id, role, text) {
  const path = transcriptPath(id);
  if (!path || typeof text !== "string" || !text.trim()) return;
  const entries = loadTranscript(id);

  // A pulled history and the answer to the turn that carried it can describe
  // the same message twice: the hook sends the transcript, then sends the
  // answer, and whether the transcript had caught up by then decides whether
  // they overlap. Saying the same thing twice in a row is always the artefact,
  // never the conversation.
  const last = entries[entries.length - 1];
  if (last && last.role === role && last.text === text) return;

  entries.push({ role, text, at: new Date().toISOString() });
  try {
    mkdirSync(transcriptDir(), { recursive: true });
    writeFileSync(path, JSON.stringify(entries.slice(-TRANSCRIPT_LIMIT), null, 2));
  } catch {
    // A lost transcript costs history, never an answer.
  }
}

/**
 * Replaces a session's record with the history pulled from the session itself.
 *
 * What the hook sends is the real conversation, including everything said
 * before this relay had ever heard of the session -- so it supersedes the
 * relay's own notes rather than being appended to them. Anything the relay
 * recorded is in there too, said by the same two people in the same order.
 *
 * Marked `pulled` so the phone can say where the history came from, and so a
 * second pull is visibly a refresh rather than a duplicate.
 */
function replaceTranscript(id, messages) {
  const path = transcriptPath(id);
  if (!path || !Array.isArray(messages)) return 0;

  const clean = [];
  for (const entry of messages) {
    if (!entry || typeof entry !== "object") continue;
    const role = entry.role === "assistant" ? "assistant" : entry.role === "user" ? "user" : null;
    const text = typeof entry.text === "string" ? entry.text.trim() : "";
    // A turn with no text of its own -- a bare tool call, an attachment -- is
    // not something to show on a phone.
    if (!role || !text) continue;
    clean.push({
      role,
      text,
      at: typeof entry.at === "string" ? entry.at : new Date().toISOString(),
      pulled: true,
    });
  }
  if (!clean.length) return 0;

  try {
    mkdirSync(transcriptDir(), { recursive: true });
    writeFileSync(path, JSON.stringify(clean.slice(-TRANSCRIPT_LIMIT), null, 2));
  } catch {
    // A lost transcript costs history, never an answer.
    return 0;
  }
  return Math.min(clean.length, TRANSCRIPT_LIMIT);
}

/**
 * Records a cloud session as one worth remembering.
 *
 * Called wherever the relay deliberately touches a session -- teleporting it,
 * starting it, or messaging it. Sending used to mark a session as *asked*
 * without remembering it, so a session you had talked to never appeared in the
 * phone's list and there was nothing to tap to talk to it again.
 *
 * Never overwrites a title that is already there: one set when the session was
 * created describes the work, while the first line of a passing message
 * usually does not.
 */
function rememberCloudSession(id, { title = null, project = null, cwd = null } = {}) {
  const key = normalizeCloudId(id);
  if (!key) return;
  const state = loadCloud();
  const existing = state[key] ?? {};
  state[key] = {
    ...existing,
    localId: existing.localId ?? null,
    previousIds: existing.previousIds ?? [],
    title: existing.title ?? title,
    project: existing.project ?? project,
    cwd: existing.cwd ?? cwd,
    updatedAt: new Date().toISOString(),
  };
  saveCloud(state);
}

/**
 * Local session ids left behind by teleport, back when it existed.
 *
 * Teleport made a new local copy each time rather than updating the old one,
 * so those copies are filtered out of the session list. Nothing writes these
 * any more -- the feature is gone -- but state written before it went still
 * has them, and showing a pile of duplicate rows to anyone who used it would
 * be a strange parting gift.
 */
function supersededLocalIds() {
  const ids = new Set();
  for (const entry of Object.values(loadCloud())) {
    for (const id of entry.previousIds ?? []) ids.add(id);
  }
  return ids;
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

/**
 * Arguments for queueing a message into a cloud session.
 *
 * The message is *not* here: it goes in on stdin. Passing it as the argument
 * to -p failed with "Input must be provided either through stdin or as a
 * prompt argument when using --print", because the relay spawns with stdin
 * ignored -- which is an empty pipe, not an absent one, so the CLI reads it,
 * finds nothing, and reports no input. `echo "..." | claude -p --cloud <id>`
 * is the form the docs give for scripts, and it is the one that matches how
 * this is spawned.
 */
function cloudSendArgs(sessionId) {
  return ["-p", "--cloud", sessionId, "--output-format", "json"];
}

/**
 * Turns a CLI failure into something worth reading.
 *
 * The one that matters: `--cloud` refuses to create a session unless it has a
 * terminal. The relay spawns with piped stdout -- that is how it reads output
 * -- so creation from here cannot work, and the CLI is right to refuse rather
 * than silently run the task locally and call it a cloud session.
 *
 * There is no way around it from a Windows service: allocating a pseudo-tty
 * needs a native module, and this relay has no dependencies. So the honest
 * answer is the workaround, said plainly, rather than a raw stderr dump.
 */
function explainCloudFailure(raw) {
  const text = String(raw ?? "");
  if (/interactive terminal|requires a tty|run from a TTY/i.test(text)) {
    return (
      "The Claude Code CLI will not create a cloud session unless it is run from a terminal, "
      + "and the relay runs it with piped output. Start the session in the Claude app or at "
      + "claude.ai/code, then paste its link here -- talking to a session that already exists "
      + "does work from the relay."
    );
  }
  return text.split("\n").filter(Boolean).slice(-3).join(" ").trim();
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

/**
 * Where the relay keeps what it remembers: titles, cloud sessions, archived
 * ids, transcripts.
 *
 * Read on each call rather than captured at import, so a test can redirect it
 * without the module having already decided. The tests used to write into a
 * real home directory and accumulate across runs, which made them pass or fail
 * depending on what had been run before.
 */
function stateDir() {
  return process.env.RELAY_STATE_DIR ?? join(homedir(), ".pocketclaude");
}

function titlesPath() {
  return join(stateDir(), "titles.json");
}

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

function archivePath() {
  return join(stateDir(), "archived.json");
}

function loadArchived() {
  try {
    const parsed = JSON.parse(readFileSync(archivePath(), "utf8"));
    return Array.isArray(parsed) ? new Set(parsed) : new Set();
  } catch {
    return new Set();
  }
}

function saveArchived(ids) {
  try {
    mkdirSync(dirname(archivePath()), { recursive: true });
    writeFileSync(archivePath(), JSON.stringify([...ids], null, 2));
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

// Names set by hand from the phone.
//
// Kept apart from the generated-title cache because they mean something
// different: the cache is a guess the relay is free to replace, and this is an
// instruction it is not. Separate files also means the titler can go on
// filling the cache without ever needing to know which rows are spoken for.
function namesPath() {
  return join(stateDir(), "names.json");
}

function loadNames() {
  try {
    const parsed = JSON.parse(readFileSync(namesPath(), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveNames(names) {
  try {
    mkdirSync(dirname(namesPath()), { recursive: true });
    writeFileSync(namesPath(), JSON.stringify(names, null, 2));
  } catch {
    // A lost name costs a row its label, never an answer.
  }
}

/** Trims and bounds a name typed on a phone. Empty means "go back to the default". */
function cleanName(value) {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").trim().slice(0, 80);
}

function loadTitles() {
  try {
    const parsed = JSON.parse(readFileSync(titlesPath(), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    // Missing, unreadable, or corrupt all mean the same thing here: no titles
    // yet. A cache that throws would take the whole session list down with it.
    return {};
  }
}

function saveTitles(titles) {
  try {
    mkdirSync(dirname(titlesPath()), { recursive: true });
    writeFileSync(titlesPath(), JSON.stringify(titles, null, 2));
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

  // Before the main auth gate: the Stop hook inside a cloud session carries the
  // narrow answer token, not the one that can run Claude Code on this machine.
  if (req.method === "POST" && req.url === "/cloud/answer") {
    if (!ANSWER_TOKEN) {
      respond(res, 503, {
        error: "Set RELAY_ANSWER_TOKEN on the relay to accept answers from cloud sessions.",
      });
      return;
    }
    if (!authorizedForAnswer(req)) {
      respond(res, 401, { error: "unauthorized" });
      return;
    }
    readJSON(req)
      .then((body) => {
        const id = normalizeCloudId(body.sessionId);
        const text = typeof body.text === "string" ? body.text : "";
        if (!id) return respond(res, 400, { error: "sessionId is required" });

        // The hook reached us with a real session id, which is the whole
        // proof that it is installed and its token is right.
        rememberProbe(id);

        // Whether this relay wants to hear from this session at all.
        const wanted = ANSWER_ALL || wasAsked(id);

        // No text is a probe. The hook asks before it sends, so a turn nobody
        // here asked about never leaves the cloud VM in the first place --
        // which is the point. Checking after the text arrived would discard it
        // having already moved it, which is not privacy, only tidiness.
        //
        // Deliberately the same path as delivery: the relay is published to the
        // internet through a single path-scoped Funnel mount, and a second
        // endpoint would mean a second mount for everyone setting this up.
        // History arrives on this same path for the same reason, and is
        // recognised by carrying `messages` instead of `text`.
        if (Array.isArray(body.messages)) {
          if (!wanted) {
            console.log(`history: ${id} ignored (this relay didn't ask that session)`);
            return respond(res, 200, { ok: true, ignored: true });
          }
          const count = replaceTranscript(id, body.messages);
          clearHistoryWant(id);
          rememberCloudSession(id);
          console.log(`history: ${id} pulled ${count} messages`);
          return respond(res, 200, { ok: true, sessionId: id, messages: count });
        }

        if (!text.trim()) {
          // `wantHistory` is the note the hook came to check for. It is only
          // ever true once per pull: the hook answers it on the next turn and
          // the flag is cleared when the history lands.
          return respond(res, 200, { ok: true, wanted, wantHistory: wanted && wantsHistory(id) });
        }

        if (!wanted) {
          // Said out loud rather than silently dropped: a hook that is working
          // correctly and a hook whose answers are being binned look identical
          // otherwise.
          console.log(`answer: ${id} ignored (this relay didn't ask that session)`);
          return respond(res, 200, { ok: true, ignored: true });
        }

        appendTranscript(id, "assistant", text);
        const claimed = deliverAnswer(id, text);
        // Logged, because the relay window is where this is watched from and
        // an unlogged POST is indistinguishable from no POST at all. `claimed`
        // is the interesting half: it separates "the hook reached us" from
        // "the hook reached us and something was waiting for it".
        const preview = text.replace(/\s+/g, " ").slice(0, 60);
        console.log(
          `answer: ${id} ${text.length} chars ${claimed ? "-> waiting request" : "(buffered)"}\n  ${preview}${text.length > 60 ? "..." : ""}`
        );
        respond(res, 200, { ok: true, sessionId: id, claimed });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
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

  // Waits for an answer without sending anything.
  //
  // A cloud turn can run for many minutes, and holding one HTTP request open
  // for the whole of it does not work: the phone's socket times out, the
  // answer arrives afterwards, and the person is told the network connection
  // was lost while the relay is sitting on a perfectly good answer.
  //
  // So the phone sends once and then waits in short hops. Each hop is a
  // request that lives well inside any timeout, and the inbox means an answer
  // that lands between two hops is still there when the next one asks.
  // The two values a cloud environment needs, ready to paste.
  //
  // Behind the main auth gate, so this needs the relay token -- which the
  // phone already holds, and which is strictly more powerful than the answer
  // token it hands back. Nothing is exposed here that the caller could not
  // already do.
  if (req.method === "GET" && req.url === "/setup") {
    const url = funnelURL();
    respond(res, 200, {
      answerUrl: url,
      answerToken: ANSWER_TOKEN || null,
      // Said separately so the phone can explain which half is missing
      // instead of showing a block with a hole in it.
      funnelRunning: Boolean(url),
      hookPath: ".claude/hooks/answer-to-relay.mjs",
    });
    return;
  }

  if (req.method === "POST" && req.url === "/cloud/await") {
    readJSON(req)
      .then(async (body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });

        // Bounded so a stuck phone cannot pin a socket open indefinitely, and
        // short enough that every hop finishes inside a client timeout.
        const asked = Number(body.timeoutMs);
        const waitMs = Math.min(Math.max(Number.isFinite(asked) ? asked : 60_000, 1_000), 90_000);

        markAsked(sessionId);
        const answer = await awaitAnswer(sessionId, waitMs);
        // `waiting: true` is not a failure -- it means ask again. Only the
        // phone knows how long it is prepared to keep waiting. `hookMissing`
        // is the one case where waiting longer cannot help.
        if (answer === null) {
          return respond(res, 200, {
            sessionId,
            answer: null,
            waiting: true,
            hookMissing: !hasProbed(sessionId),
          });
        }
        respond(res, 200, { sessionId, answer });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/cloud/ask") {
    readJSON(req)
      .then(async (body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        const text = typeof body.text === "string" ? body.text.trim() : "";
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        if (!text) return respond(res, 400, { error: "Nothing to send." });
        if (!ANSWER_TOKEN) {
          return respond(res, 503, {
            error: "Set RELAY_ANSWER_TOKEN and install the Stop hook, or an answer can never come back.",
          });
        }

        // Start waiting before sending. A short turn can finish before the
        // send call even returns, and a waiter registered afterwards would
        // miss it. The inbox would still catch it, but a race you can avoid by
        // ordering two lines correctly is not a race worth relying on a
        // safety net for.
        markAsked(sessionId);
        rememberCloudSession(sessionId, { title: firstLine(text) });
        appendTranscript(sessionId, "user", text);
        // Anything still sitting in the inbox answers a question that is no
        // longer the one being asked.
        if (discardBufferedAnswer(sessionId)) {
          console.log(`ask: ${sessionId} dropped an uncollected answer from a previous turn`);
        }
        const waiting = awaitAnswer(sessionId, Number(body.timeoutMs) || 240_000);

        try {
          execFileSync(CLAUDE_BIN, cloudSendArgs(sessionId), {
            encoding: "utf8",
            timeout: 60_000,
            input: text,
          });
        } catch (error) {
          return respond(res, 502, { error: explainCloudFailure(error.stderr || error.stdout || error.message) });
        }

        const answer = await waiting;
        if (answer === null) {
          return respond(res, 200, {
            sessionId,
            answer: null,
            waiting: true,
            hookMissing: !hasProbed(sessionId),
            error: silenceReason(sessionId),
          });
        }
        respond(res, 200, { sessionId, answer });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
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
          output = execFileSync(CLAUDE_BIN, cloudSendArgs(sessionId), {
            encoding: "utf8",
            timeout: 60_000,
            input: text,
          });
        } catch (error) {
          return respond(res, 502, {
            error: explainCloudFailure(error.stderr || error.stdout || error.message),
          });
        }
        const parsed = (() => {
          try {
            return JSON.parse(output);
          } catch {
            return null;
          }
        })();
        // Marked even though nothing here waits for the answer: the phone may
        // poll for it later, and a session the relay deliberately messaged is
        // one whose reply is wanted.
        markAsked(sessionId);
        rememberCloudSession(sessionId, { title: firstLine(text) });
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
        const names = loadNames();
        if (names[id]) {
          delete names[id];
          saveNames(names);
        }
        respond(res, 200, { ok: true, deleted: id });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  // Renames a session on this machine. An empty name puts the default back.
  if (req.method === "POST" && req.url === "/sessions/rename") {
    readJSON(req)
      .then((body) => {
        const id = typeof body.id === "string" ? body.id.trim() : "";
        // Resolved against the files that exist, like every other id the phone
        // sends: it decides which entry of a stored map gets written.
        if (!sessionFilePath(id)) {
          return respond(res, 404, { error: "No session with that id on this machine." });
        }
        const name = cleanName(body.title);
        const names = loadNames();
        if (name) {
          names[id] = name;
        } else if (!(id in names)) {
          return respond(res, 200, { ok: true, id, title: null });
        } else {
          delete names[id];
        }
        saveNames(names);
        respond(res, 200, { ok: true, id, title: name || null });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  // Renames a cloud session in this list. The session on claude.ai is
  // untouched -- this is the label on a row, not its name over there.
  if (req.method === "POST" && req.url === "/cloud/rename") {
    readJSON(req)
      .then((body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        const state = loadCloud();
        if (!state[sessionId]) {
          return respond(res, 404, { error: "That session isn't in the list." });
        }
        const name = cleanName(body.title);
        state[sessionId] = {
          ...state[sessionId],
          title: name || null,
          updatedAt: new Date().toISOString(),
        };
        saveCloud(state);
        respond(res, 200, { ok: true, sessionId, title: name || null });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/cloud/add") {
    readJSON(req)
      .then((body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        const title = typeof body.title === "string" && body.title.trim()
          ? body.title.trim()
          : null;
        // Adding is an act of interest, so its answers are wanted from here on
        // -- otherwise the first question asked would be refused by the probe.
        markAsked(sessionId);
        rememberCloudSession(sessionId, { title });
        respond(res, 200, { ok: true, sessionId, title });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "POST" && req.url === "/cloud/forget") {
    readJSON(req)
      .then((body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        const state = loadCloud();
        delete state[sessionId];
        saveCloud(state);
        // The session itself is untouched: it keeps running on claude.ai and
        // can be added again from its link. Only this list forgets it.
        respond(res, 200, { ok: true, forgot: sessionId });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
    return;
  }

  if (req.method === "GET" && req.url.startsWith("/cloud/transcript")) {
    const asked = new URL(req.url, "http://relay").searchParams.get("sessionId") ?? "";
    const sessionId = parseCloudSessionId(asked);
    if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
    const messages = loadTranscript(sessionId);
    // Whether this is the session's own history or only the part of it that
    // happened to pass through here. The phone says which, so a short record
    // reads as "nothing pulled yet" rather than "nothing was said".
    const pulled = messages.some((m) => m.pulled);
    respond(res, 200, { sessionId, messages, pulled, pullPending: wantsHistory(sessionId) });
    return;
  }

  // Asks a cloud session for its own history. This sends no message and forces
  // no turn: it leaves a note that the session's Stop hook reads the next time
  // it finishes one, so the history arrives alongside the next reply.
  if (req.method === "POST" && req.url === "/cloud/pull") {
    readJSON(req)
      .then((body) => {
        const sessionId = parseCloudSessionId(body.sessionId);
        if (!sessionId) return respond(res, 400, { error: "That doesn't look like a cloud session id." });
        if (!ANSWER_TOKEN) {
          return respond(res, 503, {
            error: "Set RELAY_ANSWER_TOKEN and install the Stop hook, or history can never come back.",
          });
        }
        requestHistory(sessionId);
        rememberCloudSession(sessionId);
        console.log(`pull: ${sessionId} will send its history after its next turn`);
        respond(res, 200, { ok: true, sessionId, requested: true });
      })
      .catch((error) => respond(res, 400, { error: error.message }));
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
  normalizeCloudId,
  deliverAnswer,
  discardBufferedAnswer,
  rememberProbe,
  hasProbed,
  silenceReason,
  parseFunnelURL,
  awaitAnswer,
  markAsked,
  wasAsked,
  requestHistory,
  wantsHistory,
  clearHistoryWant,
  replaceTranscript,
  rememberCloudSession,
  loadNames,
  saveNames,
  cleanName,
  loadTranscript,
  appendTranscript,
  parseCloudSessionId,
  cloudSendArgs,
  explainCloudFailure,
};
