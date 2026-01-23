# -*- coding: utf-8 -*-
# zip.ps1 —— AVIF 批量压缩（断电安全 · 幂等 · 并行/顺序处理）
# Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

param(
    [string]$SourcePath = "",      # 源目录
    [string]$BackupDirName = "", # 备份目录
    [string[]]$IncludeDirs = @(),        # 只扫描 SourcePath 下的指定子目录（例如 '2023','2024'）。为空则扫描所有。
    [bool]$ShowDetails = $false,            # 是否输出详细的执行命令 (CMD: ...)
    [string]$Cmd = "zip"                  # 新增参数：zip, img, video, all
)

# =============================================================
# CPU 核心自动限制与并行规模计算逻辑
# =============================================================
# 默认预留 2 个核心，防止系统卡死
$ReservedCores = 2

$configFile = Join-Path $PSScriptRoot "tools.json"

if (-Not (Test-Path $configFile)) {
    Write-Host "配置文件不存在: $configFile" -ForegroundColor Red
    exit 1
}

try {
    $configData = Get-Content $configFile -Raw | ConvertFrom-Json
} catch {
    Write-Host "[Warning] 读取 tools.json 失败" -ForegroundColor Red
    exit 1
}

if ($null -ne $configData.ReservedCores) { 
    $ReservedCores = [int]$configData.ReservedCores 
}

if (-Not ($configData.PSObject.Properties.Name -contains "ImageOutputExt")) {
    Write-Host "配置文件缺少 ImageOutputExt" -ForegroundColor Red
    exit 1
}
if (-Not ($configData.PSObject.Properties.Name -contains "VideoOutputExt")) {
    Write-Host "配置文件缺少 VideoOutputExt" -ForegroundColor Red
    exit 1
}
if (-Not ($configData.PSObject.Properties.Name -contains "SkipExt")) {
    Write-Host "配置文件缺少 SkipExt" -ForegroundColor Red
    exit 1
}

$ImageDstExt = $configData.ImageOutputExt
$VideoDstExt = $configData.VideoOutputExt
$SkipExt     = $configData.SkipExt


try {
    # 1. 获取系统总逻辑核心数
    $totalCores = [Environment]::ProcessorCount

    # 2. 计算应使用的核心数 (并行执行时建议使用的线程数)
    # 如果总核心大于预留核心，则使用剩余核心；否则强制设为 1
    if ($totalCores -gt $ReservedCores) {
        $useCores = $totalCores - $ReservedCores
    } else {
        $useCores = 1
    }

    # 3. 计算位掩码 (Bitmask)
    # 限制当前进程（及生成的子进程如 ffmpeg/magick）仅在指定的 CPU 核心上运行
    $mask = [long]0
    for ($i = 0; $i -lt $useCores; $i++) {
        $mask = $mask -bor ([long]1 -shl $i)
    }

    # 4. 应用亲和性限制到当前进程
    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $currentProcess.ProcessorAffinity = [System.IntPtr]$mask

    # 打印优化信息
    $hexMask = "{0:X}" -f $mask
    Write-Host "[System] CPU 优化控制:" -ForegroundColor Gray
    Write-Host "  - 系统总核心: $totalCores" -ForegroundColor Gray
    Write-Host "  - 用户预留值: $ReservedCores" -ForegroundColor Gray
    Write-Host "  - 脚本可用核: $useCores (掩码: 0x$hexMask)" -ForegroundColor Cyan
} catch {
    $useCores = 1 # 失败时安全回退
    Write-Host "[Warning] 自动核心限制失败，回退至单核模式: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 将 $useCores 暴露给后续的并行处理逻辑（例如 ForEach-Object -Parallel -ThrottleLimit $useCores）
$MaxThreads = $useCores

. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\tools-cfg.ps1"

# 记录开始时间
$startTime = Get-Date
$UserExtFilter = @()

# ---------- 硬件检测 ----------
$gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*NVIDIA*" }
$useGpu = [bool]$gpu
if ($useGpu) {
    Write-Host "[硬件] 检测到 NVIDIA ($($gpu.Name))，开启显卡加速 (NVENC)。" -ForegroundColor Green
}
else {
    Write-Host "[硬件] 未发现 NVIDIA 显卡，使用 CPU 模式 (libx265)。" -ForegroundColor Yellow
}

$IsAutoMode = $Cmd -in @("img", "video", "all")
if ($IsAutoMode) {
    Write-Host "[Mode] 自动化执行模式: $Cmd (全扫描/默认确认)" -ForegroundColor Cyan
}


$Supported = Get-SupportedExtensions
$videoExtensions = $Supported.video
$imageExtensions = $Supported.image
Write-Host "当前支持的视频后缀: $($videoExtensions -join ', ')" -ForegroundColor Magenta
Write-Host "当前支持的图片后缀: $($imageExtensions -join ', ')" -ForegroundColor Green

# 1. 源目录 (SourcePath)
if (-not $PSBoundParameters.ContainsKey('SourcePath')) {
    $InputSourcePath = Read-Host "请输入 源目录 (SourcePath) [默认: $SourcePath]"
    $SourcePath = if ([string]::IsNullOrWhiteSpace($InputSourcePath)) { $SourcePath } else { $InputSourcePath }
}

# 2. 模式选择 (提前到此处，以便根据模式决定后续询问内容)

$SkipExisting = $true
if (-not $PSBoundParameters.ContainsKey('BackupDirName')) { 
    Write-Host "对比模式 (转换 → 保留源)" -ForegroundColor Cyan
    if (-not $IsAutoMode) {
        $SkipExistingResp = Read-Host "对比模式: 是否跳过已存在且非空的目标文件? (Y/N) [默认: Y]"
        $SkipExisting = [string]::IsNullOrWhiteSpace($SkipExistingResp) -or $SkipExistingResp -match '^[Yy]'
    }
}
else {
    Write-Host "备份模式 (转换 → 移动源到备份目录)" -ForegroundColor Cyan
   
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
    Write-Host "📦 备份目录：$BackupRoot" -ForegroundColor Cyan
}

# 扫描子目录
if(!$IsAutoMode) {
    $InputInclude = Read-Host "请输入扫描子目录 (逗号分隔，如 2023,2024；留空则全扫) [默认: 全部扫描]"
    $IncludeDirs = if ([string]::IsNullOrWhiteSpace($InputInclude)) { @() } else { $InputInclude.Split(',').Trim() }
}

if($Cmd -eq "filter"){
    $extInput = Read-Host "请输入要处理的文件后缀（如 .jpg,.jpeg，直接回车=不过滤）"
    if (-not [string]::IsNullOrWhiteSpace($extInput)) {
        $UserExtFilter = Parse-ExtFilter -ExtInput $extInput
    }
}

# 处理类型选择

if ($IsAutoMode -or $Cmd -eq "filter") {
    $IncludeDirs = @() # 自动化模式默认扫描所有
    switch ($Cmd) {
        "img"   { [MediaType]$CurrentMode = [MediaType]::Image }
        "video" { [MediaType]$CurrentMode = [MediaType]::Video }
        "all"   { [MediaType]$CurrentMode = [MediaType]::All }
        "filter"   { [MediaType]$CurrentMode = [MediaType]::All }
    }
} else {

    $InputProcessType = Read-Host "请选择处理类型 [0] 仅图片(默认) [1] 仅视频 [2] 所有"
    if ([string]::IsNullOrWhiteSpace($InputProcessType) -or $InputProcessType -notmatch '^[012]$') {
        $CurrentMode = [MediaType]::Image
    } else {
        [MediaType]$CurrentMode = [int]$InputProcessType
    }
}

if (-not $IsAutoMode) {
    $InputShowDetails = Read-Host "是否输出详细的执行命令 (Y/N) [默认: $(if ($ShowDetails) {'Y'} else {'N'})]"
    if (![string]::IsNullOrWhiteSpace($InputShowDetails)) {
        $ShowDetails = $InputShowDetails -match '^[Yy]$' 
    }
}


# 解析源目录路径 (支持绝对/相对路径与标准化)
if ([System.IO.Path]::IsPathRooted($SourcePath)) {
    $InputRoot = [System.IO.Path]::GetFullPath($SourcePath)
}
else {
    $InputRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $SourcePath))
}
$InputRoot = (Resolve-Path $InputRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
Write-Host "扫描目录: $InputRoot" -ForegroundColor Cyan

# 打印过滤信息
if ($IncludeDirs.Count -gt 0) {
    Write-Host "子目录过滤器已启用: $($IncludeDirs -join ', ')" -ForegroundColor Yellow
}
else {
    Write-Host "子目录过滤器已禁用: 扫描所有子目录" -ForegroundColor Yellow
}

# 检查 PowerShell 版本是否支持并行
$parallelEnabled = ($PSVersionTable.PSVersion.Major -ge 7) -and ($MaxThreads -gt 1)

# ---------- 扫描文件 ----------
$imageFiles = [System.Collections.Generic.List[object]]::new()
$videoFiles = [System.Collections.Generic.List[object]]::new()

$skipCount = 0    # 手动跳过计数

# 获取所有文件
$spinner = New-ConsoleSpinner -Title "扫描目录中" -SamplingRate 500

foreach ($file in Get-ChildItem $InputRoot -Recurse -File) {
    &$spinner $file.FullName
    # 1. 根子目录过滤 (如果 $IncludeDirs 非空)
    if ($IncludeDirs.Count -gt 0) {
        if ($file.Directory.FullName -eq $InputRoot) { continue }

        $firstDir = [IO.Path]::GetRelativePath($InputRoot, $file.Directory.FullName).
            Split([IO.Path]::DirectorySeparatorChar)[0]

        if ($firstDir -notin $IncludeDirs) { continue }
    }

    $ext = $file.Extension.ToLower()
    $name = $file.Name.ToLower()

    # 1. 准备分类判断
    $isImage = $ext -in $imageExtensions
    $isVideo = $ext -in $videoExtensions

    # 2. 状态判断
    $isTranscoded = ($name.EndsWith($VideoDstExt) -or $name.EndsWith($ImageDstExt))
    $isExplicitSkip = ($isImage -or $isVideo) -and $name.EndsWith(($SkipExt + $ext))

    if ($UserExtFilter.Count -gt 0 -and $ext -notin $UserExtFilter) {
        continue
    }

    # A. 已经转换过的，直接忽略（不在任何统计中）
    if ($isTranscoded) {
        continue
    }

    # B. 被标记手动跳过的 (符合当前 CurrentMode 范围才统计)
    if ($isExplicitSkip) {
        if (($CurrentMode -in [MediaType]::Image, [MediaType]::All -and $isImage) -or ($CurrentMode -in [MediaType]::Video, [MediaType]::All -and $isVideo)) {
            $skipCount++
        }
        continue
    }

    # C. 正常分类到待处理列表
    if ($CurrentMode -in [MediaType]::Image, [MediaType]::All -and $isImage) {
        if ($SkipExisting) {
            $checkPath = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($file.Name) + $ImageDstExt)
            if ((Test-Path $checkPath) -and (Get-Item $checkPath).Length -gt 0) { continue }
        }
        $imageFiles += $file
    }
    elseif ($CurrentMode -in [MediaType]::Video, [MediaType]::All -and $isVideo) {
        $videoPath = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($file.Name) + $VideoDstExt)
        # $tmpPath = $videoPath + ".tmp"

        # # 清理残留的临时文件 (.h265.mp4.tmp)
        # if (Test-Path $tmpPath) { 
        #     Write-Host "[清理] 发现并移除残余视频临时文件: $($tmpPath)" -ForegroundColor Gray
        #     Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue 
        # }

        if ($SkipExisting) {
            if ((Test-Path $videoPath) -and (Get-Item $videoPath).Length -gt 0) { continue }
        }
        $videoFiles += $file
    }
}
&$spinner "Done" -Finalize

Write-Host ""
Write-Host " TASK SUMMARY" -ForegroundColor Cyan
Write-Host " ────────────" -ForegroundColor DarkGray 

Write-Host " 📸 待处理图片: $($imageFiles.Count)" -ForegroundColor Green
Write-Host " 🎬 待处理视频: $($videoFiles.Count)" -ForegroundColor Green
Write-Host " ⏩ 手动已跳过: $skipCount" -ForegroundColor Gray


if ($imageFiles.Count -eq 0 -and $videoFiles.Count -eq 0) {
    Write-Host "没有需要处理的文件。" -ForegroundColor Yellow
    exit 0
}


# --- 1. 获取要显示的扫描目录列表 ---
if ($IncludeDirs.Count -gt 0) {
    # 启用过滤器时，只显示过滤器列表
    $displayDirs = $IncludeDirs
}
else {
    # 未启用过滤器时，分析实际扫描到的文件，获取它们的一级父目录
    $displayDirs = $imageFiles | ForEach-Object {
        $relativePath = $_.FullName.Substring($InputRoot.Length + 1)
        $segments = $relativePath.Split([System.IO.Path]::DirectorySeparatorChar)
        
        if ($segments.Count -eq 1) {
            # 文件直接位于 $InputRoot 根目录 (e.g., photo/a.jpg)
            Split-Path $InputRoot -Leaf
        }
        else {
            # 文件位于子目录 (e.g., photo/2024/a.jpg)
            $segments[0]
        }
    } | Select-Object -Unique | Sort-Object
}

# 定义对齐函数：让中文标签也能精准对齐
function Get-AlignedLabel {
    param([string]$Text, [int]$Width = 16)
    # 计算中文字符数（因为中文占2个宽度，补空格时需要少补一点）
    $chineseCharCount = ([char[]]$Text | Where-Object { [int]$_ -gt 255 }).Count
    # 实际需要填充的空格数 = 目标宽度 - 字符串长度 - 中文额外占位
    $padding = $Width - $Text.Length - $chineseCharCount
    if ($padding -lt 1) { $padding = 1 }
    return "  $Text" + (" " * $padding) + ": "
}


# 1. 定义配置项清单
$configItems = [Ordered]@{
    "源目录"           = $InputRoot
    "备份目录"         = $BackupRoot
    "跳过已转换文件"   = if ($SkipExisting) { "已开启" } else { "已关闭" }
    "扫描范围"         = if ($null -eq $IncludeDirs -or $IncludeDirs.Count -eq 0) { "所有" } else { $IncludeDirs -join ', ' }
    "执行模式"         = if ($parallelEnabled) { "并行模式 ($MaxThreads 线程)" } else { "单线程模式" }
    "输出级别"         = if ($ShowDetails) { "详细输出" } else { "静默模式" }
}
if ($UserExtFilter.Count -gt 0) {
    $configItems["后缀过滤"] = $UserExtFilter -join ', '
}

# 2. 统一循环输出
Write-Host "”
foreach ($key in $configItems.Keys) {
    $valColor = if ($key -eq "覆盖已转换文件") { "Red" } else { "White" }
    Write-Host "$(Get-AlignedLabel $key)" -NoNewline -ForegroundColor Gray
    Write-Host $configItems[$key] -ForegroundColor $valColor
}

$allFiles= $imageFiles + $videoFiles
$allTasks = Convert-FilesToTasks -files $allFiles -InputRoot $InputRoot -BackupRoot $BackupRoot -Type $CurrentMode -UseGpu $useGpu -Silent $IsAutoMode

# 2. 根据 EnableParallel 属性进行分流
$parallelTasks = [System.Collections.Generic.List[object]]::new()
$serialTasks   = [System.Collections.Generic.List[object]]::new()

foreach ($task in $allTasks) {
    if ($task.EnableParallel -and $parallelEnabled) {
        $parallelTasks.Add($task)
    } else {
        $serialTasks.Add($task)
    }
}
Write-Host " 🚀 并行队列 (Parallel)  : $($parallelTasks.Count.ToString().PadLeft(8))" -ForegroundColor Green
Write-Host " ⏳ 串行队列 (Sequential): $($serialTasks.Count.ToString().PadLeft(8))" -ForegroundColor Yellow


if ($IsAutoMode) {
    Write-Host "`n[等待] 脚本进入自动化倒计时 (按任意键立即开始，Ctrl+C 退出):" -ForegroundColor Yellow
    $totalSeconds = 10
    for ($i = $totalSeconds; $i -gt 0; $i--) {
        # 使用 `r 实现行首覆盖，保持在同一行输出
        Write-Host -NoNewline "`r>>> 任务将在 $i 秒后开始...   " 
        if ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true); break }
        Start-Sleep -Seconds 1
    }
    #Write-Host "`r   >>> 正在启动任务...               " -ForegroundColor Green
} else {
    # 交互模式：等待手动输入 Y 确认
    do {
        $response = (Read-Host "`n输入 Y 继续处理，输入 N 退出").ToUpper()
        if ($response -eq 'N') { exit }
    } while ($response -ne 'Y')
}

Write-Host "继续批量处理..." -ForegroundColor Green

$stats = @{
    image = @{ SrcBytes = 0; NewBytes = 0; Success = 0; Failed = 0 }
    video = @{ SrcBytes = 0; NewBytes = 0; Success = 0; Failed = 0 }
}


$counter = 0

function Update-GlobalProgress {
    param($Result)
    $res = $Result
    $script:counter++
    $type = if ($null -ne $res.Type) { ([string]$res.Type).ToLower() } else { "unknown" }
    

    if ($res.Success) {
        $stats[$type].SrcBytes += $res.SrcBytes
        $stats[$type].NewBytes += $res.NewBytes
        $stats[$type].Success++
        $elapsed = [math]::Round(((Get-Date) - $res.StartTime).TotalSeconds, 2)
        Write-CompressionStatus -File $res.File -SrcBytes $res.SrcBytes -NewBytes $res.NewBytes -Index $script:counter -Total $allTasks.Count -ElapsedSeconds $elapsed
    } else {
        $stats[$type].Failed++
        Write-Host "✖ 处理失败 ($($script:counter)/$($allTasks.Count)): $($res.File)" -ForegroundColor Red
    }
}

$workerScript = Join-Path $PSScriptRoot "worker.ps1"

if ($parallelEnabled -and @($parallelTasks).Count -gt 0) {
    # --- 并行模式 ---
    # $invokeFuncStr = ${function:Invoke-ProcessTask}.ToString()
    $logMutex = New-Object System.Threading.Mutex($false, "FileLockMutex")

    @($parallelTasks) | ForEach-Object -Parallel {
        . $using:workerScript

        Worker -Task $_ -ShowDetails ($using:ShowDetails) -LogMutex ($using:logMutex) -LogDir ($using:InputRoot)
        # Set-Item -Path function:Invoke-ProcessTask -Value ([ScriptBlock]::Create($using:invokeFuncStr))
        # Invoke-ProcessTask -Task $_ -ShowDetails ($using:ShowDetails) -LogMutex ($using:logMutex) -LogDir ($using:InputRoot)
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        $res = $_
        $counter++
        $type = if ($null -ne $res.Type) { ([string]$res.Type).ToLower() } else { "unknown" }

        if ($res.Success) {
            $stats[$type].SrcBytes += $res.SrcBytes
            $stats[$type].NewBytes += $res.NewBytes
            $stats[$type].Success++
            $elapsed = [math]::Round(((Get-Date) - $res.StartTime).TotalSeconds, 2)
            Write-CompressionStatus -File $res.File -SrcBytes $res.SrcBytes -NewBytes $res.NewBytes -Index $counter -Total $allTasks.Count -ElapsedSeconds $elapsed
        } else {
            $stats[$type].Failed++
            Write-Host "✖ 处理失败 ($counter/$allTasks.Count): $($res.File)" -ForegroundColor Red
        }
    }
    $logMutex.Dispose()
}

. "$PSScriptRoot\worker.ps1"
if ($serialTasks.Count -gt 0) {
    @($serialTasks) | ForEach-Object {
        $res = Worker -Task $_ -ShowDetails $ShowDetails -LogMutex $logMutex -LogDir $InputRoot
        Update-GlobalProgress -Result $res
    }
}

# ====================== 处理完成统计 ======================
Write-Host "`n====================== 处理完成统计 ======================" -ForegroundColor Yellow

# 1. 图片处理汇总
$imgStats = $stats["Image"]
$imgTotal = $imgStats.Success + $imgStats.Failed
if ($imgTotal -gt 0) {
    Write-Host "📸 图片处理: 成功 $($imgStats.Success) 个, 失败 $($imgStats.Failed) 个" -ForegroundColor Cyan
    if ($imgStats.Success -gt 0) {
        $imgSaved = $imgStats.SrcBytes - $imgStats.NewBytes
        $imgSavedStr = Format-Size $imgSaved
        Write-Host "   原大小: $(Format-Size $imgStats.SrcBytes) → 转换后: $(Format-Size $imgStats.NewBytes) | 节省: $imgSavedStr" -ForegroundColor Green
    }
}

# 2. 视频处理汇总
$vidStats = $stats["Video"]
$vidTotal = $vidStats.Success + $vidStats.Failed
if ($vidTotal -gt 0) {
    Write-Host "🎬 视频处理: 成功 $($vidStats.Success) 个, 失败 $($vidStats.Failed) 个" -ForegroundColor Cyan
    if ($vidStats.Success -gt 0) {
        $vidSaved = $vidStats.SrcBytes - $vidStats.NewBytes
        $vidSavedStr = Format-Size $vidSaved
        Write-Host "   原大小: $(Format-Size $vidStats.SrcBytes) → 转换后: $(Format-Size $vidStats.NewBytes) | 节省: $vidSavedStr" -ForegroundColor Green
    }
}

# 3. 总计汇总
$totalSrcBytes = $imgStats.SrcBytes + $vidStats.SrcBytes
$totalNewBytes = $imgStats.NewBytes + $vidStats.NewBytes

if ($totalSrcBytes -gt 0) {
    $totalSaved = $totalSrcBytes - $totalNewBytes
    $totalSavedStr = Format-Size $totalSaved
    $totalPercent = [math]::Round(($totalNewBytes / $totalSrcBytes) * 100, 1)
    
    Write-Host "`n💾 总计节省: $totalSavedStr ($(Format-Size $totalSrcBytes) → $(Format-Size $totalNewBytes), $totalPercent%)" -ForegroundColor Green
}

$endTime = Get-Date
$elapsed = ($endTime - $startTime).TotalMinutes
$elapsedStr = "{0:N2}" -f $elapsed
Write-Host "⏱️ 耗时: $elapsedStr 分钟" -ForegroundColor Yellow