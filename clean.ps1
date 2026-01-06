# -*- coding: utf-8 -*-
# clean.ps1 —— 清理已压缩的源文件（扫描并删除已转换的源文件）

param(
    [Parameter(Mandatory = $true)]
    [string]$Dir
)

# 解析目录路径
if (-not (Test-Path -LiteralPath $Dir)) {
    Write-Host "错误: 目录不存在: $Dir" -ForegroundColor Red
    exit 1
}

$Dir = (Resolve-Path -LiteralPath $Dir).Path

# 文件扩展名配置
$imageSrcExt = @(".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif")
$imageDstExt = ".avif"

$videoSrcExt = @(".mp4", ".mkv", ".avi", ".wmv", ".mov", ".flv")
$videoDstSuffix = ".h265.mp4"

Write-Host ""
Write-Host "====================== 扫描配置 ======================" -ForegroundColor Yellow
Write-Host "  扫描目录: $Dir" -ForegroundColor Cyan
Write-Host "  扫描模式: 递归扫描所有子目录" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host ""

# 扫描文件
Write-Host "正在扫描文件..." -ForegroundColor Cyan

$allFiles = Get-ChildItem -Path $Dir -Recurse -File

# 建立索引：按目录+基名分组
$filesByDirAndBase = @{}
foreach ($f in $allFiles) {
    $key = "$($f.DirectoryName)\$($f.BaseName)"
    if (-not $filesByDirAndBase.ContainsKey($key)) { 
        $filesByDirAndBase[$key] = @{} 
    }
    $filesByDirAndBase[$key][$f.Extension.ToLowerInvariant()] = $f
}

Write-Host "正在分析文件..." -ForegroundColor Cyan

# 使用 List<T> 替代 += 提升性能
$imageMatches = [System.Collections.Generic.List[object]]::new()
$videoMatches = [System.Collections.Generic.List[object]]::new()
$imageUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$videoUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

# 在匹配时直接累加字节数，避免后续再遍历
$imgSrcBytes = 0L
$imgDstBytes = 0L
$vidSrcBytes = 0L
$vidDstBytes = 0L

foreach ($fileMap in $filesByDirAndBase.Values) {
    # 图片匹配：如果存在 .avif
    if ($fileMap.ContainsKey($imageDstExt)) {
        $dst = $fileMap[$imageDstExt]
        $src = $fileMap.Keys | Where-Object { $_ -ne $imageDstExt } | ForEach-Object { $fileMap[$_] } | Where-Object { $imageSrcExt -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 1
        if ($src) {
            $imageMatches.Add([pscustomobject]@{
                Src = $src
                Dst = $dst
                RelativePath = $src.FullName.Substring($Dir.Length + 1)
            })
            $imgSrcBytes += $src.Length
            $imgDstBytes += $dst.Length
        }
    }

    # 视频匹配：如果存在 .h265.mp4
    $dstVideoKey = $videoDstSuffix
    if ($fileMap.ContainsKey($dstVideoKey)) {
        $dst = $fileMap[$dstVideoKey]
        $src = $fileMap.Keys | Where-Object { $_ -ne $dstVideoKey } | ForEach-Object { $fileMap[$_] } | Where-Object { $videoSrcExt -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 1
        if ($src) {
            $videoMatches.Add([pscustomobject]@{
                Src = $src
                Dst = $dst
                RelativePath = $src.FullName.Substring($Dir.Length + 1)
            })
            $vidSrcBytes += $src.Length
            $vidDstBytes += $dst.Length
        }
    }

    # 未转换图片
    $srcImg = $fileMap.Keys | ForEach-Object { $fileMap[$_] } | Where-Object { $imageSrcExt -contains $_.Extension.ToLowerInvariant() }
    foreach ($s in $srcImg) {
        if (-not $fileMap.ContainsKey($imageDstExt)) { 
            $imageUnconverted.Add($s) 
        }
    }

    # 未转换视频
    $srcVid = $fileMap.Keys | ForEach-Object { $fileMap[$_] } | Where-Object { $videoSrcExt -contains $_.Extension.ToLowerInvariant() }
    foreach ($s in $srcVid) {
        if (-not $fileMap.ContainsKey($dstVideoKey)) { 
            $videoUnconverted.Add($s) 
        }
    }
}


# 辅助函数：格式化文件大小
function Format-Size {
    param([long]$bytes)
    if ($bytes -ge 1GB) {
        return "{0:N2} GB" -f ($bytes / 1GB)
    }
    elseif ($bytes -ge 1MB) {
        return "{0:N2} MB" -f ($bytes / 1MB)
    }
    elseif ($bytes -ge 1KB) {
        return "{0:N2} KB" -f ($bytes / 1KB)
    }
    else {
        return "$bytes B"
    }
}

# === 统计计算 ===
# 已转换的文件统计（字节数已在匹配时累加）
$imgSrcSize = $imgSrcBytes
$imgDstSize = $imgDstBytes
$imgSavedSize = $imgSrcSize - $imgDstSize
$imgSavedPercent = if ($imgSrcSize -gt 0) { 
    [math]::Round((1 - $imgDstSize / $imgSrcSize) * 100, 1) 
} else { 0 }

$vidSrcSize = $vidSrcBytes
$vidDstSize = $vidDstBytes
$vidSavedSize = $vidSrcSize - $vidDstSize
$vidSavedPercent = if ($vidSrcSize -gt 0) { 
    [math]::Round((1 - $vidDstSize / $vidSrcSize) * 100, 1) 
} else { 0 }

# 未转换的文件统计
if ($imageUnconverted.Count -gt 0) {
    $imgUnconvertedSize = ($imageUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
} else {
    $imgUnconvertedSize = 0
}

if ($videoUnconverted.Count -gt 0) {
    $vidUnconvertedSize = ($videoUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
} else {
    $vidUnconvertedSize = 0
}

$totalSrcSize = $imgSrcSize + $vidSrcSize
$totalDstSize = $imgDstSize + $vidDstSize
$totalSavedSize = $totalSrcSize - $totalDstSize
$totalSavedPercent = if ($totalSrcSize -gt 0) { 
    [math]::Round((1 - $totalDstSize / $totalSrcSize) * 100, 1) 
} else { 0 }

# === 美化输出 ===
Write-Host ""
Write-Host "====================== 扫描结果 ======================" -ForegroundColor Yellow
Write-Host ""

# 图片统计
Write-Host "📸 图片文件" -ForegroundColor Cyan
if ($imageMatches.Count -gt 0) {
    Write-Host "  已压缩: $($imageMatches.Count) 张" -ForegroundColor White
    Write-Host "    原始大小: $(Format-Size $imgSrcSize)" -ForegroundColor Gray
    Write-Host "    压缩后大小: $(Format-Size $imgDstSize)" -ForegroundColor Gray
    Write-Host "    节省空间: $(Format-Size $imgSavedSize) ($imgSavedPercent%)" -ForegroundColor Green
} else {
    Write-Host "  已压缩: 0 张" -ForegroundColor DarkGray
}

if ($imageUnconverted.Count -gt 0) {
    Write-Host "  未转换: $($imageUnconverted.Count) 张" -ForegroundColor Yellow
    Write-Host "    总大小: $(Format-Size $imgUnconvertedSize)" -ForegroundColor Gray
} else {
    Write-Host "  未转换: 0 张" -ForegroundColor DarkGray
}
Write-Host ""

# 视频统计
Write-Host "🎬 视频文件" -ForegroundColor Cyan
if ($videoMatches.Count -gt 0) {
    Write-Host "  已压缩: $($videoMatches.Count) 个" -ForegroundColor White
    Write-Host "    原始大小: $(Format-Size $vidSrcSize)" -ForegroundColor Gray
    Write-Host "    压缩后大小: $(Format-Size $vidDstSize)" -ForegroundColor Gray
    Write-Host "    节省空间: $(Format-Size $vidSavedSize) ($vidSavedPercent%)" -ForegroundColor Green
} else {
    Write-Host "  已压缩: 0 个" -ForegroundColor DarkGray
}

if ($videoUnconverted.Count -gt 0) {
    Write-Host "  未转换: $($videoUnconverted.Count) 个" -ForegroundColor Yellow
    Write-Host "    总大小: $(Format-Size $vidUnconvertedSize)" -ForegroundColor Gray
} else {
    Write-Host "  未转换: 0 个" -ForegroundColor DarkGray
}
Write-Host ""

# 总计
if ($imageMatches.Count + $videoMatches.Count -gt 0) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host "📊 总计" -ForegroundColor Magenta
    Write-Host "  待删除文件: $($imageMatches.Count + $videoMatches.Count) 个" -ForegroundColor White
    Write-Host "  原始总大小: $(Format-Size $totalSrcSize)" -ForegroundColor Gray
    Write-Host "  压缩后总大小: $(Format-Size $totalDstSize)" -ForegroundColor Gray
    Write-Host "  总节省空间: $(Format-Size $totalSavedSize) ($totalSavedPercent%)" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host ""
}
else {
    Write-Host "✨ 没有发现可清理的文件。" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# === 显示文件列表（前10个） ===
if ($imageMatches.Count + $videoMatches.Count -le 10) {
    Write-Host "待删除文件列表:" -ForegroundColor Yellow
    Write-Host ""
    $imageMatches | ForEach-Object {
        Write-Host "  📸 $($_.RelativePath)" -ForegroundColor DarkGray
    }
    $videoMatches | ForEach-Object {
        Write-Host "  🎬 $($_.RelativePath)" -ForegroundColor DarkGray
    }
    Write-Host ""
}
else {
    Write-Host "待删除文件列表 (显示前10个):" -ForegroundColor Yellow
    Write-Host ""
    $imageMatches | Select-Object -First 10 | ForEach-Object {
        Write-Host "  📸 $($_.RelativePath)" -ForegroundColor DarkGray
    }
    $videoMatches | Select-Object -First 10 | ForEach-Object {
        Write-Host "  🎬 $($_.RelativePath)" -ForegroundColor DarkGray
    }
    Write-Host "  ... 还有 $($imageMatches.Count + $videoMatches.Count - 10) 个文件" -ForegroundColor DarkGray
    Write-Host ""
}

# === 确认删除 ===
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
Write-Host "⚠️  警告: 即将删除 $($imageMatches.Count + $videoMatches.Count) 个源文件" -ForegroundColor Red
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
Write-Host ""

$confirm = $null
do {
    $response = Read-Host "是否清理所有已压缩的源文件？(y/n)"
    
    if ($response -eq "y" -or $response -eq "Y") {
        $confirm = $true
        break
    }
    elseif ($response -eq "n" -or $response -eq "N") {
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
Write-Host "正在删除文件..." -ForegroundColor Cyan

$deletedCount = 0
$errorCount = 0

# 删除图片
$imageMatches | ForEach-Object {
    try {
        Remove-Item -LiteralPath $_.Src.FullName -Force -ErrorAction Stop
        $deletedCount++
    }
    catch {
        Write-Host "  ✖ 删除失败: $($_.RelativePath) - $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
    }
}

# 删除视频
$videoMatches | ForEach-Object {
    try {
        Remove-Item -LiteralPath $_.Src.FullName -Force -ErrorAction Stop
        $deletedCount++
    }
    catch {
        Write-Host "  ✖ 删除失败: $($_.RelativePath) - $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
    }
}

# === 完成报告 ===
Write-Host ""
Write-Host "====================== 删除完成 ======================" -ForegroundColor Yellow
Write-Host "  ✅ 成功删除: $deletedCount 个文件" -ForegroundColor Green
if ($errorCount -gt 0) {
    Write-Host "  ❌ 删除失败: $errorCount 个文件" -ForegroundColor Red
}
Write-Host "  💾 释放空间: $(Format-Size $totalSrcSize)" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host ""
