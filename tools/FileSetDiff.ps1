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
    [string]$CPath       # Destination for moved files
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

$Supported = Get-SupportedExtensions
$videoSrcExt = $Supported.video
$imageSrcExt = $Supported.image

switch ($Mode.ToLower()) {
    "intersect"   { $Mode = "int" }
    "subtract"   { $Mode = "sub" }
}

$configFile = [System.IO.Path]::Combine($PSScriptRoot, "..", "tools.json")

if (-Not (Test-Path $configFile)) {
    Write-Host "配置文件不存在: $configFile" -ForegroundColor Red
    exit 1
}


try {
    $configData = Get-Content $configFile -Raw | ConvertFrom-Json
} catch {
    Write-Host "读取 tools.json 失败" -ForegroundColor Red
    exit 1
}

if (-Not ($configData.PSObject.Properties.Name -contains "ImageOutputExt")) {
    Write-Host "配置文件缺少 ImageOutputExt" -ForegroundColor Red
    exit 1
}
if (-Not ($configData.PSObject.Properties.Name -contains "VideoOutputExt")) {
    Write-Host "配置文件缺少 VideoOutputExt" -ForegroundColor Red
    exit 1
}

$imageDstExt = $configData.ImageOutputExt
$videoDstExt = $configData.VideoOutputExt

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
function Get-FileKey {
    param(
        [System.IO.FileInfo]$file,
        [string]$RootPath  # 用于计算相对路径
    )

    $rel = CalcRelativePath -RootPath $RootPath -FullPath $file.FullName

    $filename=$file.FullName.ToLowerInvariant()
    $ext = $file.Extension.ToLowerInvariant()
    if ($filename.EndsWith($videoDstExt)) {
        $relNoExt = $rel.Substring(0, $rel.Length - $videoDstExt.Length)
        $key="vid.$relNoExt"
    } elseif ($filename.EndsWith($imageDstExt)){
        $relNoExt = $rel.Substring(0, $rel.Length - $imageDstExt.Length)
        $key="img.$relNoExt"
    } elseif ($ext -in $videoSrcExt ) {
        $relNoExt = $rel.Substring(0, $rel.Length - $ext.Length)
        $key="vid.$relNoExt"
    } elseif ($ext -in $imageSrcExt){
        $relNoExt = $rel.Substring(0, $rel.Length - $ext.Length)
        $key="img.$relNoExt"
    }else{
        $relNoExt = $rel.Substring(0, $rel.Length - $ext.Length)
        $key="misc.$relNoExt"
    }
    return $key 
}

# ===============================
# Core Engine
# ===============================
function Invoke-SetOperation {
    param(
        [string]$APath,
        [string]$BPath,
        [string]$Mode,
        [string]$CPath
    )

    Write-Host  "load $APath  $BPath"
    # Get all files recursively
    $AFiles = Get-ChildItem $APath -Recurse -File
    $BFiles = Get-ChildItem $BPath -Recurse -File

    Write-Host "Load $($BFiles.Count) files from $BPath"

    # Ensure CPath exists
    if (-not (Test-Path $CPath)) {
        New-Item -ItemType Directory -Path $CPath | Out-Null
    }

    # Build hash index for B
    $BIndex = @{}
    foreach ($b in $BFiles) {
        $key = Get-FileKey $b $BPath
        if (-not $BIndex.ContainsKey($key)) {
            Write-Host "add:$key -> $($b.FullPath)"
            $BIndex[$key] = $b
        }
    }

    # Process each file in A
    foreach ($afile in $AFiles) {
        $matched = $false

        # Look up B index first
        $key = Get-FileKey $afile $APath
        Write-Host "check:$key"
        $bfile = $BIndex[$key]
        $matched = Test-FileEqual $afile $bfile
        Write-Host "match $matched a:$afile b:$bfile"

        # Determine whether to move based on Mode
        $shouldMove = switch ($Mode) {
            "int" { -not $matched }  # A ∩ B: move files not in B
            "sub"  {  $matched }      # A − B: move files found in B
        }

        if ($shouldMove) {
            $relativePath = $afile.FullName.Substring($APath.Length).TrimStart('\','/')
            $dest = Join-Path $CPath $relativePath
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir | Out-Null
            }
            Write-Host "Moving file: $($afile.FullName) -> $dest" -ForegroundColor Cyan
            Move-Item $afile.FullName $dest -Force
        }
    }
}

# ===============================
# Execute Engine
# ===============================
Invoke-SetOperation -APath $APath -BPath $BPath -Mode $Mode -CPath $CPath

