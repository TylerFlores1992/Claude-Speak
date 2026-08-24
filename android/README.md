# The Android client

PocketClaude for a Pixel phone and a Pixel Watch. The iOS app in
`../PocketClaude` is untouched by any of this and stays the reference
implementation.

**Nothing here changes the relay.** `../relay` is plain HTTP, SSE and a bearer
token; it does not know or care what is on the other end. That is the whole
reason a second client is cheap: the protocol, the hop design, the cloud lane
and the Stop hook are all already platform-agnostic. An Android client is a new
*client*, not a port of the system.

## Two constraints worth knowing before reading the code

**Tailscale does not run on Wear OS.** The feature request
([tailscale/tailscale#3972](https://github.com/tailscale/tailscale/issues/3972))
has been open since February 2022 with no assignee and no linked pull requests,
labelled "L1 Very few" likelihood; a separate report
([#12177](https://github.com/tailscale/tailscale/issues/12177)) has the APK
closing instantly on a Galaxy Watch. So the watch **cannot reach the relay**:
the tailnet address is member-only, and the funnel deliberately publishes only
`/answer`, because mounting `/ask` would put Claude Code on the public internet.

The watch therefore talks to the *phone*, over the Wear Data Layer, and the
phone owns the network. Same topology as the Apple Watch — but not the same
work. watchOS records audio and ships the file across to be transcribed, because
the watch could not do it itself. Wear OS can:
[`RecognizerIntent.ACTION_RECOGNIZE_SPEECH`](https://developer.android.com/training/wearables/user-input/voice)
runs on the watch, so what crosses to the phone is a short string rather than a
WAV, and the phone-side transcription stage disappears entirely.

**Android code cannot be compiled anywhere but CI.** `dl.google.com` is
egress-blocked from the build container — a bare request returns
`CONNECT tunnel failed, response 403`, the same signature documented in
`../STATUS.md` — so the Android SDK cannot be installed and `android.jar` never
arrives.

**`:core` is the answer to that, and it is why the module exists.** It is a
plain Kotlin JVM module rather than an Android one, so it needs no SDK: Maven
Central and `services.gradle.org` are reachable, and that is everything a JVM
module requires. Its tests therefore run *here*, not only in CI:

```bash
cd android && ./gradlew :core:test
```

Everything worth testing lives there — how the SSE stream is framed, what a
request carries, how events fold into an answer — so the hardest constraint on
this side of the project now applies only to the parts that genuinely need a
phone. Those are still compiled by CI and proven by a device, and nothing else.

Two settings keep that working, and both look odd without the reason. The root
`build.gradle.kts` has no `plugins { ... apply false }` block, because that
block resolves the Android Gradle Plugin whenever *any* task in the build is
configured, including `:core:test`. And `org.gradle.configureondemand=true` in
`gradle.properties` stops a task in one module from configuring the others. Put
either back and `:core:test` starts reaching for `dl.google.com` again.

## Layout

| | |
|---|---|
| `core/` | Protocol only, no Android. Runs and is tested anywhere. |
| `app/` | The phone. Owns the network, the relay client, and speech. |
| `wear/` | The watch. Speech in, text across the Data Layer, answer back. |

The two *Android* modules share one `applicationId`
(`com.tylerflores.pocketclaude`, the same string as the iOS bundle identifier).
Play requires that of a Wear app shipped beside its phone app — they are one
listing with two APKs. `core/` has none, being a library rather than an app.

## Building

```bash
cd android
./gradlew :core:test                              # no Android SDK needed
./gradlew :app:assembleDebug :wear:assembleDebug  # needs the SDK
```

Only the second line needs the Android SDK, so in practice it runs in CI
(`.github/workflows/android.yml`, on `ubuntu-latest` — no macOS runner and no
10x multiplier). Debug APKs are uploaded as a build artifact.

## What is done, and how well

Stated by how far each thing has actually been proven, because "written" and
"working" are a long way apart here and the distance is the interesting part.

| | |
|---|---|
| `core/` — SSE framing, request building, turn assembly | **Tested.** 39 unit tests, run locally and in CI. |
| `RelayClient` — the one POST and its read loop | **Compiled.** Never pointed at a relay. |
| `Settings` — address and token | **Compiled.** Never read or written on a device. |
| The phone UI | Placeholder. |
| Speech in and out | Not started. |
| The watch | Placeholder, and its topology is settled but unbuilt. |
| Signing, Play listing | Not started. |

Nothing here has run on a phone. That is not a caveat to be buried: the iOS
half of this project shipped the same fix twice because the first attempt was
described as working when it had never been run.
