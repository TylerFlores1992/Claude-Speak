# Answering from a real cloud session

This is the half of the loop that did not exist before.

Sending a message into a claude.ai cloud session is easy and documented —
`claude -p "..." --cloud <id>` queues it and exits. The problem was that it
exits *without an answer*, so nothing could be spoken into an ear, which is why
everything else in this project was built around the relay's own local sessions.

A **Stop hook** closes it. Claude Code runs Stop hooks when a turn finishes,
hands them the final text as `last_assistant_message`, and — the part that makes
this work — **runs hooks committed to a repository inside cloud sessions too**.
So the hook runs in Anthropic's cloud, in the same session you can watch in the
Claude app, and posts the answer back to your relay.

```
phone ──▶ relay ──▶ claude -p "…" --cloud <id>
                          │
              the turn runs in Anthropic's cloud,
              in the session you see in the Claude app
                          │
            Stop hook ──POST──▶ relay /cloud/answer
                          │
phone ◀── relay speaks it ◀┘
```

The relay is a courier. Claude does not run on it for this path, so no checkout
state, no local model, no "which machine has the session".

## Install

**1. Commit the hook to the repository you work in.** Copy
`answer-to-relay.mjs` to `.claude/hooks/` there, and add to that repository's
`.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$CLAUDE_PROJECT_DIR/.claude/hooks/answer-to-relay.mjs\""
          }
        ]
      }
    ]
  }
}
```

`$CLAUDE_PROJECT_DIR` resolves to the repository root, so the hook is found
whatever directory the session is working in.

If you edit that file from PowerShell, check it afterwards:

```powershell
node -e "JSON.parse(require('fs').readFileSync('.claude/settings.json','utf8')); console.log('valid')"
```

`Set-Content -Encoding UTF8` on Windows PowerShell 5.1 writes a byte-order
mark, and Node's `JSON.parse` throws on one. Claude Code reads this file with
Node, so a BOM disables **every** hook in the repository, not just the one you
were adding — and it does it silently. Strip it with:

```powershell
$path = ".\.claude\settings.json"
[IO.File]::WriteAllText((Resolve-Path $path), (Get-Content $path -Raw), (New-Object Text.UTF8Encoding $false))
```

**2. Give the relay an answer token.** A *second* token, separate from
`RELAY_TOKEN`:

```powershell
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$answer = ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
[Environment]::SetEnvironmentVariable('RELAY_ANSWER_TOKEN', $answer, 'User')
$env:RELAY_ANSWER_TOKEN = $answer
$answer
```

Separate on purpose. `RELAY_TOKEN` can run Claude Code on your machine, and this
value has to be pasted into a cloud environment variable — which the Claude Code
docs say is readable by anyone using that environment and is explicitly *not* a
secrets store. `RELAY_ANSWER_TOKEN` can deliver an answer and nothing else, so
leaking it costs far less.

**3. Make the relay reachable from the cloud.** A cloud session runs on
Anthropic's infrastructure and cannot see a Tailscale address. Tailscale Funnel
publishes one HTTPS endpoint:

```powershell
tailscale funnel --bg --set-path=/answer http://127.0.0.1:8788/cloud/answer
```

Path-scoped deliberately. `tailscale funnel 8788` would publish the *whole*
relay to the public internet, including `/ask`, which runs Claude Code on that
machine — and Funnel hostnames appear in public certificate-transparency logs,
so the address is discoverable. Mounting only the answer route means the worst a
stolen answer token buys is putting words in your ear; everything else stays
reachable only from your tailnet.

The public URL becomes `https://<machine>.<tailnet>.ts.net/answer`, and that
— not `/cloud/answer` — is what goes in `RELAY_ANSWER_URL`. `--bg` keeps it
running after you close the window; check it with `tailscale funnel status`.

**4. Set two variables on the cloud environment** at claude.ai/code, in the
environment dialog:

| Variable | Value |
|---|---|
| `RELAY_ANSWER_URL` | `https://<your-funnel-host>/cloud/answer` |
| `RELAY_ANSWER_TOKEN` | the token from step 2 |

## Check it

With the relay running and the funnel up:

On Windows, use PowerShell's own client rather than `curl.exe`. Single quotes
in PowerShell pass backslashes through literally, so a bash-style `-d '{\"a\":1}'`
arrives as mangled JSON and the relay reports an unterminated string:

```powershell
$body = @{ sessionId = "session_01TEST"; text = "hello from outside" } | ConvertTo-Json
Invoke-RestMethod -Method Post `
  -Uri "https://<your-funnel-host>/answer" `
  -Headers @{ Authorization = "Bearer $env:RELAY_ANSWER_TOKEN" } `
  -ContentType "application/json" -Body $body
```

From a shell where the quoting behaves:

```bash
curl -X POST https://<your-funnel-host>/answer \
  -H "Authorization: Bearer $RELAY_ANSWER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"session_01TEST","text":"hello from outside"}'
```

`{"ok":true,...}` means the cloud can reach you. `claimed:false` just means
nobody was waiting, which is correct for a test.

Then, from a cloud session in that repository, ask it anything. The hook fires
when the turn ends. Run the relay with `RELAY_HOOK_DEBUG=1` set in the cloud
environment to have the hook explain itself on stderr in the session.

## Why the hook is silent by default

It runs in **every** session that repository is opened in, most of which are
nobody's voice loop. Missing configuration, an unreachable relay, and a rejected
token all exit 0 with nothing printed. A hook that fails loudly interrupts a
working session for a reason the person in that session cannot act on.

It exits 0 even on an unexpected throw, for the same reason: a non-zero exit
from a Stop hook is reported into the session.

## Two ids for one session

A cloud session is `session_01ABC` in a claude.ai URL and in the JSON that
`--cloud` prints, but the session reads its own id from
`CLAUDE_CODE_REMOTE_SESSION_ID` as `cse_01ABC`. Same session, two spellings. The
relay normalises `cse_` to `session_` on both sides; matching them literally
would mean an answer never finds its question.
