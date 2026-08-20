# Where this stands

Updated after the session that shipped swipe-to-archive and the live-session
dot. Read this first when picking the project back up.

## The setup

- **Phone**: PocketClaude via TestFlight. No Mac exists in this project —
  every build is GitHub Actions (`.github/workflows/ios.yml`), delivered to
  TestFlight. `workflow_dispatch` with `upload_to_testflight: true` ships.
- **Relay**: `C:\code\Claude-Speak` on a Windows mini PC, serving
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

- **`/teleport`** — pulling a claude.ai cloud session onto the relay. Built to
  the documented CLI contract; never run against a real cloud session. The most
  likely failure is teleport wanting a terminal, which will error rather than
  hang because stdin is closed.
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

## Open threads

1. **Run `claude remote-control` on the mini PC.** Decides the whole
   session-merging direction. Nothing further should be built on it until
   this is known.
2. **Try `Bring it here`** with a real claude.ai session link — the first
   actual test of teleport.
3. **Scaffold repo config for campsite-finder** — a `.claude/settings.json`
   SessionStart hook plus `scripts/setup.sh`, so setup travels with the repo
   into both cloud sessions and relay sessions. Offered, not yet started.

## Working agreements

- Every change: CI on the branch, then squash-merge PR, then ship to TestFlight
  from `main`, then reset the branch onto `main`.
- Relay-only changes still need `git pull` on the mini PC; they do not ride
  TestFlight.
- Say plainly what is unverified. Several fixes here were shipped twice because
  the first attempt was described as working when it had never been run.
