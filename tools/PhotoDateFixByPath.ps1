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


function Clean-ChineseDate {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Raw,
        [string]$RawOffset
    )
    
    $pattern = "(?<date>\d{4}[:/-]\d{2}[:/-]\d{2})\s+(?<h>\d{1,2}):(?<m>\d{2}):(?<s>\d{2})(\.\d+)?\s*(?<p>上午|下午)?"
    if ($Raw -match $pattern) {
        $date = $Matches.date.Replace("-", ":").Replace("/", ":")
        $origH = [int]$Matches.h
        $h = $origH
        $m = $Matches.m
        $s = $Matches.s
        $period = $Matches.p
        if ($period -eq "下午" -and $h -lt 12) { 
            $h += 12 
        }
        elseif ($period -eq "上午" -and $h -eq 12) { 
            $h = 0 
        }
        $newTime = "{0:D2}:{1}:{2}" -f $h, $m, $s
        $result = "${date} ${newTime}"
        if (-not [string]::IsNullOrWhiteSpace($RawOffset) -and $RawOffset -match "[+-]\d{2}:\d{2}") {
            $result = "${result}${RawOffset}"
        }
        return $result
    }
    return $null
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

function Invoke-ExifUpdate {
    param([string]$ToolPath, [string]$FilePath, [string]$NewDate, [string]$TzOffset)
    
    $tmpArg = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllLines($tmpArg, @($FilePath), (New-Object System.Text.UTF8Encoding($false)))
    
    if ($NewDate -match "[+-]\d{2}:\d{2}$") {
        & $ToolPath -m -overwrite_original -charset filename=utf8 "-AllDates=$NewDate" "-@" $tmpArg | Out-Null
    } else {
        & $ToolPath -m -overwrite_original -charset filename=utf8 `
          "-AllDates=$NewDate" `
          "-OffsetTime=$TzOffset" `
          "-OffsetTimeOriginal=$TzOffset" `
          "-OffsetTimeDigitized=$TzOffset" `
          "-@" $tmpArg | Out-Null
    }
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
        "/mnt/media/photo/albums/2024.09.ShenZhen.Game/DSCN2838.avif",
        "/mnt/media/photo/albums/20230509175757_0060.h265.mp4",
        "/mnt/media/photo/albums/VID_20250113_165746"
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

$candidates = @{}
$batchSize = 500 
$currentIdx = 0

if ($Overwrite) {
    Write-Host "-> [OVERWRITE MODE] Adding all matching files to processing queue..." -ForegroundColor Cyan
    foreach ($file in $allFiles) {
        $candidates.Add($file.FullName)
        $candidates[$file.FullName] = @{ Date = ""; Offset = "" }
    }
} else {

    while ($currentIdx -lt $totalFiles) {
        $take = [math]::Min($batchSize, ($totalFiles - $currentIdx))
        $batch = $allFiles[$currentIdx..($currentIdx + $take - 1)]
        
        $tmpInputList = [System.IO.Path]::GetTempFileName()
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($tmpInputList, ($batch.FullName), $utf8NoBom)

        $results = & $ExifTool -charset filename=utf8 -T -s3 -f -DateTimeOriginal -OffsetTimeOriginal -@ $tmpInputList <# 批量执行ExifTool扫描 #>

        if ($null -ne $results) { <# 检查扫描结果是否为空 #>
            $resLines = @($results) <# 强制转换为数组处理 #>
            for ($i = 0; $i -lt $batch.Count; $i++) { <# 遍历当前批次文件 #>
                $line = $resLines[$i] <# 取出对应行结果 #>
                if ([string]::IsNullOrWhiteSpace($line)) { continue } <# 跳过空行 #>
                
                $parts = $line.Split("`t") <# 按制表符分割 #>
                $dtVal = $parts[0].Trim() -replace '^-+$', '' <# 清理日期占位符 #>
                $tzVal = if ($parts.Count -gt 1) { $parts[1].Trim() -replace '^-+$', '' } else { "" } <# 清理时区占位符 #>

                $fileName = [System.IO.Path]::GetFileName($batch[$i].FullName)

                if ($Overwrite -or $dtVal -eq "" -or $dtVal -notmatch "^(19|20)\d{2}" -or $dtVal -match "[\u4e00-\u9fa5]") {
                    $candidates[$batch[$i].FullName] = @{ Date = $dtVal; Offset = $tzVal } <# 加入待处理候选队列 #>
                }
            }
        }



      #  $results = & $ExifTool -charset filename=utf8 -T -s3 -DateTimeOriginal -@ $tmpInputList
      #  
      #  if ($null -ne $results) {
      #      $resArray = @($results)
      #      for ($i = 0; $i -lt $batch.Count; $i++) {
      #          if ($i -lt $resArray.Count) {
      #              $dtVal = $resArray[$i].Trim()
      #              if ($Overwrite -or $dtVal -eq "-" -or $dtVal -eq "" -or $dtVal -notmatch "^(19|20)\d{2}" -or $dtVal -match "[\u4e00-\u9fa5]") {
      #                  $candidates[$batch[$i].FullName] = $dtVal
      #              }
      #          }
      #      }
      #  }
        
        if (Test-Path $tmpInputList) { Remove-Item $tmpInputList -Force }
        $currentIdx += $take
        Write-Progress -Activity "Metadata Scanning" -Status "Processed $currentIdx of $totalFiles" -PercentComplete (($currentIdx / $totalFiles) * 100)
    }
}
Write-Progress -Activity "Metadata Scanning" -Completed

# --- 4. Task Analysis ---
$imageTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
Write-Host "-> Stage 2: Analyzing paths for repair..." -ForegroundColor Cyan

#foreach ($path in $candidates) {
#    $inferred = Get-DateFromPath -Path $path
#    if ($inferred) {
#        $imageTasks.Add([PSCustomObject]@{ Dst = $path; NewDate = $inferred+$TimeZone })
#    } else {
#        Write-Host "X Error: No date pattern found in path for: '$path'" -ForegroundColor Red
#    }
#}






foreach ($path in $candidates.Keys) { <# 遍历所有待处理文件的路径 #>
    $item = $candidates[$path] <# 获取当前文件的元数据信息对象 #>
    $rawDate = [string]$item.Date <# 显式转换为字符串 #>
    $rawOff = [string]$item.Offset <# 显式转换原始时区字符串 #>
    $fileName = [System.IO.Path]::GetFileName($path)
    
    $finalDate = $null <# 初始化最终结果日期 #>
    
    <# 1. 尝试清洗已有的异常日期 (处理 "下午" 等) #>
    if ($rawDate -match "[\u4e00-\u9fa5]") { 
        $finalDate = Clean-ChineseDate -Raw $rawDate -RawOffset $rawOff
        if ($finalDate) { Write-Host "   [STAGE2] Fixed Chinese Date for $fileName : $finalDate" -ForegroundColor Gray }
    }
    
    <# 2. 如果原始日期无法通过清洗修复，尝试从文件路径推断 #>
    if (-not $finalDate) { 
        $inferred = Get-DateFromPath -Path $path
        if ($inferred) { 
            $finalDate = $inferred 
            Write-Host "   [STAGE2] Inferred Date from path for $fileName : $finalDate" -ForegroundColor Gray
        }
    }

    <# 3. 结果汇总并入队 #>
    if ($finalDate) { 
        $taskOffset = if ([string]::IsNullOrWhiteSpace($rawOff)) { $TimeZone } else { $rawOff } <# 补全时区 #>
        $imageTasks.Add([PSCustomObject]@{ Dst = $path; NewDate = $finalDate; Offset = $taskOffset }) <# 生成最终任务 #>
    } else {
        Write-Host "   [STAGE2] Skip: No fixable pattern found for $fileName" -ForegroundColor DarkGray
    }
}







#foreach ($path in $candidates.Keys) {
#    $rawDt = $candidates[$path]
#    $finalDate = $null
#
#    if ($rawDt -match "[\u4e00-\u9fa5]") {
#        $finalDate = Clean-ChineseDate -Raw $rawDt
#    }
#    
#    if (-not $finalDate) {
#        $inferred = Get-DateFromPath -Path $path
#        if ($inferred) { $finalDate = $inferred }
#    }
#
#    if ($finalDate) {
#        $imageTasks.Add([PSCustomObject]@{ Dst = $path; NewDate = $finalDate })
#    } else {
#       Write-Host "X Error: No date pattern found in path for: '$path'" -ForegroundColor Red
#    }
#}

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