# Where this stands

Updated after the session that proved the cloud round trip on hardware, built
history pulling, and cut the app back to one lane. Read this first when picking
the project back up.

App and relay are both on `fb8409c`.

## The setup

- **Phone**: PocketClaude via TestFlight. No Mac exists in this project —
  every build is GitHub Actions (`.github/workflows/ios.yml`), delivered to
  TestFlight. `workflow_dispatch` with `upload_to_testflight: true` ships.
- **Relay**: `C:\code\Claude-Speak` on a Windows mini PC, started by the
  "PocketClaude relay" scheduled task at logon (`relay/install-autostart.ps1`),
  serving `C:\code\campsite-finder` (the CampHawk repo, actual name
  `campsite-finder`). Reached over Tailscale at `100.119.76.63:8788`.
- **Cloud sessions**: created in the Claude app, added here by link. The Stop
  hook that answers them is committed to `campsite-finder` on `master`
  (`.claude/hooks/answer-to-relay.mjs`, wired in `.claude/settings.json`).
- **Watch**: Apple Watch SE3, paired, working.
- **Branch**: all work on `claude/pocketclaude-voice-agent-oeae9p`, squash-merged
  to `main` via PR, then the branch is reset onto `main`.

## What works, confirmed on hardware

- Voice question → relay → Claude Code → spoken answer, phone pocketed.
- **The watch, with the phone locked.** Tap Ask, talk, tap Send. The watch
  records audio, transfers the file, the phone transcribes it and answers.
- **The cloud round trip.** A Stop hook inside a cloud VM reached the relay
  through Tailscale Funnel and delivered a finished turn
  (`answer: session_01R9kxxy... 233 chars (buffered)`); a message queued into a
  cloud session; both ends showed the same conversation.
- Sessions dashboard: cloud sessions first, then the relay machine's own,
  grouped by repository. Swipe to rename, archive, delete, or remove.
- Markdown rendering, model/effort chips, typed input, one-tap pairing.
- Relay update from the phone, when running under `run.ps1`.

## What is built but never verified against reality

Be honest about these rather than describing them as working:

- **History** — the pull is verified end to end against a *local* relay and a
  real transcript file (4 messages pulled, flag cleared, no duplicates, a
  `tool_use` block containing `echo secret` correctly excluded). It has never
  been watched working against a live cloud session over the Funnel. Same
  mechanism as the answers that do work, so it should — but nobody has seen it.
- **Rename** — both endpoints were exercised against a running relay before the
  UI was wired. The swipe action itself has not been tapped.
- **New chat** — starts on the relay's scratch workspace. Not tried.
- **`/cloud/send`** — queueing a message into a cloud session without waiting.
- **The green live dot** — needs `claude agents --json` on the relay machine.
- **Wake word while locked** — the premise (an app keeps a microphone it already
  holds) is documented behaviour of the `audio` background mode, not observed.
- **Keep music playing** — ducking adds a route negotiation at microphone
  acquisition, which is what caused early locked-screen crashes. If takes start
  failing with music on, that is the suspect.

## How the cloud lane works

The relay is a courier. The session is claude.ai's own, visible in the Claude
app, and the work runs on Anthropic's infrastructure.

- **Asking**: `/cloud/ask` runs `claude -p --cloud <id>` with the text on stdin,
  then waits. The answer comes back through the Stop hook, not through the CLI.
- **Answering**: the hook fires at the end of every turn, probes the relay with
  the session id and no text, and sends the answer only if the relay says it
  asked. A turn nobody here asked about never leaves the VM.
- **History**: `POST /cloud/pull` sets a flag; the probe reports it as
  `wantHistory`; the hook reads its own `transcript_path` — the conversation on
  disk beside it — keeps only plain user and assistant text, and posts it back
  on the same path. No message is sent and no turn is started, so nothing about
  a pull appears in the conversation on claude.ai.

The Stop hook payload was captured live to confirm this: it carries
`session_id`, `transcript_path`, `cwd`, `last_assistant_message`, and more.

**A cloud session needs the hook on the branch it has checked out.** New
sessions branched from `master` get it. An older session needs one file:
`git fetch origin master && git checkout origin/master -- .claude/hooks/answer-to-relay.mjs`.

## Known dead ends, with the reason

- **`--teleport` cannot fetch a cloud session's history.** Tested directly
  against a real idle cloud session, with and without a TTY: it exits 1 and
  prints nothing on either stream. It resumes an existing *teleport* session,
  not an arbitrary cloud one.
- **The MCP session tools are not available to the relay.** `list_sessions` and
  friends are injected into a cloud session by its harness; `claude mcp list` on
  a plain CLI shows no servers.
- **Creating a cloud session from the relay.** `claude --cloud "<task>"` refuses
  without a terminal: "Non-interactive invocations run locally and would
  silently ignore --cloud." Allocating a pseudo-tty needs a native module this
  project has no dependencies for. Sessions are created in the Claude app.

Do not re-attempt these without new information:

- **Listing cloud sessions.** No API, no non-interactive CLI. `claude agents
  --json` is local sessions only. The Managed Agents API is a separate
  API-billed product and cannot see claude.ai sessions.
- **Attaching to a live cloud session.** `claude --cloud <id>` attach exists but
  explicitly does not support `--output-format stream-json`, so the relay could
  attach and have no way to speak anything to the phone.
- **AirPod stem press with the screen locked.** Holding the Now Playing slot
  needs `.playback`, capturing needs `.playAndRecord`, and a backgrounded app on
  a locked phone cannot acquire the microphone. Three constraints, no solution.
- **Foregrounding the phone app from the watch.** No API. The fix was to make
  the phone answer from the background instead, which it now does.
- **Editing cloud environments.** claude.ai UI only; `/remote-env` picks a
  default and is interactive. The repo-committed route — `CLAUDE.md`,
  `.claude/settings.json` SessionStart hooks, `.claude/rules|skills|agents` —
  is the portable alternative and works locally *and* in the cloud.

## Removed, and why

**Teleport and everything reachable only through it**: the "Bring it here" flow,
the Remote Control toggle, cloud-session refresh (which re-teleported), and
starting a cloud session from the phone. Relay routes `/teleport`,
`/remote-control`, `/remote-control/stop`, `/cloud/refresh` and `/cloud/start`
went with them.

**The direct-API lane.** The app had two backends: the relay, and calling
Anthropic from the phone with an API key and a GitHub token. Only the relay was
ever used, so the second went — `AnthropicClient`, `AgentRunner`,
`ToolExecutor`, `ToolCatalog`, `GitHubClient`, the system prompt, and the write
confirmation flow that only its tool calls could trigger. Settings lost the
backend picker and the credentials, repository and model sections. 3,498 lines.

The Anthropic key and GitHub token are kept as **retired Keychain cases and
deleted at launch**: removing a feature does not remove what it stored, and
dropping the cases would have stranded two real secrets on the device with
nothing able to name them.

**From the UI**: the composer's `claude.ai` chip, the conversation's new-session
toolbar icon, the dashboard's back-to-current-conversation shortcut, the `+`
actions menu (replaced by a one-tap repeat button), the past-conversations
sheet, and the workspace picker behind "New session" — which is now "New chat"
and starts one directly.

This reverses part of the original brief, which asked for tests on the GitHub
API client and the tool-call layer: that code is gone, so those tests are too.
`ResponseParser` and its tests survive — speech and the Siri intent use it.

## The bug pattern worth remembering

Three bugs in one evening had the same shape: an error was swallowed with
`try?`, an empty value substituted with `?? []`, and an empty state shown that
read as "nothing here" instead of "something failed".

- A session added by link never appeared, because the list was gated on the
  *local* sessions found on the relay — with none there, cloud sessions were
  never drawn.
- The transcript request could never succeed: `getJSON` folded `"path?query"`
  into `URLComponents.path`, which percent-encodes what it is given, so `?`
  became `%3F` and the relay answered 400. The **History** button, gated on that
  request, was therefore correctly hidden every time.
- A momentary relay failure wiped the cloud list, making a hiccup on the way
  back to the screen look identical to a session that failed to save.

More instances of the pattern remain. `try?` followed by `?? []` is the
signature.

## Open threads

1. **Watch History work on real infrastructure.** The one feature built end to
   end and never seen running. Tap it in a cloud session, say anything.
2. **Sweep for swallowed errors** — see the pattern above.
3. **Scaffold repo config for campsite-finder** — a `.claude/settings.json`
   SessionStart hook plus `scripts/setup.sh`, so setup travels with the repo
   into both cloud sessions and relay sessions. Offered, not yet started.

## Working agreements

- Every change: CI on the branch, then squash-merge PR, then ship to TestFlight
  from `main`, then reset the branch onto `main`.
- Merge to `main` *before* asking for a `git pull` on the mini PC. Relay-only
  changes still need that pull; they do not ride TestFlight.
- Say plainly what is unverified. Several fixes here were shipped twice because
  the first attempt was described as working when it had never been run.
