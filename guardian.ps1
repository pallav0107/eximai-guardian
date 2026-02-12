param(
  [switch]$Init,
  [switch]$Check,
  [switch]$InstallTask,
  [switch]$UninstallTask,
  [string]$ConfigPath = "$PSScriptRoot\config\guardian.config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-EnvPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  return [Environment]::ExpandEnvironmentVariables($p)
}

function Ensure-ParentDir([string]$filePath) {
  $dir = Split-Path -Parent $filePath
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Write-Log([string]$logPath, [string]$msg) {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Ensure-ParentDir $logPath
  Add-Content -Path $logPath -Value "$ts  $msg"
}

function Load-Config([string]$path) {
  if (-not (Test-Path $path)) {
    throw "Config not found: $path"
  }
  $cfg = Get-Content -Raw -Path $path | ConvertFrom-Json
  $cfg.baselinePath = Expand-EnvPath $cfg.baselinePath
  $cfg.statePath = Expand-EnvPath $cfg.statePath
  $cfg.logPath = Expand-EnvPath $cfg.logPath
  return $cfg
}

function Get-ListeningPorts() {
  Get-NetTCPConnection -State Listen |
    Select-Object LocalAddress, LocalPort, OwningProcess |
    Sort-Object LocalAddress, LocalPort
}

function Get-EstablishedForPort([int]$port) {
  Get-NetTCPConnection -State Established -LocalPort $port -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess |
    Sort-Object RemoteAddress, RemotePort
}

function Get-ScheduledTasksSnapshot() {
  # keep it lightweight: name + path + state
  Get-ScheduledTask |
    Select-Object TaskName, TaskPath, State |
    Sort-Object TaskPath, TaskName
}

function Get-StartupRegistrySnapshot() {
  $paths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
  )

  $items = @()
  foreach ($p in $paths) {
    if (Test-Path $p) {
      $props = Get-ItemProperty -Path $p
      foreach ($name in $props.PSObject.Properties.Name) {
        if ($name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
        $items += [pscustomobject]@{ Path=$p; Name=$name; Value=($props.$name) }
      }
    }
  }
  $items | Sort-Object Path, Name
}

function Snapshot-System([object]$cfg) {
  $snap = [ordered]@{}
  $snap.timestamp = (Get-Date).ToString('o')
  $snap.listening = @(Get-ListeningPorts)
  $snap.tasks = @(Get-ScheduledTasksSnapshot)
  $snap.startup = @(Get-StartupRegistrySnapshot)
  return $snap
}

function Save-Json([string]$path, $obj) {
  Ensure-ParentDir $path
  ($obj | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
}

function Load-Json([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  return (Get-Content -Raw -Path $path | ConvertFrom-Json)
}

function Diff-Array($before, $after, [string[]]$keys) {
  $fmt = {
    param($x)
    ($keys | ForEach-Object { "$($_)=$($x.$_)" }) -join ';'
  }
  $b = @($before | ForEach-Object { & $fmt $_ })
  $a = @($after | ForEach-Object { & $fmt $_ })
  return [pscustomobject]@{
    added = @($a | Where-Object { $_ -notin $b })
    removed = @($b | Where-Object { $_ -notin $a })
  }
}

function Send-EmailAlert($cfg, [string]$subject, [string]$body) {
  if (-not $cfg.email.enabled) { return }

  $smtp = $cfg.email.smtpServer
  $port = [int]$cfg.email.smtpPort
  $ssl = [bool]$cfg.email.useSsl
  $user = $cfg.email.username
  $pass = $cfg.email.password

  $secure = ConvertTo-SecureString $pass -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($user, $secure)

  foreach ($to in $cfg.email.to) {
    Send-MailMessage -SmtpServer $smtp -Port $port -UseSsl:$ssl -Credential $cred -From $cfg.email.from -To $to -Subject $subject -Body $body
  }
}

function Send-RelayEvent($cfg, [string]$kind, [string]$severity, [string]$title, [string]$body, $raw) {
  if (-not $cfg.relay) { return }
  if (-not $cfg.relay.enabled) { return }
  if ([string]::IsNullOrWhiteSpace([string]$cfg.relay.baseUrl)) { return }
  if ([string]::IsNullOrWhiteSpace([string]$cfg.relay.deviceToken)) { return }

  try {
    $timeoutMs = 5000
    if ($cfg.relay.timeoutMs) { $timeoutMs = [int]$cfg.relay.timeoutMs }

    $url = ([string]$cfg.relay.baseUrl).TrimEnd('/') + '/v1/events'
    $payload = @{
      kind = $kind
      severity = $severity
      title = $title
      body = $body
      raw = $raw
      ts = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6

    $headers = @{ Authorization = "Bearer $($cfg.relay.deviceToken)" }

    Invoke-RestMethod -Method Post -Uri $url -Headers $headers -ContentType 'application/json' -Body $payload -TimeoutSec ([Math]::Ceiling($timeoutMs / 1000.0)) | Out-Null
  } catch {
    # Don't crash checks if relay is unreachable; just log
    Write-Log $cfg.logPath "Relay send failed: $($_.Exception.Message)"
  }
}

function Check-Exposure($cfg) {
  $alerts = @()

  foreach ($port in $cfg.protectedPorts) {
    $listeners = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    foreach ($l in $listeners) {
      $addr = [string]$l.LocalAddress
      $isLoopback = ($addr -eq '127.0.0.1' -or $addr -eq '::1')
      if (-not $isLoopback) {
        $alerts += "Port $port is listening on non-loopback address: $addr"
      }
    }

    $est = Get-EstablishedForPort -port $port
    foreach ($c in $est) {
      $r = [string]$c.RemoteAddress
      $remoteIsLoopback = ($r -eq '127.0.0.1' -or $r -eq '::1')
      if (-not $remoteIsLoopback) {
        $alerts += "Port $port has established connection from remote address: ${r}:$($c.RemotePort)"
      }
    }
  }

  if ($cfg.allowRemoteConnections -eq $true) {
    # user opted in; downgrade exposure alerts (still log)
    return @()
  }

  return $alerts
}

function Run-Check([object]$cfg) {
  $logPath = $cfg.logPath

  $baseline = Load-Json $cfg.baselinePath
  if (-not $baseline) {
    Write-Log $logPath "No baseline found. Run with -Init first."
    return
  }

  $snap = Snapshot-System $cfg

  $diffListening = Diff-Array $baseline.listening $snap.listening @('LocalAddress','LocalPort','OwningProcess')
  $diffTasks = Diff-Array $baseline.tasks $snap.tasks @('TaskPath','TaskName','State')
  $diffStartup = Diff-Array $baseline.startup $snap.startup @('Path','Name','Value')

  $exposureAlerts = Check-Exposure $cfg

  $hasDiff = ($diffListening.added.Count -gt 0 -or $diffListening.removed.Count -gt 0 -or
              $diffTasks.added.Count -gt 0 -or $diffTasks.removed.Count -gt 0 -or
              $diffStartup.added.Count -gt 0 -or $diffStartup.removed.Count -gt 0)

  if (-not $hasDiff -and $exposureAlerts.Count -eq 0) {
    return
  }

  $lines = @()
  if ($exposureAlerts.Count -gt 0) {
    $lines += "EXPOSURE ALERTS:"; $lines += $exposureAlerts; $lines += ''
  }

  if ($diffListening.added.Count -gt 0 -or $diffListening.removed.Count -gt 0) {
    $lines += 'LISTENING PORTS DIFF:'
    if ($diffListening.added.Count -gt 0) { $lines += '  Added:'; $lines += ($diffListening.added | ForEach-Object { "    $_" }) }
    if ($diffListening.removed.Count -gt 0) { $lines += '  Removed:'; $lines += ($diffListening.removed | ForEach-Object { "    $_" }) }
    $lines += ''
  }

  if ($diffTasks.added.Count -gt 0 -or $diffTasks.removed.Count -gt 0) {
    $lines += 'SCHEDULED TASKS DIFF:'
    if ($diffTasks.added.Count -gt 0) { $lines += '  Added:'; $lines += ($diffTasks.added | ForEach-Object { "    $_" }) }
    if ($diffTasks.removed.Count -gt 0) { $lines += '  Removed:'; $lines += ($diffTasks.removed | ForEach-Object { "    $_" }) }
    $lines += ''
  }

  if ($diffStartup.added.Count -gt 0 -or $diffStartup.removed.Count -gt 0) {
    $lines += 'STARTUP REGISTRY DIFF:'
    if ($diffStartup.added.Count -gt 0) { $lines += '  Added:'; $lines += ($diffStartup.added | ForEach-Object { "    $_" }) }
    if ($diffStartup.removed.Count -gt 0) { $lines += '  Removed:'; $lines += ($diffStartup.removed | ForEach-Object { "    $_" }) }
    $lines += ''
  }

  $body = $lines -join "`r`n"

  Write-Log $logPath $body
  Save-Json $cfg.statePath $snap

  $subject = "$($cfg.email.subjectPrefix) Alert on $env:COMPUTERNAME"
  Send-EmailAlert $cfg $subject $body

  # Send a compact event to Relay Cloud (optional)
  $severity = if ($exposureAlerts.Count -gt 0) { 'critical' } elseif ($hasDiff) { 'warn' } else { 'info' }
  $title = "Guardian alert on $env:COMPUTERNAME"
  $raw = @{
    exposureAlerts = $exposureAlerts
    diffListening = $diffListening
    diffTasks = $diffTasks
    diffStartup = $diffStartup
  }
  Send-RelayEvent $cfg 'system_change' $severity $title $body $raw
}

function Init-Baseline([object]$cfg) {
  $snap = Snapshot-System $cfg
  Save-Json $cfg.baselinePath $snap
  Write-Log $cfg.logPath "Baseline created at $($cfg.baselinePath)"
}

function Install-Task([object]$cfg) {
  $taskName = 'EximAI Guardian'
  $scriptPath = "$PSScriptRoot\guardian.ps1"
  $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Check -ConfigPath `"$ConfigPath`""

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::MaxValue)
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
  Write-Log $cfg.logPath "Scheduled Task installed: $taskName"
}

function Uninstall-Task([object]$cfg) {
  $taskName = 'EximAI Guardian'
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Log $cfg.logPath "Scheduled Task removed: $taskName"
}

$cfg = Load-Config $ConfigPath

if ($Init) {
  Init-Baseline $cfg
  exit 0
}

if ($InstallTask) {
  Install-Task $cfg
  exit 0
}

if ($UninstallTask) {
  Uninstall-Task $cfg
  exit 0
}

# default action
Run-Check $cfg
