# Where this stands

Updated after the session that proved the cloud round trip on real hardware and
built history pulling. Read this first when picking the project back up.

## The setup

- **Phone**: PocketClaude via TestFlight. No Mac exists in this project —
  every build is GitHub Actions (`.github/workflows/ios.yml`), delivered to
  TestFlight. `workflow_dispatch` with `upload_to_testflight: true` ships.
- **Relay**: `C:\code\Claude-Speak` on a Windows mini PC, started by the
  "PocketClaude relay" scheduled task at logon (`relay/install-autostart.ps1`),
  serving
  `C:\code\campsite-finder` (the CampHawk repo, actual name `campsite-finder`).
  Reached over Tailscale at `100.119.76.63:8788`.
- **Watch**: Apple Watch SE3, paired, working.
- **Branch**: all work on `claude/pocketclaude-voice-agent-oeae9p`, squash-merged
  to `main` via PR, then the branch is reset onto `main`.

## What works, confirmed on hardware

- Voice question → relay → Claude Code → spoken answer, phone pocketed.
- **The watch, with the phone locked.** Tap Ask, talk, tap Send. The watch
  records audio, transfers the file, the phone transcribes it and answers.
- Sessions dashboard listing every Claude Code session on the mini PC,
  grouped by repository, including ones started at the keyboard.
- Markdown rendering, model/effort chips, typed input, one-tap pairing.
- Relay update from the phone, when running under `run.ps1`.

## What is built but never verified against reality

Be honest about these rather than describing them as working:

- **`/cloud/send`** — queueing a message into a cloud session.
- **Remote Control** (`Watch live`) — gated on a research-preview flag.
  **`claude remote-control` on the mini PC is the one command that decides
  whether this whole path is open.** It has not been run.
- **The green live dot** — needs `claude agents --json` on the relay machine.
- **Wake word while locked** — the premise (an app keeps a microphone it already
  holds) is documented behaviour of the `audio` background mode, not observed.
- **Keep music playing** — ducking adds a route negotiation at microphone
  acquisition, which is what caused early locked-screen crashes. If takes start
  failing with music on, that is the suspect.

## Known dead ends, with the reason

- **`--teleport` cannot fetch a cloud session's history.** Tested directly
  against a real idle cloud session, with and without a TTY: it exits 1 and
  prints nothing on either stream. The flag resumes an existing *teleport*
  session, not an arbitrary cloud one. `/teleport` and the app's "Bring it
  here" are built on a contract the CLI does not offer.
- **The MCP session tools are not available to the relay.** `list_sessions`
  and friends are injected into a cloud session by its harness; `claude mcp
  list` on a plain CLI shows no servers, so the relay cannot enumerate or read
  cloud sessions that way.
- **Creating a cloud session from the relay.** `claude --cloud "<task>"` refuses
  unless it has a terminal: "Non-interactive invocations run locally and would
  silently ignore --cloud." The relay spawns with piped stdout, so this cannot
  work from it, and allocating a pseudo-tty needs a native module this project
  has no dependencies for. Sessions are created in the Claude app, at
  claude.ai/code, or by hand in a real terminal on the relay machine; the app
  then talks to one by link. `POST /cloud/start` remains, and explains this
  when it fails.

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

## Pulling a session's history — how it actually works

Verified end to end against a real relay and a real transcript file.

The Stop hook payload carries `transcript_path` (confirmed by capturing a live
payload: `session_id`, `transcript_path`, `cwd`, `last_assistant_message`, and
more). The hook runs inside the cloud session, so it can read the conversation
the relay cannot reach.

`POST /cloud/pull` sets a flag; the probe the hook already makes at the end of
every turn reports it as `wantHistory`; the hook reads its own transcript,
keeps only plain user and assistant text, and posts it back on the same path.
No message is sent and no turn is started, so nothing about a pull appears in
the conversation on claude.ai.

## The cloud round trip

The proof is built and passes end to end under test: `/cloud/ask` queues a
message into a real claude.ai session, a Stop hook committed to that repository
posts the finished turn back to `/cloud/answer`, and the waiting request returns
it. `relay/hooks/README.md` has the install.

This is the path that makes the work genuinely flow through Claude — the session
is claude.ai's own, visible in the Claude app, with the relay acting only as
courier.

**Confirmed on real infrastructure**, in three parts: a Stop hook inside a cloud
VM reached the relay through Tailscale Funnel and delivered a finished turn
(`answer: session_01R9kxxy... 233 chars (buffered)`); a message queued into a
cloud session; and both ends showed the same conversation. The two unknowns
this section used to list — whether the hook fires in a cloud VM, and whether
that VM can reach the relay — are both answered yes.

## Open threads

1. **Remove what is now known to be dead.** `/teleport` and the app's "Bring it
   here" cannot work — see the dead ends above. The button is still on screen.
2. **Simplify around cloud sessions.** The dashboard still carries local
   sessions, teleport, and Remote Control alongside the lane that actually
   works. Stated preference: less is more.
3. **Run `claude remote-control` on the mini PC.** Decides the local half of
   session merging — worth knowing before deciding whether to cut it.
4. **Scaffold repo config for campsite-finder** — a `.claude/settings.json`
   SessionStart hook plus `scripts/setup.sh`, so setup travels with the repo
   into both cloud sessions and relay sessions. Offered, not yet started.

## Working agreements

- Every change: CI on the branch, then squash-merge PR, then ship to TestFlight
  from `main`, then reset the branch onto `main`.
- Relay-only changes still need `git pull` on the mini PC; they do not ride
  TestFlight.
- Say plainly what is unverified. Several fixes here were shipped twice because
  the first attempt was described as working when it had never been run.
