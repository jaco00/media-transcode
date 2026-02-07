<#
.SYNOPSIS
    High-performance Media Metadata Fixer (Batch Optimized).
    
.DESCRIPTION
    1. Scans media files using ExifTool in batches of 1000.
    2. Identifies missing or logical-error dates (e.g., year 0907 or 7126).
    3. Infers correct dates from file/folder paths and writes them back to EXIF.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$DestPath,

    [string]$ImageExt = "*.avif, *.jpg, *.jpeg, *.png, *.heic, *.arw, *.tif",

    [int]$MaxThreads = 8
)

[Console]::OutputEncoding = [System.Text.Encoding]::Default

# --- 1. Environment Setup ---
$ExifTool = "..\bin\exiftool.exe"
if (-not (Test-Path $ExifTool)) { 
    Write-Host "X Error: exiftool.exe not found at $ExifTool" -ForegroundColor Red
    return 
}

$DestPath = (Resolve-Path $DestPath).Path
if ($PSVersionTable.PSVersion.Major -lt 7) { 
    $MaxThreads = 1 
}

# --- 2. Helper Functions ---
function Get-DateFromPath {
    param([string]$Path)
    
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    
    # --- Strategy 1: 8-digit precise date in path (YYYYMMDD) ---
    # Example: beauty_20190209165339.avif -> 2019:02:09
    if ($Path -match "(?<yyyy>(19|20)\d{2})(?<mm>0[1-9]|1[0-2])(?<dd>0[1-9]|[12]\d|3[01])") {
        return "$($Matches.yyyy):$($Matches.mm):$($Matches.dd) 12:00:00"
    }

    # --- Strategy 2: Month with delimiters in path (YYYY.MM or YYYY-MM) ---
    # Example: \2007.11.ShenZhen\ -> 2007:11:01
    if ($Path -match "(?<yyyy>(19|20)\d{2})[.\-](?<mm>0[1-9]|1[0-2])") {
        return "$($Matches.yyyy):$($Matches.mm):01 12:00:00"
    }

    # --- Strategy 3: 6-digit month concatenation (YYYYMM) ---
    # Example: \201605\DSC001.jpg -> 2016:05:01
    if ($Path -match "(?<!\d)(?<yyyy>(19|20)\d{2})(?<mm>0[1-9]|1[0-2])(?!\d)") {
        return "$($Matches.yyyy):$($Matches.mm):01 12:00:00"
    }

    # --- Strategy 4: Unix Timestamp in filename (10/13 digits) ---
    if ($fileName -match "(?<!\d)(\d{10}|\d{13})(?!\d)") {
        $val = $Matches[1]
        try {
            $dt = $null
            if ($val.Length -eq 13) {
                $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$val).DateTime.ToLocalTime()
            } elseif ($val.Length -eq 10) {
                $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$val).DateTime.ToLocalTime()
            }
            if ($dt -and $dt.Year -ge 1970 -and $dt.Year -le 2035) {
                return $dt.ToString("yyyy:MM:dd HH:mm:ss")
            }
        } catch {}
    }

    # --- Strategy 5: 4-digit year fallback (YYYY) ---
    # Example: \2016\iphone6\IMG_9216.avif -> 2016:01:01
    if ($Path -match "[\\/](?<yyyy>(19[789]\d|20[012]\d))[\\/]") {
        return "$($Matches.yyyy):01:01 12:00:00"
    }
    
    return $null
}

# --- 3. Stage 1: Batch Scanning (Silent) ---
Write-Host "-> Stage 1: Indexing file system..." -ForegroundColor Gray
$ExtList = $ImageExt.Split(',') | ForEach-Object { $_.Trim() }
$allFiles = Get-ChildItem -Path $DestPath -Recurse -File -Include $ExtList
$totalFiles = $allFiles.Count

Write-Host "-> Found $totalFiles files. Scanning metadata (this may take a while)..." -ForegroundColor Cyan

$candidates = [System.Collections.Generic.List[string]]::new()
$batchSize = 1000 
$currentIdx = 0

while ($currentIdx -lt $totalFiles) {
    $take = [math]::Min($batchSize, ($totalFiles - $currentIdx))
    $batch = $allFiles[$currentIdx..($currentIdx + $take - 1)]
    
    $tmpInputList = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($tmpInputList, ($batch.FullName), $utf8NoBom)

    $results = & $ExifTool -charset filename=utf8 -T -s3 -DateTimeOriginal -@ $tmpInputList
    
    if ($null -ne $results) {
        $resArray = @($results)
        for ($i = 0; $i -lt $batch.Count; $i++) {
            if ($i -lt $resArray.Count) {
                $dtVal = $resArray[$i].Trim()
                if ($dtVal -eq "-" -or $dtVal -eq "" -or $dtVal -notmatch "^(19|20)\d{2}") {
                    $candidates.Add($batch[$i].FullName)
                }
            }
        }
    }
    
    if (Test-Path $tmpInputList) { Remove-Item $tmpInputList -Force }
    $currentIdx += $take
    Write-Progress -Activity "Metadata Scanning" -Status "Processed $currentIdx of $totalFiles" -PercentComplete (($currentIdx / $totalFiles) * 100)
}
Write-Progress -Activity "Metadata Scanning" -Completed

# --- 4. Task Analysis ---
$imageTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-Host "-> Stage 2: Analyzing paths for repair..." -ForegroundColor Cyan

foreach ($path in $candidates) {
    $inferred = Get-DateFromPath -Path $path
    if ($inferred) {
        $imageTasks.Add([PSCustomObject]@{ Dst = $path; NewDate = $inferred })
    } else {
        Write-Host "X Error: No date pattern found in path for: '$path'" -ForegroundColor Red
    }
}

# --- 5. Summary and Execution ---
if ($imageTasks.Count -eq 0) {
    Write-Host "`nAll files are healthy or no fixable patterns found." -ForegroundColor Green
    return
}

Write-Host "`n*** Scan Summary ***" -ForegroundColor Cyan
Write-Host "Total Files Scanned : $totalFiles"
Write-Host "Invalid/Missing EXIF: $($candidates.Count)"
Write-Host "Repairable Tasks    : $($imageTasks.Count)" -ForegroundColor Yellow

# Randomly pick up to 100 files for preview
Write-Host "`nSample of files to be fixed:" -ForegroundColor Gray
$sampleCount = [math]::Min(100, $imageTasks.Count)
$imageTasks | Get-Random -Count $sampleCount | ForEach-Object {
    Write-Host "  -> [$($_.NewDate)] $($_.Dst)"
}

$confirm = Read-Host "`nApply updates to $($imageTasks.Count) files? (y/n)"
if ($confirm -ne 'y') { Write-Host "Operation cancelled." -ForegroundColor Yellow; return }

$processed = 0
$totalTasks = $imageTasks.Count

if ($MaxThreads -gt 1) {
    $imageTasks | ForEach-Object -Parallel {
        $tmpArg = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllLines($tmpArg, @($_.Dst), (New-Object System.Text.UTF8Encoding($false)))
        & ($using:ExifTool) -m -charset filename=utf8 "-DateTimeOriginal=$($_.NewDate)" "-CreateDate=$($_.NewDate)" "-ModifyDate=$($_.NewDate)" "-overwrite_original" "-@" $tmpArg | Out-Null
        if (Test-Path $tmpArg) { Remove-Item $tmpArg -Force }
        1 
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        $processed++
        Write-Progress -Activity "Writing Metadata" -Status "$processed / $totalTasks" -PercentComplete (($processed / $totalTasks) * 100)
    }
} else {
    foreach ($task in $imageTasks) {
        $processed++
        $tmpArg = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllLines($tmpArg, @($task.Dst), (New-Object System.Text.UTF8Encoding($false)))
        & $ExifTool -m -charset filename=utf8 "-DateTimeOriginal=$($task.NewDate)" "-CreateDate=$($task.NewDate)" "-ModifyDate=$($task.NewDate)" "-overwrite_original" "-@" $tmpArg | Out-Null
        if (Test-Path $tmpArg) { Remove-Item $tmpArg -Force }
        Write-Progress -Activity "Writing Metadata" -Status "$processed / $totalTasks" -PercentComplete (($processed / $totalTasks) * 100)
    }
}

Write-Progress -Activity "Writing Metadata" -Completed
Write-Host "`n*** Success: $totalTasks files updated. ***" -ForegroundColor Cyan