# Windows Patch Status Report

A read-only PowerShell script that tells you, honestly, whether a Windows machine is patched:

- Newest installed update and how many days ago (flagged when older than `-StaleDays`, default 35)
- Pending reboot from three sources: Component Based Servicing, Windows Update, pending file renames
- Uptime since last boot
- Optional: updates waiting to install, from the Windows Update agent (`-IncludePendingUpdates`)

JSON and CSV reports are written to `C:\Users\Public\AdminPackReports\PatchStatus` (change with `-ExportPath`).

## Honest results

Every run puts one result object on the pipeline and sets a matching exit code, so it works both in a console and in tools that only see exit codes.
The object starts with `Script`, `ComputerName`, `Status` and `ExitCode`, followed by the patch details and `ReportPath`. The JSON and CSV reports are written from that same object.

Exit codes follow the Nagios plugin convention, so the script drops into most monitoring tools as is:

| Status | Exit code | Nagios | Meaning |
|---|---|---|---|
| OK | 0 | OK | Every check ran and nothing needs attention. |
| Warning | 1 | WARNING | Every check ran, with findings: pending reboot, stale patch, or waiting updates. `Findings` lists them. |
| Failed | 2 | CRITICAL | The report could not be written. |
| Partial | 3 | UNKNOWN | A check could not run. `ChecksNotRun` (and the red banner) says which one and why. |

A check that could not run outranks findings, so a skipped check never hides behind a plain Warning.

```powershell
$r = .\Get-PatchStatusReport.ps1
$r.Status          # OK / Warning / Failed / Partial
$r.Findings
$r.RebootReasons
$r.ChecksNotRun
```

In scheduled tasks and RMM tools, check the exit code so a skipped check never looks like a pass. For Intune remediation, wrap it: Intune reads any non-zero exit from a detection script as "non-compliant".

## Changes in 2.0.0

- **Exit codes now follow Nagios** (thanks to feedback on r/PowerShell). If you alert on the 1.x codes, update your rules: findings are now 1, a failed report is now 2, and a check that could not run is now 3.
- Uptime is calculated in UTC, so a daylight saving change since boot no longer shifts it by an hour.
- Install dates from `Win32_QuickFixEngineering` are parsed safely. Non-US date formats and hex timestamps no longer break the last-patch check, and updates with no readable date are skipped instead of failing it.
- New `LastPatchKB` property.
- The CSV is now a view of the same result object instead of a separately built one.

## Limits

The last-patch date comes from `Win32_QuickFixEngineering`, which only lists updates installed through Component Based Servicing. It is a good signal for Windows cumulative and security updates, not a full install history.

## Usage

```powershell
Unblock-File .\Get-PatchStatusReport.ps1
.\Get-PatchStatusReport.ps1
.\Get-PatchStatusReport.ps1 -StaleDays 30 -IncludePendingUpdates -ExportPath C:\Reports\Patch
```

Requires Windows PowerShell 5.1. No modules to install.

---

Part of the **Windows & M365 SysAdmin Automation Toolkit**: 13 PowerShell scripts for solo IT admins and MSPs, all with the same honest exit codes. https://outerorigin.gumroad.com/l/windows-m365-sysadmin-toolkit

Questions or bug reports: outeroriginsupport@gmail.com
