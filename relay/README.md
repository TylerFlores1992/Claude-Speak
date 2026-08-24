# The relay — hands-free Claude Code, no API charges

This is how PocketClaude answers. It used to be one of two backends; the other
called the Anthropic API from the phone with an API key, was never actually
used, and was removed. What is left is this.

| | |
|---|---|
| Cost per question | **Nothing** — uses your Claude subscription, not an API key |
| What it can do | Read, edit, **run your tests**, build, `git log`, `rg` |
| Works when | Only while the relay machine is awake and reachable |
| Speed | A real turn is 10-60 seconds; speech starts at the first sentence |

The relay is a dependency-free Node script that turns one `claude -p` run into
a stream the phone can speak sentence by sentence, and couriers answers back
from cloud sessions running on Anthropic's infrastructure.

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

By default it triggers at **logon**, so a machine that reboots and sits at the
lock screen starts nothing until someone signs in. Pass `-AtBoot` to trigger at
startup instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\relay\install-autostart.ps1 -AtBoot -Now
```

That runs with nobody signed in, which means Windows has to store your password
— it goes into the LSA secret store, the same place every other saved task
credential lives. The task still runs as **you**, not as SYSTEM, because the
Claude Code CLI is authenticated per user. Reasonable on a machine you own that
sits in your house; think about it before doing it on a laptop that travels.

The task is set to restart on failure and to have no execution time limit,
because the default kills a task after three days, which is not a useful
lifetime for something meant to always be up.

**There is no button in the app for this, and there cannot be.** The app
reaches the relay over HTTP; if the relay is not running there is nothing
listening to receive a request to start it. Any such button would need a second
always-on process, which only moves the problem. Starting itself is the fix.

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
| `RELAY_ANSWER_TOKEN` | *(none)* | Narrow token for `/cloud/answer` only. Without it, cloud answers are refused. See `hooks/README.md`. |
| `RELAY_ANSWER_ALL` | `0` | Accept answers from every cloud session, not only ones this relay asked. |
| `RELAY_STATE_DIR` | `~/.pocketclaude` | Where titles, remembered cloud sessions, archived ids, pending history pulls, and transcripts are kept. |

### Endpoints

Everything except `/health` requires `Authorization: Bearer $RELAY_TOKEN`.

| Method | Path | What it does |
|---|---|---|
| `GET` | `/health` | Liveness, repo, version, and whether updates can restart. |
| `POST` | `/ask` | One question. Streams SSE: `session`, `chunk`, `tool`, `status`, `done`. Accepts `text`, `sessionId`, `project`, `model`, `effort`. |
| `GET` | `/sessions` | Every Claude Code session on the machine, newest first, with a `live` flag. |
| `POST` | `/sessions/archive` | Hides one from the list. The transcript stays. |
| `POST` | `/sessions/delete` | Removes the transcript file. Not undoable. |
| `POST` | `/sessions/rename` | Names one by hand. An empty name restores the default. |
| `GET` | `/projects` | Workspaces a new session may run in. |
| `POST` | `/cloud/send` | Queues a message into a cloud session. Returns without an answer. |
| `POST` | `/cloud/ask` | Queues a message into a cloud session and waits one hop for the answer, which arrives via the Stop hook. See `hooks/README.md`. |
| `POST` | `/cloud/await` | Waits for an answer without sending anything. How the phone keeps waiting past one hop. |
| `GET` | `/setup` | The answer URL and token a cloud environment needs, ready to paste. |
| `POST` | `/cloud/add` | Adds a session to the remembered list from its link, and marks its answers as wanted. |
| `POST` | `/cloud/forget` | Drops one from the list. The session itself keeps running on claude.ai. |
| `POST` | `/cloud/rename` | Names one in this list. The session on claude.ai is untouched. |
| `GET` | `/cloud/transcript?sessionId=` | A session's conversation: the relay's own record, or its real history once pulled. |
| `POST` | `/cloud/pull` | Asks a session for its own history. Sends no message and starts no turn — it arrives with the next reply. |
| `POST` | `/cloud/answer` | Where the Stop hook delivers a finished turn. Takes the narrow `RELAY_ANSWER_TOKEN`, and is the one route outside the main auth gate. |
| `GET` | `/cloud` | The cloud sessions this relay knows about. |
| `POST` | `/update` | `git pull` in the relay checkout, then restart if supervised. |

### Session titles

A name set from the phone is kept in `RELAY_STATE_DIR/names.json`, separate
from the generated-title cache, and outranks everything: a name you typed is an
instruction, and a generated title is a guess the relay is free to replace.
Clearing the name falls back through the same chain as a session that was never
renamed.


A session is otherwise titled with its first question verbatim, which is how a
list becomes six rows of `What does this proje...`. The relay asks a small model
for a few words the first time it sees a session and caches the answer in
`~/.pocketclaude/titles.json`, keyed by session id — named once, never a second
call. A title set by hand with `/rename` still wins.

Naming happens after the response is sent and is capped per refresh, because
each one spawns a process. It passes `--no-session-persistence`: without that,
naming a session creates a session, and the titler pollutes the list it exists
to tidy.

### Cloud sessions

Setting one up is two things, neither of them per-session: the Stop hook on the
repository's default branch, and `RELAY_ANSWER_URL` / `RELAY_ANSWER_TOKEN` on
the environment. After that, adding a session to the phone is pasting its link.
See [`hooks/README.md`](hooks/README.md).

**This repository has the hook installed on itself**, in `.claude/`, so a cloud
session working on the relay can answer the phone like any other. It shipped the
hook without ever installing it here, which is why the first cloud session
opened on this repo took messages and never answered one.


Sessions in the Claude app's Code tab run on Anthropic's infrastructure. Nothing
here can see them and no API lists them, so they arrive one at a time by link,
through `/cloud/add`.

**`/cloud/send`** runs `claude -p --cloud <id>` with the message on stdin, which
queues it into the session where it already runs and exits. No answer comes back
that way; read it in the Claude app.

Bringing a session *here* was tried and does not work. `--teleport` resumes an
existing teleport session, not an arbitrary cloud one: pointed at a real cloud
session it exits 1 and prints nothing, with or without a terminal. `/teleport`,
`/cloud/refresh`, `/cloud/start` and the Remote Control routes were removed once
the hook below made them unnecessary.

**`/cloud/ask`** does what `/cloud/send` does and then waits for the answer,
which a Stop hook committed to the repository posts back to `/cloud/answer`
from inside the cloud session. That closes a loop that runs entirely in
Anthropic's cloud, in the session you can watch in the Claude app, with this
machine acting only as courier. Setup is in [`hooks/README.md`](hooks/README.md).

### Waiting for an answer

A cloud turn can run for many minutes. One HTTP request cannot: the socket
times out, the answer arrives afterwards, and the phone reports that the
network connection was lost while this relay is sitting on a perfectly good
answer.

So the phone sends once and then waits in hops. `/cloud/ask` sends and waits
one hop; `/cloud/await` waits another, and another, without sending anything.
Each hop is short enough to live inside any client timeout, and an answer that
lands between two hops goes to the inbox, where the next hop collects it. A
dropped hop costs the hop and nothing else.

Hops are clamped to ninety seconds so a stuck client cannot pin a socket open.

For a dropped hop to cost only the hop, the phone has to treat it that way, and
for a while it did not: a transport failure ended the whole wait, and the turn
carried on in the cloud with its answer landing in an inbox nothing would
collect. The app now retries a dropped hop with a doubling backoff and gives up
after five in a row -- enough to ride out a network changing underneath the
phone, few enough that a relay which has genuinely gone away is reported rather
than hidden behind a quarter of an hour of silent retrying. Only the transport
is retried: a refusal, a bad token or a session with no hook is an answer about
the request, and asking again is told the same thing more slowly.

The request that *starts* the turn is deliberately not retried. It is what
queues the message into the cloud session, and a connection dropping on the way
back leaves no way to tell whether it was queued -- so retrying risks saying the
same thing to the session twice.

An answer nobody ever collects is discarded when the next question arrives:
the inbox is drained at the start of every wait, so leaving it there would hand
the previous turn's answer to a question it has never seen.

### Knowing why a session is silent

A missing hook used to fail exactly like a slow turn: silence until a timeout,
with nothing to act on. The relay can tell them apart, because **the hook probes
before it sends anything** -- so a session that has never probed has never run
the hook.

`/cloud/ask` and `/cloud/await` report that as `hookMissing`, and the phone
stops waiting rather than spending another fourteen minutes on something that
cannot arrive. Probes are recorded in `RELAY_STATE_DIR/probes.json` rather than
memory, because a restart would otherwise forget every session it had heard from
and start accusing working setups of having no hook.

It cannot distinguish a missing hook from a token that does not match -- a
rejected probe never reaches the code that records one -- so it names both.

### What a transcript is, and is not

Two things can be in `RELAY_STATE_DIR/transcripts/`, and the app says which is
on screen.

By default it is the relay's own record: every question it sent and every answer
the hook returned. Exact from the moment a session joins the list, and silent
about anything said before that.

Tapping **History** in the app replaces that with the session's real
conversation. No API returns a cloud session's messages, but the Stop hook runs
*inside* the session, where the transcript is on disk and its path is handed to
the hook. `POST /cloud/pull` leaves a note that the hook collects on
its next probe, and the history comes back with the next reply.

That note is kept in `RELAY_STATE_DIR/pulls.json`, for the same reason probes
are on disk: held in memory, a relay restart dropped every armed pull without
saying so, and the phone went on showing **Pulling** for a note nothing was
left holding. It is removed once the history lands, so a restart cannot
resurrect a pull that was already answered.

So a pull sends no message and starts no turn: nothing about it shows up in the
conversation on claude.ai. Only plain user and assistant text is sent, never
tool calls or attachments. See `relay/hooks/README.md`.

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

1. **Relay** → address `http://<tailscale-name>:8787`
2. **Relay token** → paste `RELAY_TOKEN` → **Save**

The repository, model, and permissions all live on the server — there are no
fields for them in Settings, because changing them on the phone would have no
effect.

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

97 tests: the stream-json interpreter, the CLI argument builder, and an
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

- **The machine must be awake.** Asleep or offline means no answers, and there
  is no second backend to fall back to — that was the point of removing it, but
  it does mean a sleeping box is a silent phone. Cloud sessions are the
  exception only in where the *work* runs: the relay still has to be up to
  courier the answer back.
- **Latency.** A real turn is 10–60 seconds. Streaming speech hides some of it
  by starting early, but it isn't instant.
- **Rate limits.** Subscription limits are shared with your interactive Claude
  Code use. Heavy relay use eats into the same budget.
