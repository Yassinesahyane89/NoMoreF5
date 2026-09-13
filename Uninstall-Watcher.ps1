<#
.SYNOPSIS
    Removes the scheduled task created by Install-Watcher.ps1. Config, logs and downloads are kept.

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
}
else {
    Write-Host "No scheduled task named '$TaskName' found."
}
