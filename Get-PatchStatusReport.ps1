<#
.SYNOPSIS
    Reports Windows patch status: last installed update, pending reboot, uptime and (optionally) waiting updates.
.DESCRIPTION
    Read-only. Answers the questions an admin asks before a patch window or an audit:
    - When was this machine last patched, and is that older than your patch cycle?
    - Is a reboot pending (Component Based Servicing, Windows Update, pending file renames)?
    - How long since the last reboot?
    - Optionally: which updates are waiting to install (uses the Windows Update agent, can take a few minutes).

    Outputs one result object to the pipeline with a Status of OK, Warning, Failed or Partial, writes JSON
    and CSV reports from that same object, and sets a Nagios style exit code for callers that only see
    exit codes (Task Scheduler, RMM and monitoring tools).
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
    $r.Status; $r.Findings; $r.RebootReasons; $r.ChecksNotRun
.NOTES
    Result: one object with a Status, plus the matching exit code (same meanings as Nagios plugins).
      OK      / 0 = every check ran and nothing needs attention.
      Warning / 1 = every check ran, with findings (pending reboot, stale patch, waiting updates).
      Failed  / 2 = the report files could not be written.
      Partial / 3 = one or more checks could not run (see ChecksNotRun for which and why).
    Intune remediation treats any non-zero exit from a detection script as "non-compliant", so wrap this
    script rather than using it directly as an Intune detection script.
    Version 2.0.0 (exit codes changed from 1.x: see README).
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

function ConvertTo-InstallDate {
    # Win32_QuickFixEngineering.InstalledOn is a string. It is usually M/d/yyyy, but some machines
    # store other formats or a hex FILETIME, and a plain [datetime] cast throws on those.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    $parsed = [datetime]::MinValue
    $formats = [string[]]@('M/d/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd', 'yyyyMMdd', 'd/M/yyyy', 'dd/MM/yyyy', 'd.M.yyyy', 'dd.MM.yyyy')
    if ([datetime]::TryParseExact($text, $formats, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    if ($text -match '^[0-9A-Fa-f]{16}$') {
        try { return [datetime]::FromFileTime([Convert]::ToInt64($text, 16)) } catch { }
    }
    if ([datetime]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

$Report = [ordered]@{
    Script             = 'Get-PatchStatusReport.ps1'
    ComputerName       = $env:COMPUTERNAME
    GeneratedAt        = (Get-Date).ToString('s')
    Status             = $null
    ExitCode           = $null
    OS                 = $null
    OSVersion          = $null
    LastBootTime       = $null
    UptimeDays         = $null
    LastPatchDate      = $null
    LastPatchKB        = $null
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
    # Both sides in UTC, so a daylight saving change since boot does not shift uptime by an hour.
    $Report.UptimeDays = [math]::Round(((Get-Date).ToUniversalTime() - $os.LastBootUpTime.ToUniversalTime()).TotalDays, 1)
    Write-Host "  -> $($os.Caption) ($($os.Version)), up $($Report.UptimeDays) days" -ForegroundColor Gray
} catch {
    $checksNotRun.Add((New-CheckNotRun -Check 'OperatingSystem' -Reason $_.Exception.Message))
}

# 2. Last installed update
Write-Host "`n[2/4] Last installed update..." -ForegroundColor Yellow
try {
    $hotfixes = @(Get-CimInstance -ClassName Win32_QuickFixEngineering)
    $dated = @(
        foreach ($hf in $hotfixes) {
            $installedOn = ConvertTo-InstallDate -Value $hf.InstalledOn
            if ($installedOn) { [PSCustomObject]@{ HotFixID = $hf.HotFixID; InstalledOn = $installedOn } }
        }
    )
    $undated = $hotfixes.Count - $dated.Count
    if ($undated -gt 0) {
        Write-Host "  -> $undated update(s) had no readable install date and were skipped" -ForegroundColor DarkGray
    }
    $latest = $dated | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
    if ($latest) {
        $Report.LastPatchDate = $latest.InstalledOn.ToString('yyyy-MM-dd')
        $Report.LastPatchKB = $latest.HotFixID
        $Report.DaysSinceLastPatch = ((Get-Date).Date - $latest.InstalledOn.Date).Days
        $Report.PatchStale = ($Report.DaysSinceLastPatch -gt $StaleDays)
        Write-Host "  -> Newest update $($latest.HotFixID) installed $($Report.LastPatchDate) ($($Report.DaysSinceLastPatch) days ago)" -ForegroundColor Gray
        if ($Report.PatchStale) {
            $findings.Add("Last update is $($Report.DaysSinceLastPatch) days old (threshold $StaleDays).")
        }
    } else {
        $checksNotRun.Add((New-CheckNotRun -Check 'LastPatchDate' -Reason 'No installed update reported a readable install date.'))
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

# Status and exit code (Nagios style). A check that could not run outranks findings, so a skipped
# check never hides behind a plain Warning.
$Report.Findings = $findings.ToArray()
$Report.ChecksNotRun = $checksNotRun.ToArray()
if ($checksNotRun.Count -gt 0) {
    $Report.Status = 'Partial'; $Report.ExitCode = 3
} elseif ($findings.Count -gt 0) {
    $Report.Status = 'Warning'; $Report.ExitCode = 1
} else {
    $Report.Status = 'OK'; $Report.ExitCode = 0
}

# One result object. The JSON keeps the nested detail; the CSV is a one-row view of the same object
# with the array properties joined into strings (Export-Csv would otherwise write "System.Object[]").
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$jsonFile = Join-Path -Path $ExportPath -ChildPath "PatchStatus_$($env:COMPUTERNAME)_$stamp.json"
$csvFile = Join-Path -Path $ExportPath -ChildPath "PatchStatus_$($env:COMPUTERNAME)_$stamp.csv"
$Report.ReportPath = $jsonFile
$Result = [PSCustomObject]$Report

$csvColumns = @(
    'ComputerName', 'GeneratedAt', 'Status', 'ExitCode', 'OS', 'OSVersion', 'UptimeDays',
    'LastPatchDate', 'LastPatchKB', 'DaysSinceLastPatch', 'PatchStale', 'RebootPending',
    @{ Name = 'RebootReasons'; Expression = { $_.RebootReasons -join '; ' } },
    'PendingUpdateCount',
    @{ Name = 'Findings'; Expression = { $_.Findings -join '; ' } },
    @{ Name = 'ChecksNotRun'; Expression = { ($_.ChecksNotRun | ForEach-Object { $_.Check }) -join '; ' } }
)

try {
    if (-not (Test-Path -Path $ExportPath)) {
        New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    }
    $Result | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
    $Result | Select-Object -Property $csvColumns | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
} catch {
    Write-Host "FAILED: could not write the report to ${ExportPath}: $($_.Exception.Message)" -ForegroundColor Red
    $Result.Status = 'Failed'
    $Result.ExitCode = 2
    $Result.ReportPath = $null
}

Write-Host ""
$color = switch ($Result.Status) {
    'OK'      { 'Green' }
    'Warning' { 'Yellow' }
    default   { 'Red' }
}
Write-Host "==========================================================" -ForegroundColor $color
switch ($Result.Status) {
    'Partial' {
        Write-Host " PARTIAL: $($checksNotRun.Count) check(s) could not run. Report: $jsonFile" -ForegroundColor $color
        foreach ($c in $checksNotRun) { Write-Host "   - $($c.Check): $($c.Reason)" -ForegroundColor $color }
    }
    'Failed' {
        Write-Host " FAILED: the checks ran but the report could not be written." -ForegroundColor $color
    }
    default {
        Write-Host " Patch status $($Result.Status) | Findings: $($findings.Count) | Report: $jsonFile" -ForegroundColor $color
    }
}
foreach ($f in $findings) { Write-Host "   - $f" -ForegroundColor $color }
Write-Host "==========================================================" -ForegroundColor $color

$Result
exit $Result.ExitCode
