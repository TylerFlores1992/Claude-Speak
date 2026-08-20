# Roadmap

Phase 1 and 2 are built. Phase 3 is designed here and deliberately not built.

---

## Status

| | |
|---|---|
| **Phase 1 — on-phone agent** | Built. Speech in, Messages API with tool use, GitHub REST as the tools, speech out. No server. |
| **Phase 2 — pocket + AirPod polish** | Built. Background audio, interruptible speech, session persistence, hands-free mode, cost tracking, ElevenLabs option, AirPod stem press within iOS limits. |
| **Phase 3 — full agent mode** | Designed below. Not built. |

Nothing in the codebase is stubbed or faked — see the last section of
`DECISIONS.md`.

---

## Phase 3 — the thin container, and how the app would switch to it

### What a server buys you

Exactly the things `PHASE1_RESEARCH.md` §6 lists as the ceiling, and nothing
else. A container with a cloned repo and a shell can:

- **run the tests** — the single biggest gap; today Claude cannot verify anything
  it writes;
- **typecheck and build** — `tsc --noEmit`, `next build`, so a PR isn't
  syntactically broken;
- **use real tooling** — `rg`, `git log`, `git blame`, `git diff`;
- **apply patches instead of whole-file writes**, which makes editing long files
  safe;
- **run the dev server** and reproduce behaviour, not just read code;
- **do multi-file refactors**, because it can verify them afterwards.

What it does *not* buy: any improvement to reading, searching, summarising, or
opening a PR. Those already work. If the questions you actually ask into an
AirPod are "what does this do" and "where is this handled", Phase 3 is optional
and Phase 1 is the whole product.

### Shape

```
iPhone (unchanged UI)                  fly.io / any VPS
┌──────────────────────┐              ┌──────────────────────────────────┐
│ Speech in            │              │  POST /agent   (Bearer token)    │
│ Transcript + TTS     │──HTTPS──────▶│  ── Claude Agent SDK ──────────  │
│ Settings: mode       │◀─ SSE ───────│  cloned repo + shell + tests     │
└──────────────────────┘              └──────────────────────────────────┘
```

The container runs the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk)
— Claude Code packaged as a library, with built-in Read/Write/Edit/Bash/Glob/Grep
tools and its own agent loop. That's the point: you stop maintaining a tool
catalogue and inherit a battle-tested one.

Note this is a *different* thing from the Messages API tool loop the phone runs
today. It supplies the harness, not the deployment — you still host it. (Managed
Agents is the third option: Anthropic runs both the loop and a per-session
sandbox, no VPS at all. Worth comparing before renting a machine.)

### One endpoint

```
POST /agent
Authorization: Bearer <shared secret from the phone's Keychain>
Content-Type: application/json

{ "session_id": "uuid", "message": "summarise the open TODOs in the hold lifecycle" }

→ text/event-stream
  event: tool     data: {"name":"Bash","input":"npm test"}
  event: message  data: {"text":"..."}
  event: final    data: {"spoken_summary":"...","detail":"..."}
```

Keeping the `{spoken_summary, detail}` contract is what makes the switch cheap:
the phone's `ResponseParser`, transcript, and TTS keep working untouched.

Roughly:

```ts
// server.ts — sketch, not tested
import { query } from "@anthropic-ai/claude-agent-sdk";

app.post("/agent", requireBearer, async (req, res) => {
  res.setHeader("Content-Type", "text/event-stream");
  for await (const event of query({
    prompt: req.body.message,
    options: { cwd: "/repo", resume: req.body.session_id },
  })) {
    res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
  }
  res.end();
});
```

Container needs: the repo cloned at `/repo`, `ANTHROPIC_API_KEY`, a GitHub token
for push, the project's runtime (Node + your package manager), and a persistent
volume so the clone survives restarts. Roughly $5/month on fly.io's smallest
machine; scale-to-zero works but adds cold-start latency to the first question,
which is painful in a voice loop.

### The switch in the app

Add to `AppSettings`:

```swift
enum AgentMode: String, CaseIterable { case onPhone, fullAgent }
@Published var agentMode: AgentMode
@Published var serverURL: String        // https://pocketclaude.fly.dev
// plus KeychainStore.Key.serverToken
```

Then introduce a protocol both paths satisfy:

```swift
protocol AgentBackend {
    func run(
        message: String,
        onEvent: @MainActor (AgentEvent) -> Void,
        confirm: @MainActor (ToolCall) async -> Bool
    ) async throws -> AgentTurnResult
}
```

`AgentRunner` (today's on-phone loop) conforms as-is — its `run` already has that
shape. A new `RemoteAgentBackend` opens the SSE stream, maps server events onto
the existing `AgentEvent` cases, and returns the same `AgentTurnResult`.
`ConversationViewModel.send` picks one based on `settings.agentMode`. The UI, the
transcript, the confirmation bar, and the speech layer don't change at all.

Keep on-phone mode as the fallback: it works with no signal to your server, no
cold start, and no monthly bill.

### Security, if you build it

The endpoint is a remote shell on a box with a GitHub push token, reachable from
the internet. Treat it that way:

- Bearer token in the Keychain, generated once, rotated when you like — not a
  password, not in the URL.
- Reject every unauthenticated request before any work; no unauthenticated health
  endpoint that leaks repo state.
- Keep the branch guard **server-side too**. The phone's guard is in
  `GitHubClient`; the container has its own `git` and would bypass it entirely.
  A pre-push hook or a `git config receive.denyCurrentBranch`-style guard is not
  optional.
- Keep the confirmation gate on the phone. The server proposes, you approve. The
  moment a server can write to your repo without a human in the loop, an SSE
  stream you can't see becomes a much more interesting attack surface.
- HTTPS only. fly.io terminates TLS for you; a bare VPS needs Caddy or nginx.

---

## Smaller things worth doing before Phase 3

Ordered by value per hour of work.

**Repository picker.** One repo at a time, typed as `owner/repo`, is the most
obviously temporary thing in the app. `GET /user/repos` plus a searchable list
and a recents section — half a day, removes a daily annoyance.

**Prompt-cache the tool definitions explicitly.** The system block carries a
breakpoint; the tool array renders before it and is cached along with it, but a
second breakpoint would make the boundary explicit and survive a future refactor
that reorders them.

**Better long-file editing.** `put_file` is a whole-file write. A `replace_in_file`
tool doing exact string replacement (read → match once → write) would make edits
to large files far safer, and it's the same GitHub endpoint underneath.

**Speak while thinking.** Long turns are silent. A short spoken "reading the holds
library…" on the first tool call would make a 30-second turn feel much shorter.
The `AgentEvent.toolStarted` hook is already there.

**Diff-aware PR review.** `get_pull_request` with `include_files` returns patches
today; a dedicated "review this PR" prompt template on top of it is a small
addition with a lot of use.

**Session list.** One persisted session today. A list with titles derived from the
first question, so you can pick up yesterday's thread.

**Device UI tests.** The speech and audio layers are the untested part of the
codebase (`DECISIONS.md` explains why). A small XCUITest suite on a real device
covering permission flow, record → send → speak, and interruption would close it.

**Shortcuts / App Intents.** An `AppIntent` for "Ask PocketClaude" would let Siri
and the Action Button start a session — a much better hands-free entry point than
anything the AirPods stem can offer.

**Live Activity.** A Dynamic Island activity showing which tool is running, so you
can glance at progress without unlocking.

## Explicitly not planned

- **App Store distribution.** Personal-use app; free signing and a weekly ⌘R is
  the intended workflow.
- **Multi-user anything.** No accounts, no sync, no sharing.
- **Android/web clients.** The iOS speech and audio session stack is most of the
  value here.
- **On-device models.** Nothing that fits on a phone gets close to being useful
  on a codebase you can't see.

---

# Current roadmap

`STATUS.md` has the live picture. In short:

**Next, in order of what unblocks the most:**

1. Run `claude remote-control` on the relay machine. It decides whether the
   session-merging direction is available at all, and nothing further should be
   built on it until that is known.
2. Test `Bring it here` against a real claude.ai session link — the first actual
   exercise of `/teleport`.
3. Scaffold repo-committed configuration for the target repository: a
   `.claude/settings.json` SessionStart hook plus a setup script, so environment
   setup travels with the checkout into both cloud sessions and relay sessions.
   This is the supported substitute for editing cloud environments, which has no
   API.

**Ruled out, with reasons, in `STATUS.md`:** listing cloud sessions, attaching
to a live cloud session, the AirPod stem press while locked, foregrounding the
phone app from the watch, and editing cloud environments programmatically.
