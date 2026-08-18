# Runs the relay, and restarts it after an update.
#
# The relay exits with code 42 when it has pulled new code. Anything else — a
# crash, or Ctrl+C — stops for good, so a broken build fails loudly instead of
# restarting in a loop forever.
#
# Use this rather than `node server.mjs` directly if you want the "Update relay"
# button in the app to work. Without a supervisor the relay can pull new code
# but has no way to start running it, which leaves the old version running with
# the new version on disk — the confusing half-state worth avoiding.

$ErrorActionPreference = "Stop"
$server = Join-Path $PSScriptRoot "server.mjs"

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
