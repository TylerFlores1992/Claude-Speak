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

### On Windows, use `run.ps1`

```powershell
cd C:\code\Claude-Speak
.\relay\run.ps1
```

Two things it does that `node server.mjs` does not:

- **Restarts after an update.** The relay exits with code 42 when the app's
  *Update and restart relay* button has pulled new code. Without a supervisor
  it pulls the new version and keeps running the old one.
- **Remembers the token.** `$env:RELAY_TOKEN = "..."` lasts only as long as
  that window, so a fresh PowerShell fails with `RELAY_TOKEN is required` —
  which reads as a broken relay rather than a missing variable. `run.ps1` asks
  once, saves it as a user environment variable, and never asks again.

It also passes `RELAY_REPO`, `RELAY_PORT`, `RELAY_MODEL`, `RELAY_PROJECTS` and
`RELAY_SCRATCH` through from the registry. PowerShell reads `$env:` once at
process start, so a value `setup.ps1` saved after the window opened is
invisible to `$env:` but is still found here.

### Start it after a reboot

```powershell
# As Administrator, once:
powershell -ExecutionPolicy Bypass -File .\relay\install-autostart.ps1 -Now
```

Registers a scheduled task and adds a desktop and Start Menu shortcut. The
task runs as you rather than as SYSTEM, deliberately: the relay shells out to
the Claude Code CLI, which is authenticated per user, so a task running as
SYSTEM would start a relay that cannot log in to anything.

It triggers at **logon, not at boot**. A machine that reboots and sits at the
lock screen starts nothing until someone signs in — turn on automatic sign-in
if you want it up without you. The task is set to restart on failure and to
have no execution time limit, because the default kills a task after three
days, which is not a useful lifetime for something meant to always be up.

`setup.ps1` does all of this too; this script is the same steps split out, for
a machine that was set up by hand.

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
| `RELAY_PROJECTS` | *(none)* | Extra workspaces as `name=path` pairs, comma separated. |
| `RELAY_SCRATCH` | `~/pocketclaude-chat` | The empty directory the Chat workspace uses. |
| `RELAY_AUTO_TITLE` | `1` | Set `0` to keep raw first questions as session titles. |
| `RELAY_TITLES_PER_REFRESH` | `5` | How many unnamed sessions to name per `/sessions` call. |
| `RELAY_SUPERVISED` | *(set by `run.ps1`)* | Tells the relay a supervisor exists, so an update may exit to restart. |

### Endpoints

Everything except `/health` requires `Authorization: Bearer $RELAY_TOKEN`.

| Method | Path | What it does |
|---|---|---|
| `GET` | `/health` | Liveness, repo, version, and whether updates can restart. |
| `POST` | `/ask` | One question. Streams SSE: `session`, `chunk`, `tool`, `status`, `done`. Accepts `text`, `sessionId`, `project`, `model`, `effort`. |
| `GET` | `/sessions` | Every Claude Code session on the machine, newest first, with a `live` flag. |
| `POST` | `/sessions/archive` | Hides one from the list. The transcript stays. |
| `POST` | `/sessions/delete` | Removes the transcript file. Not undoable. |
| `GET` | `/projects` | Workspaces a new session may run in. |
| `POST` | `/teleport` | Pulls a claude.ai cloud session onto this machine. |
| `POST` | `/cloud/send` | Queues a message into a cloud session. Returns without an answer. |
| `GET` | `/cloud` | Cloud sessions pulled here before. |
| `POST` | `/cloud/refresh` | Re-pulls one or all of them. |
| `GET`/`POST` | `/remote-control` | Reports or starts the Remote Control server. |
| `POST` | `/remote-control/stop` | Stops it. |
| `POST` | `/update` | `git pull` in the relay checkout, then restart if supervised. |

### Session titles

A session is otherwise titled with its first question verbatim, which is how a
list becomes six rows of `What does this proje...`. The relay asks a small model
for a few words the first time it sees a session and caches the answer in
`~/.pocketclaude/titles.json`, keyed by session id — named once, never a second
call. A title set by hand with `/rename` still wins.

Naming happens after the response is sent and is capped per refresh, because
each one spawns a process. It passes `--no-session-persistence`: without that,
naming a session creates a session, and the titler pollutes the list it exists
to tidy.

### Cloud sessions and Remote Control

Sessions in the Claude app's Code tab run on Anthropic's infrastructure. Nothing
here can see them and no API lists them, so they are reached one at a time:

- **`/teleport`** runs `claude --teleport <id>`, which pulls the session's
  branch and full history onto this machine. It becomes an ordinary local
  session that `/sessions` lists and `/ask` resumes. It is a **copy** — the
  cloud session keeps running and the two diverge from that moment.
- **`/cloud/send`** runs `claude -p "…" --cloud <id>`, which queues a message
  into the session where it already runs and exits. No answer comes back;
  read it in the Claude app.

For one session visible in two places at once, `/remote-control` starts
`claude remote-control`, a server that serves local sessions to claude.ai and
the Claude app. Sessions it serves show a green dot in the phone's dashboard.

Remote Control is a research preview and may report that it is not enabled for
your account. Run `claude remote-control` by hand once to find out.

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
