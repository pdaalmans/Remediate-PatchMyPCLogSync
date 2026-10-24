# Remediate-PatchMyPCLogSync
Move in this case Patch My PC logs over to the IME folder which is gathered via Microsoft Intune

An Intune Remediation (detection + remediation script pair) that mirrors Patch My PC client logs into the Intune Management Extension (IME) `Logs` folder. Because that folder is included when you trigger the **Collect diagnostics** remote action in Intune, the Patch My PC logs end up in the diagnostics zip without any extra effort.

| Script | Role |
|--------|------|
| [Detect-PatchMyPCLogSync.ps1](Detect-PatchMyPCLogSync.ps1) | **Detection:** checks whether the mirrored copies are in sync with the source logs. Exit `1` triggers the remediation. |
| [Remediate-PatchMyPCLogSync.ps1](Remediate-PatchMyPCLogSync.ps1) | **Remediation:** copies, truncates and cleans up the mirrored logs. |

## Credits

The idea for this script came from **Merlijn Van Waeyenberghe**, who suggested placing the Patch My PC logs under the IME log location that is gathered by the Intune **Collect diagnostics** remote action.

## How it works

![Flow of the Patch My PC log sync: a scheduled Intune Remediation mirrors the logs to the IME Logs\PatchMyPC folder, and an on-demand Collect diagnostics action includes them in the diagnostics zip](pmpc-log-sync-flow.png)

## What it does

**Detection** (`Detect-PatchMyPCLogSync.ps1`)

- Builds the list of source logs that should be mirrored, using the same selection as the remediation (age, per-file size and total size cap).
- Compares the last write time of each mirrored copy with its source. A missing copy or a different timestamp counts as out of sync.
- Exits `0` when everything is in sync or when no Patch My PC logs are found, and `1` when files need mirroring. Because both scripts apply the same total size cap, files dropped by the cap never count as out of sync.
- Makes no changes on the device.

**Remediation** (`Remediate-PatchMyPCLogSync.ps1`)

- Copies new or changed logs to `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PatchMyPC`, keeping the source folder structure under a subfolder per source.
- Opens source files with shared read access, so logs that are currently being written to can still be copied.
- Only mirrors logs written in the last `$MaxAgeDays` days.
- Truncates large logs to the last `$MaxFileSizeMB` MB (the newest entries are kept). See [Truncation](#truncation).
- Selects files newest-first so the mirror stays within `$MaxTotalSizeMB`, which keeps the diagnostics zip lean.
- Removes mirrored copies older than `$RetentionDays` days, enforces the total size cap and cleans up empty subfolders. When the cap is exceeded, copies that are no longer selected (for example rotated or deleted source logs) are removed first, oldest first. Selected copies are only removed as a last resort, so the remediation does not remove files that the detection then reports as missing.
- Sets the last write time of each copy to that of the source, so a detection script can reliably compare the two.

## Truncation

Logs larger than `$MaxFileSizeMB` are not copied in full. The remediation keeps only the end of the log, because the newest entries are usually the ones you need for troubleshooting:

- The copy starts with a marker line, so it is clear the file was truncated:
  `<<< Truncated by PatchMyPC log sync: last 10 MB of C:\ProgramData\PatchMyPC\Logs\PatchMyPC.log >>>`
- The marker counts towards `$MaxFileSizeMB`, so a truncated copy is never larger than the cap.
- The kept part starts at the first full line, so the copy does not begin with half a log entry.
- The encoding of the source is kept: for UTF-16 logs (such as MSI installation logs) and UTF-8 logs with a BOM, the BOM and marker are written in the same encoding.
- The copy contains the log as it was when it was selected, even if it is still being written to. This keeps the content in line with the timestamp of the copy, and a growing log cannot push the mirror over the size caps.

The source log is never changed; only the mirrored copy is truncated. A small log is copied as is.

## Source locations

| Name | Path | Files | Recurse |
|------|------|-------|---------|
| `PatchMyPCIntuneLogs` | `%ProgramData%\PatchMyPCIntuneLogs` | `*.log`, `*.lo_` | Yes |
| `PatchMyPCClient` | `%ProgramData%\PatchMyPC\Logs` | `*.log`, `*.lo_` | Yes |
| `PatchMyPCRoot` | `%ProgramData%\PatchMyPC` | `*.log` | No |
| `CCMLogs` | `%WinDir%\CCM\Logs` | `PatchMyPC*.log` | No |

If you changed the Patch My PC **Manage Installation Logging** folder, add it to the `$Sources` list (an example is included, commented out, in the script).

## Configuration

Settings are in the `CONFIG` block at the top of [Remediate-PatchMyPCLogSync.ps1](Remediate-PatchMyPCLogSync.ps1) and [Detect-PatchMyPCLogSync.ps1](Detect-PatchMyPCLogSync.ps1). **Keep the `CONFIG` block identical in both scripts**, otherwise detection and remediation disagree about what is in sync. `$RetentionDays` exists only in the remediation script.

| Variable | Default | Description |
|----------|---------|-------------|
| `$DestRoot` | `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\PatchMyPC` | Mirror destination inside the IME log folder |
| `$MaxAgeDays` | `14` | Only mirror source logs written in the last N days |
| `$MaxFileSizeMB` | `10` | Per-file cap; larger logs keep only the last N MB |
| `$MaxTotalSizeMB` | `75` | Size cap for the whole mirror folder |
| `$Sources` | see above | Folders, include patterns and recursion to mirror |
| `$RetentionDays` | `30` | Remove mirrored copies older than N days (remediation only) |

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
| `0` | `In sync: 12 log file(s) mirrored to C:\ProgramData\...\PatchMyPC.` | Compliant |
| `0` | `No Patch My PC logs found on this device.` | Nothing to mirror, compliant |
| `1` | `Out of sync: 3 of 12 log file(s) need mirroring.` | Remediation runs |
| `1` | `Detection error: ...` | The script hit an error |

**Remediation**

```
Copied: 12 | Failed: 0 | Removed: 3 | Mirror: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PatchMyPC
```

| Exit code | Meaning |
|-----------|---------|
| `0` | Success |
| `1` | One or more files failed to copy, or the script hit an error |

## Collecting the logs

In the Intune admin center, select the device and run **Collect diagnostics**. The Patch My PC logs are included in the diagnostics zip under the IME logs, in the `PatchMyPC` folder.

## License

[MIT](LICENSE)
