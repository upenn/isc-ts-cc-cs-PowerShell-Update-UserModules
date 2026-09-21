# isc-ts-cc-cs-PowerShell-Update-UserModules
A simple PowerShell script to update a user's modules, and clean up old versions of the modules.

`Update-UserModules.ps1` works on Windows, macOS and Linux. It only touches modules installed with `Install-Module` in the **CurrentUser** scope. Modules installed for all users are left alone.

## What it does

1. **Update:** checks the repository (PSGallery by default) for a newer version of each user-scope module and installs it.
2. **Clean up:** keeps the newest version of each module plus a set number of older versions (default 1, so versions *n* and *n-1*), and uninstalls the rest.

Every action is written to a log file. By default the script prints nothing to the console.

## Requirements

- Windows PowerShell 5.1, or PowerShell 7+ on Windows, macOS or Linux
- PowerShellGet (`Get-InstalledModule`, `Find-Module`, `Update-Module`, `Uninstall-Module`)

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-LogPath` | `./Update-UserModules_<yyyyMMdd-HHmmss>.log` | Log file path. If you give a folder, the default file name is created inside it. |
| `-KeepVersions` | `1` | Number of older versions to keep alongside the newest. `0` keeps only the newest. |
| `-CleanupOnly` | off | Skip the update step and only remove old versions. |
| `-Name` | `*` | Module name filter; wildcards allowed. |
| `-Repository` | `PSGallery` | Repository to check for updates. |
| `-WhatIf` | off | Log what would happen without changing anything. |
| `-Verbose` | off | Also show each log line on screen. |
| `-Confirm` | off | Prompt before each update or removal. |

## Examples

```powershell
# Update everything, keep n and n-1, log to the current folder, no console output
./Update-UserModules.ps1

# Preview what would be updated and removed
./Update-UserModules.ps1 -WhatIf -Verbose

# Only remove old versions, keeping just the newest
./Update-UserModules.ps1 -CleanupOnly -KeepVersions 0

# Limit to specific modules and log to another folder
./Update-UserModules.ps1 -Name Microsoft.Graph*, ExchangeOnlineManagement -LogPath ~/Logs -Verbose
```

## Log format

Syslog-style lines with an ISO 8601 timestamp:

```
2026-09-21T08:59:43-04:00 myhost Update-UserModules[2372]: notice: Removed FakeMod 1.2.0
```

| Severity | Meaning |
|---|---|
| `info` | Progress and status |
| `notice` | A change was made (or would be, when the message starts with `WhatIf:`) |
| `warning` | Something was skipped, e.g. a module wasn't found in the repository |
| `err` | An update or removal failed |

## User module locations

| Platform | Path |
|---|---|
| Windows (PowerShell 5.1) | `<Documents>\WindowsPowerShell\Modules` |
| Windows (PowerShell 7+) | `<Documents>\PowerShell\Modules` |
| macOS / Linux | `$XDG_DATA_HOME/powershell/Modules` (default `~/.local/share/powershell/Modules`) |

## Exit codes

- `0`: every action succeeded (or there was nothing to do)
- `1`: at least one update or removal failed; see the log for details

## Notes

- A module version that's loaded in any open PowerShell session may fail to uninstall. Run from a fresh session (`pwsh -NoProfile`) for best results.
- On macOS/Linux, don't run the script with `sudo`. That switches `$HOME` to root's, so root's modules would be cleaned up instead of yours.
