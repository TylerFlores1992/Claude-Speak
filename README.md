# PocketClaude

A voice-driven Claude agent for iPhone. Phone in your pocket, one AirPod in:
hold a button, ask a question about your GitHub repo, hear the answer.

**No server anywhere.** Speech recognition, the Anthropic Messages API, the
GitHub tool calls, and text-to-speech all run on the phone.

```
 you ──speak──▶ SFSpeechRecognizer ──▶ Claude Opus 5 (Messages API)
                                            │
                                    tool_use │ tool_result
                                            ▼
                                   GitHub REST, called
                                   by the phone itself
                                            │
 you ◀──AirPod── AVSpeechSynthesizer ◀──────┘
```

## What it can do

- **Read and reason about your repo** — list files, read them, search code, read
  issues and pull requests.
- **Propose changes properly** — create a branch, commit files, open a PR. Never
  commits to `main`; every write asks you out loud before it happens.
- **Answer in your ear** — a short conversational summary is spoken; the full
  detail with file paths and code stays on screen.

## What it can't do

No shell, no test runner, no build. It can write code but cannot verify it —
everything it proposes is unverified until CI runs on the PR.
[`PHASE1_RESEARCH.md`](PHASE1_RESEARCH.md) is honest about where the ceiling is
and why; [`ROADMAP.md`](ROADMAP.md) covers what a small container would add.

## Getting started

[`SETUP.md`](SETUP.md) — clone, sign with your free Apple ID, add two keys, run.
About twenty minutes, most of it Xcode.

Requires Xcode 16+, an iPhone on iOS 17+, an Anthropic API key, and a GitHub
personal access token. No paid developer account.

## The code

Zero third-party dependencies. ~3,900 lines of app and ~1,500 lines of tests,
commented for someone who knows TypeScript and is new to Swift.

| Path | What lives there |
|---|---|
| `PocketClaude/Anthropic/` | Messages API client, system prompt, response parser, cost estimator |
| `PocketClaude/GitHub/` | REST client — this is the tool layer |
| `PocketClaude/Agent/` | Tool catalogue, tool executor, the agent loop |
| `PocketClaude/Voice/` | Speech in, speech out, audio session, AirPod remote commands |
| `PocketClaude/UI/` | One screen, plus settings |
| `PocketClaude/Core/` | Keychain, settings, JSON |
| `PocketClaudeTests/` | Hermetic tests — every HTTP call is stubbed |

## Documents

- [`SETUP.md`](SETUP.md) — getting it on your phone
- [`PHASE1_RESEARCH.md`](PHASE1_RESEARCH.md) — what's actually possible on-device, with the limits
- [`DECISIONS.md`](DECISIONS.md) — every choice and why
- [`ROADMAP.md`](ROADMAP.md) — the server upgrade path, and smaller next steps

## Security

API keys live in the iOS Keychain, entered at runtime, never committed and never
in `UserDefaults`. Write actions require confirmation. Commits to `main`,
`master`, and the repository's default branch are refused before the request is
even built.
