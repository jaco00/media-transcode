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

    # Allows manual timezone override; defaults to empty for auto-detection
    [string]$TimeZone = "",

    [int]$MaxThreads = 8, 
    # Added Force switch to re-process files that already have timestamps
    [switch]$Overwrite,
    [switch]$Test
)

# --- 1. TimeZone Initialization (Must be after param block) ---
if ([string]::IsNullOrWhiteSpace($TimeZone)) {
    try {
        $currentOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now)
        $hours = [math]::Abs($currentOffset.Hours).ToString("00")
        $minutes = [math]::Abs($currentOffset.Minutes).ToString("00")
        $sign = if ($currentOffset.Ticks -ge 0) { "+" } else { "-" }
        $TimeZone = "${sign}${hours}:${minutes}"
    } catch {
        $TimeZone = "+08:00" # Fallback to UTC+8 if detection fails
    }
}
Write-Host "--------------------------------------------------" -ForegroundColor Gray
Write-Host "-> System detected / Current TimeZone: $TimeZone" -ForegroundColor Green
Write-Host "--------------------------------------------------" -ForegroundColor Gray

#[Console]::OutputEncoding = [System.Text.Encoding]::Default

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8


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

# --- 2. Helper Functions --
function Get-DateFromPath {
    param([string]$Path)
    
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)


    # 1. High Priority: Unix Timestamps (13-digit for MS, 10-digit for Sec)
    # --- Strategy 1: Unix Timestamp in filename (10/13 digits) ---
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
    
    # --- Strategy 2: 8-digit precise date in path (YYYYMMDD) ---
    # Example: beauty_20190209165339.avif -> 2019:02:09
    if ($Path -match "(?<yyyy>(19|20)\d{2})(?<mm>0[1-9]|1[0-2])(?<dd>0[1-9]|[12]\d|3[01])") {
        return "$($Matches.yyyy):$($Matches.mm):$($Matches.dd) 12:00:00"
    }

    # --- Strategy 3: Month with delimiters in path (YYYY.MM or YYYY-MM) ---
    # Example: \2007.11.ShenZhen\ -> 2007:11:01
    if ($Path -match "(?<yyyy>(19|20)\d{2})[.\-](?<mm>0[1-9]|1[0-2])") {
        return "$($Matches.yyyy):$($Matches.mm):01 12:00:00"
    }

    # --- Strategy 4: 6-digit month concatenation (YYYYMM) ---
    # Example: \201605\DSC001.jpg -> 2016:05:01
    if ($Path -match "(?<!\d)(?<yyyy>(19|20)\d{2})(?<mm>0[1-9]|1[0-2])(?!\d)") {
        return "$($Matches.yyyy):$($Matches.mm):01 12:00:00"
    }


    # --- Strategy 5: 4-digit year fallback (YYYY) ---
    # Example: \2016\iphone6\IMG_9216.avif -> 2016:01:01
    if ($Path -match "[\\/](?<yyyy>(19[789]\d|20[012]\d))[\\/]") {
        return "$($Matches.yyyy):01:01 12:00:00"
    }
    
    return $null
}


# Encapsulated ExifTool update command - Optimized for Images
function Invoke-ExifUpdate {
    param(
        [string]$ToolPath,
        [string]$FilePath,
        [string]$NewDate,
        [string]$TzOffset
    )
    
    # Combined metadata write command passing FilePath directly
    # Note: QuickTimeUTC removed as this script is now image-focused
    $tmpArg = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllLines($tmpArg, @($FilePath), (New-Object System.Text.UTF8Encoding($false)))
    & $ToolPath -m -overwrite_original -charset filename=utf8 `
      "-DateTimeOriginal=$NewDate" `
      "-CreateDate=$NewDate" `
      "-ModifyDate=$NewDate" `
      "-OffsetTimeOriginal=$TzOffset" `
      "-OffsetTimeDigitized=$TzOffset" `
      "-OffsetTime=$TzOffset" `
      "-@" $tmpArg | Out-Null
      if (Test-Path $tmpArg) { Remove-Item $tmpArg -Force }
}

# --- 4. Special Mode: Test Mode ---
if ($Test) {
    Write-Host "-> [TEST MODE] Running predefined path extraction test cases..." -ForegroundColor Cyan
    $testPaths = @(
        "C:\Users\Photos\2024-08-15\IMG_1234.jpg",      
        "D:\Work\Projects\2024.04.20\image.png",         
        "E:\Documents\20240503_report.pdf",             
        "F:\202405\meeting_notes.txt",                  
        "F:\202405_\meeting_notes.txt",                 
        "G:\Archive\2024\IMG_5678.jpg",                 
        "C:\2007.11.ShenZhen.a\DSC_0143.avi",
        "D:\linux\photo\2019\hw-p20\beauty_20190209165339.avif",
        "D:\linux\photo\2016\iphone6\IMG_0155.avif",
        "D:\linux\photo\2023\mmexport1453209205104.avif",
        "d:\linux\photo\2025\mmexport1632052960498_mr1632055641594_mh1632063041769.avif",
        "d:\linux\photo\2022goMeihuaTemp_mh1527519531227.avif",
        "/mnt/media/photo/albums/2008.04.hunan.旅游/DSC_0277.avif",
        "/mnt/media/photo/albums/2024.09.ShenZhen.Game/DSCN2838.avif"
    )

    foreach ($path in $testPaths) {
        $date = Get-DateFromPath -Path $path -tz $TimeZone
        if ($date) {
            Write-Host "File: $path`n   -> Extracted Date: $date" -ForegroundColor Green
        } else {
            Write-Host "❌ Error: Unable to extract date from path: '$path'" -ForegroundColor Red
        }
    }
    return
}

# --- 3. Stage 1: Batch Scanning (Silent) ---
Write-Host "-> Stage 1: Indexing file system..." -ForegroundColor Gray
$ExtList = $ImageExt.Split(',') | ForEach-Object { $_.Trim() }

if (Test-Path -Path $DestPath -PathType Leaf) {
    # CASE A: Single File (Ignore extension filter, focus on specific target)
    Write-Host "-> Single file detected: $DestPath" -ForegroundColor Cyan
    $allFiles = @(Get-Item -Path $DestPath)
    $totalFiles=1
}else{
    $allFiles = Get-ChildItem -Path $DestPath -Recurse -File -Include $ExtList
    $totalFiles = $allFiles.Count
}


Write-Host "-> Found $totalFiles files. Scanning metadata (this may take a while)..." -ForegroundColor Cyan

$candidates = [System.Collections.Generic.List[string]]::new()
$batchSize = 500 
$currentIdx = 0

if ($Overwrite) {
    Write-Host "-> [OVERWRITE MODE] Adding all matching files to processing queue..." -ForegroundColor Cyan
    foreach ($file in $allFiles) {
        $candidates.Add($file.FullName)
    }
} else {

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
}
Write-Progress -Activity "Metadata Scanning" -Completed

# --- 4. Task Analysis ---
$imageTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-Host "-> Stage 2: Analyzing paths for repair..." -ForegroundColor Cyan

foreach ($path in $candidates) {
    $inferred = Get-DateFromPath -Path $path
    if ($inferred) {
        $imageTasks.Add([PSCustomObject]@{ Dst = $path; NewDate = $inferred+$TimeZone })
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
$tzOnly = $TimeZone

if ($MaxThreads -gt 1) {
    # Extract the function definition to a string for parallel importing
    $funcExifUpdate = "function Invoke-ExifUpdate { ${function:Invoke-ExifUpdate} }"
    $imageTasks | ForEach-Object -Parallel {
        Invoke-Expression $using:funcExifUpdate
        Invoke-ExifUpdate -ToolPath ($using:ExifTool) -FilePath $_.Dst -NewDate $_.NewDate -TzOffset ($using:tzOnly)
        1 # Signal increment
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        $processed++
        Write-Progress -Activity "Writing Metadata (Parallel)" -Status "$processed / $totalTasks" -PercentComplete (($processed / $totalTasks) * 100)
    }
} else {
    foreach ($task in $imageTasks) {
        $processed++
        Invoke-ExifUpdate -ToolPath $ExifTool -FilePath $task.Dst -NewDate $task.NewDate -TzOffset $tzOnly
        Write-Progress -Activity "Writing Metadata (Sequential)" -Status "$processed / $totalTasks" -PercentComplete (($processed / $totalTasks) * 100)
    }
}

Write-Progress -Activity "Writing Metadata" -Completed
Write-Host "`n*** Success: $totalTasks files updated. ***" -ForegroundColor Cyan