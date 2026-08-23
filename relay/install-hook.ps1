<#
.SYNOPSIS
Installs the PocketClaude Stop hook into a repository.

.DESCRIPTION
A cloud session can only answer your phone if a Stop hook is committed to the
repository it is running in. That is two files and one JSON edit, and every
part of it has a way to go quietly wrong:

  - Set-Content -Encoding UTF8 on Windows PowerShell 5.1 writes a byte-order
    mark. Claude Code reads settings.json with Node, and Node's JSON.parse
    throws on a BOM -- which disables EVERY hook in the repository, silently.
  - A repository that already has hooks needs the new one added to them, not
    written over them.
  - A hook that is present but not wired, or wired but not present, fails the
    same way as no hook at all: the session takes messages and never answers.

So this writes both files, merges rather than replaces, writes UTF-8 without a
BOM, and then reads the result back with Node to prove it parses.

.PARAMETER Repo
Path to the repository to install into.

.PARAMETER Commit
Also commit the result. The hook has to be on the branch a cloud session runs,
so it is not installed until it is committed and pushed.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\relay\install-hook.ps1 -Repo C:\code\campsite-finder
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [switch]$Commit
)

$ErrorActionPreference = "Stop"

function Fail($message) {
    Write-Host "FAILED: $message" -ForegroundColor Red
    exit 1
}

# --- Where things are -------------------------------------------------------

$relayRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot "hooks\answer-to-relay.mjs"
if (-not (Test-Path $source)) {
    Fail "Cannot find the hook at $source. Run this from a Claude-Speak checkout."
}

if (-not (Test-Path $Repo)) { Fail "No such directory: $Repo" }
$Repo = (Resolve-Path $Repo).Path
if (-not (Test-Path (Join-Path $Repo ".git"))) {
    Fail "$Repo is not a git repository. The hook has to be committed to be installed."
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Fail "node is not on PATH. It runs the hook, so it has to be." }

$claudeDir = Join-Path $Repo ".claude"
$hooksDir = Join-Path $claudeDir "hooks"
$settingsPath = Join-Path $claudeDir "settings.json"
$destination = Join-Path $hooksDir "answer-to-relay.mjs"

New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null

# --- The hook itself --------------------------------------------------------

Copy-Item $source $destination -Force
Write-Host "Wrote  .claude\hooks\answer-to-relay.mjs"

# --- settings.json ----------------------------------------------------------
#
# Merged, not replaced. A repository with its own Stop hooks keeps them, and
# running this twice does not leave two copies of ours.

$command = 'node "$CLAUDE_PROJECT_DIR/.claude/hooks/answer-to-relay.mjs"'

if (Test-Path $settingsPath) {
    $raw = Get-Content $settingsPath -Raw
    # A BOM survives -Raw as a single U+FEFF character, not three bytes, and
    # ConvertFrom-Json chokes on it exactly like Node does.
    $raw = $raw.TrimStart([char]0xFEFF)
    try {
        $settings = $raw | ConvertFrom-Json
    } catch {
        Fail "$settingsPath is not valid JSON, so it cannot be merged into. Fix or move it, then run this again."
    }
} else {
    $settings = [PSCustomObject]@{}
}

if ($settings.PSObject.Properties.Name -notcontains "hooks") {
    $settings | Add-Member -MemberType NoteProperty -Name hooks -Value ([PSCustomObject]@{})
}
if ($settings.hooks.PSObject.Properties.Name -notcontains "Stop") {
    $settings.hooks | Add-Member -MemberType NoteProperty -Name Stop -Value @()
}

$existing = @($settings.hooks.Stop)
$already = $false
foreach ($entry in $existing) {
    foreach ($inner in @($entry.hooks)) {
        if ($inner.command -eq $command) { $already = $true }
    }
}

if ($already) {
    Write-Host "Kept   .claude\settings.json (the hook was already wired)"
} else {
    $entry = [PSCustomObject]@{
        hooks = @([PSCustomObject]@{ type = "command"; command = $command })
    }
    $settings.hooks.Stop = @($existing + $entry)
    Write-Host "Wired  .claude\settings.json"
}

# UTF8Encoding($false) is the whole point: no BOM. Set-Content -Encoding UTF8
# writes one on PowerShell 5.1, and a BOM here disables every hook in the repo.
$json = $settings | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($settingsPath, $json, (New-Object Text.UTF8Encoding $false))

# --- Prove it, rather than assume it ----------------------------------------

$check = & node -e "const b=require('fs').readFileSync(process.argv[1]); if (b[0]===0xEF) { console.log('BOM'); process.exit(1) } const j=JSON.parse(b.toString('utf8')); const wired=JSON.stringify(j.hooks && j.hooks.Stop || []).includes('answer-to-relay'); console.log(wired ? 'ok' : 'unwired'); process.exit(wired ? 0 : 1)" $settingsPath 2>&1
if ($LASTEXITCODE -ne 0) { Fail "settings.json did not come out right ($check)." }

& node --check $destination
if ($LASTEXITCODE -ne 0) { Fail "The hook itself does not parse." }

Write-Host "Checked settings.json parses and the hook is wired." -ForegroundColor Green

# --- Committing -------------------------------------------------------------

if ($Commit) {
    Push-Location $Repo
    try {
        & git add .claude/hooks/answer-to-relay.mjs .claude/settings.json
        & git commit -m "Install the PocketClaude relay hook"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Nothing to commit - it was already up to date."
        }
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "Installed into $Repo"
Write-Host ""
Write-Host "Still to do, and the hook stays silent until both are true:"
Write-Host "  1. Commit and push this to the branch your cloud sessions run."
if (-not $Commit) {
    Write-Host "     (re-run with -Commit to have this do the commit for you)"
}
Write-Host "  2. Set RELAY_ANSWER_URL and RELAY_ANSWER_TOKEN on that repository's"
Write-Host "     environment at claude.ai/code. The app's Settings screen shows"
Write-Host "     both values ready to copy."
