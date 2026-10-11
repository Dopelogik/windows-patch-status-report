<#
.SYNOPSIS
    Reports Windows patch status: last installed update, pending reboot, uptime and (optionally) waiting updates.
.DESCRIPTION
    Read-only. Answers the questions an admin asks before a patch window or an audit:
    - When was this machine last patched, and is that older than your patch cycle?
    - Is a reboot pending (Component Based Servicing, Windows Update, pending file renames)?
    - How long since the last reboot?
    - Optionally: which updates are waiting to install (uses the Windows Update agent, can take a few minutes).
    Writes JSON and CSV reports. Run it across many machines with Invoke-FleetExecution.ps1 -ScriptPath.
.PARAMETER ExportPath
    Folder for the JSON and CSV reports. Created if missing.
.PARAMETER StaleDays
    A machine whose newest installed update is older than this many days is flagged. Default 35.
.PARAMETER IncludePendingUpdates
    Also query the Windows Update agent for updates that are available but not installed. Slower.
.EXAMPLE
    .\Get-PatchStatusReport.ps1
.EXAMPLE
    .\Get-PatchStatusReport.ps1 -IncludePendingUpdates -StaleDays 30 -ExportPath "C:\AuditReports\Patch"
.NOTES
    Exit codes: 0 = every check ran (findings such as a pending reboot are results, not failures),
    1 = FAILED (the report could not be written), 2 = PARTIAL (one or more checks could not run).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path -Path $env:PUBLIC -ChildPath 'AdminPackReports\PatchStatus'),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$StaleDays = 35,

    [Parameter(Mandatory = $false)]
    [switch]$IncludePendingUpdates
)

$ErrorActionPreference = 'Stop'
$script:ChecksNotRun = @()

function Add-CheckNotRun {
    param([string]$Check, [string]$Reason)
    $script:ChecksNotRun += [PSCustomObject]@{ Check = $Check; Result = 'check could not run'; Reason = $Reason }
    Write-Host "  -> CHECK COULD NOT RUN: ${Check}: $Reason" -ForegroundColor Red
}

$Report = [ordered]@{
    ComputerName        = $env:COMPUTERNAME
    GeneratedAt         = (Get-Date).ToString('s')
    OS                  = $null
    OSVersion           = $null
    LastBootTime        = $null
    UptimeDays          = $null
    LastPatchDate       = $null
    DaysSinceLastPatch  = $null
    PatchStale          = $null
    RebootPending       = $null
    RebootReasons       = @()
    PendingUpdateCount  = $null
    PendingUpdates      = @()
    Findings            = @()
    ChecksNotRun        = @()
}

Write-Host "=== Patch Status Report: $env:COMPUTERNAME ===" -ForegroundColor Cyan

# 1. OS and uptime
Write-Host "`n[1/4] Operating system and uptime..." -ForegroundColor Yellow
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $Report.OS = $os.Caption
    $Report.OSVersion = $os.Version
    $Report.LastBootTime = $os.LastBootUpTime.ToString('s')
    $Report.UptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    Write-Host "  -> $($os.Caption) ($($os.Version)), up $($Report.UptimeDays) days" -ForegroundColor Gray
} catch {
    Add-CheckNotRun -Check 'OperatingSystem' -Reason $_.Exception.Message
}

# 2. Last installed update
Write-Host "`n[2/4] Last installed update..." -ForegroundColor Yellow
try {
    $hotfixes = @(Get-CimInstance -ClassName Win32_QuickFixEngineering)
    $dated = @($hotfixes | Where-Object { $_.InstalledOn } | ForEach-Object {
        [PSCustomObject]@{ HotFixID = $_.HotFixID; InstalledOn = [datetime]$_.InstalledOn }
    })
    if ($dated.Count -gt 0) {
        $latest = $dated | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
        $Report.LastPatchDate = $latest.InstalledOn.ToString('yyyy-MM-dd')
        $Report.DaysSinceLastPatch = [int]((Get-Date) - $latest.InstalledOn).TotalDays
        $Report.PatchStale = ($Report.DaysSinceLastPatch -gt $StaleDays)
        Write-Host "  -> Newest update $($latest.HotFixID) installed $($Report.LastPatchDate) ($($Report.DaysSinceLastPatch) days ago)" -ForegroundColor Gray
        if ($Report.PatchStale) {
            $Report.Findings += "Last update is $($Report.DaysSinceLastPatch) days old (threshold $StaleDays)."
        }
    } else {
        Add-CheckNotRun -Check 'LastPatchDate' -Reason 'No installed update reported an install date.'
    }
} catch {
    Add-CheckNotRun -Check 'LastPatchDate' -Reason $_.Exception.Message
}

# 3. Pending reboot
Write-Host "`n[3/4] Pending reboot..." -ForegroundColor Yellow
try {
    $reasons = @()
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'Component Based Servicing'
    }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update'
    }
    $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if ($sessionManager.PSObject.Properties['PendingFileRenameOperations'] -and $sessionManager.PendingFileRenameOperations) {
        $reasons += 'Pending file rename operations'
    }
    $Report.RebootPending = ($reasons.Count -gt 0)
    $Report.RebootReasons = $reasons
    if ($Report.RebootPending) {
        $Report.Findings += "Reboot pending: $($reasons -join ', ')."
        Write-Host "  -> Reboot pending: $($reasons -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "  -> No reboot pending" -ForegroundColor Gray
    }
} catch {
    Add-CheckNotRun -Check 'RebootPending' -Reason $_.Exception.Message
}

# 4. Waiting updates (optional)
if ($IncludePendingUpdates) {
    Write-Host "`n[4/4] Searching Windows Update for waiting updates (this can take a few minutes)..." -ForegroundColor Yellow
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0 and Type=''Software''')
        $pending = @()
        foreach ($update in $result.Updates) {
            $kb = @($update.KBArticleIDs) -join ','
            $pending += [PSCustomObject]@{
                Title    = $update.Title
                KB       = $kb
                Severity = $update.MsrcSeverity
            }
        }
        $Report.PendingUpdateCount = $pending.Count
        $Report.PendingUpdates = $pending
        if ($pending.Count -gt 0) {
            $Report.Findings += "$($pending.Count) update(s) waiting to install."
        }
        Write-Host "  -> $($pending.Count) update(s) waiting" -ForegroundColor Gray
    } catch {
        Add-CheckNotRun -Check 'PendingUpdates' -Reason $_.Exception.Message
    }
} else {
    Write-Host "`n[4/4] Waiting updates: skipped (add -IncludePendingUpdates to check)" -ForegroundColor DarkGray
}

$Report.ChecksNotRun = $script:ChecksNotRun

# Export
try {
    if (-not (Test-Path -Path $ExportPath)) {
        New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonFile = Join-Path -Path $ExportPath -ChildPath "PatchStatus_$($env:COMPUTERNAME)_$stamp.json"
    $csvFile = Join-Path -Path $ExportPath -ChildPath "PatchStatus_$($env:COMPUTERNAME)_$stamp.csv"
    [PSCustomObject]$Report | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
    [PSCustomObject]@{
        ComputerName       = $Report.ComputerName
        OS                 = $Report.OS
        UptimeDays         = $Report.UptimeDays
        LastPatchDate      = $Report.LastPatchDate
        DaysSinceLastPatch = $Report.DaysSinceLastPatch
        PatchStale         = $Report.PatchStale
        RebootPending      = $Report.RebootPending
        PendingUpdateCount = $Report.PendingUpdateCount
        ChecksNotRun       = @($Report.ChecksNotRun).Count
    } | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
} catch {
    Write-Host "FAILED: could not write the report to ${ExportPath}: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
if (@($script:ChecksNotRun).Count -gt 0) {
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " PARTIAL: $(@($script:ChecksNotRun).Count) check(s) could not run. Report: $jsonFile" -ForegroundColor Red
    foreach ($c in $script:ChecksNotRun) { Write-Host "   - $($c.Check): $($c.Reason)" -ForegroundColor Red }
    Write-Host "==========================================================" -ForegroundColor Red
    exit 2
}

$color = if (@($Report.Findings).Count -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "==========================================================" -ForegroundColor $color
Write-Host " Patch status complete | Findings: $(@($Report.Findings).Count) | Report: $jsonFile" -ForegroundColor $color
foreach ($f in $Report.Findings) { Write-Host "   - $f" -ForegroundColor $color }
Write-Host "==========================================================" -ForegroundColor $color
exit 0
