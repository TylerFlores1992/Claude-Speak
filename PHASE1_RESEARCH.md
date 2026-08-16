# Phase 1 research — how far can this get with nothing but the phone?

Written before the app code, and revised while building it. The question was:
**can a hands-free Claude agent that works against a GitHub repo run entirely on
an iPhone, with no server anywhere?**

Short answer: **yes for read, analyse, answer, and propose-changes-via-PR. No for
anything that needs a shell.** The rest of this document is the working.

---

## 1. Voice in — Apple's Speech framework

### What's available

`SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` + `AVAudioEngine`
gives streaming transcription from the live microphone with partial results. Two
permissions are required and both must be requested before the first recording:
`NSSpeechRecognitionUsageDescription` (via `SFSpeechRecognizer.requestAuthorization`)
and `NSMicrophoneUsageDescription` (via `AVAudioApplication.requestRecordPermission`,
which replaced `AVAudioSession.requestRecordPermission` in iOS 17).

### On-device recognition

`recognizer.supportsOnDeviceRecognition` reports whether the locale has a local
model; setting `request.requiresOnDeviceRecognition = true` then keeps audio off
Apple's servers entirely and works with no signal.

Caveats worth knowing, all of which the app handles or documents:

- **Not every locale has a model**, and the model may need to download after
  install, so `supportsOnDeviceRecognition` can be false on a fresh device and
  true later. The app checks per session and falls back to server recognition
  rather than failing.
- **On-device is less accurate** than server recognition, particularly on
  technical vocabulary — exactly the vocabulary this app deals in. It's a
  setting (`Prefer on-device recognition`, default on) rather than a hard rule.

### Hard limits I could not engineer around

- **Roughly one minute of audio per recognition request.** The framework stops
  tasks that run longer. For push-to-talk this is a non-issue — you don't hold
  the button for a minute — but it does rule out "leave the mic open all day".
- **~1000 recognition requests per hour, per device**, shared across all apps on
  the device. Push-to-talk usage is nowhere near this; a continuously restarting
  hands-free loop could approach it.

**Consequence for the design:** push-to-talk is the primary interaction, and
hands-free mode is explicitly a foreground-only, battery-hungry extra rather
than the headline feature.

### Background listening — not possible

iOS does not grant a general "keep the microphone open in the background"
capability to an app like this. The `audio` background mode keeps *playback*
alive; it does not license continuous recording for a non-VoIP app. Hands-free
mode therefore stops when the app is backgrounded, and the honest framing in the
UI is "keep the screen on if you want hands-free".

---

## 2. AirPods stem press — what iOS actually allows

This was the question I most wanted a real answer to, and the answer is a
qualified no with a usable workaround.

**There is no API for AirPods gestures.** A stem press, squeeze, or double tap is
an HID event that the system resolves against a fixed set of actions the user
picks in Settings → Bluetooth → AirPods. Third-party apps cannot register for the
gesture, cannot see the raw event, and cannot rebind it. The third-party apps
that claim to do this rely on background location, permanent microphone access,
or code injection into Bluetooth processes — all of which break App Store rules
and none of which are things I'd want running on a phone in my pocket.

**What does work:** AirPods behave like any other remote control. When the press
is mapped to play/pause, the system delivers a media transport command to the
current **Now Playing** app. If PocketClaude is that app, it receives the command
through `MPRemoteCommandCenter`.

So the app implements exactly that, as an opt-in setting
(`AirPod stem press starts talking`, see `Voice/RemoteCommandController.swift`):

1. Publish `MPNowPlayingInfoCenter` metadata and actually play audio (the TTS
   does this), which makes us the Now Playing app.
2. Handle `togglePlayPauseCommand`, `playCommand`, and `pauseCommand` — different
   accessories send different commands for the same physical press — and treat
   any of them as "start or stop listening".

**Be honest about what this costs:** it is a borrowed channel. Play something in
Spotify and Spotify becomes the Now Playing app; the stem stops reaching
PocketClaude until PocketClaude next speaks. There is no fix for that from inside
an app, and anyone claiming otherwise is describing a private API.

---

## 3. The brain — Anthropic Messages API, called directly

No SDK exists for Swift, which turns out not to matter: the Messages API is one
`POST` to `https://api.anthropic.com/v1/messages` with three headers
(`x-api-key`, `anthropic-version: 2023-06-01`, `content-type`). `URLSession` and
`JSONEncoder` cover it in about 80 lines (`Anthropic/AnthropicClient.swift`).

Things that specifically shaped the implementation:

- **Thinking is on by default on Claude Opus 5.** Responses contain `thinking`
  blocks carrying an opaque `signature`, and they must be echoed back on the next
  turn **unmodified** or the request is rejected. This is why conversation
  history stores raw `[JSONValue]` content blocks rather than decoded structs —
  a hand-written struct would silently drop fields we don't model. There's a test
  pinning the round trip (`testThinkingBlocksArePreservedVerbatim`).
- **`temperature` / `top_p` / `top_k` are rejected with a 400** on Opus 5. There's
  a test asserting we never send them, because it's the kind of thing someone
  adds back out of habit.
- **A refusal is an HTTP 200**, not an error status: `stop_reason: "refusal"` with
  empty or partial content. Code that reads `content[0]` unconditionally breaks
  on it, so `stop_reason` is checked first.
- `max_tokens` bounds thinking *plus* answer, so the default is 16,000 rather
  than something tuned to the size of the answer alone.

**No server is needed for any of this.** The API key sits in the iOS Keychain and
goes out in a request header from the phone. This is exactly the same trust model
as putting the key in a server's environment, minus the server.

---

## 4. The key insight — GitHub REST as the tool layer

This is what makes Phase 1 work at all.

Claude's tool use doesn't care *where* a tool runs. The API says "call
`read_file` with `{path: ...}`"; something executes it and hands back a
`tool_result`. Normally that something is a server with a cloned repo. It doesn't
have to be. It can be twelve Swift methods that call `api.github.com`.

The app defines twelve tools (`Agent/ToolCatalog.swift`), executed by
`Agent/ToolExecutor.swift` against `GitHub/GitHubClient.swift`:

| Tool | GitHub endpoint | Mode |
|---|---|---|
| `get_repo_info` | `GET /repos/{o}/{r}` | read |
| `list_repo_files` | `GET /repos/{o}/{r}/git/trees/{ref}?recursive=1` | read |
| `read_file` | `GET /repos/{o}/{r}/contents/{path}` | read |
| `search_code` | `GET /search/code` (with `text-match` media type) | read |
| `list_issues` / `get_issue` | `GET /repos/{o}/{r}/issues[/{n}]` | read |
| `list_pull_requests` / `get_pull_request` | `GET /repos/{o}/{r}/pulls[/{n}]` | read |
| `create_issue` | `POST /repos/{o}/{r}/issues` | write |
| `create_branch` | `GET git/ref` + `POST git/refs` | write |
| `put_file` | `PUT /repos/{o}/{r}/contents/{path}` | write |
| `create_pull_request` | `POST /repos/{o}/{r}/pulls` | write |

Everything runs on the phone. There is no relay, no proxy, and nothing to deploy.

### Practical limits of the REST-as-tools approach

- **`put_file` is a whole-file write, not a patch.** GitHub's contents API
  replaces a blob; there's no diff endpoint. So Claude has to read a file before
  editing it and send the complete new contents back. The tool description says
  so explicitly, because a model that guesses here produces a destructive commit.
- **Code search indexes the default branch and lags recent pushes.** The tool
  result says so on an empty result, so Claude falls back to
  `list_repo_files` + `read_file` instead of concluding the code doesn't exist.
- **Tool results go straight into the context window**, so they need caps.
  `read_file` truncates at 60,000 characters and says it truncated;
  `list_repo_files` caps at 800 entries and tells Claude to narrow with a prefix.
- **Rate limits are GitHub's** (5,000 REST requests/hour for a PAT, 30/minute for
  code search). A voice session makes single-digit calls per turn, so this is
  slack, not a constraint.
- **Files over 1 MB** don't return content through the contents API. This is
  reported as a decoding error rather than silently returning nothing.

---

## 5. Voice out — free by default

`AVSpeechSynthesizer` is free, offline, and instant. The only real work is
making Claude produce something *worth* speaking: a summary in
`spoken_summary` with no code, no markdown, and no file paths read as
punctuation, plus a `detail` body for the screen. That contract lives in the
system prompt, and `Anthropic/ResponseParser.swift` degrades through four
strategies if the model drifts out of format, because a voice app that reads raw
JSON into your ear is worse than useless.

Background playback with the screen off needs `UIBackgroundModes: audio` in
Info.plist plus an `AVAudioSession` category of `.playback`. Recording needs
`.playAndRecord`. The app switches between them rather than staying in
`.playAndRecord`, because `.playAndRecord` on a Bluetooth headset forces the
low-quality HFP path and every answer would sound like a phone call.

ElevenLabs is behind a settings toggle with its own Keychain entry, and falls
back to the system voice if a request fails so you never end up in silence
because a paid API had a bad minute.

---

## 6. The honest ceiling — what Phase 1 cannot do

None of these are missing features; they are consequences of there being no
computer other than the phone.

- **No shell.** No `grep`, no `git`, no `npm`, no `rg`. Every repository
  operation has to map to a REST endpoint, which is why there is no "rename this
  symbol everywhere" tool.
- **No test runner.** Claude cannot verify a change it proposes. Everything it
  writes is unverified until CI runs on the PR. This is the single biggest
  practical limitation.
- **No build, no typecheck, no lint.** A commit can be syntactically broken and
  the app will happily open a PR for it.
- **No dev server, no preview, no runtime behaviour.** It cannot reproduce a bug,
  only read the code around it.
- **No local diff.** Changes are whole-file writes composed from what Claude
  read, not patches applied to a working tree. Long files are riskier to edit
  than short ones.
- **No cross-repo work**, no dependency inspection, no reading anything that
  isn't in the repo or the model's training.
- **Context is the budget.** Reading four large files can cost more context than
  the answer is worth. Prompt caching on the stable prefix (system + tools) helps
  a lot; reading a whole `src/` tree still doesn't fit.

Where the ceiling actually bites, in the order you'll hit it:

1. "Does this change pass the tests?" — can't answer.
2. "Refactor X across the codebase" — too many whole-file writes, no verification.
3. "Why is this failing in production?" — no logs, no runtime, no Vercel access.

Everything above the ceiling — "what does this code do", "where is X handled",
"summarise the open TODOs in the hold lifecycle", "draft a fix and open a PR for
me to review on a laptop" — works, and is what a phone in your pocket is actually
good for.

`ROADMAP.md` describes what a small container would add and where the switch
between the two modes would live.

---

## Sources

- [Use controls and gestures with your AirPods — Apple Support](https://support.apple.com/guide/airpods/use-controls-and-gestures-with-your-airpods-devb2c431317/web)
- [Supporting AirPods in your iOS and tvOS media apps — David Cordero](https://dcordero.medium.com/supporting-airpods-in-your-ios-and-tvos-media-apps-f313a95834b2)
- [MPRemoteCommandCenter behaviour with remote transport controls — Apple Developer Forums](https://developer.apple.com/forums/thread/4036)
- [iOS speech recognition limits (duration and per-device request rate)](https://picovoice.ai/blog/ios-speech-recognition/)
- [SFSpeechRecognizer timeout behaviour — Apple Developer Forums](https://developer.apple.com/forums/thread/82839)
- [Continuous on-device speech recognition — Apple Developer Forums](https://developer.apple.com/forums/thread/131940)
