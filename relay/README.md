# The relay — hands-free Claude Code, no API charges

PocketClaude has two backends. This is the second one.

| | Direct API | **Relay (this)** |
|---|---|---|
| Cost per question | Billed to your Anthropic API key | **Nothing** — uses your Claude subscription |
| What it can do | Read the repo, open PRs | Read, edit, **run your tests**, build, `git log`, `rg` |
| Works when | Anywhere with a signal | Only while the relay machine is awake and reachable |
| Speed | Faster (does less) | Slower (does more) |

The relay is a ~250-line Node script that turns one `claude -p` run into a
stream the phone can speak sentence by sentence. It needs no dependencies.

**Why this is free:** the Claude Code CLI authenticates with your claude.ai
login, not an API key. Anthropic's docs are explicit about it — the `--bare`
flag exists precisely because it *skips* subscription auth and needs
`ANTHROPIC_API_KEY` instead. We deliberately don't pass `--bare`. Your Max
usage limits still apply, shared with your other Claude Code use.

---

## What you need

- A machine that stays awake: a mini PC, an old laptop, a Raspberry Pi 4/5, a
  NAS that runs containers, or a small VPS. It does the real work.
- **Node 18+** and the **Claude Code CLI**, signed in with `claude auth login`.
- A clone of the repository you want to ask about.
- **[Tailscale](https://tailscale.com)** on both the machine and the phone.
  Free for personal use, and it means the relay is never exposed to the
  internet — no port forwarding, no dynamic DNS, no certificate to manage.

## 1. Prove the CLI works first

Before any of this is worth setting up, on the relay machine:

```bash
cd ~/code/camphawk
claude -p "What does the hold lifecycle code do?" --output-format json | jq -r '.result'
```

If that prints a real answer, everything else is plumbing. If it complains
about authentication, run `claude auth login` and try again.

## 2. Start the relay

```bash
git clone <this repo> ~/code/Claude-Speak

export RELAY_TOKEN="$(openssl rand -hex 32)"   # save this — the phone needs it
export RELAY_REPO=~/code/camphawk

node ~/code/Claude-Speak/relay/server.mjs
```

You should see:

```
PocketClaude relay on http://0.0.0.0:8787
  repo:        /home/you/code/camphawk
  permissions: dontAsk
  model:       (Claude Code default)
```

Check it from the phone's browser at `http://<tailscale-name>:8787/health` —
you should get `{"ok":true,...}`.

### Configuration

| Variable | Default | What it does |
|---|---|---|
| `RELAY_TOKEN` | *(required)* | Bearer token the phone must send. Generate with `openssl rand -hex 32`. |
| `RELAY_REPO` | current directory | The checkout Claude Code works in. |
| `RELAY_PORT` | `8787` | |
| `RELAY_HOST` | `0.0.0.0` | Set to `127.0.0.1` if you front it with a reverse proxy. |
| `RELAY_MODEL` | Claude Code's default | e.g. `sonnet` for quicker answers. |
| `RELAY_PERMISSION_MODE` | `dontAsk` | See the safety note below. |
| `RELAY_ALLOWED_TOOLS` | *(none)* | Extra tools to permit, e.g. `"Bash(npm test *)"`. |
| `RELAY_TIMEOUT_MS` | `300000` | Kills a run that hangs. |
| `RELAY_CLAUDE_BIN` | `claude` | Path to the CLI if it isn't on `PATH`. |

### Safety: why `dontAsk` is the default

There is nobody at a keyboard to approve a permission prompt. That leaves two
sane options and one bad one:

- **`dontAsk` (default)** — denies anything outside Claude Code's read-only
  command set unless you've added explicit allow rules. Read, search,
  understand. No prompts, no edits.
- **Widen deliberately** — `RELAY_ALLOWED_TOOLS="Bash(npm test *),Bash(git diff *)"`
  lets it run your tests without letting it change files.
- **Don't use `acceptEdits` or `bypassPermissions`** unless you have genuinely
  thought about an agent editing that checkout unattended while you're walking
  the dog.

This mirrors the app's original rule — read-only by default, writes are a
deliberate choice — moved to where the tools now live.

## 3. Keep it running

**systemd** (Linux):

```ini
# /etc/systemd/system/pocketclaude-relay.service
[Unit]
Description=PocketClaude relay
After=network-online.target

[Service]
User=you
Environment=RELAY_TOKEN=your-token-here
Environment=RELAY_REPO=/home/you/code/camphawk
ExecStart=/usr/bin/node /home/you/code/Claude-Speak/relay/server.mjs
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now pocketclaude-relay
journalctl -u pocketclaude-relay -f
```

**launchd** (macOS): same idea with a `~/Library/LaunchAgents/*.plist`, or just
run it in a `tmux` session while you try it out.

## 4. Point the phone at it

In PocketClaude → **⚙ Settings**:

1. **Backend** → *Relay (Claude Code)*
2. **Relay** → address `http://<tailscale-name>:8787`
3. **Relay token** → paste `RELAY_TOKEN` → **Save**

The repository, model, and permissions all live on the server now — those
fields disappear from Settings in relay mode, because changing them on the
phone would have no effect.

Leave **Voice out → Speak while the answer arrives** on. That's what makes the
answer start playing after the first sentence instead of a minute later.

---

## How it works

```
hold button → Apple Speech → POST /ask {text, sessionId}
                                  ↓
                     claude -p <text> --resume <id>
                       --output-format stream-json
                                  ↓
       SSE: session → chunk × N → tool → done
                                  ↓
         SpeechChunker → whole sentences → AVSpeechSynthesizer
```

The phone stores the `sessionId` from the first answer and sends it back with
the next question, so `--resume` keeps the conversation going. Tapping **✎ New
session** in the app clears it and starts a fresh Claude Code conversation.

Text is spoken a sentence at a time rather than a token at a time, and fenced
code blocks are skipped — hearing a shell script read aloud is useless, and it
stays on screen where you can read it later.

## Testing

```bash
node relay/test.mjs
```

19 tests: the stream-json interpreter, the CLI argument builder, and an
end-to-end pass that runs the real server against a fake `claude` binary and
asserts on the SSE frames a phone would receive — including that subagent
chatter never reaches the speech path.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `401` in the app | Token mismatch. The app's token must equal `RELAY_TOKEN` exactly. |
| "Could not run claude" | CLI not on the service's `PATH`. Set `RELAY_CLAUDE_BIN` to the absolute path. |
| "not logged in" | Run `claude auth login` **as the same user** the service runs as. |
| Answers stop after one question | The app didn't get a `sessionId`. Check the relay log for the `result` line. |
| Everything times out | The agent is waiting on a permission prompt. Keep `RELAY_PERMISSION_MODE=dontAsk`. |
| Works on wifi, not on cellular | Tailscale isn't connected on the phone. |

## What this doesn't solve

- **The machine must be awake.** Asleep or offline means no answers. Switch the
  app back to Direct API when you're away from home and the box is off.
- **Latency.** A real turn is 10–60 seconds. Streaming speech hides some of it
  by starting early, but it isn't instant.
- **Rate limits.** Subscription limits are shared with your interactive Claude
  Code use. Heavy relay use eats into the same budget.
