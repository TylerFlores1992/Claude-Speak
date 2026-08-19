# PocketClaude relay — one-shot setup for Windows.
#
#   irm https://raw.githubusercontent.com/TylerFlores1992/Claude-Speak/main/relay/setup.ps1 | iex
#
# Installs what's missing, logs you in, generates a token, opens the firewall,
# registers a startup task, drops a shortcut on the desktop, and prints the two
# values to type into the phone.
#
# Written to be run twice safely. Every step checks before acting, so re-running
# after a failure picks up where it stopped rather than starting over.

$ErrorActionPreference = "Stop"

function Step($text) { Write-Host "`n=== $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "  OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "  !   $text" -ForegroundColor Yellow }
function Die($text)  { Write-Host "`n  X  $text" -ForegroundColor Red; exit 1 }

function Have($name) { $null -ne (Get-Command $name -ErrorAction SilentlyContinue) }

Write-Host "PocketClaude relay setup" -ForegroundColor White

# --- Node ------------------------------------------------------------------
Step "Node.js"
if (Have node) {
    Ok "already installed ($(node --version))"
} else {
    Warn "installing — this takes a minute"
    winget install --silent --accept-package-agreements --accept-source-agreements OpenJS.NodeJS.LTS
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Have node)) { Die "Node installed but isn't on PATH yet. Close this window, open a new one, and run the script again." }
    Ok "installed ($(node --version))"
}

# --- git -------------------------------------------------------------------
Step "git"
if (Have git) {
    Ok "already installed"
} else {
    Warn "installing"
    winget install --silent --accept-package-agreements --accept-source-agreements Git.Git
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Have git)) { Die "git installed but isn't on PATH yet. Open a new window and run the script again." }
    Ok "installed"
}

# --- Claude Code CLI -------------------------------------------------------
Step "Claude Code CLI"
if (Have claude) {
    Ok "already installed ($(claude --version))"
} else {
    Warn "installing"
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    $local = "$env:USERPROFILE\.local\bin"
    if (Test-Path "$local\claude.exe") {
        # The installer often can't update PATH for the running session.
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$local*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$local", "User")
            Ok "added $local to PATH"
        }
        $env:Path += ";$local"
    }
    if (-not (Have claude)) { Die "Claude CLI installed but isn't on PATH yet. Open a new window and run the script again." }
    Ok "installed ($(claude --version))"
}

# --- Login -----------------------------------------------------------------
# `claude -p` exits non-zero and says "Not logged in" when it isn't, which is a
# cheaper check than parsing anything.
Step "Claude account"
$probe = & claude -p "reply with the single word: ok" --output-format json 2>&1 | Out-String
if ($probe -match "Not logged in" -or $probe -match "/login") {
    Warn "not signed in — a browser will open. Sign in with the account that has your Claude subscription."
    Write-Host "  (type /exit once you're back at the prompt)`n"
    & claude
    $probe = & claude -p "reply with the single word: ok" --output-format json 2>&1 | Out-String
    if ($probe -match "Not logged in") { Die "Still not signed in. Run 'claude' by hand, use /login, then re-run this script." }
}
if ($probe -match "ANTHROPIC_API_KEY") {
    Die "The CLI wants an API key rather than your subscription. Run 'claude' and use /login — the whole point is that subscription runs cost nothing per question."
}
Ok "signed in"

# --- Repository ------------------------------------------------------------
Step "Repository to answer questions about"
$repo = Read-Host "  Path to a local clone (blank to clone one now)"
if ([string]::IsNullOrWhiteSpace($repo)) {
    $url = Read-Host "  Git URL to clone"
    if ([string]::IsNullOrWhiteSpace($url)) { Die "Need either a path or a URL." }
    $name = [IO.Path]::GetFileNameWithoutExtension($url.TrimEnd('/'))
    $repo = "C:\code\$name"
    if (Test-Path $repo) {
        Warn "$repo already exists — using it"
    } else {
        git clone $url $repo
    }
}
if (-not (Test-Path $repo)) { Die "$repo doesn't exist." }
$repo = (Resolve-Path $repo).Path
Ok "using $repo"

# --- The relay itself ------------------------------------------------------
Step "Relay code"
$relayRoot = "C:\code\Claude-Speak"
if (Test-Path "$relayRoot\relay\server.mjs") {
    Ok "already present at $relayRoot"
} else {
    git clone https://github.com/TylerFlores1992/Claude-Speak $relayRoot
    Ok "cloned to $relayRoot"
}

# --- Token -----------------------------------------------------------------
Step "Relay token"
$existing = [Environment]::GetEnvironmentVariable("RELAY_TOKEN", "User")
if ($existing) {
    Ok "reusing the token already saved on this machine"
    $token = $existing
} else {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
    Ok "generated a new one"
}

# --- Settings that persist -------------------------------------------------
Step "Saving settings"
$port = "8788"
[Environment]::SetEnvironmentVariable("RELAY_TOKEN", $token, "User")
[Environment]::SetEnvironmentVariable("RELAY_REPO",  $repo,  "User")
[Environment]::SetEnvironmentVariable("RELAY_PORT",  $port,  "User")
# Sonnet rather than the default: pocket questions want an answer sooner, and it
# draws down subscription limits more slowly.
[Environment]::SetEnvironmentVariable("RELAY_MODEL", "sonnet", "User")
Ok "saved for this user"

# --- Firewall --------------------------------------------------------------
# Skipping this is the most common way to lose an hour: Windows drops the
# phone's connection with no error anywhere.
Step "Firewall"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (Get-NetFirewallRule -DisplayName "PocketClaude relay" -ErrorAction SilentlyContinue) {
    Ok "rule already present"
} elseif ($admin) {
    New-NetFirewallRule -DisplayName "PocketClaude relay" -Direction Inbound `
        -LocalPort $port -Protocol TCP -Action Allow | Out-Null
    Ok "opened port $port"
} else {
    Warn "not running as Administrator, so the firewall rule wasn't added."
    Warn "Run this in an admin PowerShell, or the phone won't be able to connect:"
    Write-Host "    New-NetFirewallRule -DisplayName 'PocketClaude relay' -Direction Inbound -LocalPort $port -Protocol TCP -Action Allow" -ForegroundColor White
}

# --- Start on login --------------------------------------------------------
Step "Start automatically"
if (Get-ScheduledTask -TaskName "PocketClaude relay" -ErrorAction SilentlyContinue) {
    Ok "startup task already registered"
} elseif ($admin) {
    # Through run.ps1, not node directly: the supervisor is what restarts the
    # relay after it updates itself.
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                                       -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$relayRoot\relay\run.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName "PocketClaude relay" -Action $action -Trigger $trigger | Out-Null
    Ok "registered — it will start when you log in"
} else {
    Warn "not running as Administrator, so the startup task wasn't registered. The relay will only run while you keep a window open."
}

# --- Shortcut --------------------------------------------------------------
Step "Desktop shortcut"
$shortcut = "$([Environment]::GetFolderPath('Desktop'))\Start PocketClaude relay.lnk"
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = "powershell.exe"
$link.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$relayRoot\relay\run.ps1`""
$link.WorkingDirectory = $repo
$link.Description = "Runs the PocketClaude relay"
$link.Save()
Ok "created '$shortcut'"

# --- Tailscale -------------------------------------------------------------
Step "Tailscale"
$ts = "C:\Program Files\Tailscale\tailscale.exe"
$ip = $null
if (Test-Path $ts) {
    $status = & $ts status 2>&1 | Out-String
    $ip = ([regex]::Match($status, '100\.\d+\.\d+\.\d+')).Value
    if ($ip) { Ok "this machine is $ip" } else { Warn "Tailscale is installed but not connected. Sign in, then re-run to see the address." }
} else {
    Warn "not installed. Install from https://tailscale.com/download/windows and sign in on both this machine and the phone."
    Warn "Without it the phone can only reach the relay on the same Wi-Fi."
}

# --- Go --------------------------------------------------------------------
Step "Starting the relay"
Write-Host ""
Write-Host "  Put these two values into PocketClaude -> Settings:" -ForegroundColor White
Write-Host ""
Write-Host "    Relay address   http://$(if ($ip) { $ip } else { '<this-machine>' }):$port" -ForegroundColor Yellow
Write-Host "    Relay token     $token" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Or skip the typing: the relay prints a pocketclaude:// link when it" -ForegroundColor Gray
Write-Host "  starts. Send that line to yourself and tap it." -ForegroundColor Gray
Write-Host ""
Write-Host "  Leave this window open. Ctrl+C stops the relay." -ForegroundColor Gray
Write-Host ""

$env:RELAY_TOKEN = $token
$env:RELAY_REPO  = $repo
$env:RELAY_PORT  = $port
$env:RELAY_MODEL = "sonnet"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$relayRoot\relay\run.ps1"
