#!/usr/bin/env node
//
// A Stop hook: hands the answer back to the PocketClaude relay.
//
// Claude Code runs this when a turn finishes, in whichever session it is
// configured for -- including a cloud session on claude.ai, because hooks
// committed to a repository travel with the checkout. It receives the hook
// payload on stdin and posts the final text to the relay, which is what lets a
// phone speak the answer to a question that ran in Anthropic's cloud.
//
// Install by committing this file and the matching .claude/settings.json entry
// to the repository you work in, then setting two environment variables on the
// cloud environment at claude.ai/code:
//
//     RELAY_ANSWER_URL    https://your-funnel-host/cloud/answer
//     RELAY_ANSWER_TOKEN  the value of RELAY_ANSWER_TOKEN on the relay
//
// Silence is the design. A hook that fails loudly interrupts a working session
// for a reason the person in that session cannot act on, and this one runs in
// every session the repo is opened in -- most of which are not waiting on a
// phone. Missing configuration, an unreachable relay, and a rejected token all
// exit 0 with nothing printed unless RELAY_HOOK_DEBUG is set.

import { readFileSync } from "fs";

const DEBUG = process.env.RELAY_HOOK_DEBUG === "1";

// A phone renders a scrollback, not an archive. Enough to read back through a
// working session, small enough to post in one request.
const HISTORY_LIMIT = 200;
const HISTORY_CHARS = 400_000;

/**
 * Reads the conversation this session is having, from the session's own disk.
 *
 * The relay has no way to fetch a cloud session's history -- but this hook is
 * running inside that session, and the payload hands it `transcript_path`.
 * That file is JSONL, one record per line, of which only the plain user and
 * assistant turns are worth showing on a phone.
 *
 * Tool calls, attachments, and the various bookkeeping records are skipped on
 * purpose. They are the bulk of the file, they are meaningless without the
 * tooling that made them, and they are the records most likely to be carrying
 * something -- a file, a command, a key -- that has no business leaving this
 * VM for a phone's reference pane.
 */
function readHistory(transcriptPath) {
  if (typeof transcriptPath !== "string" || !transcriptPath) return [];

  let raw;
  try {
    raw = readFileSync(transcriptPath, "utf8");
  } catch (error) {
    note(`could not read the transcript: ${error.message}`);
    return [];
  }

  const messages = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      // A partially written last line is normal: the transcript is appended to
      // while this runs. Skip it rather than abandoning the whole history.
      continue;
    }
    const role = record?.message?.role;
    if (role !== "user" && role !== "assistant") continue;

    const content = record.message.content;
    let text = "";
    if (typeof content === "string") {
      text = content;
    } else if (Array.isArray(content)) {
      // Text blocks only -- a tool_use block is skipped by having no `text`.
      text = content
        .filter((block) => block?.type === "text" && typeof block.text === "string")
        .map((block) => block.text)
        .join("\n");
    }
    text = text.trim();
    if (!text) continue;

    messages.push({ role, text, at: record.timestamp ?? undefined });
  }

  // Trim from the front: the recent end of a conversation is the part worth
  // having when only part of it fits.
  let trimmed = messages.slice(-HISTORY_LIMIT);
  while (trimmed.length > 1 && JSON.stringify(trimmed).length > HISTORY_CHARS) {
    trimmed = trimmed.slice(Math.ceil(trimmed.length / 10));
  }
  return trimmed;
}

function note(message) {
  if (DEBUG) process.stderr.write(`answer-to-relay: ${message}\n`);
}

function readStdin() {
  return new Promise((resolve) => {
    let raw = "";
    // Never block a session on a hook that has no input to read.
    const bail = setTimeout(() => resolve(raw), 5000);
    bail.unref?.();
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      raw += chunk;
    });
    process.stdin.on("end", () => {
      clearTimeout(bail);
      resolve(raw);
    });
    process.stdin.on("error", () => {
      clearTimeout(bail);
      resolve(raw);
    });
  });
}

async function main() {
  const url = process.env.RELAY_ANSWER_URL ?? "";
  const token = process.env.RELAY_ANSWER_TOKEN ?? "";
  if (!url || !token) {
    note("RELAY_ANSWER_URL or RELAY_ANSWER_TOKEN is unset; nothing to do");
    return;
  }

  let payload;
  try {
    payload = JSON.parse(await readStdin());
  } catch (error) {
    note(`could not parse the hook payload: ${error.message}`);
    return;
  }

  // `last_assistant_message` is handed to Stop hooks directly. The transcript
  // is written asynchronously and lags behind, so reading *this turn's* answer
  // out of it would sometimes send the previous turn's instead.
  //
  // History is the opposite case and can be read from the file safely: it is
  // wanted for the turns already finished, and the one this lags by is the one
  // being sent alongside it anyway.
  const text = typeof payload.last_assistant_message === "string"
    ? payload.last_assistant_message.trim()
    : "";

  // The cloud session's own id, which is what the phone asked against.
  // CLAUDE_CODE_REMOTE_SESSION_ID is the cse_ spelling of the same session;
  // the relay normalises the two. `session_id` is the local fallback, which is
  // what a session running on your own machine has instead.
  const sessionId = process.env.CLAUDE_CODE_REMOTE_SESSION_ID || payload.session_id || "";
  if (!sessionId) {
    note("no session id in the environment or the payload");
    return;
  }

  const post = (body) =>
    fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(body),
      // A hook holds the session's turn open while it runs. Ten seconds is
      // plenty for one POST and short enough not to be noticed.
      signal: AbortSignal.timeout(10_000),
    });

  try {
    // Ask before sending. This hook fires at the end of every turn in the
    // repository it is committed to, and most of those turns are nobody's
    // voice loop -- work done at a keyboard, a teammate's session, an
    // unrelated cloud task. Sending first and letting the relay discard would
    // move the text out of this VM before deciding it was not wanted, which is
    // tidiness rather than privacy.
    //
    // Set RELAY_ANSWER_ALWAYS=1 to skip the check, which is useful when
    // proving the path works and nothing has asked anything yet.
    let wantHistory = false;
    if (process.env.RELAY_ANSWER_ALWAYS !== "1") {
      const probe = await post({ sessionId });
      if (!probe.ok) {
        note(`relay replied ${probe.status} to the probe`);
        return;
      }
      const answered = await probe.json().catch(() => ({}));
      if (!answered.wanted) {
        note("relay did not ask this session; not sending the answer");
        return;
      }
      // The probe is also where a pull request is collected. Someone tapped
      // "pull" on the phone; this is the first turn to finish since, so this
      // is the turn that carries the history back.
      wantHistory = answered.wantHistory === true;
    }

    if (wantHistory) {
      const messages = readHistory(payload.transcript_path);
      if (messages.length) {
        const sent = await post({ sessionId, messages });
        note(`sent ${messages.length} messages of history; relay replied ${sent.status}`);
      } else {
        note("history was asked for but the transcript had nothing readable in it");
      }
    }

    if (!text) {
      note("no last_assistant_message on this turn");
      return;
    }

    const response = await post({ sessionId, text });
    note(`relay replied ${response.status}`);
  } catch (error) {
    note(`could not reach the relay: ${error.message}`);
  }
}

main().then(
  () => process.exit(0),
  // Exit 0 even on an unexpected throw: a non-zero exit from a Stop hook is
  // reported into the session, and nothing here is worth interrupting work for.
  (error) => {
    note(`unexpected: ${error?.message ?? error}`);
    process.exit(0);
  }
);
