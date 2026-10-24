<#
.SYNOPSIS
    Intune Remediation - REMEDIATION
    Mirrors Patch My PC client logs into the IME Logs folder so they are
    included when "Collect diagnostics" is triggered from Intune.
 
.DESCRIPTION
    - Copies new/changed logs (opens source with shared read, so locked logs still copy)
    - Large logs are truncated to the last $MaxFileSizeMB (tail), newest entries kept
    - Removes mirrored copies older than $RetentionDays
    - Enforces a total size cap on the mirror folder (oldest removed first)
 
.NOTES
    Run as:            SYSTEM
    64-bit PowerShell: Yes
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
 
# Remediation-only settings
$RetentionDays  = 30   # remove mirrored copies older than this
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
 
function Copy-LogFile {
    param(
        [Parameter(Mandatory)] [IO.FileInfo] $Source,
        [Parameter(Mandatory)] [string]      $Target,
        [Parameter(Mandatory)] [long]        $MaxBytes
    )
    $dir = Split-Path -Path $Target -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
 
    # Shared read so logs that are currently being written to can still be copied
    $in = [IO.File]::Open($Source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                          [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $out = [IO.File]::Open($Target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            if ($in.Length -gt $MaxBytes) {
                [void]$in.Seek(-$MaxBytes, [IO.SeekOrigin]::End)
                $marker = [Text.Encoding]::UTF8.GetBytes("<<< Truncated by PatchMyPC log sync: last $([math]::Round($MaxBytes/1MB)) MB of $($Source.FullName) >>>`r`n")
                $out.Write($marker, 0, $marker.Length)
            }
            $in.CopyTo($out)
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
 
    # Match source timestamp so detection can compare reliably
    [IO.File]::SetLastWriteTimeUtc($Target, $Source.LastWriteTimeUtc)
}
 
$copied = 0; $failed = 0; $removed = 0
 
try {
    if (-not (Test-Path -LiteralPath $DestRoot)) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    }
 
    # 1. Mirror new/changed logs
    foreach ($item in @(Get-SelectedFiles)) {
        $needsCopy = -not (Test-Path -LiteralPath $item.Target) -or
                     ([IO.File]::GetLastWriteTimeUtc($item.Target) -ne $item.Source.LastWriteTimeUtc)
        if (-not $needsCopy) { continue }
        try {
            Copy-LogFile -Source $item.Source -Target $item.Target -MaxBytes ($MaxFileSizeMB * 1MB)
            $copied++
        }
        catch { $failed++ }
    }
 
    # 2. Retention: remove old mirrored copies
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $DestRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
 
    # 3. Total size cap: remove oldest first
    $all   = @(Get-ChildItem -LiteralPath $DestRoot -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    $total = ($all | Measure-Object -Property Length -Sum).Sum
    $cap   = $MaxTotalSizeMB * 1MB
    foreach ($f in $all) {
        if ($total -le $cap) { break }
        $total -= $f.Length
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $removed++
    }
 
    # 4. Clean up empty subfolders
    Get-ChildItem -LiteralPath $DestRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
 
    Write-Output "Copied: $copied | Failed: $failed | Removed: $removed | Mirror: $DestRoot"
    if ($failed -gt 0) { exit 1 } else { exit 0 }
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message) | Copied: $copied | Failed: $failed"
    exit 1
}