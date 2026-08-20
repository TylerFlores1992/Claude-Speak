# Decisions

Every choice made without asking, and why. Where a decision is easy to reverse,
that's noted.

---

## Architecture

### The GitHub REST API is the tool layer

The thing that makes a serverless agent possible. Claude's tool-use protocol
doesn't care where a tool executes — it emits `tool_use`, something returns
`tool_result`. Normally that something is a server with a cloned repo; here it's
twelve Swift methods hitting `api.github.com` from the phone. See
`PHASE1_RESEARCH.md` §4 for the endpoint mapping and its limits.

### Manual agent loop, not a streaming one

There is no Anthropic Swift SDK, and the loop is about forty lines:
call → append the assistant turn verbatim → execute tools → append all
`tool_result` blocks in one user message → repeat until `stop_reason` isn't
`tool_use`.

Non-streaming was chosen deliberately. Streaming would let the transcript fill in
token by token, but the *spoken* answer can't start until the text is complete
anyway (we speak a summary, not a running commentary), so streaming would add SSE
parsing and partial-state handling for no user-visible gain. The tool-progress
events in the status bar cover "is it still working?".

**Reversible:** swap `AnthropicClient.send` for a streaming variant; nothing else
in the loop changes.

### Conversation history stores raw JSON content blocks

`ChatMessage.content` is `[JSONValue]`, not typed structs. Claude Opus 5 thinks
by default and returns `thinking` blocks with an opaque `signature` that must be
echoed back **unmodified** or the next request is rejected. Decoding into
hand-written structs would silently drop fields we don't model. There's a test
pinning this (`testThinkingBlocksArePreservedVerbatim`).

### Twelve tools, not five and not thirty

Enough to read a repo properly (tree, file, search, issues, PRs) and to make a
change the sanctioned way (branch → commit → PR). Fewer would force Claude to
guess; more would spend context on schemas it rarely uses.

`get_repo_info` exists because every other tool needs the default branch, and
having Claude ask for it explicitly beat threading it through every schema.

### `ToolExecutor` is an actor

It caches the repository's default branch for the session. An `actor` gives that
mutable state thread safety for free, without locks, which matters because tool
calls in one assistant turn are executed in sequence from a non-isolated context.

---

## Model and API

### Claude Opus 5 by default, `effort: high`

Opus 5 is the current flagship and the app's whole job is reasoning about code
you can't see. The model picker offers Sonnet 5 and Haiku 4.5 for when you want
cheaper and faster; the default is not cost-optimised, because a wrong answer
about your own codebase costs more than the tokens did.

`effort` defaults to `high` — the API default and the right floor for
intelligence-sensitive work. `medium` is a reasonable everyday setting for a
phone; the picker exposes `low` through `max`.

### `max_tokens` defaults to 16,000

Thinking counts against `max_tokens`, so a budget sized for the answer alone
truncates mid-thought. 16,000 is the safe non-streaming default (higher risks SDK
HTTP timeouts, which is also why the URLSession timeout is 300s).

### Thinking and effort are gated by model

Adaptive thinking and `output_config.effort` arrived with Claude 4.6. Haiku 4.5
predates both and rejects either with a 400, so `Configuration` carries a
`supportsAdaptiveThinking` flag driven by the picked model, and the request body
simply omits both fields for older models. Structured output still works there.
Without this, picking Haiku in the settings picker would break every request.

### No sampling parameters, ever

`temperature`, `top_p`, and `top_k` are rejected with a 400 on Opus 5. There's a
test asserting the request body never contains them, because it's exactly the
sort of thing that gets added back out of habit.

### Prompt caching on the system prompt

Tools + system prompt are byte-identical across every turn in a session, so a
single `cache_control: ephemeral` breakpoint on the system block makes every turn
after the first read them at ~10% of input price. This is why `SystemPrompt.build`
takes the default branch as a parameter and is built once per turn rather than
being assembled with anything volatile in it.

### Structured output is opt-in, off by default

The API can enforce the `{spoken_summary, detail}` schema via
`output_config.format`. It's a settings toggle rather than the default because:

- the system prompt alone gets the format right nearly always, and the parser
  handles the rest;
- a new schema costs a one-time compilation latency on the first request;
- it's one fewer thing interacting with the tool loop.

Turn it on if you see the model drifting out of format. The parser handles both
paths identically.

### Refusals are surfaced, not swallowed

`stop_reason: "refusal"` arrives as an HTTP 200 with empty or partial content. The
client checks `stop_reason` before touching `content` and throws a typed
`.refused(category:)`. Server-side `fallbacks` were **not** wired up — for a
personal tool asking questions about your own repository, a refusal is worth
seeing rather than silently re-routing to another model.

---

## The response contract

### Claude answers with `{"spoken_summary": ..., "detail": ...}`

The single most important design decision for a voice app. The system prompt is
explicit about what belongs in each: `spoken_summary` is conversational, under 60
words, no code, no markdown, no file paths ("the hold capacity constant, in the
holds library" — not "RC_HOLD_CAPACITY in lib/holds/capacity.ts:42").

### The parser degrades in four steps

Models are not perfectly reliable about output format, and reading raw JSON into
someone's ear is worse than no answer:

1. Whole body parses as the object.
2. A fenced or brace-balanced object inside prose does.
3. A `Spoken:` / `Summary:` label prefix.
4. Heuristic: strip fenced code and markdown, take the first two sentences.

Fifteen tests cover these paths including malformed JSON and braces inside
strings.

### Paths and branches are rewritten for speech

`src/lib/holds.ts` read aloud is unusable. `ToolCatalog.spokenPath` turns it into
"holds dot ts, in src lib", and `spokenBranch` turns `fix/hold-decline` into
"fix slash hold decline". Only used in spoken confirmations, where you're
deciding whether to approve a write without looking at the screen.

---

## Safety

### Writes require confirmation, always

`AgentRunner` gates every write tool behind an `async` confirmation callback. The
prompt is spoken and shown; you answer by tapping **Confirm**/**Cancel** or by
holding the talk button and saying "confirm"/"cancel". An ambiguous spoken answer
asks again rather than guessing — guessing wrong on a write is unrecoverable in a
way that guessing wrong on a read is not.

Declining returns an error `tool_result` saying *"The user declined this action.
Do not retry it."* so Claude adapts rather than looping.

### Never push to main — enforced in three places

1. The system prompt says branch-and-PR only.
2. `GitHubClient.guardBranch` rejects `main`, `master`, `trunk`, `release`,
   `production`, and the repository's actual default branch — before any network
   call.
3. Write tools are only in the tool list when writes are enabled, and
   `AgentRunner` refuses a write tool call outright if they aren't.

Prompts can be argued with. The guard cannot; it throws before the request is
built and there is no flag to disable it.

### Secrets only in the Keychain

`kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlock`. Never
`UserDefaults` (a readable plist in the app container), never `@AppStorage`,
never a committed file. `.gitignore` blocks the obvious accidents from the first
commit. The Settings UI is write-only — a saved key cannot be read back out.

### Session file is written with complete file protection

Transcripts quote private source code, so `pocketclaude-session.json` is written
with `.completeFileProtection` — encrypted at rest while the device is locked.

### Tool results are capped

`read_file` truncates at 60,000 characters (and says so), `list_repo_files` at
800 entries (and says to narrow with a prefix), PR patches at 4,000 characters
each. Tool results go straight into the context window; an uncapped tool is a
bill waiting to happen.

### The agent loop stops at 12 iterations

A confused model asking for tools forever would bill indefinitely. At the ceiling
it returns a spoken "I hit the tool limit — ask me to continue" and leaves the
conversation intact.

---

## Voice

### Two audio session categories, switched

`.playAndRecord` while recording, `.playback` (mode `.spokenAudio`) while
speaking. Staying in `.playAndRecord` the whole time is simpler but forces
Bluetooth headsets onto the low-quality HFP path, so every answer would sound
like a phone call. `.playback` plus `UIBackgroundModes: audio` is also what keeps
TTS alive with the screen off.

### Push-to-talk is primary; hands-free is an explicit trade

Apple's speech framework stops a recognition task after roughly one minute, and
limits a device to ~1000 recognition requests per hour across all apps. Neither
matters for press-and-hold. Both matter for an always-listening loop, which is
also foreground-only (iOS doesn't grant background microphone access to an app
like this) and noticeably battery-hungry. Hands-free is a toggle with that stated
plainly in its footer, not the headline feature.

### On-device recognition preferred but not required

Keeps audio off Apple's servers and works with no signal — but not every locale
has a model, the model may download after install, and on-device is less accurate
on technical vocabulary. So: default on, automatic fallback, and a toggle.

### AirPod stem press implemented as far as iOS allows

There is no API for AirPods gestures. The workaround — become the Now Playing app
and read the play/pause command a squeeze produces via `MPRemoteCommandCenter` —
is implemented as an opt-in setting, with its real limitation stated in the UI:
it stops working when another app takes the Now Playing slot. See
`PHASE1_RESEARCH.md` §2.

### System voice by default, ElevenLabs optional

`AVSpeechSynthesizer` is free, offline, and instant. ElevenLabs is a toggle with
its own Keychain entry and the low-latency `eleven_turbo_v2_5` model, and falls
back to the system voice on failure rather than leaving you in silence.

---

## UI

### One screen

Transcript, status, talk button. Anything you'd need two screens for is something
you'd take the phone out of your pocket for anyway, which is what the **Detail**
disclosure is for.

### Cost estimate in the status bar

Accumulated from `usage` on every response, priced at public list rates including
the 1.25× cache-write and 0.1× cache-read multipliers. It's an estimate for
awareness, not an invoice — and unknown model IDs fall back to Opus pricing so
it's never a pleasant surprise. During Sonnet 5's introductory pricing period the
estimate reads high.

### Typed input as a fallback

Speech recognition mangles repository names and unusual identifiers. The keyboard
button exists for those, and for when you can't talk.

---

## Testing

### Everything hermetic, via `URLProtocol`

`MockURLProtocol` answers every request from a closure, so the full networking
layer is testable with no network, no keys, and no repo. The one wrinkle worth
knowing: `URLProtocol` moves `httpBody` into `httpBodyStream`, so
`MockURLProtocol.body(of:)` drains the stream — otherwise every body assertion
silently passes against empty data.

### What's covered

The two layers the prompt asked for, plus the two that turned out to be riskiest:

- **Tool-call layer** — URL construction, auth headers, base64 with embedded
  newlines, truncation, the branch guard (including "no request was made"),
  error mapping.
- **Response parsing** — all four degradation paths, malformed JSON, braces
  inside strings.
- **Agent loop** — tool round trip, usage accumulation, message ordering, the
  confirmation gate (approve / decline / writes-disabled), the iteration ceiling.
- **Supporting types** — JSON round-tripping of unknown fields, cost maths,
  session persistence, system-prompt contents, settings parsing.

### Not covered

The speech and audio layers. `AVAudioEngine`, `SFSpeechRecognizer`, and
`AVSpeechSynthesizer` need real hardware and real permissions; testing them
meaningfully means a device UI test, which is in `ROADMAP.md` rather than here.

---

## Build

### Hand-written `.xcodeproj` with folder-synchronised groups

`objectVersion = 77` (Xcode 16) lets a target reference a *folder* rather than
enumerating every file with a UUID. Adding a Swift file means adding a Swift
file — no project churn, no merge conflicts in `project.pbxproj`. Cost: it needs
Xcode 16+. `project.yml` is committed as an XcodeGen fallback, and `SETUP.md`
documents the manual route.

### Explicit `Config/Info.plist`, not generated keys

`UIBackgroundModes` is an array, and the generated-Info.plist build settings are
awkward for arrays. An explicit plist is also just easier to read — it's where
the two permission strings live, and you should be able to see them. It sits
outside the synchronised folder so it isn't also copied in as a resource.

### ATS: `NSAllowsArbitraryLoads`, because the relay speaks plain HTTP

The relay is reached at `http://100.x.y.z:8788` over Tailscale, and iOS blocks
cleartext by default — without an exception every relay request fails with "App
Transport Security policy requires the use of a secure connection".

The narrower keys don't fit. `NSAllowsLocalNetworking` covers `.local`,
unqualified hostnames, and RFC 1918 addresses; Tailscale hands out
`100.64.0.0/10` (CGNAT), which it doesn't cover. `NSExceptionDomains` has to
name a specific host, and the address is whatever you type into Settings.

The traffic isn't actually unprotected: Tailscale is WireGuard, so it's
encrypted at the network layer. Terminating TLS on the relay would mean managing
a certificate in order to re-encrypt an already-encrypted tunnel — which is
exactly the setup burden the Tailscale choice existed to avoid. The exception
also doesn't weaken anything else: HTTPS calls still negotiate TLS normally, and
it only permits cleartext where the URL asks for it.

### iOS 17, iPhone only, no third-party dependencies

iOS 17 unlocks `AVAudioApplication.requestRecordPermission` and the two-parameter
`onChange`. Zero dependencies: `URLSession` over Alamofire, hand-rolled JSON over
SwiftyJSON, `Security.framework` over KeychainAccess. The app is ~3,900 lines
plus ~1,500 lines of tests — readable in an evening.

---

## Nothing is stubbed

There are no `// TODO(TYLER):` markers in the code. Both credentials are entered
at runtime through Settings, so nothing was blocked on a secret only you can
provide. What's *absent* is absent by design — see the honest-limits section of
`PHASE1_RESEARCH.md` and the "what's next" section of `ROADMAP.md`.

## Sessions are merged by making the relay the home, not by reaching into the cloud

The Claude app's Code tab lists sessions running on Anthropic's infrastructure.
The obvious goal was to show those in this app. Three routes were investigated
and two are closed:

- **Listing them** — no API, and no non-interactive CLI. `claude agents --json`
  covers local sessions only.
- **Attaching to one** — `claude --cloud <id>` does attach a terminal to a
  running cloud session, but the docs state plainly that `--output-format
  stream-json` is unsupported with it. The relay could attach and then have no
  way to speak anything to the phone.
- **`--teleport`** — works, and is what the cloud button uses, but it makes a
  *copy*. The cloud session keeps running and the two diverge immediately.

The direction that actually works is the inverse. `claude remote-control` is a
server that serves *local* sessions to claude.ai and the Claude app. Run it on
the relay machine and a session is simultaneously live on the phone, in a
browser, and in the Claude app — one session, three surfaces — and it lands in
`~/.claude/projects` like any other local session, so the dashboard lists it
with nothing extra to build.

So: stop trying to import their sessions, and export ours instead. The green dot
on a dashboard row marks a session that is live under this arrangement, because
resuming one is walking into a running conversation rather than reopening a
transcript.

The catch is honest and unresolved: Remote Control is a research preview behind
a feature flag, and it has not yet been confirmed available on this account.

## Archiving hides; deleting removes

Claude Code has no archive — a session is a transcript file that exists or does
not. Archive is therefore this relay keeping a list of hidden ids; the file
stays and `claude --resume` still works at a keyboard. Delete unlinks the file
and cannot be undone, so it is the swipe that confirms first, and full-swipe is
disabled because iOS runs the first action on a full swipe and "flick left,
session gone" is the wrong ergonomics beside a destructive button.

The id comes from the phone and ends up naming a file to unlink, so it is
resolved by matching against files that already exist under `~/.claude/projects`
and refused if it is shaped like a path — the same rule as every other value
this app sends that becomes an argument.
