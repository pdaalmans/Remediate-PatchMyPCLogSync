<#
.SYNOPSIS
    Intune Remediation - REMEDIATION
    Mirrors Patch My PC client logs into %windir%\CCM\Logs so they are
    included when "Collect diagnostics" is triggered from Intune.
 
.DESCRIPTION
    - Copies new/changed logs flat into $DestRoot as <FilePrefix>-<Source>-<relative path>.log
      (opens source with shared read, so locked logs still copy)
    - Large logs are truncated to the last $MaxFileSizeMB (tail), newest entries kept,
      starting at a full line and with a marker line at the top (marker included in the cap)
    - Removes mirrored copies older than $RetentionDays
    - Enforces a total size cap on the mirrored copies (copies no longer selected go first, then oldest)
    - Only files named <FilePrefix>-* are removed; other logs in $DestRoot are never touched
    - Removes the old mirror folder ($LegacyDestRoot) used by earlier versions
 
.NOTES
    Run as:            SYSTEM
    64-bit PowerShell: Yes
    Keep the CONFIG block identical in detection and remediation.
#>
 
#region CONFIG ---------------------------------------------------------------
# Collect diagnostics only gathers %windir%\CCM\Logs\*.log (no subfolders), so copies are stored flat
# as <FilePrefix>-<Source Name>-<relative path>.log. Only files with this prefix are ever touched here.
$DestRoot   = Join-Path $env:WinDir 'CCM\Logs'
$FilePrefix = 'PMPCSync'
$MaxAgeDays = 14     # only mirror source logs written in the last N days
$MaxFileSizeMB  = 10   # per-file cap; larger logs keep only the last N MB
$MaxTotalSizeMB = 75   # cap for all mirrored copies together (keeps the diagnostics zip lean)
 
$Sources = @(
    [pscustomobject]@{ Name = 'PatchMyPCIntuneLogs'; Path = (Join-Path $env:ProgramData 'PatchMyPCIntuneLogs'); Include = @('*.log','*.lo_'); Recurse = $true  }
    [pscustomobject]@{ Name = 'PatchMyPCClient';     Path = (Join-Path $env:ProgramData 'PatchMyPC\Logs');      Include = @('*.log','*.lo_'); Recurse = $true  }
    [pscustomobject]@{ Name = 'PatchMyPCRoot';       Path = (Join-Path $env:ProgramData 'PatchMyPC');           Include = @('*.log');         Recurse = $false }
    [pscustomobject]@{ Name = 'PatchMyPCInstallLogs'; Path = (Join-Path $env:ProgramData 'PatchMyPCInstallLogs'); Include = @('*.log');        Recurse = $true  }
    # If you changed the "Manage Installation Logging" folder, update the PatchMyPCInstallLogs path above, or add it, e.g.:
    # [pscustomobject]@{ Name = 'InstallLogs'; Path = 'D:\Logs\PatchMyPCInstallLogs'; Include = @('*.log'); Recurse = $true }
)
 
# Remediation-only settings
$RetentionDays  = 30   # remove mirrored copies older than this
$LegacyDestRoot = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\PatchMyPC'  # old mirror, not collected (subfolder)
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
                # Flatten the relative path into the file name; non-.log files (e.g. rotated .lo_) get
                # a .log extension, because Collect diagnostics only gathers *.log
                $rel  = $_.FullName.Substring($root.Length).TrimStart('\') -replace '\\', '_'
                $name = "$FilePrefix-$($s.Name)-$rel"
                if ($name -notlike '*.log') { $name += '.log' }
                [pscustomobject]@{
                    Source = $_
                    Target = Join-Path $DestRoot $name
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
        # Copy the file as it was when selected, so the content matches the timestamp set below
        # and a log that grows during the copy cannot push the mirror over the size caps
        $end    = [math]::Min($in.Length, $Source.Length)
        $start  = [long]0
        $header = [byte[]]@()
 
        if ($end -gt $MaxBytes) {
            # Detect the encoding from the BOM, so the marker matches the rest of the log (MSI logs are UTF-16)
            $bom = New-Object byte[] 3
            $n   = $in.Read($bom, 0, 3)
            $enc = [Text.Encoding]::UTF8
            if ($n -ge 2 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
            $preamble = [byte[]]@()
            if ($enc -eq [Text.Encoding]::Unicode -or ($n -eq 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
                $preamble = $enc.GetPreamble()
            }
            $marker = $enc.GetBytes("<<< Truncated by PatchMyPC log sync: last $([math]::Round($MaxBytes/1MB)) MB of $($Source.FullName) >>>`r`n")
            $header = [byte[]]($preamble + $marker)
 
            # Keep the tail; the marker counts towards the per-file cap
            $newline = $enc.GetBytes("`n")
            $start   = $end - ($MaxBytes - $header.Length)
            if ($start % $newline.Length) { $start++ }
 
            # Start at the next full line, so the copy does not begin with a partial log entry
            [void]$in.Seek($start, [IO.SeekOrigin]::Begin)
            $buf  = New-Object byte[] ([int][math]::Min(65536, $end - $start))
            $read = $in.Read($buf, 0, $buf.Length)
            for ($i = 0; $i -le $read - $newline.Length; $i += $newline.Length) {
                if ($buf[$i] -eq $newline[0] -and ($newline.Length -eq 1 -or $buf[$i + 1] -eq $newline[1])) {
                    $start += $i + $newline.Length
                    break
                }
            }
        }
 
        $out = [IO.File]::Open($Target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $out.Write($header, 0, $header.Length)
            [void]$in.Seek($start, [IO.SeekOrigin]::Begin)
            $buffer    = New-Object byte[] 81920
            $remaining = $end - $start
            while ($remaining -gt 0) {
                $read = $in.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
                if ($read -le 0) { break }
                $out.Write($buffer, 0, $read)
                $remaining -= $read
            }
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
    $selected = @(Get-SelectedFiles)
    foreach ($item in $selected) {
        $needsCopy = -not (Test-Path -LiteralPath $item.Target) -or
                     ([IO.File]::GetLastWriteTimeUtc($item.Target) -ne $item.Source.LastWriteTimeUtc)
        if (-not $needsCopy) { continue }
        try {
            Copy-LogFile -Source $item.Source -Target $item.Target -MaxBytes ($MaxFileSizeMB * 1MB)
            $copied++
        }
        catch { $failed++ }
    }
 
    # Only our own copies; other logs in $DestRoot (e.g. ConfigMgr client logs) are never touched
    $mirrorFilter = "$FilePrefix-*.log"
 
    # 2. Retention: remove old mirrored copies
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $DestRoot -File -Filter $mirrorFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
 
    # 3. Total size cap: remove oldest first, starting with copies that are no longer selected,
    #    so the files detection checks are never removed (that would loop remediation forever)
    $keep  = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $selected) { [void]$keep.Add($item.Target) }
    $all   = @(Get-ChildItem -LiteralPath $DestRoot -File -Filter $mirrorFilter -ErrorAction SilentlyContinue |
               Sort-Object @{ Expression = { $keep.Contains($_.FullName) } }, LastWriteTime)
    $total = ($all | Measure-Object -Property Length -Sum).Sum
    $cap   = $MaxTotalSizeMB * 1MB
    foreach ($f in $all) {
        if ($total -le $cap) { break }
        $total -= $f.Length
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $removed++
    }
 
    # 4. Remove the old mirror folder from earlier versions (subfolders are not collected)
    if (Test-Path -LiteralPath $LegacyDestRoot -PathType Container) {
        Remove-Item -LiteralPath $LegacyDestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
 
    Write-Output "Copied: $copied | Failed: $failed | Removed: $removed | Mirror: $DestRoot"
    if ($failed -gt 0) { exit 1 } else { exit 0 }
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message) | Copied: $copied | Failed: $failed"
    exit 1
}