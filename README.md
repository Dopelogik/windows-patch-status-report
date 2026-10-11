# Windows Patch Status Report

A read-only PowerShell script that tells you, honestly, whether a Windows machine is patched:

- Newest installed update and how many days ago (flagged when older than `-StaleDays`, default 35)
- Pending reboot from three sources: Component Based Servicing, Windows Update, pending file renames
- Uptime since last boot
- Optional: updates waiting to install, from the Windows Update agent (`-IncludePendingUpdates`)

JSON and CSV reports are written to `C:\Users\Public\AdminPackReports\PatchStatus` (change with `-ExportPath`).

## Honest exit codes

| Code | Meaning |
|---|---|
| 0 | Every check ran. A pending reboot or stale patch is a finding, not a failure. |
| 2 | PARTIAL: a check could not run. The red banner says which one and why. |
| 1 | FAILED: the report could not be written. |

Check `$LASTEXITCODE` in scheduled tasks and RMM tools so a skipped check never looks like a pass.

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
