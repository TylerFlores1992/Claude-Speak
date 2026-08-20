# Where this stands

Updated after the session that shipped swipe-to-archive and the live-session
dot. Read this first when picking the project back up.

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

## The cloud round trip

The proof is built and passes end to end under test: `/cloud/ask` queues a
message into a real claude.ai session, a Stop hook committed to that repository
posts the finished turn back to `/cloud/answer`, and the waiting request returns
it. `relay/hooks/README.md` has the install.

This is the path that makes the work genuinely flow through Claude — the session
is claude.ai's own, visible in the Claude app, with the relay acting only as
courier. **Never run against a real cloud session yet.** The remaining unknowns
are whether a Stop hook fires as documented inside a cloud VM and whether that
VM can reach the relay through Tailscale Funnel. Both are one trial away.

## Open threads

1. **Prove the cloud round trip against a real session.** Install the Stop
   hook in campsite-finder, set `RELAY_ANSWER_TOKEN`, start Tailscale Funnel,
   and ask a cloud session something. This is the go/no-go for making cloud
   sessions the default lane.
2. **Run `claude remote-control` on the mini PC.** Decides the local half of
   session merging. Independent of the above; the two lanes complement.
3. **Try `Bring it here`** with a real claude.ai session link — the first
   actual test of teleport.
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
