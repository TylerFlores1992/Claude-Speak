# Makes the relay start on its own after a reboot, and adds a shortcut for
# starting it by hand.
#
# Run this once, as Administrator:
#     powershell -ExecutionPolicy Bypass -File .\relay\install-autostart.ps1
#
# This is the part of setup.ps1 that matters after a restart, split out so it
# can be run on a machine that was set up by hand.
#
# The task logs on as you, not as SYSTEM, and that is deliberate: the relay
# shells out to the Claude Code CLI, which is authenticated per user. A task
# running as SYSTEM would start a relay that cannot log in to anything.

param(
    # Start the relay straight away as well, rather than waiting for a logon.
    [switch]$Now,

    # Trigger at boot instead of at logon, so the relay comes back after a
    # restart without anyone signing in. Windows has to store your password to
    # do this, because the task still runs as you -- the Claude Code CLI is
    # authenticated per user, so a task running as SYSTEM would start a relay
    # that cannot log in to anything.
    #
    # The password goes into the LSA secret store, which is the same place
    # Windows keeps every other saved task credential. Reasonable on a machine
    # you own and sits in your house; think about it before using it on a
    # laptop that travels.
    [switch]$AtBoot
)

$ErrorActionPreference = "Stop"
$relayRoot = Split-Path -Parent $PSScriptRoot
$runScript = Join-Path $PSScriptRoot "run.ps1"

function Ok($m)   { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Step($m) { Write-Host "`n$m" -ForegroundColor Cyan }

if (-not (Test-Path $runScript)) {
    Write-Host "Can't find $runScript. Run this from the Claude-Speak checkout." -ForegroundColor Red
    exit 1
}

# --- Settings check --------------------------------------------------------
#
# Checked before registering anything: a task that starts a relay which then
# exits for want of a token is worse than no task, because it fails silently at
# logon where nobody is watching.
Step "Settings"
$token = [Environment]::GetEnvironmentVariable("RELAY_TOKEN", "User")
$repo  = [Environment]::GetEnvironmentVariable("RELAY_REPO",  "User")
$port  = [Environment]::GetEnvironmentVariable("RELAY_PORT",  "User")

if ($token) { Ok "RELAY_TOKEN is saved for this user" }
else { Warn "RELAY_TOKEN is not saved. run.ps1 will ask for it the first time it starts by hand, but a task that starts at logon has nobody to ask." }

if ($repo) { Ok "RELAY_REPO is $repo" }
else { Warn "RELAY_REPO is not set, so the relay will answer questions about its own checkout rather than your project." }

if ($port) { Ok "RELAY_PORT is $port" } else { Warn "RELAY_PORT is not set; the relay will use 8787." }

# --- Scheduled task --------------------------------------------------------
Step "Start after a reboot"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$taskName = "PocketClaude relay"
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if (-not $admin) {
    Warn "not running as Administrator, so the startup task can't be registered."
    Warn "Right-click PowerShell, choose 'Run as administrator', and run this again."
} else {
    # Through run.ps1 rather than node directly: the supervisor is what turns
    # the app's update button into a restart, and what supplies the token.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runScript`""
    $trigger = if ($AtBoot) {
        New-ScheduledTaskTrigger -AtStartup
    } else {
        New-ScheduledTaskTrigger -AtLogOn
    }
    # Restart if it dies, and never stop it for running too long -- the default
    # task settings kill a task after three days, which is not a useful
    # lifetime for something meant to always be up.
    $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    # -AtBoot needs the password so Windows can run the task with nobody signed
    # in. Read as a SecureString and handed straight to Register-ScheduledTask,
    # which is the only thing that sees it.
    $register = @{
        TaskName = $taskName
        Action   = $action
        Trigger  = $trigger
        Settings = $settings
    }
    if ($AtBoot) {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        Write-Host ""
        Write-Host "Starting at boot means running with nobody signed in, so Windows needs" -ForegroundColor Yellow
        Write-Host "your password for $user. It is stored by Windows, not by this script." -ForegroundColor Yellow
        $secure = Read-Host "Windows password for $user" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $register.User = $user
            $register.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $register.RunLevel = "Highest"
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    # Unregister rather than Set: a trigger change from logon to boot also
    # changes the principal, and Set-ScheduledTask cannot alter that.
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Register-ScheduledTask @register | Out-Null

    if ($AtBoot) {
        Ok "registered '$taskName' -- it will start at boot, with nobody signed in"
    } else {
        Ok "registered '$taskName' -- it will start when you log in"
        Warn "It starts at *logon*, not at boot. If this machine reboots and sits at the lock screen, nothing starts until you sign in."
        Warn "Re-run with -AtBoot to have it start without anyone signing in."
    }
}

# --- Shortcut --------------------------------------------------------------
Step "Shortcut"
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                   (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"))) {
    if (-not (Test-Path $dir)) { continue }
    $path = Join-Path $dir "Start PocketClaude relay.lnk"
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = "powershell.exe"
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runScript`""
    $link.WorkingDirectory = $relayRoot
    $link.Description = "Runs the PocketClaude relay"
    $link.Save()
    Ok "created '$path'"
}

# --- Start now -------------------------------------------------------------
if ($Now) {
    Step "Starting the relay"
    if ($admin -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        Start-ScheduledTask -TaskName $taskName
        Ok "started through the task, so it behaves exactly as it will after a reboot"
        Warn "It runs hidden. Check it with:  curl.exe http://127.0.0.1:$(if ($port) { $port } else { '8787' })/health"
    } else {
        & $runScript
    }
} else {
    Write-Host ""
    Write-Host "Done. Start it now with the desktop shortcut, or re-run this with -Now." -ForegroundColor Cyan
}
