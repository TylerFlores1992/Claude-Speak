# Where this stands

Updated after the session that got the cloud lane working end to end for the
first time, watched a history pull land from a live cloud session, and fixed
the environment that had been quietly breaking both. Read this first when
picking the project back up.

The iOS app is finished for now and **unchanged by any of the Android work
below** — that was the condition it was done under, and `git status` was checked
against `PocketClaude/`, `relay/` and `ios.yml` on every commit.

Merges, in order:

| | |
|---|---|
| `a99293d` | A pending history pull survives a relay restart (`pulls.json`) |
| `8df72f8` | Two swallowed errors, the alert's baked-in spacing, `install-hook.ps1` shape check |
| `8857b78` | The hook-install recipe said one file when it needs two |
| `4964208` | A dropped hop costs the hop, not the whole wait |
| `f225c83` | This document, rewritten |
| `a80047f` | Android: skeleton and CI |
| `e7fd069` | Android: SSE parser and request builder |
| `e0bbe65` | Android: turn assembly, HTTP client, settings |
| `6e0ae93` | Android: protocol moved to a JVM module that tests locally |

**The relay machine needs a `git pull`.** It is now several merges behind and
relay changes do not ride TestFlight. It has not been done.

TestFlight shipped twice, from `8df72f8` and from `4964208`. A third attempt in
between was **cancelled mid-upload** — see the concurrency hazard below.

## The setup

- **Phone**: PocketClaude via TestFlight. No Mac exists in this project —
  every build is GitHub Actions (`.github/workflows/ios.yml`), delivered to
  TestFlight. `workflow_dispatch` with `upload_to_testflight: true` ships.
- **Relay**: `C:\code\Claude-Speak` on a Windows mini PC, started by the
  "PocketClaude relay" scheduled task at logon (`relay/install-autostart.ps1`),
  serving `C:\code\campsite-finder` (the CampHawk repo, actual name
  `campsite-finder`). Reached over Tailscale at `100.119.76.63:8788`, and from
  the cloud through Tailscale Funnel at
  `https://desktop-mdc5q6e.tailef3c66.ts.net/answer`.
- **Cloud sessions**: created in the Claude app, added here by link. The Stop
  hook that answers them is committed to `campsite-finder` on `master`, to this
  repository in `.claude/`, and to `Threaded_Hope` on `main`.
- **Watch**: Apple Watch SE3, paired, working.
- **Branch**: all work on the session's assigned `claude/…` branch,
  squash-merged to `main` via PR, then the branch is reset onto `main`.

## What works, confirmed on hardware

- Voice question → relay → Claude Code → spoken answer, phone pocketed.
- **The watch, with the phone locked.** Tap Ask, talk, tap Send. The watch
  records audio, transfers the file, the phone transcribes it and answers.
- **The Claude-Speak cloud lane, end to end.** A cloud session on *this*
  repository answered the phone. Previously only `campsite-finder` had ever
  completed the round trip.
- **History, against a live cloud session over the Funnel.** This was the one
  feature built end to end and never seen running. It has now been seen. It is
  no longer an open thread.
- Sessions dashboard: cloud sessions first, then the relay machine's own,
  grouped by repository. Swipe to rename, archive, delete, or remove.
- Markdown rendering, model/effort chips, typed input, one-tap pairing.
- Relay update from the phone, when running under `run.ps1`.

## Mechanism, learned the hard way

This section is worth more than the fixes it came from. Two separate cloud
sessions got the first item wrong, in opposite directions, and one of them
recommended abandoning the architecture over it.

- **Tailscale Funnel hostnames are public, not tailnet-only.** A cloud
  container resolves them: `getent` returns `2607:f740:0:3f::3cc` from inside a
  session that is not a tailnet member. The *tailnet* address
  (`100.119.76.63`) is member-only; the funnel host is not. Do not re-derive
  this, and do not accept "MagicDNS only resolves for tailnet members" as a
  reason the design cannot work.
- **Environment and network-policy changes apply only to sessions started
  afterward.** A running session keeps the values it was born with for its
  whole life. Any environment change must be tested in a *new* session; the
  current one can never confirm it, however many times you retry.
- **Reading the reachability test.** `401` from a bare `GET` on `/answer` is a
  **pass** — the tunnel opened and the relay answered. `000` with `CONNECT
  tunnel failed, response 403` is the egress block.
- **Merging to `main` cancels an in-flight TestFlight ship.** `ios.yml` sets
  `concurrency: group: ios-${{ github.ref }}` with `cancel-in-progress: true`,
  so a push to `main` and a `workflow_dispatch` on `main` share a group. Merging
  a docs pull request killed run 216 six seconds before its upload finished, and
  the step showed `cancelled` rather than failed, which reads like nothing
  happened. **Merge everything first and dispatch the ship last.** `android.yml`
  deliberately uses a different group so it can never do this.
- **A history pull rides the next turn that finishes *in the session*,** from
  any surface — not the next thing you say in PocketClaude. One landed via an
  unrelated command run in the Claude app. Nothing signals when it arrives; the
  app simply has it next time you open the screen. This is by design and is not
  a bug, and it is the explanation for a pull that looks lost.

## Environment configuration that is known good

The **Default** cloud environment (`env_016SUUYfPcrmTXTeKNnxqQQW`):

| | |
|---|---|
| `RELAY_ANSWER_URL` | `https://desktop-mdc5q6e.tailef3c66.ts.net/answer` |
| `RELAY_HOOK_DEBUG` | `1` |
| `RELAY_ANSWER_TOKEN` | matches the relay — proven by a delivered answer, not by reading it |
| Network access | **Custom**, allowed domain `desktop-mdc5q6e.tailef3c66.ts.net`, with *"Also include default list of common package managers"* ticked |

A literal trailing `+` in `RELAY_ANSWER_URL` was the original bug. It is gone.

Re-confirmed from a session started after the fix: the URL is correct, the
funnel host resolves, and `GET /answer` returns 401.

**Threaded Hope** (`env_017fxpjnM2HYnGcjWUwCjRcN`) was set up the same way
afterwards, and `Threaded_Hope` got the hook it had never had — the repository
had no `.claude` directory at all, which is why a session there took a message
and answered nothing.

That lane is now **probe proven**: the phone stopped showing the missing-hook
alert for it, and the relay only stops saying `hookMissing` once it has
*recorded a probe from that session*. Since the hook probes before it sends
anything, that single fact establishes three things at once — the hook is
installed and running, `RELAY_ANSWER_TOKEN` matches, and the network policy
lets it out. What has still not been seen is an actual **answer** arriving from
it; the attempt that would have shown one died on the phone's own connection,
which is what `4964208` fixes.

**CampHawk** (`env_01NNXGWqS3cK1KTqhy4dH3JF`) is the one still in doubt — see
open thread 1. The environment list exposes names but no variable *values*, so
a token mismatch cannot be diagnosed by reading it; only by testing from a
session started afterward.

## Restarting the relay

`Start-ScheduledTask` can report `LastTaskResult 0` while the **old** process
still holds port 8788. The new instance cannot bind, exits silently, and the
old one keeps serving — so the restart appears to succeed and changes nothing.
Only a fresh PID on the port proves it:

```powershell
Stop-ScheduledTask -TaskName "PocketClaude relay"
Get-NetTCPConnection -LocalPort 8788 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName "PocketClaude relay"
Start-Sleep -Seconds 5
Get-NetTCPConnection -LocalPort 8788 -State Listen |
  ForEach-Object { Get-Process -Id $_.OwningProcess } |
  Select-Object Id, StartTime
```

## What is built but never verified against reality

Be honest about these rather than describing them as working:

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
- **`relay/install-hook.ps1`** — has still never been run, because there is no
  PowerShell in the build environment. Its verification step was strengthened
  by reading, and the JavaScript half of that step *was* executed against every
  failure shape, but the PowerShell around it has not been. The `[object[]]`
  casts on the write side are untested belt; the check is the braces.
- **The hop retry** (`4964208`) — compiled, and its three tests pass in CI
  against a real `URLError` driven through the stub. Not seen surviving a real
  dropped connection on a phone. The failure it repairs *was* seen on hardware,
  twice; the repair has not been.
- **An answer from a Threaded Hope session.** The hook probes (above), so the
  path is established as far as the relay. Nothing has been heard back yet.

## The Android client

A Pixel 11 and a Pixel Watch 2 arrive on Wednesday, so `android/` is a second
client of the same relay. **The relay needs no changes for it** — `relay/` is
plain HTTP, SSE and a bearer token and does not know what is on the other end,
which is what makes a second client cheap rather than a port.

Stated by how far each piece is actually proven, because that distance is the
whole story here:

| | |
|---|---|
| `core/` — SSE framing, request building, turn assembly | **Tested.** 39 unit tests, run locally *and* in CI |
| `RelayClient` — one POST and a read loop | **Compiled.** Never pointed at a relay |
| `Settings` — address and token | **Compiled.** Never read or written on a device |
| Phone UI, speech in and out | Placeholder / not started |
| The watch | Placeholder. Its topology is settled, below |
| Signing, Play listing | Not started. The Play account is paid for |

**Nothing has run on a phone.**

### Two constraints that are settled, not open questions

**Tailscale does not run on Wear OS.**
[tailscale/tailscale#3972](https://github.com/tailscale/tailscale/issues/3972)
has been open since February 2022 with no assignee and no linked pull requests,
labelled "L1 Very few" likelihood;
[#12177](https://github.com/tailscale/tailscale/issues/12177) has the APK
closing instantly on a Galaxy Watch. So the watch **cannot** reach the relay:
the tailnet address is member-only, and the funnel publishes only `/answer`
because mounting `/ask` would put Claude Code on the public internet.

The watch therefore talks to the phone over the Wear Data Layer, and the phone
owns the network. Same topology as the Apple Watch — but *less* work, because
[`RecognizerIntent` runs on Wear OS](https://developer.android.com/training/wearables/user-input/voice),
so the watch transcribes locally and sends a string rather than a WAV. The
phone-side transcription stage disappears.

**`dl.google.com` is egress-blocked from the build container**, so the Android
SDK cannot be installed and no Android module compiles outside CI. That is why
`core/` exists as a plain Kotlin JVM module: it needs no SDK, so its tests run
anywhere, including here. Two settings protect that and both look wrong without
their reason, which each carries in a comment — the root `build.gradle.kts` has
no `plugins { ... apply false }` block, and `configureondemand=true` is set. Put
either back and `:core:test` reaches for the blocked host again.

```bash
cd android && ./gradlew :core:test          # runs anywhere
cd android && ./gradlew :app:assembleDebug  # needs the SDK, so CI
```

## How the cloud lane works

The relay is a courier. The session is claude.ai's own, visible in the Claude
app, and the work runs on Anthropic's infrastructure.

- **Asking**: `/cloud/ask` runs `claude -p --cloud <id>` with the text on stdin,
  then waits. The answer comes back through the Stop hook, not through the CLI.
- **Answering**: the hook fires at the end of every turn, probes the relay with
  the session id and no text, and sends the answer only if the relay says it
  asked. A turn nobody here asked about never leaves the VM.
- **History**: `POST /cloud/pull` sets a flag, now persisted in
  `RELAY_STATE_DIR/pulls.json`; the probe reports it as `wantHistory`; the hook
  reads its own `transcript_path` — the conversation on disk beside it — keeps
  only plain user and assistant text, and posts it back on the same path. No
  message is sent and no turn is started, so nothing about a pull appears in the
  conversation on claude.ai.

**A cloud session needs the hook on the branch it has checked out.** New
sessions branched from the default branch get it. An older session needs the
files brought across by hand — *both* of them if that branch has no `.claude`
at all, because the script with nothing wired to run it does nothing:

```bash
git fetch origin <default-branch>
git checkout origin/<default-branch> -- .claude/hooks/answer-to-relay.mjs .claude/settings.json
```

Only the first file is needed when the repository already had the hook and you
are updating it. `relay/hooks/README.md` has both cases and how to tell them
apart. Two things that look like the file not existing, and are not: the commit
that adds it has not merged yet, and `git fetch origin main` updates only
`main`, so a branch pushed since the last full fetch is invisible to
`git branch -r`.

## Known dead ends, with the reason

- **`--teleport` cannot fetch a cloud session's history.** Tested directly
  against a real idle cloud session, with and without a TTY: it exits 1 and
  prints nothing on either stream. It resumes an existing *teleport* session,
  not an arbitrary cloud one.
- **The MCP session tools are not available to the relay.** `list_sessions` and
  friends are injected into a cloud session by its harness; `claude mcp list` on
  a plain CLI shows no servers.
- **Creating a cloud session from the relay.** `claude --cloud "<task>"` refuses
  without a terminal. Allocating a pseudo-tty needs a native module this project
  has no dependencies for. Sessions are created in the Claude app.

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
- **Editing cloud environments programmatically.** claude.ai UI only. The API
  lists environments but exposes no variable values, so a token mismatch cannot
  be diagnosed by reading — only by testing from a session started afterward.
  The repo-committed route — `CLAUDE.md`, `.claude/settings.json` SessionStart
  hooks, `.claude/rules|skills|agents` — is the portable alternative and works
  locally *and* in the cloud.

## The bug pattern worth remembering

Bugs in this project keep having one shape: an error swallowed with `try?`, an
empty value substituted with `?? []`, and an empty state shown that reads as
"nothing here" instead of "something failed".

- A session added by link never appeared, because the list was gated on the
  *local* sessions found on the relay.
- The transcript request could never succeed: `getJSON` folded `"path?query"`
  into `URLComponents.path`, so `?` became `%3F` and the relay answered 400.
- A momentary relay failure wiped the cloud list, making a hiccup look identical
  to a session that failed to save.
- A pull armed before a relay restart was dropped silently, and the phone went
  on showing **Pulling** for a note nothing was left holding.
- `getJSON` again: a 200 whose body would not parse became `{}`, so the
  dashboard said "No sessions yet" about a relay that had answered.
- `SessionStore.files()`: a failed directory read became `[]`, so an unreadable
  store started a blank conversation at launch and looked exactly like every
  past session having been lost.

**And once running backwards, which is worth watching for separately.** The hop
loop in `askCloud` treated a *recoverable* error as fatal: a dropped connection
on one hop was thrown straight out of the wait, ending a turn that was still
running in the cloud and whose answer was on its way to the relay's inbox. The
code contradicted its own doc comment three lines above it. So the pattern is
not only "an error hidden as emptiness" but "an error classified wrongly in
either direction" -- and the fix in both cases is to say which errors are
answers about the request and which are the transport faltering.

`try?` followed by `?? []` is the signature of the first kind. A bare `try`
inside a retry loop is the signature of the second. The sweep has now been through the
app once; the sites checked and found *not* to be instances are
`ConversationViewModel.swift:535`, `DashboardView.swift:174`,
`RelayCatalog.swift:296`, `PairingLink.swift:26` and `RelayClient.swift:273`.

## Open threads

0. **`git pull` on the relay machine.** Nothing else here is blocked on it, but
   the relay is several merges behind and one of them is the `install-hook.ps1`
   hardening you would want before installing the hook into any further
   repository from there. Mind the restart gotcha above: only a fresh PID on
   8788 proves a restart happened.

1. **`RELAY_ANSWER_TOKEN` disagreement in the CampHawk environment**
   (`env_01NNXGWqS3cK1KTqhy4dH3JF`). It was changed mid-debugging, it was never
   established what it was changed to, and the relay itself was not touched. If
   the two now disagree, that lane cannot answer, and its sessions show the
   "never reported back to the relay" alert — which the relay cannot distinguish
   from a missing hook, by design. There are usually live CampHawk sessions.
   Recovery: the relay is the source of truth; phone Settings → Cloud session
   setup copies its real token to the clipboard; paste into **both**
   environments; verify with the authenticated POST in `relay/hooks/README.md`
   under "Check it".
2. **Rotate `RELAY_ANSWER_TOKEN`.** It was exposed in plaintext in a screenshot
   in an earlier session. Procedure is `relay/hooks/README.md` step 2 — copy to
   the clipboard rather than echoing it. Rotation means updating both
   environments *and* restarting the relay, and it breaks the campsite-finder
   lane until its environment is updated, so time it when CampHawk is quiet.
   Thread 1 and this thread touch the same value; doing them as one operation
   costs one restart instead of two.
3. **Scaffold repo config for campsite-finder** — a `.claude/settings.json`
   SessionStart hook plus `scripts/setup.sh`, so setup travels with the repo
   into both cloud sessions and relay sessions. Cannot be done from a
   Claude-Speak session: repository scope does not include campsite-finder.
4. **Run `relay/install-hook.ps1` on a scratch repository.** Never executed. The
   specific thing to watch for is `hooks.Stop` serialising as an object rather
   than an array on PowerShell 5.1, which the script's own check now catches and
   names.
5. **A CampHawk auto-login report needs delivering.** Auto-login lands on the
   recreation.gov calendar and stalls until login is tapped by hand; after that
   it completes. It should also land in the cart rather than prompting to go to
   it. This must not be fixed from Claude-Speak — a campsite-finder session is
   already editing `maybeAutoLogin`.
6. **Watch a Threaded Hope session actually answer.** The hook probes, so the
   lane is proven as far as the relay, but no answer has come back from it yet.
   The next attempt is also the first real test of the hop retry, since the
   previous one died exactly where that fix applies.
7. **Finish the Android client.** In order: phone UI and speech, then the watch
   over the Data Layer, then signing and a Play internal-testing track. All of
   it needs the device to mean anything — the protocol half is already tested.
   Anything that can be written as plain Kotlin belongs in `core/`, because that
   is the only code in `android/` that can be run without CI.
8. **Add the third cause to the missing-hook alert.** It names two — no hook on
   the branch, or a token mismatch — and there are three. A cloud environment
   whose **network policy** does not allow the funnel host fails identically:
   the hook posts, the CONNECT is refused with 403, and the hook swallows it by
   design. That was the original Default-environment bug and it would have been
   named by the alert if the alert knew about it.

## Working agreements

- Every change: CI on the branch via PR, then squash-merge, then ship to
  TestFlight from `main`, then reset the branch onto `main`.
- A feature-branch push runs **no CI**. The workflow triggers on
  `pull_request`, `push: [main]` and `workflow_dispatch` only, so a branch with
  no pull request has never been tested.
- Merge to `main` *before* asking for a `git pull` on the mini PC. Relay-only
  changes still need that pull; they do not ride TestFlight.
- Say plainly what is unverified. Several fixes here were shipped twice because
  the first attempt was described as working when it had never been run.
