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
    - Removes copies that are no longer selected (source rotated, deleted, older than $MaxAgeDays
      or dropped by the $MaxTotalSizeMB cap); only <FilePrefix>-*.log files are ever removed
 
.NOTES
    Run as:            SYSTEM
    64-bit PowerShell: Yes
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
 
function Copy-LogFile {
    param(
        [Parameter(Mandatory)] [IO.FileInfo] $Source,
        [Parameter(Mandatory)] [string]      $Target,
        [Parameter(Mandatory)] [long]        $MaxBytes
    )
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
 
    # 2. Remove copies that are no longer selected (source rotated, deleted, older than $MaxAgeDays
    #    or dropped by the size cap). Only our own copies; other logs in $DestRoot are never touched
    $keep = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $selected) { [void]$keep.Add($item.Target) }
    Get-ChildItem -LiteralPath $DestRoot -File -Filter "$FilePrefix-*.log" -ErrorAction SilentlyContinue |
        Where-Object { -not $keep.Contains($_.FullName) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
 
    Write-Output "Copied: $copied | Failed: $failed | Removed: $removed | Mirror: $DestRoot"
    if ($failed -gt 0) { exit 1 } else { exit 0 }
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message) | Copied: $copied | Failed: $failed"
    exit 1
}