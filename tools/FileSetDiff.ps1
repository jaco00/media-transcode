<#
============================================================
File Set Operation Tool
============================================================

This tool performs set-based operations on files between
two directories:

- A : Source / Full Set
- B : Reference / Selected Set
- C : Output directory for moved files

------------------------------------------------------------
Mode 1: refine (keep matched)
------------------------------------------------------------
Description:
  Refine A by intersecting with B, prune unmatched files.

Mathematical definition:
  A := A ∩ B
  C := A − B

Engineering meaning:
  - Keep only files in A that have a match in B
  - Files in A that do NOT exist in B are moved to C

Typical use case:
  - Keep only selected / approved / transcoded files
  - Remove leftovers, raws, or obsolete files

------------------------------------------------------------
Mode 2: exclude (remove matched)
------------------------------------------------------------
Description:
  Exclude B from A, extract intersection.

Mathematical definition:
  A := A − B
  C := A ∩ B

Engineering meaning:
  - Remove files from A that already exist in B
  - Matched files are moved to C

Typical use case:
  - Remove already-processed files
  - Separate duplicates or completed items

------------------------------------------------------------
Notes:
- File equality logic is abstracted via Test-FileEqual()
- Comparison strategy (hash, metadata, ffprobe, etc.)
  can be swapped without changing set logic
============================================================
#>


param(
    [Parameter(Mandatory)]
    [string]$APath,      # Full set
    [Parameter(Mandatory)]
    [string]$BPath,      # Reference / Selected
    [Parameter(Mandatory)]
    [ValidateSet("Intersect","int","Subtract","sub")]
    [string]$Mode,       # Operation mode
    [Parameter(Mandatory)]
    [string]$CPath,       # Destination for moved files
    [switch]$Trace,    
    [switch]$CaseSensitive 
)

. ([System.IO.Path]::Combine($PSScriptRoot, "..", "helpers.ps1"))
. ([System.IO.Path]::Combine($PSScriptRoot, "..", "tools-cfg.ps1"))
function Resolve-ScriptPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    } else {
        return [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($PSScriptRoot, $Path)
        )
    }
}

# ===============================
# Init config Data 
# ===============================
$Supported = Get-SupportedExtensions
$videoSrcExt = $Supported.video
$imageSrcExt = $Supported.image

switch ($Mode.ToLower()) {
    "intersect"   { $Mode = "int" }
    "subtract"   { $Mode = "sub" }
}

$configFile = [System.IO.Path]::Combine($PSScriptRoot, "..", "tools.json")


if (-Not (Test-Path $configFile)) { Write-Error "Config file not found: $configFile"; exit 1 }
$configData = Get-Content $configFile -Raw | ConvertFrom-Json
$imageDstExt = $configData.ImageOutputExt
$videoDstExt = $configData.VideoOutputExt


$ExtMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Populate video extensions
foreach ($ext in $videoSrcExt) { $ExtMap[$ext] = "vid" }

# Populate image extensions
foreach ($ext in $imageSrcExt) { $ExtMap[$ext] = "img" }


Write-Host "Video files: $videoDstExt,$videoSrcExt" -ForegroundColor DarkGreen
Write-Host "Image files: $imageDstExt,$imageSrcExt" -ForegroundColor DarkGreen

$APath = Resolve-ScriptPath $APath
$BPath = Resolve-ScriptPath $BPath
$CPath = Resolve-ScriptPath $CPath

if ($CPath.StartsWith($APath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "CPath must NOT be inside APath (will cause infinite recursion)"
}
if ($CPath.StartsWith($BPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "CPath must NOT be inside BPath"
}




# ===============================
# File Equality Interface
# ===============================
function Test-FileEqual {
    param(
        [System.IO.FileInfo]$FileA,
        [System.IO.FileInfo]$FileB
    )

    # TODO: implement your custom equality logic here
    # Example: files with same relative path are considered equal even if extensions differ
    return ($null -ne $FileA -and $null -ne $FileB)
}

# ===============================
# Generate Key for HashSet
# ===============================
function Get-FileKey{
    param(
        [System.IO.FileInfo]$File,
        [string]$RootPath  # 用于计算相对路径
    )

    #$rel = CalcRelativePath -RootPath $RootPath -FullPath $file.FullName
    $rel = $File.FullName.Substring($RootPath.Length).TrimStart('\','/')

    $ext = $file.Extension.ToLowerInvariant()
    #Write-Host "res:$rel|$($File.FullName)|$RootPath"

    $type = ""
    if ($File.Name.EndsWith($videoDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
        $key = "vid." + $rel.Substring(0, $rel.Length - $videoDstExt.Length)
    } elseif ($File.Name.EndsWith($imageDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
        $key = "img." + $rel.Substring(0, $rel.Length - $imageDstExt.Length)
    } elseif ($ExtMap.TryGetValue($ext, [ref]$type)) {
        $key = "$type." + $rel.Substring(0, $rel.Length - $ext.Length)
    } else {
        $key = "misc." + $rel.Substring(0, $rel.Length - $ext.Length)
    }

    if ($Trace) {
        Write-Host "[TRACE] File: $($File.FullName) => Key: $key" -ForegroundColor Yellow
    }

    return $key 
}


# ===============================
# Core Engine
# ===============================

Write-Host "`n[1/4] Scanning file systems..." -ForegroundColor Cyan
Write-Host  "APath:[$APath]"
Write-Host  "BPath:[$BPath]"
# Get all files recursively
$AFiles = Get-ChildItem $APath -Recurse -File
$BFiles = Get-ChildItem $BPath -Recurse -File

Write-Host "Load $($BFiles.Count) files from $BPath"

# Ensure CPath exists
if (-not (Test-Path $CPath)) {
    New-Item -ItemType Directory -Path $CPath | Out-Null
}

# Build hash index for B
Write-Host "[2/4] Building index and calculating set operations..." -ForegroundColor Cyan
#$BIndex = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new()

$KeyComparer = if ($CaseSensitive) {
    [System.StringComparer]::Ordinal
} else {
    [System.StringComparer]::OrdinalIgnoreCase
}

$BIndex = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new($KeyComparer)


$count = 0
foreach ($b in $BFiles) {
    $count++
    if (($count % 200) -eq 0) {
        Write-Progress -Activity "[2/4] Building B index" -Status "$count/ $($BFiles.Count)" -PercentComplete ($count * 100 / $BFiles.Count)
    }
    $key = Get-FileKey $b $BPath 


    $exists = $BIndex.ContainsKey($key)

    if (-not $BIndex.ContainsKey($key)) {
        $BIndex.Add($key, $b)
    }
}
Write-Progress -Activity "[2/4] Building B index" -Completed

# Process each file in A
$FilesToMove = New-Object System.Collections.Generic.List[PSCustomObject]
$count = 0
foreach ($afile in $AFiles) {
    $count++
    if (($count % 200) -eq 0) {
        $percent = [math]::Round(($count / $AFiles.Count) * 100)
        Write-Progress -Activity "Analyzing Files" -Status "Checking: $($afile.Name)" -PercentComplete $percent
    }

    # Look up B index first
    $key = Get-FileKey $afile $APath 
    $bfile = $BIndex[$key]
    $matched = Test-FileEqual $afile $bfile

    # Determine whether to move based on Mode
    $shouldMove = switch ($Mode) {
        "int" { -not $matched }  # A ∩ B: move files not in B
        "sub"  {  $matched }      # A − B: move files found in B
    }

    if ($shouldMove) {
        $relativePath = $afile.FullName.Substring($APath.Length).TrimStart('\','/')
        $destFile = Join-Path $CPath $relativePath
        $destDir = Split-Path $destFile -Parent

        $FilesToMove.Add([PSCustomObject]@{
            FileName    = $afile.Name
            Source      = $afile.FullName
            DestFile    = $destFile
            DestDir = $destDir 
        })
    }
}
Write-Progress -Activity "Analyzing Files" -Completed

# --- Step 3: Preview & Confirmation ---
Write-Host ("`n" + ("═" * 70)) -ForegroundColor Yellow
Write-Host " SCAN COMPLETE" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow


Write-Host "Total files in Source (A): $($AFiles.Count)"
Write-Host "Files identified to move:  $($FilesToMove.Count)" -ForegroundColor Cyan
Write-Host ("─" * 70)

if ($FilesToMove.Count -gt 0) {
    Write-Host "Top 50 Files to be Moved (Ramdom):" -ForegroundColor Gray
    # Randomly pick 20 items from the list, then format the table
    $FilesToMove | Get-Random -Count 50 | Select-Object Source, DestFile | Format-Table -AutoSize
    
    $confirm = Read-Host "Proceed with moving $($FilesToMove.Count) files? (Type 'y' to confirm)"
    if ($confirm -ne 'y') {
        Write-Host "Operation cancelled by user." -ForegroundColor Red
        exit
    }
} else {
    Write-Host "No files match the criteria for moving." -ForegroundColor Green
    exit
}

# --- Step 4: Execution ---
Write-Host "`n[4/4] Executing move operations..." -ForegroundColor Cyan
$movedCount = 0
foreach ($task in $FilesToMove) {
    $movedCount++
    if (($movedCount % 200) -eq 0) {
        $percent = [math]::Round(($movedCount / $FilesToMove.Count) * 100)
        Write-Progress -Activity "Moving Files" -Status "Progress: $movedCount / $($FilesToMove.Count)" -PercentComplete $percent
    }
    
    if (-not (Test-Path $task.DestDir)) { New-Item -ItemType Directory -Path $task.DestDir | Out-Null }
    
    try {
        Move-Item $task.Source $task.DestFile -Force -ErrorAction Stop
    } catch {
        Write-Host "Failed to move: $($task.FileName)" -ForegroundColor Red
    }
}
Write-Progress -Activity "Moving Files" -Completed
Write-Host "`nDone! Successfully moved $movedCount files." -ForegroundColor Green

