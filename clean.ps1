# -*- coding: utf-8 -*-
# clean_optimized.ps1 —— 清理已压缩的源文件（扫描并删除已转换的源文件）

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
$videoDstExt = $videoDstSuffix.ToLowerInvariant() # 统一使用小写后缀进行查找

Write-Host ""
Write-Host "====================== 扫描配置 ======================" -ForegroundColor Yellow
Write-Host "  扫描目录: $Dir" -ForegroundColor Cyan
Write-Host "  扫描模式: 递归扫描所有子目录" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host ""

# 扫描文件
Write-Host "正在扫描文件..." -ForegroundColor Cyan

# 快速获取所有文件对象
$allFiles = Get-ChildItem -Path $Dir -Recurse -File

# 建立索引：按目录+基名分组 (此步骤已是高效的)
$filesByDirAndBase = @{}
foreach ($f in $allFiles) {
    $key = "$($f.DirectoryName)\$($f.BaseName)"
    if (-not $filesByDirAndBase.ContainsKey($key)) { 
        $filesByDirAndBase[$key] = @{} 
    }
    # 使用小写扩展名作为键
    $filesByDirAndBase[$key][$f.Extension.ToLowerInvariant()] = $f
}

Write-Host "正在分析文件 (优化后的单次遍历)..." -ForegroundColor Cyan

# 使用 List<T> 替代 += 提升性能
$imageMatches = [System.Collections.Generic.List[object]]::new()
$videoMatches = [System.Collections.Generic.List[object]]::new()
$imageUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$videoUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

# 在匹配时直接累加字节数
$imgSrcBytes = 0L
$imgDstBytes = 0L
$vidSrcBytes = 0L
$vidDstBytes = 0L

# ----------------------------------------------------
# 关键优化区域：单次高效遍历文件组
# ----------------------------------------------------
foreach ($group in $filesByDirAndBase.Values) {
    # 查找所有源文件和目标文件
    $srcImagesInGroup = @()
    $srcVideosInGroup = @()
    $dstImage = $null
    $dstVideo = $null

    foreach ($ext in $group.Keys) {
        $file = $group[$ext]
        
        if ($ext -eq $imageDstExt) { # .avif
            $dstImage = $file
        } elseif ($ext -eq $videoDstExt) { # .h265.mp4
            $dstVideo = $file
        } elseif ($imageSrcExt -contains $ext) {
            $srcImagesInGroup += $file
        } elseif ($videoSrcExt -contains $ext) {
            $srcVideosInGroup += $file
        }
    }

    # 1. 处理图片匹配 (已转换)
    if ($dstImage) {
        # 优化: 找到任意一个匹配的源文件作为待删除对象
        $src = $srcImagesInGroup | Select-Object -First 1
        if ($src) {
            $imageMatches.Add([pscustomobject]@{
                Src = $src
                Dst = $dstImage
                RelativePath = $src.FullName.Substring($Dir.Length + 1)
            })
            $imgSrcBytes += $src.Length
            $imgDstBytes += $dstImage.Length
        }
    }
    
    # 2. 处理视频匹配 (已转换)
    if ($dstVideo) {
        # 优化: 找到任意一个匹配的源文件作为待删除对象
        $src = $srcVideosInGroup | Select-Object -First 1
        if ($src) {
            $videoMatches.Add([pscustomobject]@{
                Src = $src
                Dst = $dstVideo
                RelativePath = $src.FullName.Substring($Dir.Length + 1)
            })
            $vidSrcBytes += $src.Length
            $vidDstBytes += $dstVideo.Length
        }
    }

    # 3. 处理未转换文件 (排除已匹配的源文件，避免重复)
    # 未转换图片: 如果组内有图片源文件，但没有 .avif 目标
    if (-not $dstImage) {
        # 修复：显式转换为 FileInfo 数组
        $imageUnconverted.AddRange([System.IO.FileInfo[]]$srcImagesInGroup)
    }
    
    # 未转换视频: 如果组内有视频源文件，但没有 .h265.mp4 目标
    if (-not $dstVideo) {
        # 修复：显式转换为 FileInfo 数组
        $videoUnconverted.AddRange([System.IO.FileInfo[]]$srcVideosInGroup)
    }
}
# ----------------------------------------------------

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
$imgUnconvertedSize = if ($imageUnconverted.Count -gt 0) {
    ($imageUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
} else { 0 }

$vidUnconvertedSize = if ($videoUnconverted.Count -gt 0) {
    ($videoUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
} else { 0 }

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
    Write-Host "  原始大小: $(Format-Size $imgSrcSize)" -ForegroundColor Gray
    Write-Host "  压缩后大小: $(Format-Size $imgDstSize)" -ForegroundColor Gray
    Write-Host "  节省空间: $(Format-Size $imgSavedSize) ($imgSavedPercent%)" -ForegroundColor Green
} else {
    Write-Host "  已压缩: 0 张" -ForegroundColor DarkGray
}

if ($imageUnconverted.Count -gt 0) {
    Write-Host "  未转换: $($imageUnconverted.Count) 张" -ForegroundColor Yellow
    Write-Host "  总大小: $(Format-Size $imgUnconvertedSize)" -ForegroundColor Gray
} else {
    Write-Host "  未转换: 0 张" -ForegroundColor DarkGray
}
Write-Host ""

# 视频统计
Write-Host "🎬 视频文件" -ForegroundColor Cyan
if ($videoMatches.Count -gt 0) {
    Write-Host "  已压缩: $($videoMatches.Count) 个" -ForegroundColor White
    Write-Host "  原始大小: $(Format-Size $vidSrcSize)" -ForegroundColor Gray
    Write-Host "  压缩后大小: $(Format-Size $vidDstSize)" -ForegroundColor Gray
    Write-Host "  节省空间: $(Format-Size $vidSavedSize) ($vidSavedPercent%)" -ForegroundColor Green
} else {
    Write-Host "  已压缩: 0 个" -ForegroundColor DarkGray
}

if ($videoUnconverted.Count -gt 0) {
    Write-Host "  未转换: $($videoUnconverted.Count) 个" -ForegroundColor Yellow
    Write-Host "  总大小: $(Format-Size $vidUnconvertedSize)" -ForegroundColor Gray
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
$allMatches = $imageMatches + $videoMatches

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
if ($imageUnconverted.Count -gt 0 -or $videoUnconverted.Count -gt 0) {
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
    if ($videoUnconverted.Count -gt 0) {
        $vidUnconvertedToShow = $videoUnconverted | Select-Object -First 10
        $vidUnconvertedToShow | ForEach-Object {
            $relPath = $_.FullName.Substring($Dir.Length + 1)
            Write-Host "  🎬 $relPath" -ForegroundColor DarkGray
        }
        if ($videoUnconverted.Count -gt 10) {
            Write-Host "  ... 还有 $($videoUnconverted.Count - 10) 个未转换视频" -ForegroundColor DarkGray
        }
    }
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
Write-Host "正在删除文件..." -ForegroundColor Cyan

$deletedCount = 0
$errorCount = 0

$allMatches | ForEach-Object {
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