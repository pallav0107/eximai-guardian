param(
  [string]$ConfigPath = "$PSScriptRoot\config\guardian.config.json",
  [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-EnvPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  return [Environment]::ExpandEnvironmentVariables($p)
}

if (-not (Test-Path $ConfigPath)) {
  throw "Config not found: $ConfigPath"
}

$cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$alertsPath = Expand-EnvPath $cfg.alertsPath
if (-not $alertsPath) {
  $alertsPath = "$env:ProgramData\EximAI\Guardian\alerts.json"
}

$alerts = @()
if (Test-Path $alertsPath) {
  try { $alerts = @(Get-Content -Raw -Path $alertsPath | ConvertFrom-Json) } catch { $alerts = @() }
}

# newest first
$alerts = @($alerts | Sort-Object ts -Descending)

$rows = ($alerts | ForEach-Object {
  $ts = [string]$_.ts
  $sev = [string]$_.severity
  $title = [string]$_.title
  $body = [string]$_.body
  $safeBody = ($body -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') -replace "\r?\n","<br/>"
  $safeTitle = ($title -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
  "<tr><td class='ts'>$ts</td><td class='sev sev-$sev'>$sev</td><td><div class='title'>$safeTitle</div><div class='body'>$safeBody</div></td></tr>"
}) -join "\n"

$html = @"
<!doctype html>
<html>
<head>
  <meta charset='utf-8' />
  <meta name='viewport' content='width=device-width, initial-scale=1' />
  <title>EximAI Guardian — Alerts</title>
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial;margin:24px;background:#0b1020;color:#e8eeff}
    .wrap{max-width:1100px;margin:0 auto}
    .card{background:#0f1630;border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:16px}
    h1{margin:0 0 6px 0;font-size:20px}
    .muted{color:rgba(232,238,255,.65);font-size:13px}
    table{width:100%;border-collapse:collapse;margin-top:12px}
    td,th{padding:10px;border-top:1px solid rgba(255,255,255,.08);vertical-align:top;font-size:13px}
    .ts{white-space:nowrap;color:rgba(232,238,255,.7)}
    .sev{font-weight:600;text-transform:uppercase;font-size:12px}
    .sev-info{color:#7dd3fc}
    .sev-warn{color:#fbbf24}
    .sev-critical{color:#fb7185}
    .title{font-weight:600;margin-bottom:6px}
    .body{color:rgba(232,238,255,.75);line-height:1.35}
    .empty{margin-top:10px;color:rgba(232,238,255,.75)}
    code{background:rgba(255,255,255,.08);padding:2px 6px;border-radius:8px}
  </style>
</head>
<body>
  <div class='wrap'>
    <div class='card'>
      <h1>EximAI Guardian — Local Alerts</h1>
      <div class='muted'>Source: <code>$alertsPath</code></div>

      $(if ($alerts.Count -eq 0) { "<div class='empty'>No alerts yet. Run <code>guardian.ps1 -Check</code> (or wait for the scheduled task).</div>" } else { "<table><thead><tr><th style='width:190px'>Time</th><th style='width:90px'>Severity</th><th>Alert</th></tr></thead><tbody>$rows</tbody></table>" })
    </div>
  </div>
</body>
</html>
"@

$outPath = Join-Path $PSScriptRoot 'alerts.html'
Set-Content -Path $outPath -Value $html -Encoding UTF8

Write-Host "Wrote: $outPath"

if ($Open) {
  Start-Process $outPath
}
