# Setup — from clone to talking into an AirPod

Target: **20 minutes**, most of it waiting for Xcode. No paid Apple Developer
account needed; free personal-team signing is enough.

## What you need

| | |
|---|---|
| Mac with **Xcode 16 or newer** | The project uses Xcode 16's folder-synchronised groups. If you're on Xcode 15, see [If Xcode won't open the project](#if-xcode-wont-open-the-project). |
| iPhone running **iOS 17 or newer** | Plus a Lightning/USB-C cable for the first install. |
| An **Anthropic API key** | [console.anthropic.com](https://console.anthropic.com) → API Keys. |
| A **GitHub personal access token** | See [Making the GitHub token](#making-the-github-token) below. |
| AirPods (optional) | Any Bluetooth headset works; AirPods just make the pocket case pleasant. |

---

## 1. Open and sign

```bash
git clone <this repo>
cd Claude-Speak
open PocketClaude.xcodeproj
```

In Xcode:

1. Select the **PocketClaude** target → **Signing & Capabilities**.
2. **Team**: pick your personal team (your Apple ID). If none is listed, add your
   Apple ID under Xcode → Settings → Accounts first.
3. **Bundle Identifier**: change `com.pocketclaude.PocketClaude` to something
   unique to you — `com.tylerflores.PocketClaude`. Free signing rejects an
   identifier someone else has already claimed.
4. Do the same for the **PocketClaudeTests** target (`…PocketClaudeTests`).

You do **not** need to add any capabilities by hand — background audio, the
microphone description, and the speech-recognition description are already in
`Config/Info.plist`.

## 2. Run it on the phone

1. Plug the iPhone in and pick it as the run destination (top of the Xcode window).
2. Press **⌘R**.
3. First run will fail with *"Untrusted Developer"*. On the phone:
   **Settings → General → VPN & Device Management → your Apple ID → Trust**.
4. Press **⌘R** again.

Grant the microphone and speech-recognition prompts when they appear.

> **Free signing expires after 7 days.** The app stops launching and you re-run
> ⌘R from Xcode to refresh it. Your keys and session survive — they're in the
> Keychain and app container, not the build. A paid account ($99/yr) extends this
> to a year.

## 3. Add your keys

Tap the **gear** icon in the app.

- **Anthropic API key** → paste → **Save**
- **GitHub token** → paste → **Save**
- **Repository** → `owner/repo`, e.g. `tylerflores1992/camphawk`

Both keys go straight into the iOS Keychain. The field clears itself after
saving, and there is no way to read a saved key back out of the UI — if you need
to change one, paste a new value and save again.

## 4. Talk to it

Put an AirPod in. Hold the big button, say:

> "What does the hold lifecycle code do in my repo?"

Release. You'll see the tools it calls scroll past on screen, then hear a short
spoken answer with the full detail on screen behind the **Detail** disclosure.

Try a write, too:

> "Draft a fix for the offered-to-requested hold decline path and open a PR."

It will read out something like *"Create the branch fix slash hold decline.
Confirm?"* — say **"confirm"** (hold the button) or tap **Confirm**. Nothing is
written to GitHub until you do.

---

## Making the GitHub token

Use a **fine-grained** token: [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)

- **Repository access**: Only select repositories → pick your repo.
- **Permissions**:

| Permission | Set to | Needed for |
|---|---|---|
| Contents | **Read-only** | reading files, listing the tree |
| Metadata | Read-only (automatic) | repo info |
| Issues | Read-only | listing/reading issues |
| Pull requests | Read-only | listing/reading PRs |

That's everything for read-only use. If you want Claude to be able to open PRs,
upgrade two of them:

| Permission | Set to |
|---|---|
| Contents | **Read and write** |
| Pull requests | **Read and write** |
| Issues | Read and write (only if you want it filing issues) |

A classic token with the `repo` scope also works and is quicker to make, but it
grants access to every repository you can see — the fine-grained one is worth the
extra minute.

**Note on code search:** GitHub's code search API indexes the repository's
default branch and can lag recent pushes. If Claude says it can't find something
you know is there, ask it to list the directory and read the file directly.

---

## Running the tests

**⌘U** in Xcode, or:

```bash
xcodebuild test \
  -project PocketClaude.xcodeproj \
  -scheme PocketClaude \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The tests are hermetic — every HTTP call is stubbed through `MockURLProtocol`,
so nothing touches the network, your keys, or your repo. They cover the GitHub
tool layer (URLs, auth headers, base64 decoding, the never-push-to-main guard),
the response parser, the agent loop including the confirmation gate, cost
estimation, and session persistence.

---

## Everyday use

| Control | What it does |
|---|---|
| Hold the big button | Record; release to send |
| Hold it again while Claude is speaking | Interrupts and starts a new question |
| ↺ (toolbar) | Re-read the last answer |
| ✎ (toolbar) | New session — clears history and cost |
| ⌨ (toolbar) | Type instead of talking |
| Cost figure (status bar) | Running estimate for this session |

**AirPod stem press** (Settings → *AirPod stem press starts talking*) works when
PocketClaude is the Now Playing app — which it becomes after it speaks. Start
music in another app and the stem goes back to that app until PocketClaude
speaks again. This is an iOS constraint, not a bug; `PHASE1_RESEARCH.md` §2
explains why there's no way around it.

**Hands-free mode** keeps the mic open while the app is in the foreground and
sends when it hears your end keyword ("done" by default). It costs battery and
stops when you background the app — push-to-talk is the mode to live in.

---

## If Xcode won't open the project

The `.xcodeproj` here is hand-written and uses `objectVersion = 77`
(folder-synchronised groups), which needs **Xcode 16+**. If your Xcode refuses
it, regenerate the project from the same sources:

```bash
brew install xcodegen
xcodegen generate      # rewrites PocketClaude.xcodeproj from project.yml
open PocketClaude.xcodeproj
```

If you'd rather not install anything, the manual route works too: File → New →
Project → iOS App (SwiftUI, name it `PocketClaude`), delete the generated
`ContentView.swift` and `PocketClaudeApp.swift`, then drag the `PocketClaude/`
and `PocketClaudeTests/` folders in with *Create groups* checked, and set
`INFOPLIST_FILE` to `Config/Info.plist` with `GENERATE_INFOPLIST_FILE = NO`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "No Anthropic API key" | Key not saved yet, or saved to a different install. Re-enter it in Settings. |
| "GitHub HTTP 403: Resource not accessible by personal access token" | The token's permissions are too narrow, or the repo isn't in its *Selected repositories* list. |
| "GitHub HTTP 404" on a repo you own | Fine-grained token that doesn't include this repository. |
| Button does nothing, no listening state | Microphone or speech permission denied. iOS Settings → PocketClaude. |
| Nothing is spoken but text appears | Silent switch, volume, or the audio route went to the phone speaker. Check the Now Playing route. |
| ElevenLabs silent | The app falls back to the system voice on failure and shows the error in Settings; check the key and voice ID. |
| Answers cut off mid-sentence | `max_tokens` too low for the effort level. Raise it in Settings (thinking counts against it). |
| Very slow answers | Effort is `high` by default. `medium` is a good trade for quick questions. |
| App won't launch after a week | Free-signing expiry. Re-run from Xcode (⌘R). |
