<#
.SYNOPSIS
    Intune Remediation - DETECTION
    Checks whether Patch My PC client logs are mirrored into the IME Logs folder,
    so they are included in Intune "Collect diagnostics".

.NOTES
    Run as:            SYSTEM
    64-bit PowerShell: Yes
    Exit 0 = in sync (compliant), Exit 1 = out of sync (run remediation)
    Keep the CONFIG block identical in detection and remediation.
#>

#region CONFIG ---------------------------------------------------------------
$DestRoot   = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\PatchMyPC'
$MaxAgeDays = 14     # only mirror source logs written in the last N days
$MaxFileSizeMB  = 10   # per-file cap; larger logs keep only the last N MB
$MaxTotalSizeMB = 75   # cap for the whole mirror folder (keeps the diagnostics zip lean)

$Sources = @(
    [pscustomobject]@{ Name = 'PatchMyPCIntuneLogs'; Path = (Join-Path $env:ProgramData 'PatchMyPCIntuneLogs'); Include = @('*.log','*.lo_'); Recurse = $true  }
    [pscustomobject]@{ Name = 'PatchMyPCClient';     Path = (Join-Path $env:ProgramData 'PatchMyPC\Logs');      Include = @('*.log','*.lo_'); Recurse = $true  }
    [pscustomobject]@{ Name = 'PatchMyPCRoot';       Path = (Join-Path $env:ProgramData 'PatchMyPC');           Include = @('*.log');         Recurse = $false }
    [pscustomobject]@{ Name = 'CCMLogs';             Path = (Join-Path $env:WinDir 'CCM\Logs');                 Include = @('PatchMyPC*.log'); Recurse = $false }
    # Add your custom "Manage Installation Logging" folder here if you changed it, e.g.:
    # [pscustomobject]@{ Name = 'InstallLogs'; Path = 'C:\Windows\Logs\PatchMyPCInstallLogs'; Include = @('*.log'); Recurse = $true }
)
#endregion -------------------------------------------------------------------

function Get-SourceFiles {
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    foreach ($s in $Sources) {
        if (-not (Test-Path -LiteralPath $s.Path -PathType Container)) { continue }
        $root = $s.Path.TrimEnd('\')
        Get-ChildItem -LiteralPath $root -File -Recurse:$s.Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $f = $_
                $f.LastWriteTime -ge $cutoff -and
                -not $f.FullName.StartsWith($DestRoot, [StringComparison]::OrdinalIgnoreCase) -and
                ($s.Include | Where-Object { $f.Name -like $_ })
            } |
            ForEach-Object {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\')
                [pscustomobject]@{
                    Source = $_
                    Target = Join-Path (Join-Path $DestRoot $s.Name) $rel
                }
            }
    }
}

# Newest-first selection that fits within the total cap. Detection and remediation
# use the same selection, so files dropped by the cap never count as "out of sync".
function Get-SelectedFiles {
    $maxFile = $MaxFileSizeMB * 1MB
    $budget  = $MaxTotalSizeMB * 1MB
    $used    = 0
    foreach ($item in (@(Get-SourceFiles) | Sort-Object { $_.Source.LastWriteTimeUtc } -Descending)) {
        $size = [math]::Min($item.Source.Length, $maxFile)
        if (($used + $size) -gt $budget) { continue }
        $used += $size
        $item
    }
}

try {
    $files = @(Get-SelectedFiles)

    if ($files.Count -eq 0) {
        Write-Output 'No Patch My PC logs found on this device.'
        exit 0
    }

    $outOfSync = @($files | Where-Object {
        -not (Test-Path -LiteralPath $_.Target) -or
        ([IO.File]::GetLastWriteTimeUtc($_.Target) -ne $_.Source.LastWriteTimeUtc)
    })

    if ($outOfSync.Count -gt 0) {
        Write-Output "Out of sync: $($outOfSync.Count) of $($files.Count) log file(s) need mirroring."
        exit 1
    }

    Write-Output "In sync: $($files.Count) log file(s) mirrored to $DestRoot."
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
