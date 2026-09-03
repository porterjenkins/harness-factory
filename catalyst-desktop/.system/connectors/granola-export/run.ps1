# Wrapper: loads the GRANOLA_ vars from the shared .system\.env, then runs the
# exporter. The Windows peer of run.sh.
# Used by Task Scheduler (with -Log) and by hand (without).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 -Log
param([switch]$Log)
$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot

# --- .env -------------------------------------------------------------------
# Same contract as run.sh: KEY=VALUE, # comments, quotes stripped, and an
# already-set variable is left alone rather than overridden by the file.
#
# One config file for every connector, same as run.sh: .system\.env filtered to
# this connector's GRANOLA_ prefix. The filter is what keeps one connector from
# seeing another's credentials.
$envPrefix = "GRANOLA_"

# Anchor on the vault root instead of counting "..\.." hops: a miscount is
# silent, and only surfaces later as a confusing "GRANOLA_API_KEY is not set".
$vault  = (Resolve-Path (Join-Path $dir "..\..\..")).Path
$system = Join-Path $vault ".system"

function Import-EnvFile {
  param([string]$Path, [Parameter(Mandatory)][string]$Prefix)
  if (-not (Test-Path $Path)) { return }
  foreach ($line in Get-Content $Path) {
    if ($line -match '^\s*(#|$)' -or $line -notmatch '=') { continue }
    $name, $value = $line -split '=', 2
    $name = ($name.Trim() -replace '^export\s+', '')
    if (-not $name) { continue }
    if ($name -notlike "$Prefix*") { continue }
    # Never clobber an already-set variable, so a one-off
    #   $env:GRANOLA_TRANSCRIPT = 1; .\run.ps1
    # wins over the file. Matches run.sh and debug.mjs.
    if (Test-Path "Env:$name") { continue }
    $value = $value.Trim().Trim('"').Trim("'")
    Set-Item -Path "Env:$name" -Value $value
  }
}

Import-EnvFile -Path (Join-Path $system ".env") -Prefix $envPrefix

# --- log trim ---------------------------------------------------------------
# Cap at the last N runs (default 1000). A "run" starts with the "Fetching note
# list" marker line. Keep the most recent (N-1) so this run's output brings the
# file to ~N. Unlike run.sh there is no open append handle to preserve: this
# script owns the writing, so a plain rewrite is safe.
$logPath = Join-Path $dir "export.log"
$keepRuns = if ($env:GRANOLA_LOG_KEEP_RUNS) { [int]$env:GRANOLA_LOG_KEEP_RUNS } else { 1000 }
if ((Test-Path $logPath) -and $keepRuns -gt 1) {
  $markers = @(Select-String -Path $logPath -Pattern "Fetching note list from Granola" -SimpleMatch |
                 ForEach-Object { $_.LineNumber })
  if ($markers.Count -ge $keepRuns) {
    $start = $markers[$markers.Count - ($keepRuns - 1)]   # 1-based line number
    $lines = Get-Content $logPath
    Set-Content -Path $logPath -Encoding utf8 -Value $lines[($start - 1)..($lines.Count - 1)]
  }
}

# --- node -------------------------------------------------------------------
# node.exe is a real executable, not a .cmd shim, so PATH resolution is enough.
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
  foreach ($c in @("$env:ProgramFiles\nodejs\node.exe",
                   "${env:ProgramFiles(x86)}\nodejs\node.exe",
                   "$env:LOCALAPPDATA\Volta\bin\node.exe",
                   "$env:APPDATA\nvm\node.exe")) {
    if (Test-Path $c) { $node = $c; break }
  }
}
if (-not $node) { Write-Error "node not found"; exit 1 }

# Scheduled runs go to the log; by-hand runs print to the terminal, matching the
# launchd/run.sh split on the Mac.
$script = Join-Path $dir "export.mjs"
if ($Log) {
  & $node $script *>&1 | Out-File -FilePath $logPath -Append -Encoding utf8
} else {
  & $node $script
}
exit $LASTEXITCODE
