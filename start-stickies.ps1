param([int]$Port)

$root = $PSScriptRoot
. (Join-Path $root 'stickies-db.ps1')
$db = Open-StickiesDb (Join-Path $root 'stickies.db')

# Per-instance config lives next to the deployed scripts, like the db.
# An explicit -Port argument wins over the config file.
$config = @{ port = 8123; title = 'Stickies' }
$configPath = Join-Path $root 'stickies.config.json'
if (Test-Path $configPath) {
  try {
    $c = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    if ($c.port)  { $config.port  = [int]$c.port }
    if ($c.title) { $config.title = [string]$c.title }
  } catch {
    Write-Host "Ignoring stickies.config.json - not valid JSON: $($_.Exception.Message)"
  }
}
if ($PSBoundParameters.ContainsKey('Port')) { $config.port = $Port }
$Port = $config.port

$mime = @{
  '.html' = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'text/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.svg'  = 'image/svg+xml'
  '.png'  = 'image/png'
  '.ico'  = 'image/x-icon'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try {
  $listener.Start()
} catch {
  Write-Host "Could not listen on http://localhost:$Port/ - is the Stickies server already running?"
  Write-Host "If the board is already open in your browser, you're good. Otherwise: Get-NetTCPConnection -LocalPort $Port | Select-Object OwningProcess"
  exit 1
}

Write-Host "Stickies server running at http://localhost:$Port/  (Ctrl+C to stop)"
Start-Process "http://localhost:$Port/"

try {
  while ($listener.IsListening) {
    # GetContext() blocks in .NET, which locks Ctrl+C out until the next
    # request arrives. Waiting on the async task in 250ms slices returns
    # control to PowerShell often enough for Ctrl+C to be processed.
    $ctxTask = $listener.GetContextAsync()
    while (-not $ctxTask.Wait(250)) { }
    $ctx = $ctxTask.Result
    $req = $ctx.Request
    $res = $ctx.Response
    $res.Headers.Add('Cache-Control', 'no-store')
    try {
      $path = $req.Url.AbsolutePath

      if ($req.HttpMethod -eq 'POST' -and $path -eq '/op') {
        # Explicit UTF-8: $req.ContentEncoding defaults to ANSI under Windows
        # PowerShell 5.1, which mangles multibyte chars (em dashes etc.).
        $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $op = $null
        try { $op = $body | ConvertFrom-Json } catch {}
        if ($null -eq $op -or -not $op.kind) {
          $res.StatusCode = 400
          $bytes = [System.Text.Encoding]::UTF8.GetBytes('Body is not a valid op')
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
          continue
        }
        try {
          Invoke-StickiesOp $db $op
        } catch {
          $res.StatusCode = 400
          $bytes = [System.Text.Encoding]::UTF8.GetBytes("Op failed: $($_.Exception.Message)")
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
          Write-Host "POST /op $($op.kind) FAILED: $($_.Exception.Message)"
          continue
        }
        $res.ContentType = 'application/json'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        Write-Host "POST /op  $($op.kind)"
      }
      elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/config') {
        $res.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"title":' + ($config.title | ConvertTo-Json) + '}'))
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      }
      elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/data') {
        # Scoped reads (kb-t22): ?project=<id>, ?titles=1, ?list=1, ?archived=1
        # (list wins; the others compose). Bare /data stays the full live board.
        $q = $req.QueryString
        $json = Export-StickiesJson $db -ProjectId $q['project'] -TitlesOnly:($q['titles'] -eq '1') -ProjectList:($q['list'] -eq '1') -Archived:($q['archived'] -eq '1')
        $res.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      }
      elseif ($req.HttpMethod -eq 'GET') {
        if ($path -eq '/') { $path = '/stickies.html' }
        $file = [System.IO.Path]::GetFullPath((Join-Path $root ($path.TrimStart('/') -replace '/', '\')))
        if (-not $file.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $file -PathType Leaf)) {
          $res.StatusCode = 404
        }
        else {
          $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
          $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
          $bytes = [System.IO.File]::ReadAllBytes($file)
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
      }
      else {
        $res.StatusCode = 405
      }
    }
    catch {
      Write-Host "ERROR $($req.HttpMethod) $($req.Url.AbsolutePath): $_"
      try { $res.StatusCode = 500 } catch {}
    }
    finally {
      try { $res.OutputStream.Close() } catch {}
    }
  }
}
finally {
  if ($listener.IsListening) { $listener.Stop() }
  $db.Close()
}
