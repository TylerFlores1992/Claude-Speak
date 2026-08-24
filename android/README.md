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

**This code cannot be compiled anywhere but CI.** `dl.google.com` is
egress-blocked from the build container — a bare request returns
`CONNECT tunnel failed, response 403`, the same signature documented in
`../STATUS.md` — so the Android SDK cannot be installed and `android.jar` never
arrives. Maven Central and `services.gradle.org` *are* reachable, which is
enough for the Gradle wrapper and nothing else.

That is stricter than the iOS side, where at least the relay tests run locally.
It is why this module landed as a skeleton with green CI before it had any
behaviour: a pipeline proven while there is nothing to lose is worth more than
one proven at the same time as the first feature.

## Layout

| | |
|---|---|
| `app/` | The phone. Owns the network, the relay client, and speech. |
| `wear/` | The watch. Speech in, text across the Data Layer, answer back. |

Both modules share one `applicationId` (`com.tylerflores.pocketclaude`, the same
string as the iOS bundle identifier). Play requires that of a Wear app shipped
beside its phone app — they are one listing with two APKs.

## Building

```bash
cd android
./gradlew test
./gradlew :app:assembleDebug :wear:assembleDebug
```

Needs the Android SDK, so in practice this runs in CI
(`.github/workflows/android.yml`, on `ubuntu-latest` — no macOS runner and no
10x multiplier). Debug APKs are uploaded as a build artifact.

## Not done yet

Everything. This is the skeleton: two modules that build, a unit test that
proves the test task runs, and a workflow that is green. No relay client, no
speech, no Data Layer, no signing, no Play listing.
