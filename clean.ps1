# -*- coding: utf-8 -*-
# clean_optimized.ps1 —— 清理已压缩的源文件（扫描并删除已转换的源文件）

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [string]$BackupDirName = "", # 备份目录
    [string]$ExtFilter = "" 
)

# 解析目录路径
if (-not (Test-Path -LiteralPath $SourcePath)) {
    Write-Host "错误: 目录不存在: $SourcePath" -ForegroundColor Red
    exit 1
}

$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
Write-Host "🔍 扫描目录: $SourcePath" -ForegroundColor Green


# 备份目录处理
if (-not $PSBoundParameters.ContainsKey('BackupDirName')) {
    $Mode = 1
    Write-Host "🗑️ 清理模式：清理所有已经转换过的源文件" -ForegroundColor Cyan
}
else {
    $Mode = 0
    if ([System.IO.Path]::IsPathRooted($BackupDirName)) {
        $BackupRoot = [System.IO.Path]::GetFullPath($BackupDirName)
    }
    else {
        $BackupRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $BackupDirName))
    }
    if (-not (Test-Path $BackupRoot)) {
        Write-Host "❌ 错误：备份目录不存在 -> $BackupRoot" -ForegroundColor Red
        exit 1
    }
    Write-Host "💾 备份模式: 将所有已转换的文件备份到指定目录" -ForegroundColor Cyan
    Write-Host "📁 目标备份目录: $BackupRoot" -ForegroundColor Green
}

. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\tools-cfg.ps1"

$Supported = Get-SupportedExtensions
$videoSrcExt = $Supported.video
$imageSrcExt = $Supported.image

$configFile = Join-Path $PSScriptRoot "tools.json"

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


# 扫描文件
#$allFiles = [System.Collections.Generic.List[object]]::new()
$UserExtFilter = Parse-ExtFilter -ExtInput $ExtFilter
$filesByDirAndBase = @{}
$spinnerScan = New-ConsoleSpinner -Title "扫描目录中" -SamplingRate 500
foreach ($file in Get-ChildItem $SourcePath -Recurse -File) {
    $key="unknown"
    $filename=$file.FullName.ToLowerInvariant()
    $ext = $file.Extension.ToLowerInvariant()
    $conved = $false
    if ($filename.EndsWith($videoDstExt)) {
        $baseName = $file.Name.Substring(0, $file.Name.Length - $videoDstExt.Length)
        $key="vid.$($file.DirectoryName)/$baseName"
        $conved=$true
    } elseif ($filename.EndsWith($imageDstExt)){
        $baseName = $file.Name.Substring(0, $file.Name.Length - $imageDstExt.Length)
        $key="img.$($file.DirectoryName)/$baseName"
        $conved=$true
    } elseif ($ext -in $videoSrcExt ) {
        $key="vid.$($file.DirectoryName)/$($file.BaseName)"
    } elseif ($ext -in $imageSrcExt){
        $key="img.$($file.DirectoryName)/$($file.BaseName)"
    }else{
        continue
    }
    if ($file.Length -le 10){
        Write-Host "文件太小,跳过:$($file.FullName)" -ForegroundColor Red
        continue
    }

    if (-not $filesByDirAndBase.ContainsKey($key)) {
        $filesByDirAndBase[$key] = [pscustomobject]@{
            OriginalFile = $null  
            ConvertedFile = $null # 转换后的文件
        }
    }

    $entry = $filesByDirAndBase[$key]

    # 判断是否为转换后的文件
    if ($conved){
        $entry.ConvertedFile = $file
    }
    else{
        if ($null -ne $entry.OriginalFile) {
            Write-Host "`n⚠ 发现同名(basename)文件，无法处理:$($file.FullName)" -ForegroundColor Red
            Write-Host $entry.OriginalFile.FullName
            Write-Host $file.FullName
            $entry.OriginalFile = $null
        } else {
            $entry.OriginalFile = $file
        }
    }
}
&$spinnerScan "Done" -Finalize


# 使用 List<T> 替代 += 提升性能
$imageMatches = [System.Collections.Generic.List[object]]::new()
$vidMatches = [System.Collections.Generic.List[object]]::new()
$imageUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$vidUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

# 在匹配时直接累加字节数
$imgSrcBytes = 0L
$imgDstBytes = 0L
$vidSrcBytes = 0L
$vidDstBytes = 0L

$vidDstCount = 0L
$imgDstCount = 0L

# ----------------------------------------------------
# 关键优化区域：单次高效遍历文件组
# ----------------------------------------------------
$spinnerTask = New-ConsoleSpinner -Title "正在分析文件" -Total $filesByDirAndBase.Count  -SamplingRate 1000
foreach ($entry in $filesByDirAndBase.Values) {
    # 查找所有源文件和目标文件
    $file = if ($entry.OriginalFile) { $entry.OriginalFile } else { $entry.ConvertedFile }
    &$spinnerTask $file.FullName
    if (-not $file){
         continue
    }
    $ext = $file.Extension.ToLowerInvariant()

    if ($UserExtFilter.Count -gt 0 -and $ext -notin $UserExtFilter) {
        continue
    }

    if (-not $entry.OriginalFile){
        if ($entry.ConvertedFile.Name.EndsWith($imageDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            $imgDstCount += 1
        }elseif ($entry.ConvertedFile.Name.EndsWith($videoDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            $vidDstCount += 1
        }
        continue
    }

    if ($entry.ConvertedFile) {
        
        $matchObj = [pscustomobject]@{
            Src          = $entry.OriginalFile
            Dst          = $entry.ConvertedFile
            RelativePath = CalcRelativePath $SourcePath $entry.OriginalFile.FullName
        }
                
        if ($ext -in $imageSrcExt) {
            $imageMatches.Add($matchObj)
            $imgSrcBytes += $entry.OriginalFile.Length
            $imgDstBytes += $entry.ConvertedFile.Length
        }
        elseif ($ext -in $videoSrcExt) {
            $vidMatches.Add($matchObj)
            $vidSrcBytes += $entry.OriginalFile.Length
            $vidDstBytes += $entry.ConvertedFile.Length
        }
    }else{
        if ($ext -in $imageSrcExt) {
            $imageUnconverted.Add($entry.OriginalFile)
        }elseif ($ext -in $videoSrcExt) {
            $vidUnconverted.Add($entry.OriginalFile)
        }
    }
}
# === 统计计算 ===
# 已转换的文件统计（字节数已在匹配时累加）
$imgSrcSize = $imgSrcBytes
$imgDstSize = $imgDstBytes

$vidSrcSize = $vidSrcBytes
$vidDstSize = $vidDstBytes

# 未转换的文件统计
$imgUnconvertedSize = if ($imageUnconverted.Count -gt 0) {
    ($imageUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
}
else { 0 }

$vidUnconvertedSize = if ($vidUnconverted.Count -gt 0) {
    ($vidUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
}
else { 0 }

$totalSrcSize = $imgSrcSize + $vidSrcSize
$totalDstSize = $imgDstSize + $vidDstSize
$totalSavedSize = $totalSrcSize - $totalDstSize
$totalSavedPercent = if ($totalSrcSize -gt 0) { 
    [math]::Round((1 - $totalDstSize / $totalSrcSize) * 100, 1) 
}
else { 0 }

# 图片统计
$imageParams = @{
    Title            = "📸 图片文件"
    Count            = $imageMatches.Count 
    SrcSize          = $imgSrcSize  
    DstSize          = $imgDstSize  # 100MB
    UnconvertedCount = $imageUnconverted.Count 
    UnconvertedSize  = $imgUnconvertedSize 
    DoneCount     = $imgDstCount 
}
Write-ScanSummary @imageParams

$vidParams = @{
    Title            = "🎬 视频文件" 
    Count            = $vidMatches.Count 
    SrcSize          = $vidSrcSize  
    DstSize          = $vidDstSize  # 100MB
    UnconvertedCount = $vidUnconverted.Count 
    UnconvertedSize  = $vidUnconvertedSize 
    DoneCount     = $vidDstCount 
}
Write-ScanSummary @vidParams

# 总计
if ($imageMatches.Count + $vidMatches.Count -gt 0) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "📊 总计" -ForegroundColor Magenta
    Write-Host "  待删除文件: $($imageMatches.Count + $vidMatches.Count) 个" -ForegroundColor White
    Write-Host "  原始总大小: $(Format-Size $totalSrcSize)" -ForegroundColor Gray
    Write-Host "  压缩后总大小: $(Format-Size $totalDstSize)" -ForegroundColor Gray
    Write-Host "  总节省空间: $(Format-Size $totalSavedSize) ($totalSavedPercent%)" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host ""
}
else {
    Write-Host "✨ 没有发现可清理的文件。" -ForegroundColor Yellow
    exit 0
}

# === 显示文件列表（前10个） ===
$allMatches = $imageMatches + $vidMatches

if ($allMatches.Count -le 10) {
    Write-Host "待删除文件列表:" -ForegroundColor Yellow
    Write-Host ""
    $allMatches | ForEach-Object {
        # 使用 .Extension 属性检查是否是图片或视频源文件
        Write-Host "  $(if ($imageSrcExt -contains $_.Src.Extension.ToLowerInvariant()) {'📸'} else {'🎬'}) $($_.RelativePath)" -ForegroundColor DarkGray
    }
    Write-Host ""
}
else {
    Write-Host "待删除文件列表 (显示前10个):" -ForegroundColor Yellow
    Write-Host ""
    $allMatches | Select-Object -First 10 | ForEach-Object {
        Write-Host "  $(if ($imageSrcExt -contains $_.Src.Extension.ToLowerInvariant()) {'📸'} else {'🎬'}) $($_.RelativePath)" -ForegroundColor DarkGray
    }
    Write-Host "  ... 还有 $($allMatches.Count - 10) 个文件" -ForegroundColor DarkGray
    Write-Host ""
}

# === 显示未转换文件列表（前10个） ===
if ($imageUnconverted.Count -gt 0 -or $vidUnconverted.Count -gt 0) {
    Write-Host "未转换文件列表:" -ForegroundColor Yellow
    Write-Host ""
    
    # 未转换图片
    if ($imageUnconverted.Count -gt 0) {
        $imgUnconvertedToShow = $imageUnconverted | Select-Object -First 10
        $imgUnconvertedToShow | ForEach-Object {
            $relPath = $_.FullName.Substring($Dir.Length + 1)
            Write-Host "  📸 $relPath" -ForegroundColor DarkGray
        }
        if ($imageUnconverted.Count -gt 10) {
            Write-Host "  ... 还有 $($imageUnconverted.Count - 10) 个未转换图片" -ForegroundColor DarkGray
        }
    }
    
    # 未转换视频
    if ($vidUnconverted.Count -gt 0) {
        $vidUnconvertedToShow = $vidUnconverted | Select-Object -First 10
        $vidUnconvertedToShow | ForEach-Object {
            $relPath = $_.FullName.Substring($Dir.Length + 1)
            Write-Host "  🎬 $relPath" -ForegroundColor DarkGray
        }
        if ($vidUnconverted.Count -gt 10) {
            Write-Host "  ... 还有 $($vidUnconverted.Count - 10) 个未转换视频" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# === 确认删除 ===
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
if ($Mode -eq 0) {
    Write-Host "⚠️ 警告: 即将移动 $($imageMatches.Count + $vidMatches.Count) 个源文件到备份目录" -ForegroundColor Red
    Write-Host "备份目录: $BackupRoot" -ForegroundColor Yellow
} else {
    Write-Host "⚠️ 警告: 即将删除 $($imageMatches.Count + $vidMatches.Count) 个源文件" -ForegroundColor Red
}
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
Write-Host ""

$confirm = $null
do {
    $response = Read-Host "是否清理所有已压缩的源文件？(y/n)"

    if ($response -match "^[yY]$") {
        $confirm = $true
        break
    }
    elseif ($response -match "^[nN]$") {
        $confirm = $false
        break
    }
    else {
        Write-Host "输入无效，请输入 y 或 n" -ForegroundColor Red
    }
} while ($true)

if (-not $confirm) {
    Write-Host ""
    Write-Host "已取消，不做任何删除。" -ForegroundColor Yellow
    exit 0
}

# === 执行删除 ===
Write-Host ""
if ($Mode -eq 0) {
    Write-Host "正在移动文件到备份目录..." -ForegroundColor Cyan
} else {
    Write-Host "正在删除文件..." -ForegroundColor Cyan
}

$deletedCount = 0
$errorCount = 0

$allMatches | ForEach-Object {
    try {
        if ($Mode -eq 0) {
            # 备份模式：移动到备份目录，保持相同的相对路径
            $backupPath = Join-Path $BackupRoot $_.RelativePath
            $backupDir = Split-Path $backupPath -Parent

            # 确保目标目录存在
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }

            # 移动文件
            Move-Item -LiteralPath $_.Src.FullName -Destination $backupPath -Force
            $deletedCount++
        } else {
            # 删除模式：直接删除
            Remove-Item -LiteralPath $_.Src.FullName -Force -ErrorAction Stop
            $deletedCount++
        }
    }
    catch {
        Write-Host "  ✖ 操作失败: $($_.RelativePath) - $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
    }
}

# === 完成报告 ===
Write-Host ""
if ($Mode -eq 0) {
    Write-Host "====================== 移动完成 ======================" -ForegroundColor Yellow
    Write-Host "  ✅ 成功移动: $deletedCount 个文件到备份目录" -ForegroundColor Green
} else {
    Write-Host "====================== 删除完成 ======================" -ForegroundColor Yellow
    Write-Host "  ✅ 成功删除: $deletedCount 个文件" -ForegroundColor Green
}
if ($errorCount -gt 0) {
    Write-Host "  ❌ 操作失败: $errorCount 个文件" -ForegroundColor Red
}
Write-Host "  💾 释放空间: $(Format-Size $totalSrcSize)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host ""