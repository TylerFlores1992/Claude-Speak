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

const DEBUG = process.env.RELAY_HOOK_DEBUG === "1";

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
  // is written asynchronously and lags behind, so reading it here would
  // sometimes send the previous turn's answer.
  const text = typeof payload.last_assistant_message === "string"
    ? payload.last_assistant_message.trim()
    : "";
  if (!text) {
    note("no last_assistant_message on this turn");
    return;
  }

  // The cloud session's own id, which is what the phone asked against.
  // CLAUDE_CODE_REMOTE_SESSION_ID is the cse_ spelling of the same session;
  // the relay normalises the two. `session_id` is the local fallback, which is
  // what a session running on your own machine has instead.
  const sessionId = process.env.CLAUDE_CODE_REMOTE_SESSION_ID || payload.session_id || "";
  if (!sessionId) {
    note("no session id in the environment or the payload");
    return;
  }

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ sessionId, text }),
      // A hook holds the session's turn open while it runs. Ten seconds is
      // plenty for one POST and short enough not to be noticed.
      signal: AbortSignal.timeout(10_000),
    });
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
