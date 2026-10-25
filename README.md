# Remediate-PatchMyPCLogSync

An Intune Remediation (detection + remediation script pair) that copies Patch My PC logs into `C:\Windows\CCM\Logs`, so they end up in the zip of the Intune **Collect diagnostics** remote action.

Collect diagnostics only gathers `.log` files **directly in** `C:\Windows\CCM\Logs` (`%WinDir%\CCM\Logs\*.log`): no subfolders and no other extensions. The logs are therefore copied flat into that folder, with a prefix that shows which folder they came from (see [File naming](#file-naming)).

| Script | Role |
|--------|------|
| [Detect-PatchMyPCLogSync.ps1](Detect-PatchMyPCLogSync.ps1) | **Detection:** checks whether the mirrored copies are in sync with the source logs. Exit `1` triggers the remediation. |
| [Remediate-PatchMyPCLogSync.ps1](Remediate-PatchMyPCLogSync.ps1) | **Remediation:** copies, truncates and cleans up the mirrored logs. |

## Credits

The idea for this script came from **Merlijn Van Waeyenberghe**, who suggested placing the Patch My PC logs in a log location that is gathered by the Intune **Collect diagnostics** remote action.

## How it works

![Flow of the Patch My PC log sync: a scheduled Intune Remediation copies the logs flat into C:\Windows\CCM\Logs as PMPC-*.log, and an on-demand Collect diagnostics action includes them in the diagnostics zip](pmpc-log-sync-flow.png)

## What it does

**Detection** (`Detect-PatchMyPCLogSync.ps1`)

- Builds the list of logs that should be copied, using the same selection as the remediation.
- Compares the last write time of each mirrored copy with its source. A missing copy or a different timestamp counts as out of sync.
- Exits `0` when everything is in sync or when no Patch My PC logs are found, and `1` when files need mirroring.
- Makes no changes on the device.

**Remediation** (`Remediate-PatchMyPCLogSync.ps1`)

- Copies new or changed logs flat to `C:\Windows\CCM\Logs`, with short names such as `PMPC-Intune-ScriptRunner.log` (see [File naming](#file-naming)). The folder is created when it does not exist.
- Opens source files with shared read access, so logs that are currently being written to can still be copied.
- Only mirrors logs written in the last `$MaxAgeDays` days.
- Truncates large logs to the last `$MaxFileSizeMB` MB (the newest entries are kept). See [Truncation](#truncation).
- Selects files newest-first so the mirror stays within `$MaxTotalSizeMB`, which keeps the diagnostics zip lean.
- Removes copies that are no longer selected: the source log was rotated or deleted, is older than `$MaxAgeDays` days, or was dropped by the `$MaxTotalSizeMB` cap. Only files named `PMPC-*.log` are ever removed; the ConfigMgr client logs and other files in `C:\Windows\CCM\Logs` are never touched.

## File naming

![How source logs are named in C:\Windows\CCM\Logs: PMPC, the source tag and the file name, ending in .log](pmpc-log-sync-naming.png)

Every copy is stored as `<FilePrefix>-<Name>-<relative path>.log`. Names are kept as short as possible while still showing where the log came from:

- `<FilePrefix>` is `PMPC` by default. It marks the file as a copy made by these scripts, and the remediation only ever removes files with this prefix.
- `<Name>` is the short tag of the source in `$Sources` (`Intune`, `Client`, `Root` or `Install`, see [Source locations](#source-locations)), so you can tell which folder the log came from.
- `<relative path>` is the path below that source folder, with `\` replaced by `_`. A leading `PatchMyPC-` is dropped, because the prefix already says so.
- Files that do not end in `.log` (such as rotated `.lo_` logs) get `.log` appended, because Collect diagnostics only gathers `*.log` from this folder.
- Names longer than `$MaxNameLength` (80) characters are cut off and end in `~` plus a short code made from the source path, so they stay unique.

| Source file | Copy in `C:\Windows\CCM\Logs` |
|-------------|-----------------------------------|
| `C:\ProgramData\PatchMyPCIntuneLogs\PatchMyPC-ScriptRunner.log` | `PMPC-Intune-ScriptRunner.log` |
| `C:\ProgramData\PatchMyPCIntuneLogs\PatchMyPC-ScriptRunner.lo_` | `PMPC-Intune-ScriptRunner.lo_.log` |
| `C:\ProgramData\PatchMyPCIntuneLogs\Sub\Nested.log` | `PMPC-Intune-Sub_Nested.log` |
| `C:\ProgramData\PatchMyPC\Logs\PatchMyPC.log` | `PMPC-Client-PatchMyPC.log` |
| `C:\ProgramData\PatchMyPCInstallLogs\7-Zip.log` | `PMPC-Install-7-Zip.log` |
| `C:\ProgramData\PatchMyPCInstallLogs\Microsoft Visual C++ 2015-2022 Redistributable (x64) 14.40.33816_x64_MSI_Install.log` | `PMPC-Install-Microsoft Visual C++ 2015-2022 Redistributable (x64) 14.~0445a7.log` |

## Truncation

Logs larger than `$MaxFileSizeMB` are not copied in full. The remediation keeps only the end of the log, because the newest entries are usually the ones you need for troubleshooting:

- The copy starts with a marker line, so it is clear the file was truncated:
  `<<< Truncated by PatchMyPC log sync: last 10 MB of C:\ProgramData\PatchMyPC\Logs\PatchMyPC.log >>>`
- The kept part starts at the first full line, so the copy does not begin with half a log entry.
- The encoding of the source is kept, so UTF-16 logs (such as MSI installation logs) stay readable.

The source log is never changed; only the mirrored copy is truncated. A small log is copied as is.

## Source locations

| Name | Path | Files | Recurse |
|------|------|-------|---------|
| `Intune` | `%ProgramData%\PatchMyPCIntuneLogs` | `*.log`, `*.lo_` | Yes |
| `Client` | `%ProgramData%\PatchMyPC\Logs` | `*.log`, `*.lo_` | Yes |
| `Root` | `%ProgramData%\PatchMyPC` | `*.log` | No |
| `Install` | `%ProgramData%\PatchMyPCInstallLogs` | `*.log` | Yes |

The `Name` is the tag in the file name of each copy, so keep it short and unique when you add a source.

`Install` holds the installation logs (for example MSI logs) written by Patch My PC when **Manage Installation Logging** is enabled. If you changed that folder, update the `Install` path in the `$Sources` list of both scripts, or add your folder as an extra entry (an example is included, commented out, in the scripts).

The `PatchMyPC*.log` files that the ConfigMgr client writes to `C:\Windows\CCM\Logs` are not mirrored: they are already in the collected folder.

## Configuration

Settings are in the `CONFIG` block at the top of [Remediate-PatchMyPCLogSync.ps1](Remediate-PatchMyPCLogSync.ps1) and [Detect-PatchMyPCLogSync.ps1](Detect-PatchMyPCLogSync.ps1). **Keep the `CONFIG` block identical in both scripts**, otherwise detection and remediation disagree about what is in sync.

| Variable | Default | Description |
|----------|---------|-------------|
| `$DestRoot` | `%WinDir%\CCM\Logs` | Destination; the copies are stored flat, because Collect diagnostics does not gather subfolders |
| `$FilePrefix` | `PMPC` | Prefix of every copy; cleanup only touches files with this prefix |
| `$MaxNameLength` | `80` | Longer file names are cut off and get a short code, so they stay unique |
| `$MaxAgeDays` | `14` | Only mirror source logs written in the last N days |
| `$MaxFileSizeMB` | `10` | Per-file cap; larger logs keep only the last N MB |
| `$MaxTotalSizeMB` | `75` | Size cap for all mirrored copies together |
| `$Sources` | see above | Folders, include patterns and recursion to mirror |

## Deployment

Create a script package under **Devices > Scripts and remediations** in the Intune admin center:

- **Detection script:** `Detect-PatchMyPCLogSync.ps1`
- **Remediation script:** `Remediate-PatchMyPCLogSync.ps1`
- **Run this script using the logged-on credentials:** No (runs as SYSTEM)
- **Run script in 64-bit PowerShell:** Yes
- **Schedule:** for example daily

## Output and exit codes

Both scripts write a one-line summary that shows up in the Intune remediation report.

**Detection**

| Exit code | Output example | Meaning |
|-----------|----------------|---------|
| `0` | `In sync: 12 log file(s) mirrored to C:\Windows\CCM\Logs.` | Compliant |
| `0` | `No Patch My PC logs found on this device.` | Nothing to mirror, compliant |
| `1` | `Out of sync: 3 of 12 log file(s) need mirroring.` | Remediation runs |
| `1` | `Detection error: ...` | The script hit an error |

**Remediation**

```
Copied: 12 | Failed: 0 | Removed: 3 | Mirror: C:\Windows\CCM\Logs
```

| Exit code | Meaning |
|-----------|---------|
| `0` | Success |
| `1` | One or more files failed to copy, or the script hit an error |

## Collecting the logs

In the Intune admin center, select the device and run **Collect diagnostics**. The Patch My PC logs are included in the diagnostics zip with the other CCM logs, as the `PMPC-*.log` files.

## License

[MIT](LICENSE)
