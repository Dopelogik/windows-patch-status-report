<#
.SYNOPSIS
    Reports Windows patch status: last installed update, pending reboot, uptime and (optionally) waiting updates.
.DESCRIPTION
    Read-only. Answers the questions an admin asks before a patch window or an audit:
    - When was this machine last patched, and is that older than your patch cycle?
    - Is a reboot pending (Component Based Servicing, Windows Update, pending file renames)?
    - How long since the last reboot?
    - Optionally: which updates are waiting to install (uses the Windows Update agent, can take a few minutes).

    Outputs one result object to the pipeline with a Status of OK, Partial or Failed, writes JSON and CSV
    reports, and sets an exit code for callers that only see exit codes (Task Scheduler, RMM tools).
.PARAMETER ExportPath
    Folder for the JSON and CSV reports. Created if missing.
.PARAMETER StaleDays
    A machine whose newest installed update is older than this many days is flagged. Default 35.
.PARAMETER IncludePendingUpdates
    Also query the Windows Update agent for updates that are available but not installed. Slower.
.EXAMPLE
    .\Get-PatchStatusReport.ps1
.EXAMPLE
    $r = .\Get-PatchStatusReport.ps1 -IncludePendingUpdates -StaleDays 30 -ExportPath "C:\AuditReports\Patch"
    $r.Status; $r.RebootReasons; $r.ChecksNotRun
.NOTES
    Status / exit code:
      OK      / 0 = every check ran. A pending reboot or stale patch is a finding, not a failure.
      Partial / 2 = one or more checks could not run (see ChecksNotRun for which and why).
      Failed  / 1 = the report files could not be written.
    Intune remediation treats exit 1 from a detection script as "non-compliant", so wrap this script
    rather than using it directly as an Intune detection script.
    Version 1.1: pipeline result object, generic lists instead of array +=, no script-scope writes.
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

$checksNotRun = [System.Collections.Generic.List[object]]::new()
$findings = [System.Collections.Generic.List[string]]::new()

function New-CheckNotRun {
    param([string]$Check, [string]$Reason)
    Write-Host "  -> CHECK COULD NOT RUN: ${Check}: $Reason" -ForegroundColor Red
    [PSCustomObject]@{ Check = $Check; Reason = $Reason }
}

$Report = [ordered]@{
    ComputerName       = $env:COMPUTERNAME
    GeneratedAt        = (Get-Date).ToString('s')
    Status             = $null
    OS                 = $null
    OSVersion          = $null
    LastBootTime       = $null
    UptimeDays         = $null
    LastPatchDate      = $null
    DaysSinceLastPatch = $null
    PatchStale         = $null
    RebootPending      = $null
    RebootReasons      = @()
    PendingUpdateCount = $null
    PendingUpdates     = @()
    Findings           = @()
    ChecksNotRun       = @()
    ReportPath         = $null
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
    $checksNotRun.Add((New-CheckNotRun -Check 'OperatingSystem' -Reason $_.Exception.Message))
}

# 2. Last installed update
Write-Host "`n[2/4] Last installed update..." -ForegroundColor Yellow
try {
    $latest = Get-CimInstance -ClassName Win32_QuickFixEngineering |
        Where-Object { $_.InstalledOn } |
        Select-Object -Property HotFixID, @{ Name = 'InstalledOn'; Expression = { [datetime]$_.InstalledOn } } |
        Sort-Object -Property InstalledOn -Descending |
        Select-Object -First 1
    if ($latest) {
        $Report.LastPatchDate = $latest.InstalledOn.ToString('yyyy-MM-dd')
        $Report.DaysSinceLastPatch = [int]((Get-Date) - $latest.InstalledOn).TotalDays
        $Report.PatchStale = ($Report.DaysSinceLastPatch -gt $StaleDays)
        Write-Host "  -> Newest update $($latest.HotFixID) installed $($Report.LastPatchDate) ($($Report.DaysSinceLastPatch) days ago)" -ForegroundColor Gray
        if ($Report.PatchStale) {
            $findings.Add("Last update is $($Report.DaysSinceLastPatch) days old (threshold $StaleDays).")
        }
    } else {
        $checksNotRun.Add((New-CheckNotRun -Check 'LastPatchDate' -Reason 'No installed update reported an install date.'))
    }
} catch {
    $checksNotRun.Add((New-CheckNotRun -Check 'LastPatchDate' -Reason $_.Exception.Message))
}

# 3. Pending reboot
Write-Host "`n[3/4] Pending reboot..." -ForegroundColor Yellow
try {
    $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $reasons = @(
        if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            'Component Based Servicing'
        }
        if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            'Windows Update'
        }
        if ($sessionManager.PSObject.Properties['PendingFileRenameOperations'] -and $sessionManager.PendingFileRenameOperations) {
            'Pending file rename operations'
        }
    )
    $Report.RebootPending = ($reasons.Count -gt 0)
    $Report.RebootReasons = $reasons
    if ($Report.RebootPending) {
        $findings.Add("Reboot pending: $($reasons -join ', ').")
        Write-Host "  -> Reboot pending: $($reasons -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "  -> No reboot pending" -ForegroundColor Gray
    }
} catch {
    $checksNotRun.Add((New-CheckNotRun -Check 'RebootPending' -Reason $_.Exception.Message))
}

# 4. Waiting updates (optional)
if ($IncludePendingUpdates) {
    Write-Host "`n[4/4] Searching Windows Update for waiting updates (this can take a few minutes)..." -ForegroundColor Yellow
    try {
        $searcher = (New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateSearcher()
        $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $pending = @(
            foreach ($update in $searchResult.Updates) {
                [PSCustomObject]@{
                    Title    = $update.Title
                    KB       = @($update.KBArticleIDs) -join ','
                    Severity = $update.MsrcSeverity
                }
            }
        )
        $Report.PendingUpdateCount = $pending.Count
        $Report.PendingUpdates = $pending
        if ($pending.Count -gt 0) {
            $findings.Add("$($pending.Count) update(s) waiting to install.")
        }
        Write-Host "  -> $($pending.Count) update(s) waiting" -ForegroundColor Gray
    } catch {
        $checksNotRun.Add((New-CheckNotRun -Check 'PendingUpdates' -Reason $_.Exception.Message))
    }
} else {
    Write-Host "`n[4/4] Waiting updates: skipped (add -IncludePendingUpdates to check)" -ForegroundColor DarkGray
}

$Report.Findings = $findings.ToArray()
$Report.ChecksNotRun = $checksNotRun.ToArray()
$Report.Status = if ($checksNotRun.Count -gt 0) { 'Partial' } else { 'OK' }

# Export. The ordered dictionary goes to JSON as is (nested arrays kept). The CSV is a flattened
# one-row summary, because Export-Csv would write the array properties as "System.Object[]".
try {
    if (-not (Test-Path -Path $ExportPath)) {
        New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonFile = Join-Path -Path $ExportPath -ChildPath "PatchStatus_$($env:COMPUTERNAME)_$stamp.json"
    $csvFile = Join-Path -Path $ExportPath -ChildPath "PatchStatus_$($env:COMPUTERNAME)_$stamp.csv"
    $Report.ReportPath = $jsonFile
    $Report | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
    [PSCustomObject]@{
        ComputerName       = $Report.ComputerName
        Status             = $Report.Status
        OS                 = $Report.OS
        UptimeDays         = $Report.UptimeDays
        LastPatchDate      = $Report.LastPatchDate
        DaysSinceLastPatch = $Report.DaysSinceLastPatch
        PatchStale         = $Report.PatchStale
        RebootPending      = $Report.RebootPending
        RebootReasons      = $Report.RebootReasons -join '; '
        PendingUpdateCount = $Report.PendingUpdateCount
        ChecksNotRun       = ($Report.ChecksNotRun | ForEach-Object { $_.Check }) -join '; '
    } | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
} catch {
    Write-Host "FAILED: could not write the report to ${ExportPath}: $($_.Exception.Message)" -ForegroundColor Red
    $Report.Status = 'Failed'
    $Report.ReportPath = $null
    [PSCustomObject]$Report
    exit 1
}

Write-Host ""
if ($Report.Status -eq 'Partial') {
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " PARTIAL: $($checksNotRun.Count) check(s) could not run. Report: $jsonFile" -ForegroundColor Red
    foreach ($c in $checksNotRun) { Write-Host "   - $($c.Check): $($c.Reason)" -ForegroundColor Red }
    Write-Host "==========================================================" -ForegroundColor Red
    [PSCustomObject]$Report
    exit 2
}

$color = if ($findings.Count -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "==========================================================" -ForegroundColor $color
Write-Host " Patch status complete | Findings: $($findings.Count) | Report: $jsonFile" -ForegroundColor $color
foreach ($f in $findings) { Write-Host "   - $f" -ForegroundColor $color }
Write-Host "==========================================================" -ForegroundColor $color
[PSCustomObject]$Report
exit 0
