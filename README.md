# isc-ts-cc-cs-PowerShell-Update-UserModules
A PowerShell module to update a user's modules, and clean up old versions of the modules.

The module works on Windows, macOS and Linux and provides two scope-specific commands:

- `Update-CurrentUserModules` manages modules installed in the **CurrentUser** scope.
- `Update-AllUsersModules` manages modules installed in the **AllUsers** scope and should be run from an elevated PowerShell session.

## Installation

Clone or copy this repository into a module directory, then import the manifest:

```powershell
Import-Module ./Update-UserModules.psd1
Get-Command Update-CurrentUserModules, Update-AllUsersModules
```

The functions are stored in `Functions/` and exported by the module manifest.

## What it does

1. **Update:** checks the repository (PSGallery by default) for a newer version of each module in the selected scope and installs it.
2. **Clean up:** keeps the newest version of each module plus a set number of older versions (default 1, so versions *n* and *n-1*), and uninstalls the rest.

Every action is written to a log file. By default the commands print nothing to the console.

## Requirements

- Windows PowerShell 5.1, or PowerShell 7+ on Windows, macOS or Linux
- PowerShellGet (`Get-InstalledModule`, `Find-Module`, `Update-Module`, `Uninstall-Module`)

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-LogPath` | `./<CommandName>_<yyyyMMdd-HHmmss>.log` | Log file path. If you give a folder, the default file name is created inside it. |
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
Update-CurrentUserModules

# Preview what would be updated and removed
Update-CurrentUserModules -WhatIf -Verbose

# Only remove old versions, keeping just the newest
Update-CurrentUserModules -CleanupOnly -KeepVersions 0

# Limit to specific modules and log to another folder
Update-CurrentUserModules -Name Microsoft.Graph*, ExchangeOnlineManagement -LogPath ~/Logs -Verbose

# Preview updates and cleanup for modules installed for all users
Update-AllUsersModules -WhatIf -Verbose

# Update and clean up all-users modules (run PowerShell elevated)
Update-AllUsersModules
```

## Log format

Syslog-style lines with an ISO 8601 timestamp:

```
2026-09-21T08:59:43-04:00 myhost Update-CurrentUserModules[2372]: notice: Removed FakeMod 1.2.0
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

AllUsers module locations:

| Platform | Path |
|---|---|
| Windows (PowerShell 5.1) | `$env:ProgramFiles\WindowsPowerShell\Modules` |
| Windows (PowerShell 7+) | `$env:ProgramFiles\PowerShell\Modules` |
| macOS / Linux | `/usr/local/share/powershell/Modules` |

## Errors

The commands throw a terminating error when a required PowerShellGet command is unavailable or when one or more update/removal operations fail. See the generated log for details.

## Notes

- A module version that's loaded in any open PowerShell session may fail to uninstall. Run from a fresh session (`pwsh -NoProfile`) for best results.
- On macOS/Linux, don't run `Update-CurrentUserModules` with `sudo`. That switches `$HOME` to root's, so root's modules would be targeted instead of yours.
- Run `Update-AllUsersModules` in an elevated session (Run as Administrator on Windows or through `sudo pwsh` on macOS/Linux).
