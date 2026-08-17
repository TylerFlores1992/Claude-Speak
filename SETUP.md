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
3. **Bundle Identifier**: already set to `com.tylerflores.pocketclaude` (tests:
   `com.tylerflores.pocketclaude.tests`). Change it only if you want a different
   one — it just has to be globally unique, and free signing rejects an
   identifier someone else has already claimed.

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

## TestFlight (optional — needs a paid account)

Free signing expires every 7 days. If that gets old, the fix is the **Apple
Developer Program** ($99/yr), which unlocks App Store Connect and TestFlight.
Nothing in this project needs to change for it — the icon, the version strings,
and the encryption declaration are already set up for an upload.

**Internal TestFlight builds last 90 days and skip Beta App Review**, so this is
purely a distribution convenience: you never submit to the App Store, you never
talk to a reviewer. (External testing — up to 10,000 people — *does* require
review. You don't need it.)

### One-time setup

1. Enrol at [developer.apple.com/programs](https://developer.apple.com/programs/).
2. Register the bundle ID `com.tylerflores.pocketclaude` as an **explicit** App
   ID at [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
   — or just build once to a device with automatic signing and Xcode registers
   it for you. No capabilities need ticking; this app uses no entitlements.
3. In [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** →
   New App: pick iOS, your bundle ID, and any name that's still free (names must
   be unique across App Store Connect even for TestFlight-only apps).
4. Users and Access → add yourself as an **Internal Tester** if you aren't
   already on the team.

### Building without a Mac

`.github/workflows/ios.yml` runs everything on GitHub's macOS runners, so you
never need Xcode locally.

- **`build`** runs on every push: compiles and runs the tests, no secrets, no
  Apple account. This is your compiler.
- **`ship`** is manual only — Actions tab → **iOS** → **Run workflow** → tick
  *Archive and upload to TestFlight*. It signs, archives, and uploads, using
  `github.run_number` as the build number so it's always unique.

Add four repository secrets (Settings → Secrets and variables → Actions):

| Secret | Where to get it |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → **+**. The 10-character Key ID. Give it the **Admin** role — see below. |
| `APP_STORE_CONNECT_ISSUER_ID` | Same page, shown above the key list. A UUID. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The `.p8` file you download when creating the key — paste its **entire contents**, including the BEGIN/END lines. Apple lets you download it once. |
| `APPLE_TEAM_ID` | [developer.apple.com/account](https://developer.apple.com/account) → Membership. 10 characters. |

Give the API key the **Admin** role. App Manager is enough to *upload* a build,
but not to create the cloud-managed distribution certificate that signing needs
— that one is restricted to Admin and the Account Holder. A key without it fails
at export with `Cloud signing permission error` followed by a misleading `No
profiles for '...' were found`. A key's role can't be edited after creation, so
fixing this means revoking the key and generating a new one.

`-allowProvisioningUpdates` plus the API key lets Xcode create the distribution
certificate and provisioning profile on the runner, so there's no `.p12` to
export from a Mac you don't have.

The archive passes `CODE_SIGN_IDENTITY="Apple Distribution"` deliberately.
Automatic signing reads that setting to decide which kind of profile to mint,
and the iOS default (`Apple Development`) needs at least one **registered
device** — which a CI runner doesn't have, and which you can't easily add
without a Mac. A distribution profile needs no devices, and it's what an upload
wants anyway. If that still fails, the step retries with `CODE_SIGNING_ALLOWED=NO`
and lets `-exportArchive` do the signing instead.

Note macOS runners consume Actions minutes at **10×**, so a free-tier private
repo gets roughly 200 macOS minutes a month. If that bites, change the `build`
job's `on:` to only run on `main` and pull requests.

### Each upload (from a Mac)

```bash
# Bump the build number — App Store Connect rejects a build number it has seen.
agvtool next-version -all
```

Then in Xcode: destination **Any iOS Device (arm64)** → **Product → Archive** →
**Distribute App → TestFlight & App Store**.

Processing takes 5–15 minutes, then the build appears under TestFlight and the
TestFlight app on your phone offers the update.

### What's already handled

| Requirement | Where |
|---|---|
| 1024×1024 app icon, no alpha channel | `PocketClaude/Assets.xcassets/AppIcon.appiconset/AppIcon.png` |
| Version and build driven by build settings | `Config/Info.plist` uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`; `VERSIONING_SYSTEM = apple-generic` makes `agvtool` work |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` — the app only uses HTTPS through system APIs, which is exempt, so App Store Connect won't ask on every upload |
| Privacy strings | Microphone and speech-recognition descriptions are in `Config/Info.plist` |

The app icon is a placeholder waveform. Replace `AppIcon.png` with anything
1024×1024 and **without an alpha channel** — App Store Connect rejects icons that
have one.

### Worth knowing

- Your keys are **not** in the build. Every tester (i.e. you, on each device)
  enters their own in Settings; they live in that device's Keychain.
- Bumping the build number is the single most common upload failure. `agvtool
  next-version -all` before every archive avoids it.
- Archive builds use the **Release** configuration, which the unit tests don't
  exercise by default. Worth one `⌘U` before an upload.

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
