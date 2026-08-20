# PocketClaude

A voice-driven Claude agent for iPhone, Apple Watch, and your own machine.
Phone in your pocket, one AirPod in: ask a question about a repo, hear the
answer. Or tap your wrist and talk, with the phone locked and in a bag.

Personal use only. Never going to the App Store, so it does things an
App Store app could not.

## Two backends

The app can answer from either of two places, chosen in Settings.

**Relay (the one worth using).** A ~1,300-line Node script on a machine you own
runs the Claude Code CLI against a real checkout. It costs nothing per question
— the CLI uses your Claude subscription — and it can read files, run tests, and
edit code. Requires that machine awake and reachable, normally over Tailscale.

**Direct API.** Calls Anthropic straight from the phone, billed per token to an
API key. Works anywhere with a signal, but can only read the repository and open
pull requests through the GitHub REST API — no shell, no test runner.

```
   watch ──record──▶ phone ──┐
                             │  (phone transcribes, then asks)
   you ──speak──▶ phone ─────┼──▶ relay ──▶ claude -p ──▶ your checkout
                             │       ▲
   you ◀──AirPod── phone ◀───┴───────┘  SSE, spoken as it arrives
```

## What it does

- **Ask by voice** — hold the button, or say a wake phrase, or tap the watch.
- **Sessions dashboard** — every Claude Code session on the relay machine,
  grouped by repository, including ones started at the keyboard. Swipe to
  archive or delete. A green dot marks sessions running right now.
- **Sessions get named** — a small model titles each one, cached forever, so the
  list is not sixty rows of the first question truncated.
- **Cloud sessions** — bring one from claude.ai onto the relay machine with
  `--teleport`, or queue a message into one where it already runs.
- **Watch live** — start Remote Control on the relay so claude.ai and the Claude
  app can watch the same session the phone is driving.
- **Model and effort** from the composer, per question.
- **Update the relay from the phone**, when it runs under `relay/run.ps1`.

## The parts that were hard

Each of these cost real debugging, and the reasoning is in `DECISIONS.md`:

- **AirPod stem press works only with the screen on.** Holding the Now Playing
  slot needs `.playback`; capturing audio needs `.playAndRecord`; a backgrounded
  app on a locked phone cannot acquire the microphone. Three constraints that do
  not reconcile. The wake word exists because of this.
- **The wake word works locked** for a specific reason: iOS will not *hand* the
  microphone to a backgrounded app, but it will let one that already holds it
  keep recording. So it is taken while the app is open and never released.
- **The watch records audio rather than asking watchOS for text.** Presenting
  the text input controller with nil suggestions is documented to open dictation
  and does not — it opens Scribble.
- **`.duckOthers` is not enough to duck.** The audio session *mode* decides
  duck-versus-pause; `.spokenAudio` pauses Spotify no matter what options say.

## Getting started

- [`SETUP.md`](SETUP.md) — the phone: clone, sign with a free Apple ID, run.
- [`relay/README.md`](relay/README.md) — the relay: the part that makes it good.

On Windows, `relay/setup.ps1` does the whole relay side in one script, and
`relay/run.ps1` runs it with a supervisor so the phone's update button works.

There is no Mac in this project's loop: every build is done by GitHub Actions
(`.github/workflows/ios.yml`) and delivered over TestFlight.

## The code

Zero third-party dependencies, in the app and in the relay.

| Path | What lives there |
|---|---|
| `PocketClaude/Relay/` | Relay client — SSE reader, sessions, cloud, Remote Control |
| `PocketClaude/Voice/` | Speech in and out, audio session, wake word, cues |
| `PocketClaude/UI/` | Dashboard, conversation, settings, Markdown rendering |
| `PocketClaude/Anthropic/` | Direct-API client, system prompt, response parser |
| `PocketClaude/GitHub/` | REST client — the direct-API tool layer |
| `PocketClaude/Agent/` | Tool catalogue, executor, agent loop |
| `PocketClaude/Core/` | Keychain, settings, pairing link, address validation |
| `PocketClaude/Watch/` | The phone's side of the watch |
| `PocketClaudeWatch/` | The watch app: record, send, show |
| `relay/` | The Node relay, its tests, and the Windows scripts |

Roughly 8,000 lines of app, 2,400 of app tests, 1,400 of relay, 700 of relay
tests. 166 iOS tests and 52 relay tests, all hermetic.

## Documents

- [`STATUS.md`](STATUS.md) — where this stands: what works, what is unverified,
  what has been ruled out and why. Read this first when picking it back up.
- [`SETUP.md`](SETUP.md) — getting it on your phone
- [`relay/README.md`](relay/README.md) — the relay, its endpoints, its settings
- [`DECISIONS.md`](DECISIONS.md) — every choice and why, including the wrong ones
- [`ROADMAP.md`](ROADMAP.md) — what is next and what is not possible
- [`PHASE1_RESEARCH.md`](PHASE1_RESEARCH.md) — the original on-device limits study

## Security

Every secret lives in the iOS Keychain, entered at runtime, never committed and
never in `UserDefaults`. The relay is bearer-token authenticated with a
constant-time compare and is meant to sit on a Tailscale address, not the public
internet.

Anything the phone sends that becomes a command-line argument is allowlisted
rather than passed through — session ids, model names, effort levels, project
names. A session id that names a file to delete is resolved by matching against
files that already exist, never by building a path from the request.

On the direct-API path, write actions require spoken or tapped confirmation, and
commits to `main`, `master`, or the default branch are refused before the
request is built.
