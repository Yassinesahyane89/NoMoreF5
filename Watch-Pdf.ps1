<#
.SYNOPSIS
    Checks once whether the FSTM list PDFs are online. For each new one: downloads it,
    then alerts you on your phone (ntfy.sh), with a Windows toast and a popup.

.DESCRIPTION
    Meant to be run every 10 minutes by Task Scheduler (see Install-Watcher.ps1).
    Each run makes one HEAD request per URL listed in config.json:
      404            -> not published yet: log, next URL
      200            -> download, check it really is a PDF, alert
      other / error  -> log, next URL (the next run retries)
    A downloaded PDF doubles as the "done" marker for its URL: while it exists in
    downloads\, that URL is not checked any more. Delete it to watch it again.

.PARAMETER Url
    Checks these URLs instead of the ones in config.json, e.g. to test with a list
    that is already online.

.PARAMETER TestNotification
    Sends a test alert on every channel and exits, without checking any URL.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Watch-Pdf.ps1 -TestNotification
#>
[CmdletBinding()]
param(
    [string[]]$Url,
    [switch]$TestNotification
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar slows downloads down a lot in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Root        = $PSScriptRoot
$LogDir      = Join-Path $Root 'logs'
$LogFile     = Join-Path $LogDir 'watcher.log'
$DownloadDir = Join-Path $Root 'downloads'
$ConfigFile  = Join-Path $Root 'config.json'
New-Item -ItemType Directory -Force -Path $LogDir, $DownloadDir | Out-Null

function Write-Log([string]$Message) {
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
    }
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-HttpStatus([string]$Uri) {
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Head -UseBasicParsing -TimeoutSec 30 -Headers @{ 'Cache-Control' = 'no-cache' }
        return [int]$response.StatusCode
    }
    catch {
        # 4xx/5xx answers are thrown as exceptions that carry the response.
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw   # no answer at all: DNS failure, timeout, no network...
    }
}

function Test-IsPdf([string]$Path) {
    $header = New-Object byte[] 5
    $stream = [IO.File]::OpenRead($Path)
    try { $read = $stream.Read($header, 0, 5) } finally { $stream.Dispose() }
    return ($read -eq 5) -and ([Text.Encoding]::ASCII.GetString($header) -eq '%PDF-')
}

function Invoke-Check([string]$PdfUrl) {
    # Checks one URL. Outputs an alert item if its PDF was just found, nothing otherwise.
    $name   = [IO.Path]::GetFileName(([Uri]$PdfUrl).AbsolutePath)
    $target = Join-Path $DownloadDir $name

    if (Test-Path -LiteralPath $target) {
        Write-Log "$name was already found and downloaded, nothing to do. Delete downloads\$name to watch it again."
        return
    }

    try {
        $status = Get-HttpStatus $PdfUrl
    }
    catch {
        Write-Log "$name - network error, retrying next run: $($_.Exception.Message)"
        return
    }
    if ($status -eq 404) {
        Write-Log "$name not published yet (404)."
        return
    }
    if ($status -ne 200) {
        Write-Log "$name answered HTTP $status, retrying next run."
        return
    }

    # 200: download to a temporary file first so a half-downloaded file never counts as "found".
    $partial = "$target.part"
    try {
        Invoke-WebRequest -Uri $PdfUrl -OutFile $partial -UseBasicParsing -TimeoutSec 300 -Headers @{ 'Cache-Control' = 'no-cache' }
    }
    catch {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Write-Log "$name answered 200 but the download failed, retrying next run: $($_.Exception.Message)"
        return
    }
    if (-not (Test-IsPdf $partial)) {
        Remove-Item -LiteralPath $partial -Force
        Write-Log "$name answered 200 but the content is not a PDF, ignoring."
        return
    }
    Move-Item -LiteralPath $partial -Destination $target -Force
    Write-Log "FOUND: $name is online, saved to $target"

    [pscustomobject]@{
        Title   = "FSTM: $name is available!"
        Message = "The list is online. A copy was saved on your PC in downloads\$name."
        Url     = $PdfUrl
        Path    = $target
    }
}

function Send-PhoneAlert([string]$Title, [string]$Message, [string]$ClickUrl) {
    $topic = [string]$Config.ntfyTopic
    if (-not $topic -or $topic -like '*CHANGE-ME*') {
        Write-Log 'Phone alert skipped: set ntfyTopic in config.json.'
        return
    }
    $body = @{
        topic    = $topic
        title    = $Title
        message  = $Message
        priority = 5                      # max: pop-over notification + long vibration
        tags     = @('rotating_light')
        click    = $ClickUrl              # tapping the notification opens the PDF
    } | ConvertTo-Json
    Invoke-WebRequest -Uri 'https://ntfy.sh' -Method Post -UseBasicParsing -TimeoutSec 30 `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    Write-Log 'Phone alert sent.'
}

function Show-Toast([string]$Title, [string]$Message, [string]$ClickUrl) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Write-Log 'Toast skipped: it needs Windows PowerShell 5.1 (powershell.exe), not pwsh.'
        return
    }
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $t = [Security.SecurityElement]::Escape($Title)
    $m = [Security.SecurityElement]::Escape($Message)
    $u = [Security.SecurityElement]::Escape($ClickUrl)
    # scenario="reminder" keeps the toast on screen until you click it.
    $xml = @"
<toast scenario="reminder" activationType="protocol" launch="$u">
  <visual>
    <binding template="ToastGeneric">
      <text>$t</text>
      <text>$m</text>
    </binding>
  </visual>
  <actions>
    <action content="Open PDF" activationType="protocol" arguments="$u"/>
    <action content="" activationType="system" arguments="dismiss"/>
  </actions>
</toast>
"@
    $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $doc.LoadXml($xml)
    # Borrow Windows PowerShell's app id: Windows only shows toasts from registered apps.
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($doc))
    Write-Log 'Desktop toast shown.'
}

function Show-Popup([string]$Title, [string]$Message, [string]$PdfPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }   # keeps the popup above other windows
    try {
        if ($PdfPath) {
            $answer = [System.Windows.Forms.MessageBox]::Show($owner, "$Message`n`nOpen it now?", $Title, 'YesNo', 'Information')
            if ($answer -eq 'Yes') { Invoke-Item -LiteralPath $PdfPath }
        }
        else {
            [void][System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title, 'OK', 'Information')
        }
    }
    finally { $owner.Dispose() }
}

function Send-Alerts($Items) {
    # Each channel is independent so one failure does not block the others.
    # Phone and toasts for every item first; popups last because each one waits for a click.
    foreach ($item in $Items) {
        try { Send-PhoneAlert $item.Title $item.Message $item.Url } catch { Write-Log "Phone alert failed: $($_.Exception.Message)" }
        try { Show-Toast $item.Title $item.Message $item.Url }      catch { Write-Log "Toast failed: $($_.Exception.Message)" }
    }
    foreach ($item in $Items) {
        try { Show-Popup $item.Title $item.Message $item.Path }     catch { Write-Log "Popup failed: $($_.Exception.Message)" }
    }
}

# --- Main ---------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    Write-Log 'config.json not found: run Install-Watcher.ps1 (or copy config.example.json to config.json).'
    exit 1
}
try {
    $Config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Log "config.json is not valid JSON, check its quotes and commas: $($_.Exception.Message)"
    exit 1
}
$Urls = @($(if ($Url) { $Url } else { $Config.urls }) | Where-Object { $_ })
if (-not $Urls) {
    Write-Log 'No URL to check: add them to "urls" in config.json.'
    exit 1
}

if ($TestNotification) {
    Send-Alerts ([pscustomobject]@{
        Title   = 'TEST - FSTM watcher'
        Message = 'Notifications work. You will get this alert when a list is published.'
        Url     = $Urls[0]
        Path    = ''
    })
    exit 0
}

# Check every URL before alerting, so a popup waiting for a click never delays a check.
$found = foreach ($pdfUrl in $Urls) {
    try { Invoke-Check $pdfUrl }
    catch { Write-Log "Unexpected error on $pdfUrl, retrying next run: $($_.Exception.Message)" }
}
if ($found) { Send-Alerts $found }
