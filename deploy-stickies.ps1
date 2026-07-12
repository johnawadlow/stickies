param([Parameter(Mandatory = $true)][string]$Target)

$files = 'kanban.html', 'kanban.css', 'kanban.js', 'api.html',
         'start-stickies.ps1', 'stickies-db.ps1', 'stickies-mcp.ps1'

if (-not (Test-Path $Target)) {
  New-Item -ItemType Directory -Path $Target | Out-Null
}

foreach ($f in $files) {
  Copy-Item (Join-Path $PSScriptRoot $f) -Destination $Target -Force
}

Write-Host "Deployed $($files.Count) app files to $Target"
Write-Host "Data (stickies.db) is created next to the deployed scripts on first run."
