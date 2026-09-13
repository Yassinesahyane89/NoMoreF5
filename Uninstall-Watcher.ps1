<#
.SYNOPSIS
    Removes the scheduled task created by Install-Watcher.ps1 and sends a "watcher stopped"
    notification. Config, logs and downloads are kept.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-Watcher.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'FSTM-IASC-Watcher'
)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
    # Cancel a "watcher is running" notification still waiting for its first check, then announce the stop.
    Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'logs\start-pending') -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Watch-Pdf.ps1') -AnnounceStop
}
else {
    Write-Host "No scheduled task named '$TaskName' found."
}
