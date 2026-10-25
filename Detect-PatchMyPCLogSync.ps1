<#
.SYNOPSIS
    Intune Remediation - DETECTION
    Checks whether Patch My PC client logs are mirrored into %windir%\CCM\Logs,
    so they are included in Intune "Collect diagnostics".

.NOTES
    Run as:            SYSTEM
    64-bit PowerShell: Yes
    Exit 0 = in sync (compliant), Exit 1 = out of sync (run remediation)
    Keep the CONFIG block identical in detection and remediation.
#>

#region CONFIG ---------------------------------------------------------------
# Collect diagnostics only gathers %windir%\CCM\Logs\*.log (no subfolders), so copies are stored flat
# as <FilePrefix>-<Source Name>-<relative path>.log. Only files with this prefix are ever touched here.
$DestRoot   = Join-Path $env:WinDir 'CCM\Logs'
$FilePrefix = 'PMPC'
$MaxNameLength = 80  # longer names are shortened and get a hash, so they stay unique
$MaxAgeDays = 14     # only mirror source logs written in the last N days
$MaxFileSizeMB  = 10   # per-file cap; larger logs keep only the last N MB
$MaxTotalSizeMB = 75   # cap for all mirrored copies together (keeps the diagnostics zip lean)

$Sources = @(
    # Name is the short tag in the copy's file name, so keep it short and unique
    [pscustomobject]@{ Name = 'Intune';  Path = (Join-Path $env:ProgramData 'PatchMyPCIntuneLogs');  Include = @('*.log','*.lo_'); Recurse = $true  }
    [pscustomobject]@{ Name = 'Client';  Path = (Join-Path $env:ProgramData 'PatchMyPC\Logs');       Include = @('*.log','*.lo_'); Recurse = $true  }
    [pscustomobject]@{ Name = 'Root';    Path = (Join-Path $env:ProgramData 'PatchMyPC');            Include = @('*.log');         Recurse = $false }
    [pscustomobject]@{ Name = 'Install'; Path = (Join-Path $env:ProgramData 'PatchMyPCInstallLogs'); Include = @('*.log');         Recurse = $true  }
    # If you changed the "Manage Installation Logging" folder, update the Install path above, or add it, e.g.:
    # [pscustomobject]@{ Name = 'Install2'; Path = 'D:\Logs\PatchMyPCInstallLogs'; Include = @('*.log'); Recurse = $true }
)
#endregion -------------------------------------------------------------------

# Short, readable, unique file name for a copy: <FilePrefix>-<Name>-<relative path>.log
#  - subfolders become '_', and a leading 'PatchMyPC-' is dropped (the prefix already says so)
#  - non-.log files (e.g. rotated .lo_) get .log appended, because Collect diagnostics only gathers *.log
#  - names over $MaxNameLength are shortened and end in a hash of the source path
function Get-TargetName {
    param([string] $Tag, [string] $RelativePath, $Used)
    $flat  = $RelativePath -replace '\\', '_'
    $sha   = [Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Tag\$RelativePath".ToLowerInvariant()))
    $hash  = -join ($bytes[0..2] | ForEach-Object { $_.ToString('x2') })
    # Fall back to the full name, then to a hashed name, if a shorter name is already taken
    foreach ($candidate in @(($flat -replace '^PatchMyPC[-_]', ''), $flat, $null)) {
        $hashed = -not $candidate
        if ($hashed) { $candidate = $flat }
        $name = "$FilePrefix-$Tag-$candidate"
        if ($name -notlike '*.log') { $name += '.log' }
        if ($hashed -or $name.Length -gt $MaxNameLength) {
            $base = $name -replace '\.log$', ''
            $name = $base.Substring(0, [math]::Min($base.Length, $MaxNameLength - 11)) + "~$hash.log"
        }
        if ($Used.Add($name)) { return $name }
    }
    return $name
}
 
function Get-SourceFiles {
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    $used   = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Sources) {
        if (-not (Test-Path -LiteralPath $s.Path -PathType Container)) { continue }
        $root = $s.Path.TrimEnd('\')
        Get-ChildItem -LiteralPath $root -File -Recurse:$s.Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $f = $_
                $f.LastWriteTime -ge $cutoff -and
                ($s.Include | Where-Object { $f.Name -like $_ })
            } |
            ForEach-Object {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\')
                [pscustomobject]@{
                    Source = $_
                    Target = Join-Path $DestRoot (Get-TargetName -Tag $s.Name -RelativePath $rel -Used $used)
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
