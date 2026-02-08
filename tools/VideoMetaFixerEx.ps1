<#
.SYNOPSIS
    Advanced Media Metadata Fixer (Target-First & Map-Matched).
    Specialized in purging hard-coded Chinese characters in metadata.
    Full support for UTF-8 Chinese file paths.
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$DestPath,

    [Parameter(Position=1)]
    [string]$SourcePath = "",

    [string]$VideoTargetExt = ".h265.mp4",
    
    # 视频后缀匹配列表，默认支持 mp4, mov, avi, mkv
    [string]$VideoExtRegex = "mp4|mov|avi|mkv",
    
    [string]$TimeZone = "", # Format: +08:00
    [switch]$Overwrite,
    [switch]$Test
)

# --- 1. Environment Initialization ---
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($TimeZone)) {
    try {
        $currentOffset = [System.TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now)
        $hours = [math]::Abs($currentOffset.Hours).ToString("00")
        $minutes = [math]::Abs($currentOffset.Minutes).ToString("00")
        $sign = if ($currentOffset.Ticks -ge 0) { "+" } else { "-" }
        $TimeZone = "${sign}${hours}:${minutes}"
    } catch { $TimeZone = "+08:00" }
}

$ExifTool = "..\bin\exiftool.exe"
if (-not (Test-Path $ExifTool)) { Write-Host "❌ Error: exiftool.exe not found at ..\bin\" -ForegroundColor Red; return }

# --- 2. Core Helper Functions ---

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

function Test-DateValid {
    param([string]$FilePath)
    $res = & $ExifTool -charset filename=utf8 -n -s3 -T -DateTimeOriginal $FilePath
    
    $isValid = $true
    if ([string]::IsNullOrWhiteSpace($res) -or $res -eq "-") { $isValid = $false }
    elseif ($res -match "[\u4e00-\u9fa5]") { $isValid = $false }
    elseif ($res -match "[a-zA-Z]" -and $res -notmatch "^\d{4}:\d{2}:\d{2}") { $isValid = $false }
    elseif ($res -match "^0000") { $isValid = $false }

    return [PSCustomObject]@{
        IsValid = $isValid
        Date    = if ($isValid) { $res } else { "Invalid" }
    }
}

function Invoke-MetadataFix {
    param($Task)
    $exifArgs = @("-charset", "filename=utf8", "-m", "-P", "-q", "-q", "-overwrite_original")
    $isVideo = $Task.Dst -match "\.($VideoExtRegex)$"
    if ($isVideo) { $exifArgs += "-api", "QuickTimeUTC" }

    if ($Task.Mode -match "Clone") {
        $cloneArgs = $exifArgs + @("-tagsFromFile", $Task.Src, "-all:all>all:all", "-CreationDate<EncodedDate", "-MediaCreateDate<EncodedDate", "-CreateDate<EncodedDate", $Task.Dst)
        & $ExifTool $cloneArgs
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Status = "Error"; Date = "FAILED"; Detail = "ExifTool Error ($LASTEXITCODE)" }
        }

        $check = Test-DateValid -FilePath $Task.Dst
        if (-not $check.IsValid) {
            $bestDate = Get-DateFromPath -Path $Task.Dst
            $detailTag = "Clone->Path"
            if (-not $bestDate) { 
                $bestDate = (Get-Item -LiteralPath $Task.Src).LastWriteTime.ToString("yyyy:MM:dd HH:mm:ss") 
                $detailTag = "Clone->SrcTime"
            }
            Write-Host "  [!] Clone Failed/Invalid Metadata. Falling back to manual fix: $bestDate" -ForegroundColor Yellow
            $fixArgs = $exifArgs + @("-DateTimeOriginal=$bestDate", "-CreateDate=$bestDate", "-ModifyDate=$bestDate")
            if ($isVideo) { 
                $fixArgs += "-CreationDate=$bestDate$TimeZone"
                $fixArgs += "-MediaCreateDate=$bestDate" 
            }
            $fixArgs += $Task.Dst
            & $ExifTool $fixArgs
             
            if ($LASTEXITCODE -ne 0) {
                return [PSCustomObject]@{ Status = "Error"; Date = "FAILED"; Detail = "Fallback Error" }
            }
            return [PSCustomObject]@{ Status = "Warning"; Date = $bestDate; Detail = $detailTag }
        } else {
            return [PSCustomObject]@{ Status = "Success"; Date = $check.Date; Detail = "Cloned OK" }
        }
    } else {
        $val = $Task.NewDate
        $exifArgs += "-DateTimeOriginal=$val", "-CreateDate=$val", "-ModifyDate=$val"
        if ($isVideo) { 
            $exifArgs += "-CreationDate=$val$TimeZone"
            $exifArgs += "-MediaCreateDate=$val" 
        }
        $exifArgs += $Task.Dst
        & $ExifTool @exifArgs
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Status = "Error"; Date = "FAILED"; Detail = "Exif Error ($LASTEXITCODE)" }
        }
        return [PSCustomObject]@{ Status = "Info"; Date = $val; Detail = "Inferred" }
    }
}

# --- 3. Scanning & Task Building ---

Write-Host "`n🔍 Stage 1: Indexing target files ($VideoTargetExt)..." -ForegroundColor Gray
$targetFiles = Get-ChildItem -LiteralPath $DestPath -Recurse -File -Filter "*$VideoTargetExt"
if (-not $targetFiles) { Write-Host "⚠️ No target files found." -ForegroundColor Yellow; return }

$targetMap = @{}
foreach ($f in $targetFiles) {
    $pureName = $f.Name.Replace($VideoTargetExt, "").ToLower()
    $targetMap[$pureName] = $f.FullName
}

$tasks = [System.Collections.Generic.List[PSCustomObject]]::new()
$processedDests = @{}
$sourceFileCache = @{} 

# Stage 2: Source Match
if (-not [string]::IsNullOrEmpty($SourcePath) -and (Test-Path -LiteralPath $SourcePath)) {
    Write-Host "🔍 Stage 2: Matching source files..." -ForegroundColor Gray
    $srcFiles = Get-ChildItem -LiteralPath $SourcePath -Recurse -File
    foreach ($sFile in $srcFiles) {
        $sName = $sFile.BaseName.ToLower()
        $sourceFileCache[$sName] = $sFile.FullName 
        if ($targetMap.ContainsKey($sName)) {
            $dstPath = $targetMap[$sName]
            $tasks.Add([PSCustomObject]@{ 
                Dst = $dstPath; 
                Src = $sFile.FullName; 
                Mode = "📦 Clone"; 
                NewDate = "Sync from EXIF" 
            })
            $processedDests[$dstPath] = $true
        }
    }
}

# Stage 3: Validation & Fallback
Write-Host "🔍 Stage 3: Analyzing logic for orphans..." -ForegroundColor Gray

$targetArray = $targetMap.Values | Sort-Object
$totalTargets = $targetArray.Count
$currentCount = 0
$skippedCount = 0

foreach ($tPath in $targetArray) {
    $currentCount++
    if ($totalTargets -gt 0 -and ($currentCount % 50 -eq 0 -or $currentCount -eq $totalTargets)) {
        $percent = [math]::Round(($currentCount / $totalTargets) * 100)
        Write-Progress -Activity "Analyzing files..." -Status "Processing $currentCount of $totalTargets ($percent%)" -PercentComplete $percent
    }
    if (-not $processedDests.ContainsKey($tPath)) {

        $check = Test-DateValid -FilePath $tPath
        if ($check.IsValid -and -not $Overwrite) { 
            continue 
        }

        $finalDate = Get-DateFromPath -Path $tPath
        $mode = "🔍 Inferred"

        if (-not $finalDate) {
            $tName = (Split-Path $tPath -Leaf).Replace($VideoTargetExt, "").ToLower()
            if ($sourceFileCache.ContainsKey($tName)) {
                $finalDate = (Get-Item -LiteralPath $sourceFileCache[$tName]).LastWriteTime.ToString("yyyy:MM:dd HH:mm:ss")
                $mode = "💾 FileSystem(Src)"
            } 
        }
        if (-not $finalDate) {
            # Write-Host "⏩ Skip (No Date Info): $(Split-Path $tPath -Leaf)" -ForegroundColor Gray
            $skippedCount++
            continue
        }
        $tasks.Add([PSCustomObject]@{ Dst = $tPath; Src = "-- NONE --"; Mode = $mode; NewDate = $finalDate })
    }
}
Write-Progress -Activity "Analyzing files..." -Completed

Write-Host "✅ Analysis Complete." -ForegroundColor Green
Write-Host "   - Total Targets  : $totalTargets" -ForegroundColor Gray
Write-Host "   - Pending Tasks  : $($tasks.Count)" -ForegroundColor Cyan
Write-Host "   - Skipped (No Date Info): $skippedCount" -ForegroundColor Yellow

# --- 4. Task Preview (Random 50) ---
if ($tasks.Count -gt 0) {
    $sampleSize = [math]::Min(50, $tasks.Count)
    $displayTasks = if ($tasks.Count -gt 1) { $tasks | Get-Random -Count $sampleSize } else { $tasks }

    Write-Host "`n📊 Task Preview (Sampled $sampleSize of $($tasks.Count))" -ForegroundColor Yellow
    Write-Host "===========================================================================================================" -ForegroundColor Gray
    
    $displayTable = foreach ($t in $displayTasks) {
        [PSCustomObject]@{
            "Mode"         = $t.Mode
            "Target File"  = Split-Path $t.Dst -Leaf
            "Source Ref"   = if ($t.Src -eq "-- NONE --") { "--" } else { Split-Path $t.Src -Leaf }
            "Target Date"  = $t.NewDate
        }
    }
    $displayTable | Format-Table -AutoSize
    
    Write-Host "===========================================================================================================" -ForegroundColor Gray
    Write-Host "💡 Legend & Logic Flow:" -ForegroundColor Gray
    Write-Host "    📦 Clone      : Found original. Step 1: Sync EXIF. Step 2: If fail, fallback to Source Time." -ForegroundColor Cyan
    Write-Host "    🔍 Inferred   : No original. Extracting YYYYMMDDHHMMSS from the target file path/name." -ForegroundColor Magenta
    Write-Host "    💾 FileSystem : No original & no date in name. Using Source File's LastWriteTime as last resort." -ForegroundColor DarkYellow
    Write-Host "`n✅ Preview Complete." -ForegroundColor Green
} else {
    Write-Host "✨ All files are clean. No tasks to perform." -ForegroundColor Green
    return
}

# --- 5. Execution ---
Write-Host "`n🚀 Ready to process $($tasks.Count) files." -ForegroundColor Cyan

while ($true) {
    $userInput = (Read-Host "`n🚀 Confirm execution? (y/n)").Trim().ToLower()
    if ($userInput -eq 'y') {
        break
    }
    if ($userInput -eq 'n') {
        Write-Host "🛑 Execution cancelled by user." -ForegroundColor Yellow
        return
    }
    Write-Host "⚠️  Invalid input '$userInput'. Please type 'y' to start or 'n' to exit." -ForegroundColor Red
}

$count = 0
$total = $tasks.Count
$idxLen = $total.ToString().Length
$outFmt = "{0} {1,-14} {2,-15} | {3,-19} | {4}"
foreach ($task in $tasks) {
    $count++
    $result = Invoke-MetadataFix -Task $task

    $cStr = $count.ToString().PadLeft($idxLen)
    $prog = "[$cStr/$total]"
    
    $icon = switch ($result.Status) {
        "Success" { "✅" }
        "Warning" { "⚠️ " }
        "Info"    { "🛠️ " }
        "Error"   { "❌" }
    }
    
    $color = switch ($result.Status) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Info"    { "Cyan" }
        "Error"   { "Red" }
    }

    $fName = Split-Path $task.Dst -Leaf
    Write-Host ($outFmt -f $icon,$prog, $result.Detail, $result.Date, $fName) -ForegroundColor $color
}

Write-Host "`n✨ Finished! Metadata standardized successfully." -ForegroundColor Green