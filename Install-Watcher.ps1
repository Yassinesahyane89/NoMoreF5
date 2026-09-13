<#
.SYNOPSIS
    Registers a Windows scheduled task that runs Watch-Pdf.ps1 every 10 minutes.

.DESCRIPTION
    - Creates config.json from config.example.json, with a random ntfy topic, if it does not exist.
    - Registers (or replaces) the task for the current user. The task runs only while you are
      logged in, which is what allows it to show desktop notifications.
    Run it again any time to change the interval. Run Uninstall-Watcher.ps1 to stop watching.

.PARAMETER IntervalMinutes
    Minutes between two checks. Default: 10.

.PARAMETER NoVbsLauncher
    Starts powershell.exe directly instead of going through run-hidden.vbs. Use it if your
    company blocks Windows Script Host. Downside: a window flashes briefly at each check.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Install-Watcher.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1440)][int]$IntervalMinutes = 10,
    [string]$TaskName = 'FSTM-IASC-Watcher',
    [switch]$NoVbsLauncher
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# 1. config.json (ignored by git: it holds your private ntfy topic)
$configFile = Join-Path $Root 'config.json'
if (-not (Test-Path -LiteralPath $configFile)) {
    $topic = 'fstm-iasc-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $example = Get-Content -LiteralPath (Join-Path $Root 'config.example.json') -Raw -Encoding UTF8
    [IO.File]::WriteAllText($configFile, $example.Replace('fstm-iasc-CHANGE-ME', $topic))
    Write-Host 'Created config.json with a random ntfy topic.' -ForegroundColor Green
}
$config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json

# 2. Scheduled task
if ($NoVbsLauncher) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $Root `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Root 'Watch-Pdf.ps1'))
}
else {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -WorkingDirectory $Root `
        -Argument ('"{0}"' -f (Join-Path $Root 'run-hidden.vbs'))
}
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 365)
# StartWhenAvailable: if the PC was off or asleep at a check time, run as soon as it is back.
# Parallel: a run whose popup is still waiting for your click must not block the next checks.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances Parallel
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Checks the FSTM list PDFs from config.json every $IntervalMinutes minutes." -Force | Out-Null

# 3. The first scheduled check sends a "watcher is running" notification (see Watch-Pdf.ps1).
$logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $logDir 'start-pending') | Out-Null

# 4. What to do next
$watchScript = Join-Path $Root 'Watch-Pdf.ps1'
Write-Host ''
Write-Host "Task '$TaskName' registered: first check in 1 minute, then every $IntervalMinutes minutes." -ForegroundColor Green
Write-Host 'Watching:'
@($config.urls) | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host 'In about 1 minute you will get a "FSTM watcher is running" notification: it confirms the background checks work.'
Write-Host ''
if ($config.ntfyTopic -and $config.ntfyTopic -notlike '*CHANGE-ME*') {
    Write-Host 'Phone alerts:'
    Write-Host "  1. Install the 'ntfy' app (Android or iPhone)."
    Write-Host "  2. Tap +, then subscribe to this topic:  $($config.ntfyTopic)"
}
else {
    Write-Host 'Phone alerts are off: set ntfyTopic in config.json.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Test all notifications now:'
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File `"$watchScript`" -TestNotification"
Write-Host ''
Write-Host "Log file: $(Join-Path $Root 'logs\watcher.log')"
