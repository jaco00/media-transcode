# -*- coding: utf-8 -*-
# clean_optimized.ps1 —— 清理已压缩的源文件（扫描并删除已转换的源文件）

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath
)
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\tools-cfg.ps1"

$script:CheckerByExt = @{}
function Initialize-Config {
    param([string]$ConfigName)

    $ScriptDir = $PSScriptRoot
    if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

    $configPath = Join-Path $scriptDir $ConfigName

    if (-not (Test-Path $configPath)) {
        throw "配置文件不存在: $configPath"
    }
     # 读取 JSON
    $jsonText = Get-Content $configPath -Raw -Encoding UTF8

    try {
        $config = ConvertFrom-Json $jsonText
        if ($null -eq $config.checker) {
            Write-Host "❌ 警告: checker 属性确实是空的！" -ForegroundColor Red
        }
    } catch {
        throw "❌ JSON 解析失败: $_"
    }

    # 建立扩展名映射
    $map = @{}
    foreach ($checker in $config.checker) {
        Write-Host  "check>> $checker"
        foreach ($fmt in $checker.format) {
            $ext = $fmt.ToLower()
            Write-Host  "check>> $ext"
            if (-not $map.ContainsKey($ext)) {
                $map[$ext] = @()
            }
            $map[$ext] += $checker
        }
    }
    Write-Host "✅ 配置初始化完成，共 $($config.checker.Count) 个 checker"
    foreach ($c in $config.checker) {
        $formats = $c.format -join ", "
        Write-Host "  Checker: $($c.name), Metric: $($c.metric_name), Formats: $formats" -ForegroundColor Green
    }
    $script:CheckerByExt=$map
}

function Get-CheckersByExtension {
    param([string]$Extension)
    if (-not $Extension) {
        return @()
    }
    # 标准化扩展名，保证带点，且小写
    $ext = $Extension.ToLower()
    if (-not $ext.StartsWith(".")) {
        $ext = "." + $ext
    }
    # 查表，如果找不到返回空数组
    Write-Host  "check $ext  $script:CheckerByExt"
    Write-Host "CheckerByExt keys: $($script:CheckerByExt.Keys -join ', ')"
    if ($script:CheckerByExt.ContainsKey($ext)) {
    Write-Host "CheckerByExt keys: $($script:CheckerByExt.Keys -join ', ')"
        return ,$script:CheckerByExt[$ext]
    }
    return @()
}

function Measure-FileQuality {
    param(
        [Parameter(Mandatory=$true)][string]$SrcFile,
        [Parameter(Mandatory=$true)][string]$DstFile,
        [Parameter(Mandatory=$true)][PSObject]$Checker
    )

    $result = [PSCustomObject]@{
        SrcFile      = $SrcFile
        DstFile      = $DstFile
        SrcSize      = 0
        DstSize      = 0
        CheckerName  = $Checker.name
        QualityValue = 0
        Grade        = "F"
        Color        = "Gray"
        Metric       = $Checker.metric_name
        Success      = $false
        FileName     = $SrcFile
    }

    try {
        if (-not (Test-Path $SrcFile)) { throw "源文件不存在: $SrcFile" }
        if (-not (Test-Path $DstFile)) { throw "压缩文件不存在: $DstFile" }

        # ----------------------
        # 获取源/压缩文件大小
        # ----------------------
        $result.SrcSize = (Get-Item $SrcFile).Length
        $result.DstSize = (Get-Item $DstFile).Length

        # ----------------------
        # 视频参数填充
        # ----------------------
        $startTime = "0"
        $durationLimit = "10"
        $subsample = "1"

        if ($Checker.category -eq "video_quality") {
            $ffprobePath = Resolve-ToolExe -ExeName "ffprobe"
            $realLenText = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$SrcFile`"" 2>$null
            Write-Host  $realLenText
            if ($realLenText -match '^[0-9.]+$') {
                $realLen = [double]$realLenText
                if ($realLen -gt 10) {
                    $startTime = "5"
                    $subsample = "6"
                } else {
                    $durationLimit = $realLen.ToString()
                }
            }
        }
       Write-Host  $durationLimit

        # ----------------------
        # 获取工具可执行路径
        # ----------------------
        $ToolName = $Checker.tool
        $Tool = $script:ConfigJson.tools.$ToolName
        $ExeNameForLookup = if ($Tool.path -and $Tool.path -ne "") { $Tool.path } else { $ToolName }
        $ResolvedPath = if ($ExeNameForLookup -notmatch "[\\/]") { Resolve-ToolExe -ExeName $ExeNameForLookup } else { $ExeNameForLookup }

        # ----------------------
        # 参数扁平化与变量替换
        # ----------------------
        $flatArgs = @()
        foreach ($paramRow in $Checker.parameters) {
            foreach ($item in $paramRow) {
                $processed = $item.Replace('$SRC$', "`"$SrcFile`"").Replace('$DST$', "`"$DstFile`"")
                $processed = $processed.Replace('$START_TIME$', $startTime).Replace('$DURATION$', $durationLimit).Replace('$SUBSAMPLE$', $subsample)
                $flatArgs += $processed
            }
        }

        # ----------------------
        # 执行检测
        # ----------------------
        $output = & $ResolvedPath $flatArgs 2>&1 | Out-String

        # ----------------------
        # 解析结果
        # ----------------------
        if ($output -match $Checker.result_regex) {
            $score = [double]$Matches[1]
            $result.QualityValue = [math]::Round($score, 3)
            $result.Success = $true

            # 查找评分
            $gradeEntry = $Checker.grading | Sort-Object min -Descending | Where-Object { $score -ge $_.min } | Select-Object -First 1
            if ($gradeEntry) {
                $result.Grade = $gradeEntry.grade
                $result.Color = $gradeEntry.color
            }
        }

    } catch {
        Write-Warning "[$($result.SrcFile)] 检测失败: $($_.Exception.Message)"
    }

    return $result
}

function Show-Result {
    param($r)

    $icon = if ($r.Type -eq "video") { "🎬" } else { "🖼️" }

    # 使用辅助函数格式化文件大小
    $srcStr = Format-Size $r.SrcSize
    $dstStr = Format-Size $r.DstSize

    # 压缩率计算
    $compressRatio = 1 - ($r.DstSize / $r.SrcSize)
    $ratioPercent = [math]::Round($compressRatio * 100, 1)

    # 压缩率颜色
    $ratioColor = if ($ratioPercent -lt 0) { "Red" } else { "White" }

    # 对齐宽度
    $srcStr = $srcStr.PadLeft(8)
    $dstStr = $dstStr.PadLeft(8)
    $ratioStr = ("{0,6}%" -f $ratioPercent)

    # 构造输出
    Write-Host "$icon $srcStr → $dstStr [" -NoNewline
    Write-Host $ratioStr -ForegroundColor $ratioColor -NoNewline
    Write-Host "] | $($r.Metric): " -NoNewline
    Write-Host $r.QualityValue -ForegroundColor $r.Color -NoNewline
    Write-Host " [$($r.Grade)] | $($r.FileName)"
}
function New-Task {
    param(
        [string]$Src,
        [string]$Dst,
        [string]$Type,   # image / video
        [object]$Checker
    )

    [PSCustomObject]@{
        Src     = $Src
        Dst     = $Dst
        Type    = $Type
        Checker = $Checker
        Result  = $null
    }
}


Initialize-Config "tools.json"
$checkers = Get-CheckersByExtension ".mp4"

$Src="b.mp4"
$Dst="bb.mp4"

$tasks = @()

$checkers = Get-CheckersByExtension ".mp4"
$tasks += New-Task -Src "b.mp4" -Dst "bb.mp4" -Type "video" -Checker $checkers[0]
#$checkers = Get-CheckersByExtension ".jpeg"
#$tasks += New-Task -Src "a.jpeg" -Dst "a.avif" -Type "image" -Checker $checkers[0]


@($tasks) | ForEach-Object {
    $res = Measure-FileQuality -SrcFile $_.Src -DstFile $_.Dst -Checker $_.Checker 
    Show-Result $res
}

# if ($checkers -and $checkers.Count -gt 0) {
    # $targetChecker = $checkers[0]
    # 
    #3. 直接调用，函数内部会自己算 START_TIME 等
    # $finalResult = Measure-FileQuality -SrcFile $Src -DstFile $Dst -Checker $targetChecker 
# 
    #4. 输出结果
    # if ($finalResult.Success) {
        # Write-Host ">>> 结果: $($finalResult.FileName)" -ForegroundColor Cyan
        # Write-Host "分数: $($finalResult.QualityValue) [$($finalResult.Grade)]" -ForegroundColor $finalResult.Color
    # }
# } else {
    # Write-Host "未找到匹配的检测器" -ForegroundColor Red
# }


exit 0

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

$imageDstExt = ".avif"
$videoDstExt = ".h265.mp4"

# 扫描文件
#$allFiles = [System.Collections.Generic.List[object]]::new()
$filesByDirAndBase = @{}
$spinnerScan = New-ConsoleSpinner -Title "扫描目录中" -SamplingRate 500
foreach ($file in Get-ChildItem $SourcePath -Recurse -File) {
    &$spinnerScan $file.FullName
    $fExt = $file.Extension.ToLowerInvariant()
    $fBase = $file.BaseName
    if ($file.Name.EndsWith($videoDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
        $fExt = $videoDstExt
        $fBase = $file.Name.Substring(0, $file.Name.Length - $videoDstExt.Length)
    }

    $key = Join-Path $file.DirectoryName $fBase


    if (-not $filesByDirAndBase.ContainsKey($key)) {
        $filesByDirAndBase[$key] = [pscustomobject]@{
            OriginalFile = $null  
            ConvertedFile = $null # 转换后的文件
        }
    }

    $entry = $filesByDirAndBase[$key]

    # 判断是否为转换后的文件
    if ($file.Name.EndsWith($videoDstExt, [System.StringComparison]::OrdinalIgnoreCase) -or
        $file.Name.EndsWith($imageDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
        $entry.ConvertedFile = $file
    }
    elseif ($fExt -in $imageSrcExt -or $fExt -in $videoSrcExt) {
        $entry.OriginalFile = $file
    }
}
&$spinnerScan "Done" -Finalize


# 使用 List<T> 替代 += 提升性能
$imageMatches = [System.Collections.Generic.List[object]]::new()
$vidMatches = [System.Collections.Generic.List[object]]::new()
$imageUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$videoUnconverted = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

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
    if (-not $entry.OriginalFile){
        if ($entry.ConvertedFile.Name.EndsWith($imageDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            $imgDstCount += 1
        }elseif ($entry.ConvertedFile.Name.EndsWith($videoDstExt, [System.StringComparison]::OrdinalIgnoreCase)) {
            $vidDstCount += 1
        }
        continue
    }

    $ext = $file.Extension.ToLowerInvariant()
    if ($entry.ConvertedFile) {
        
        $matchObj = [pscustomobject]@{
            Src          = $entry.OriginalFile
            Dst          = $entry.ConvertedFile
            RelativePath = [System.IO.Path]::GetRelativePath($SourcePath, $entry.OriginalFile.FullName)
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
            $videoUnconverted.Add($entry.OriginalFile)
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

$vidUnconvertedSize = if ($videoUnconverted.Count -gt 0) {
    ($videoUnconverted | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
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
    UnconvertedCount = $videoUnconverted.Count 
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
    Write-Host ""
    exit 0
}


function DoClean {
    Write-Host "clean..."
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
}

function DoCompare {
    Write-Host "compare..."
}

if ($Cmd -eq "clean"){
    DoClean
}elseif ($Cmd -eq "comp"){
}else{
    DoCompare
    Write-Host "Bad Command" -ForegroundColor Red
}