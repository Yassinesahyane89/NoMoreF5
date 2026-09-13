<#
.SYNOPSIS
    Checks once whether the FSTM list PDFs are online. As soon as one is: downloads it,
    alerts you on your phone (ntfy.sh), with a Windows toast and a popup, then stops the
    watcher for good.

.DESCRIPTION
    Meant to be run every 10 minutes by Task Scheduler (see Install-Watcher.ps1).
    Each run makes one HEAD request per URL listed in config.json:
      404            -> not published yet: log, next URL
      200            -> download, check it really is a PDF
      other / error  -> log, next URL (the next run retries)
    If a list was found, the run alerts you, sends a "watcher stopped" notification and
    removes the scheduled task: no check runs after that. As a safety net, while the PDF
    of a watched URL exists in downloads\, runs exit straight away.

    The first run after Install-Watcher.ps1 also sends a "watcher is running" notification,
    and Uninstall-Watcher.ps1 uses -AnnounceStop to send a "watcher stopped" one.

.PARAMETER Url
    Checks these URLs instead of the ones in config.json, e.g. to test with a list that is
    already online. Such manual runs never stop the watcher.

.PARAMETER TestNotification
    Sends a test alert on every channel and exits, without checking any URL.

.PARAMETER AnnounceStop
    Sends the "watcher stopped" notification and exits, without checking any URL.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Watch-Pdf.ps1 -TestNotification
#>
[CmdletBinding()]
param(
    [string[]]$Url,
    [switch]$TestNotification,
    [switch]$AnnounceStop
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar slows downloads down a lot in Windows PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$TaskName    = 'FSTM-IASC-Watcher'                   # scheduled task created by Install-Watcher.ps1
$Root        = $PSScriptRoot
$LogDir      = Join-Path $Root 'logs'
$LogFile     = Join-Path $LogDir 'watcher.log'
$StartMarker = Join-Path $LogDir 'start-pending'     # created by Install-Watcher.ps1
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

function Get-PdfPath([string]$PdfUrl) {
    # Where the PDF of this URL is saved once found.
    Join-Path $DownloadDir ([IO.Path]::GetFileName(([Uri]$PdfUrl).AbsolutePath))
}

function Invoke-Check([string]$PdfUrl) {
    # Checks one URL. Outputs an alert item if its PDF was just found, nothing otherwise.
    $target = Get-PdfPath $PdfUrl
    $name   = Split-Path $target -Leaf

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
        Name    = $name
        Title   = "FSTM: $name is available!"
        Message = "The list is online. A copy was saved on your PC in downloads\$name."
        Url     = $PdfUrl
        Path    = $target
    }
}

function Send-PhoneAlert([string]$Title, [string]$Message, [string]$ClickUrl, [int]$Priority = 5, [string]$Tag = 'rotating_light') {
    $topic = [string]$Config.ntfyTopic
    if (-not $topic -or $topic -like '*CHANGE-ME*') {
        Write-Log 'Phone alert skipped: set ntfyTopic in config.json.'
        return
    }
    $body = @{
        topic    = $topic
        title    = $Title
        message  = $Message
        priority = $Priority              # 5 = max (pop-over + long vibration), 3 = normal
        tags     = @($Tag)                # emoji shown next to the title
    }
    if ($ClickUrl) { $body.click = $ClickUrl }   # tapping the notification opens the PDF
    $json = $body | ConvertTo-Json
    Invoke-WebRequest -Uri 'https://ntfy.sh' -Method Post -UseBasicParsing -TimeoutSec 30 `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
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
    $sticky = ''
    $actions = ''
    if ($ClickUrl) {
        # A list alert stays on screen until you click it, with a button to open the PDF.
        $u = [Security.SecurityElement]::Escape($ClickUrl)
        $sticky = " scenario=`"reminder`" activationType=`"protocol`" launch=`"$u`""
        $actions = "<actions><action content=`"Open PDF`" activationType=`"protocol`" arguments=`"$u`"/><action content=`"`" activationType=`"system`" arguments=`"dismiss`"/></actions>"
    }
    $xml = @"
<toast$sticky>
  <visual>
    <binding template="ToastGeneric">
      <text>$t</text>
      <text>$m</text>
    </binding>
  </visual>
  $actions
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
    # Phone and toast for every item. Each channel is independent so one failure does not block the others.
    foreach ($item in $Items) {
        try { Send-PhoneAlert $item.Title $item.Message $item.Url } catch { Write-Log "Phone alert failed: $($_.Exception.Message)" }
        try { Show-Toast $item.Title $item.Message $item.Url }      catch { Write-Log "Toast failed: $($_.Exception.Message)" }
    }
}

function Show-Popups($Items) {
    # Always called last: each popup waits for a click.
    foreach ($item in $Items) {
        try { Show-Popup $item.Title $item.Message $item.Path } catch { Write-Log "Popup failed: $($_.Exception.Message)" }
    }
}

function Send-Status([string]$Title, [string]$Message, [string]$Tag) {
    # Watcher started/stopped: normal priority on the phone, a plain toast on the PC, no popup.
    Write-Log $Title
    try { Send-PhoneAlert -Title $Title -Message $Message -Priority 3 -Tag $Tag } catch { Write-Log "Phone alert failed: $($_.Exception.Message)" }
    try { Show-Toast -Title $Title -Message $Message }                           catch { Write-Log "Toast failed: $($_.Exception.Message)" }
}

function Stop-Watcher([string]$Reason) {
    # Announces the stop first, then removes the scheduled task so no check runs any more.
    Send-Status -Title 'FSTM watcher stopped' -Tag 'stop_sign' `
        -Message "$Reason No more checks will run. Run Install-Watcher.ps1 to start again."
    Remove-Item -LiteralPath $StartMarker -Force -ErrorAction SilentlyContinue
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log "Scheduled task '$TaskName' removed."
        }
    }
    catch {
        Write-Log "Could not remove scheduled task '$TaskName', later runs will exit by themselves: $($_.Exception.Message)"
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

if ($AnnounceStop) {
    Send-Status -Title 'FSTM watcher stopped' -Tag 'stop_sign' `
        -Message 'The lists are no longer being checked. Run Install-Watcher.ps1 to start again.'
    exit 0
}

$Urls = @($(if ($Url) { $Url } else { $Config.urls }) | Where-Object { $_ })
if (-not $Urls) {
    Write-Log 'No URL to check: add them to "urls" in config.json.'
    exit 1
}
$invalid = @($Urls | Where-Object { -not [Uri]::IsWellFormedUriString($_, [UriKind]::Absolute) })
if ($invalid) {
    Write-Log "Invalid URL, fix it in config.json: $($invalid -join ', ')"
    exit 1
}

if ($TestNotification) {
    $test = [pscustomobject]@{
        Title   = 'TEST - FSTM watcher'
        Message = 'Notifications work. You will get this alert when a list is published.'
        Url     = $Urls[0]
        Path    = ''
    }
    Send-Alerts $test
    Show-Popups $test
    exit 0
}

# Safety net: a list found earlier means the job is done, even if the task could not be removed.
$foundEarlier = @($Urls | Where-Object { Test-Path -LiteralPath (Get-PdfPath $_) })
if ($foundEarlier) {
    $name = Split-Path (Get-PdfPath $foundEarlier[0]) -Leaf
    Write-Log "$name was already found, so the watcher is stopped. To watch again, delete downloads\$name or remove its URL from config.json, then run Install-Watcher.ps1."
    exit 0
}

# Check every URL of this run first, so lists published at the same time are all downloaded and alerted.
$found = @(foreach ($pdfUrl in $Urls) {
    try { Invoke-Check $pdfUrl }
    catch { Write-Log "Unexpected error on $pdfUrl, retrying next run: $($_.Exception.Message)" }
})

if ($found) {
    Send-Alerts $found
    if ($Url) { Write-Log 'Manual run with -Url: the watcher is not stopped.' }
    else { Stop-Watcher -Reason "Found: $(@($found.Name) -join ', ')." }
    Show-Popups $found
    exit 0
}

# First background run after Install-Watcher.ps1: proves the scheduled checks really work.
# Manual test runs with -Url leave the marker alone.
if (-not $Url -and (Test-Path -LiteralPath $StartMarker)) {
    Remove-Item -LiteralPath $StartMarker -Force
    Send-Status -Title 'FSTM watcher is running' -Tag 'white_check_mark' `
        -Message "First background check done. Watching $($Urls.Count) list(s): you will be alerted as soon as one is published."
}
