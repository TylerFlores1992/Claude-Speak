# Runs the relay, and restarts it after an update.
#
# The relay exits with code 42 when it has pulled new code. Anything else - a
# crash, or Ctrl+C - stops for good, so a broken build fails loudly instead of
# restarting in a loop forever.
#
# Use this rather than `node server.mjs` directly if you want the "Update relay"
# button in the app to work. Without a supervisor the relay can pull new code
# but has no way to start running it, which leaves the old version running with
# the new version on disk - the confusing half-state worth avoiding.

$ErrorActionPreference = "Stop"
$server = Join-Path $PSScriptRoot "server.mjs"

# --- Configuration ---------------------------------------------------------
#
# The relay reads its settings from the environment, and `$env:RELAY_TOKEN =
# "..."` only lasts as long as the window you typed it in. Opening a fresh
# PowerShell and running this script then fails with "RELAY_TOKEN is required",
# which reads as a broken relay rather than a missing variable - so resolve it
# here, and save it where a new window will find it.
#
# Order: this process, then the persisted user value, then the machine value.
# PowerShell only refreshes $env: from the registry when a process starts, so a
# variable saved by setup.ps1 after this window opened is invisible to $env:.
function Resolve-Setting($name) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ($value) { return $value }
    $value = [Environment]::GetEnvironmentVariable($name, "User")
    if ($value) { return $value }
    return [Environment]::GetEnvironmentVariable($name, "Machine")
}

$token = Resolve-Setting "RELAY_TOKEN"

if (-not $token) {
    Write-Host "No RELAY_TOKEN found on this machine." -ForegroundColor Yellow
    Write-Host "It has to match the token saved in the app's Settings."
    Write-Host "Paste that token, or press Enter to generate a new one (you will"
    Write-Host "then need to re-pair the phone)."
    Write-Host ""

    # -AsSecureString so a shared screen or a scrollback buffer never shows the
    # token. Reading it back needs an unmanaged buffer, which has to be zeroed
    # and freed by hand - .NET will not do it, and the token would otherwise sit
    # in process memory for the life of the relay.
    $entered = Read-Host "Relay token" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($entered)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ($plain) {
        $token = $plain
        Write-Host "Using the token you entered." -ForegroundColor Green
    } else {
        $bytes = New-Object byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $token = ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
        Write-Host "Generated a new token. Re-pair the phone with the link below." -ForegroundColor Green
    }

    # Persist, so this prompt happens exactly once per machine.
    [Environment]::SetEnvironmentVariable("RELAY_TOKEN", $token, "User")
    Write-Host "Saved for this user. Future windows will pick it up." -ForegroundColor Green
    Write-Host ""
}

# Hand every resolved setting to the child process explicitly. Without this a
# value that only exists in the registry - saved by setup.ps1, or by the prompt
# above - is not in $env: and node never sees it.
$env:RELAY_TOKEN = $token
# Tells the relay a supervisor exists, so the app's update button is allowed to
# exit for a restart. Without it the relay updates but keeps running the old
# code, which is the honest outcome when nothing would bring it back.
$env:RELAY_SUPERVISED = "1"
foreach ($name in @("RELAY_REPO", "RELAY_PORT", "RELAY_MODEL", "RELAY_PROJECTS",
                    "RELAY_SCRATCH", "RELAY_ANSWER_TOKEN")) {
    $value = Resolve-Setting $name
    if ($value) { Set-Item -Path "env:$name" -Value $value }
}

# RELAY_REPO is not required - the relay falls back to its own directory - but
# that fallback silently points Claude at the relay's checkout instead of the
# repository you meant, and the answers look plausible while being about the
# wrong code. Worth a warning, not a failure.
if (-not $env:RELAY_REPO) {
    Write-Host "RELAY_REPO is not set - the relay will work on $PWD." -ForegroundColor Yellow
    Write-Host "Set it with:  [Environment]::SetEnvironmentVariable('RELAY_REPO', 'C:\code\campsite-finder', 'User')" -ForegroundColor Yellow
    Write-Host ""
}

# --- Supervisor ------------------------------------------------------------
while ($true) {
    Write-Host "Starting relay..." -ForegroundColor Cyan
    & node $server
    $code = $LASTEXITCODE

    if ($code -eq 42) {
        Write-Host "`nUpdated. Restarting.`n" -ForegroundColor Green
        continue
    }

    if ($code -ne 0) {
        Write-Host "`nRelay exited with code $code. Not restarting." -ForegroundColor Red
    }
    break
}
