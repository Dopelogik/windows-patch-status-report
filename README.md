# Windows Patch Status Report

A read-only PowerShell script that tells you, honestly, whether a Windows machine is patched:

- Newest installed update and how many days ago (flagged when older than `-StaleDays`, default 35)
- Pending reboot from three sources: Component Based Servicing, Windows Update, pending file renames
- Uptime since last boot
- Optional: updates waiting to install, from the Windows Update agent (`-IncludePendingUpdates`)

JSON and CSV reports are written to `C:\Users\Public\AdminPackReports\PatchStatus` (change with `-ExportPath`).

## Honest results

Every run puts one result object on the pipeline and sets a matching exit code, so it works both in a console and in tools that only see exit codes.
The object starts with `Script`, `ComputerName`, `Status` and `ExitCode`, followed by the patch details and `ReportPath`.

| Status | Exit code | Meaning |
|---|---|---|
| OK | 0 | Every check ran. A pending reboot or stale patch is a finding, not a failure. |
| Partial | 2 | A check could not run. `ChecksNotRun` (and the red banner) says which one and why. |
| Failed | 1 | The report could not be written. |

```powershell
$r = .\Get-PatchStatusReport.ps1
$r.Status          # OK / Partial / Failed
$r.RebootReasons
$r.ChecksNotRun
```

In scheduled tasks and RMM tools, check the exit code so a skipped check never looks like a pass. For Intune remediation, wrap it: Intune reads exit 1 from a detection script as "non-compliant".

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
