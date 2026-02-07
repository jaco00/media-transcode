<#
.SYNOPSIS
    Fixes metadata for transcoded videos based on source files (Simplified Serial Version).
    
.DESCRIPTION
    Reads original videos from SourcePath, matches them with corresponding .h265.mp4 files 
    in DestPath, and injects EncodedDate into standard metadata tags via ExifTool.

.PARAMETER SourcePath
    The directory path of the original source videos.
    
.PARAMETER DestPath
    The directory path where transcoded videos are stored.

.PARAMETER VideoExt
    Extension patterns for source video files (e.g., "*.mov", "*.mp4").
    
.PARAMETER VideoTargetExt
    Extension pattern for target video files (e.g., ".h265.mp4").
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,

    [Parameter(Mandatory=$true)]
    [string]$DestPath,

    [string]$VideoTargetExt = ".h265.mp4",
    [string]$VideoExt = "*.mp4, *.mov, *.wmv, *.avi, *.mkv"
)

# --- 1. Environment Check ---
$ExifTool = "..\bin\exiftool.exe"
if (-not (Test-Path $ExifTool)) {
    Write-Host "❌ Error: exiftool.exe not found in .\bin\ directory" -ForegroundColor Red
    return
}

if (-not (Test-Path $SourcePath)) { Write-Error "SourcePath does not exist"; return }
if (-not (Test-Path $DestPath)) { Write-Error "DestPath does not exist"; return }


# Resolve absolute paths
$SourcePath = (Resolve-Path $SourcePath).Path
$DestPath = (Resolve-Path $DestPath).Path

# --- 2. Scan Files ---
Write-Host "🔍 Scanning files..." -ForegroundColor Gray
$IncludeList = $VideoExt.Split(',') | ForEach-Object { $_.Trim() }
$srcFiles = Get-ChildItem -Path $SourcePath -Recurse -File -Include $IncludeList

$tasks = @()
foreach ($file in $srcFiles) {
    # Calculate relative path
    $relPath = $file.FullName.Substring($SourcePath.Length).TrimStart('\')
    
    # Target naming rule: SourceBaseName + .h265.mp4
    $targetName = $file.BaseName + $VideoTargetExt
    
    # Safely determine the parent directory of the relative path
    $parentDir = Split-Path $relPath
    
    # Handle files in the root directory (where Split-Path returns empty)
    if ([string]::IsNullOrEmpty($parentDir)) {
        $targetFull = Join-Path $DestPath $targetName
    } else {
        $targetRelPath = Join-Path $parentDir $targetName
        $targetFull = Join-Path $DestPath $targetRelPath
    }

    if (Test-Path $targetFull) {
        # Note: We process all matched files. 
        # Repeating the process will OVERWRITE tags, not duplicate them.
        $tasks += [PSCustomObject]@{
            Src = $file.FullName
            Dst = $targetFull
        }
    }
}


if ($tasks.Count -eq 0) {
    Write-Host "☕ No matching .h265.mp4 target files found." -ForegroundColor Yellow
    return
}

# --- 3. Preview & User Confirmation ---
Write-Host "`n✅ Found $($tasks.Count) matching tasks." -ForegroundColor Cyan

# Random Preview of 10 items
$previewCount = [math]::Min(10, $tasks.Count)
Write-Host "--- Random Preview ($previewCount items) ---" -ForegroundColor DarkGray
$tasks | Get-Random -Count $previewCount | ForEach-Object {
    Write-Host "Source: $($_.Src)" -ForegroundColor Gray
    Write-Host "Target: $($_.Dst)" -ForegroundColor White
    Write-Host ""
}
Write-Host "----------------------------------------" -ForegroundColor DarkGray

do {
    $response = Read-Host "Do you want to start fixing metadata for these files? (y/n)"

    if ($response -match "^[yY]$") {
        break
    }
    elseif ($response -match "^[nN]$") {
        Write-Host "🛑 Operation cancelled by user." -ForegroundColor Yellow
        return
    }
    else {
        Write-Host "Invalid input. Please enter 'y' or 'n'." -ForegroundColor Red
    }
} while ($true)

Write-Host "`n🚀 Starting sequential processing...`n" -ForegroundColor Cyan

# --- 4. Sequential Execution ---
$count = 0
foreach ($task in $tasks) {
    $count++
    $percentage = [math]::Round(($count / $tasks.Count) * 100)
    Write-Host "[$count/$($tasks.Count) - $percentage%] Fixing: $(Split-Path $task.Dst -Leaf)" -ForegroundColor White

    # Construct ExifTool arguments
    # Note: Using '=' or '<' performs an OVERWRITE, so multiple runs are safe.
    $exifArgs = @(
        "-tagsFromFile", $task.Src,
        "-all:all>all:all",
        "-CreationDate<EncodedDate",
        "-MediaCreateDate<EncodedDate",
        "-CreateDate<EncodedDate",
        $task.Dst,
        "-overwrite_original"
    )

    # Execute ExifTool
    & $ExifTool $exifArgs | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "   Success" -ForegroundColor Green
    } else {
        Write-Host "   Failed (Exit Code: $LASTEXITCODE)" -ForegroundColor Red
    }
}

Write-Host "`n✨ All tasks completed!" -ForegroundColor Cyan