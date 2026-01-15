# -*- coding: utf-8 -*-
# zip.ps1 —— AVIF 批量压缩（断电安全 · 幂等 · 并行/顺序处理）
# Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

param(
    [string]$SourcePath = "",      # 源目录
    [int]$AvifQuality = 80,                 # AVIF 质量模式 (-q)。根据用户测试，数值越高，画质越清晰 (80 为高质量，范围 0-100)。
    [string]$BackupDirName = "", # 备份目录
    [string[]]$IncludeDirs = @(),        # 只扫描 SourcePath 下的指定子目录（例如 '2023','2024'）。为空则扫描所有。
    [int]$MaxThreads = 8,                 # 并行处理的最大线程数。0 或 1 表示顺序处理。
    [int]$HeicQuality = 75,              # HEIC/HEIF 转换质量 (0-100, NConvert)5
    [int]$AVIFJobs = 1,                   # AVIF 编码器内部使用的线程数 (--jobs)。在 PowerShell 并行模式下（MaxThreads > 1），强烈建议保持 1 以避免资源竞争。设为 0 或大于 1 适用于顺序处理。
    [bool]$ShowDetails = $false,            # 是否输出详细的执行命令 (CMD: ...)
    [string]$AvifColorOptions = "-y 444", # 新增：AVIF 附加颜色选项 (默认 -y 444, 移除 --cicp 以保留原图 ICC)
    [string]$Codec = "libx265",          # 视频编码器
    [string]$CRF = "21",                 # CPU 视频质量 (CRF)
    [string]$CQ = "22"                   # GPU 视频质量 (CQ)
)



# 读取配置文件
$configFile = Join-Path $PSScriptRoot "config.json"
if (Test-Path $configFile) {
    Write-Host "✅ 已加载配置文件: config.json" -ForegroundColor Green
    $configData = Get-Content $configFile | ConvertFrom-Json
    if ($null -ne $configData.AvifQuality) { [int]$AvifQuality = $configData.AvifQuality }
    if ($null -ne $configData.MaxThreads) { [int]$MaxThreads = $configData.MaxThreads }
    if ($null -ne $configData.HeicQuality) { [int]$HeicQuality = $configData.HeicQuality }
    if ($null -ne $configData.AVIFJobs) { [int]$AVIFJobs = $configData.AVIFJobs }
    if ($null -ne $configData.AvifColorOptions) { [string]$AvifColorOptions = $configData.AvifColorOptions }
    if ($null -ne $configData.Codec) { [string]$Codec = $configData.Codec }
    if ($null -ne $configData.CRF) { [string]$CRF = $configData.CRF }
    if ($null -ne $configData.CQ) { [string]$CQ = $configData.CQ }
}

. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\tools-cfg.ps1"

# 记录开始时间
$startTime = Get-Date



# ---------- 硬件检测 ----------
$gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*NVIDIA*" }
$useGpu = [bool]$gpu
if ($useGpu) {
    $Codec = "hevc_nvenc"
    Write-Host "[硬件] 检测到 NVIDIA ($($gpu.Name))，开启显卡加速 (NVENC)。" -ForegroundColor Green
}
else {
    $Codec = "libx265"
    Write-Host "[硬件] 未发现 NVIDIA 显卡，使用 CPU 模式 (libx265)。" -ForegroundColor Yellow
}
# ---------- 配置 ----------
#$imageExtensions = @(".jpg", ".jpeg", ".png", ".heic", ".heif")
#$videoExtensions = @(".mp4", ".mov", ".wmv", ".avi", ".mkv")

$Supported = Get-SupportedExtensions

# 3. 直接替换你原来的静态数组
# 以前：$videoExtensions = @(".mp4", ".mov", ".wmv", ".avi", ".mkv")
$videoExtensions = $Supported.video
$imageExtensions = $Supported.image
Write-Host "当前支持的视频后缀: $($videoExtensions -join ', ')" -ForegroundColor Magenta
Write-Host "当前支持的图片后缀: $($imageExtensions -join ', ')" -ForegroundColor Green


$FFmpegExe = Resolve-ToolExe "ffmpeg.exe"
$AvifEncExe = Resolve-ToolExe "avifenc.exe"
$NConvertExe = Resolve-ToolExe "nconvert.exe"


# 1. 源目录 (SourcePath)
if (-not $PSBoundParameters.ContainsKey('SourcePath')) {
    $InputSourcePath = Read-Host "请输入 源目录 (SourcePath) [默认: $SourcePath]"
    $SourcePath = if ([string]::IsNullOrWhiteSpace($InputSourcePath)) { $SourcePath } else { $InputSourcePath }
}

# 2. 模式选择 (提前到此处，以便根据模式决定后续询问内容)
$Mode = $null
if (-not $PSBoundParameters.ContainsKey('BackupDirName')) {
    $Mode = 1
    Write-Host "对比模式 (转换 → 保留源)" -ForegroundColor Cyan
}
else {
    $Mode = 0
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

# Add SkipExisting prompt
$SkipExisting = $false
if ($Mode -eq 1) {
    $SkipExistingResp = Read-Host "共存模式: 是否跳过已存在且非空的目标文件 (h265.mp4/avif)? (Y/N) [默认: Y]"
    $SkipExisting = [string]::IsNullOrWhiteSpace($SkipExistingResp) -or $SkipExistingResp -match '^[Yy]'
}


# 扫描子目录
$InputInclude = Read-Host "请输入扫描子目录 (逗号分隔，如 2023,2024；留空则全扫) [默认: 全部扫描]"
$IncludeDirs = if ([string]::IsNullOrWhiteSpace($InputInclude)) { @() } else { $InputInclude.Split(',').Trim() }

# 处理类型选择
$InputProcessType = Read-Host "请选择处理类型 [0] 仅图片(默认) [1] 仅视频 [2] 所有"

# 验证输入并转换为枚举类型
if ([string]::IsNullOrWhiteSpace($InputProcessType) -or $InputProcessType -notmatch '^[012]$') {
    $CurrentMode = [MediaType]::Image # 默认值
} else {
    # PowerShell 会自动将匹配的数字字符串转换为对应的枚举成员
    [MediaType]$CurrentMode = [int]$InputProcessType
}

# 转换为字符串用于后续调用
$processTypeStr = $CurrentMode.ToString().ToLower()

# 4. 询问压制参数
if ($true) {
    # 最大并行线程
    $InputMaxThreads = Read-Host "请输入并行处理线程数 (MaxThreads) [默认: $MaxThreads]"
    $MaxThreads = if ([string]::IsNullOrWhiteSpace($InputMaxThreads)) { $MaxThreads } else { [int]$InputMaxThreads }

    # 质量设置确认
    # 默认视频质量标签
    $videoQualityLabel = "CRF"
    $defaultVideoQuality = $CRF
    if ($useGpu) {
        $videoQualityLabel = "CQ"
        $defaultVideoQuality = $CQ
    }
    
    $UseDefaultQuality = Read-Host "是否使用默认质量设置 (HEIC: $HeicQuality, AVIF: $AvifQuality, $videoQualityLabel = $defaultVideoQuality) ? (Y/N) [默认: Y]"
    if ($UseDefaultQuality -match '^[Nn]') {
        $InputHeicQuality = Read-Host "请输入 HEIC 转换质量 (HeicQuality) [默认: $HeicQuality]"
        $HeicQuality = if ([string]::IsNullOrWhiteSpace($InputHeicQuality)) { $HeicQuality } else { [int]$InputHeicQuality }

        $InputAvifQuality = Read-Host "请输入 AVIF 质量 (0-100) [默认: $AvifQuality]"
        $AvifQuality = if ([string]::IsNullOrWhiteSpace($InputAvifQuality)) { $AvifQuality } else { [int]$InputAvifQuality }
        
        if ($useGpu) {
            $InputVideoQuality = Read-Host "请输入 NVIDIA 显卡压缩质量 (CQ, 建议 25-30) [默认: $CQ]"
            $CQ = if ([string]::IsNullOrWhiteSpace($InputVideoQuality)) { $CQ } else { [string]$InputVideoQuality }
        }
        else {
            $InputVideoQuality = Read-Host "请输入 CPU 视频压缩质量 (CRF, 建议 21-25) [默认: $CRF]"
            $CRF = if ([string]::IsNullOrWhiteSpace($InputVideoQuality)) { $CRF } else { [string]$InputVideoQuality }
        }
    }

    # 详细输出/静默模式
    $InputShowDetails = Read-Host "是否输出详细的执行命令 (Y/N) [默认: $(if ($ShowDetails) {'Y'} else {'N'})]"
    if (![string]::IsNullOrWhiteSpace($InputShowDetails)) {
        $ShowDetails = $InputShowDetails -match '^[Yy]$'
    }
}




# **重要提示:**
# 处理 HEIC/HEIF 文件现在依赖 NConvert (XnView).


$psMajor = $PSVersionTable.PSVersion.Major 

# AVIF 编码器通用选项，不再包含 --quiet，使用重定向实现静默
$encoderOptions = @("--speed", "6") 
if ($AVIFJobs -ge 0) {
    $encoderOptions += "--jobs", $AVIFJobs
}
$encoderOptions += $AvifColorOptions.Split(' ').Where({ $_ }) 

# 解析源目录路径 (支持绝对/相对路径与标准化)
if ([System.IO.Path]::IsPathRooted($SourcePath)) {
    $InputRoot = [System.IO.Path]::GetFullPath($SourcePath)
}
else {
    $InputRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $SourcePath))
}
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

$imageFiles = @()      # 图片列表
$videoFiles = @() # 视频列表
$skipCount = 0    # 手动跳过计数

# 获取所有文件
$rawFiles = Get-ChildItem $InputRoot -Recurse -File

foreach ($file in $rawFiles) {
    # 1. 根子目录过滤 (如果 $IncludeDirs 非空)
    if ($IncludeDirs.Count -gt 0) {
        # 获取相对于 $InputRoot 的完整相对路径
        $relativePath = $file.FullName.Substring($InputRoot.Length + 1)
        # 分割路径
        $segments = $relativePath.Split([System.IO.Path]::DirectorySeparatorChar)
        
        # 跳过根目录文件
        if ($segments.Count -eq 1) { continue }
        
        # 检查一级目录是否匹配
        if ($segments[0] -notin $IncludeDirs) { continue }
    }

    $ext = $file.Extension.ToLower()
    $name = $file.Name.ToLower()

    # 1. 准备分类判断
    $isImage = $ext -in $imageExtensions
    $isVideo = $ext -in $videoExtensions

    # 2. 状态判断
    $isTranscoded = ($name.EndsWith(".h265.mp4") -or $ext -eq ".avif")
    $isExplicitSkip = ($isImage -or $isVideo) -and $name.EndsWith(".skip" + $ext)

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
            $checkPath = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($file.Name) + ".avif")
            if ((Test-Path $checkPath) -and (Get-Item $checkPath).Length -gt 0) { continue }
        }
        $imageFiles += $file
    }
    elseif ($CurrentMode -in [MediaType]::Video, [MediaType]::All -and $isVideo) {
        $videoPath = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($file.Name) + ".h265.mp4")
        $tmpPath = $videoPath + ".tmp"

        # 清理残留的临时文件 (.h265.mp4.tmp)
        if (Test-Path $tmpPath) { 
            Write-Host "[清理] 发现并移除残余视频临时文件: $($tmpPath)" -ForegroundColor Gray
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue 
        }

        if ($SkipExisting) {
            if ((Test-Path $videoPath) -and (Get-Item $videoPath).Length -gt 0) { continue }
        }
        $videoFiles += $file
    }
}

Write-Host ""
Write-Host "====================== 扫描统计 ======================" -ForegroundColor Yellow
Write-Host " 📸 待处理图片: $($imageFiles.Count)" -ForegroundColor Green
Write-Host " 🎬 待处理视频: $($videoFiles.Count)" -ForegroundColor Green
Write-Host " ⏩ 手动已跳过: $skipCount" -ForegroundColor Gray
Write-Host "======================================================" -ForegroundColor Yellow

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



Write-Host "====================== 当前配置摘要 ======================" -ForegroundColor Yellow
Write-Host " 源目录: $InputRoot" -ForegroundColor Green
if ($Mode -eq 0) {
    Write-Host " 备份目录: $BackupRoot" -ForegroundColor Green
}
if ($SkipExisting) {
    Write-Host " 跳过已存在: 已开启" -ForegroundColor Yellow
}
Write-Host " 扫描子目录: $($IncludeDirs -join ', ')" -ForegroundColor Green
Write-Host " 最大线程: $MaxThreads" -ForegroundColor Green
Write-Host " HEIC质量: $HeicQuality" -ForegroundColor Green
Write-Host " AVIF质量: $AvifQuality" -ForegroundColor Green
if ($useGpu) {
    Write-Host " 视频转码: $Codec (CQ: $CQ)" -ForegroundColor Green
}
else {
    Write-Host " 视频转码: $Codec (CRF: $CRF)" -ForegroundColor Green
}
Write-Host " 详细输出/静默: $(if ($ShowDetails) {'详细输出 (非静默)'} else {'静默模式'})" -ForegroundColor Green

if ($parallelEnabled) {
    # 提示用户多线程处于活动状态
    Write-Host "处理模式: 并行 ($MaxThreads 线程，父进程 PID: $pid)。AVIFjobs: $AVIFJobs" -ForegroundColor Cyan
}
else {
    
    Write-Host "处理模式: 顺序 (PS 版本: $psMajor, MaxThreads: $MaxThreads)。AVIFjobs: $AVIFJobs。" -ForegroundColor Cyan
}
Write-Host "==========================================================" -ForegroundColor Yellow

# --- 3. 确认步骤 (仅 Mode 0, 1 运行) ---
Write-Host ""
Write-Host "====================== 执行确认 ======================" -ForegroundColor Yellow



do {
    # 使用 Read-Host 获取用户输入
    $response = Read-Host "输入 Y 继续处理，输入 N 退出脚本"
    # 将用户输入转换为大写，并使用 -ceq 进行精确比较（不区分大小写）
    $responseUpper = $response.ToUpper()
    
    if ($responseUpper -ceq "Y") {
        break
    }
    elseif ($responseUpper -ceq "N") {
        Write-Host "用户选择退出。脚本终止。" -ForegroundColor Red
        exit 0
    }
    else {
        Write-Host "输入无效，请重新 输入 (Y/N)。" -ForegroundColor Red
    }
} while ($true)

Write-Host "继续批量处理..." -ForegroundColor Green

# $userParams = Invoke-ParameterInteraction -Type $processTypeStr -UseGpu $useGpu -Silent $false
# if ($null -eq $userParams -or $userParams.Count -eq 0) {
#     Write-Error "加载工具配置失败"
#     exit 1
# }
# $commandMap = Get-CommandMap -UserParamsMap $userParams

$videoTaskList = Convert-FilesToTasks -files $videoFiles -InputRoot $InputRoot -BackupRoot $BackupRoot -Type ([MediaType]::Video) -UseGpu $useGpu
$imageTaskList = Convert-FilesToTasks -files $imageFiles -InputRoot $InputRoot -BackupRoot $BackupRoot -Type ([MediaType]::Image) 

# 打印测试结果
foreach ($task in $imageTaskList) {
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "源文件: $($task.Src)"
    Write-Host "相对路径: $($task.RelativePath)"
    Write-Host "目标文件: $($task.TargetOut)"
    Write-Host "备份路径: $($task.BackupPath)"
    Write-Host "命令键: $($task.CmdKey)"
    
    foreach ($cmd in $task.Cmds) {
        Write-Host "`n  [工具: $($cmd.ToolName)]" -ForegroundColor Green
        Write-Host "  执行路径 (Path): $($cmd.Path)"
        Write-Host "  参数数组 (Args): $($cmd.Args -join ' | ')"
        Write-Host "  显示命令 (DisplayCmd):" -ForegroundColor Yellow
        Write-Host "  $($cmd.DisplayCmd)"
    }
}
Write-Host "----------------------------------------" -ForegroundColor Gray

function Invoke-ProcessTask {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Task,
        [Parameter()] [bool]$ShowDetails = $false,
        [Parameter()] $LogMutex = $null
    )

    if ($null -eq $Task) { return $null }

    $startTime = Get-Date
    $src, $rel, $tempOut, $finalOut = $Task.Src, $Task.RelativePath, $Task.TempOut, $Task.TargetOut
    $rootPath = Split-Path $src -Parent

    $resultTemplate = [ordered]@{
        File         = $src
        Type         = $Task.Type
        SrcBytes     = $Task.OldSize
        NewBytes     = 0
        StartTime    = $startTime
        Success      = $false
        ToolUsed     = ""
        ErrorMessage = ""
    }

    if (-not $Task.Cmds -or $Task.Cmds.Count -eq 0) {
        $resultTemplate.ErrorMessage = "任务 [$rel] 配置异常: 无有效工具命令。"
        return [pscustomobject]$resultTemplate
    }

    # 外层 try 包裹整个循环，确保 finally 能在函数结束时执行一次
    try {
        $totalCmds = $Task.Cmds.Count
        for ($idx = 0; $idx -lt $totalCmds; $idx++) {
            $cmdObj = $Task.Cmds[$idx]
            $toolLabel = if ($totalCmds -gt 1) { "[$($cmdObj.ToolName)] ($($idx+1)/$totalCmds)" } else { "[$($cmdObj.ToolName)]" }
            $output = ""
            
            try {
                if ($Task.Type.ToString() -eq "video") {
                    if ($ShowDetails) { Write-Host "CMD ${toolLabel}: $($cmdObj.DisplayCmd)" -ForegroundColor Yellow }
                  
                    & $cmdObj.Path @($cmdObj.Args)
                } else {
                    $output = & $cmdObj.Path @($cmdObj.Args) 2>&1
                    if ($ShowDetails) {
                        Write-Host "CMD ${toolLabel}: $($cmdObj.DisplayCmd)" -ForegroundColor Yellow 
                        Write-Host ($output -join "`n") -ForegroundColor Yellow
                    }
                }

                if ($LASTEXITCODE -eq 0 -and (Test-Path $tempOut)) {
                    # 必须在 Move-Item 之前获取大小，因为移动后临时路径就消失了
                    $resultTemplate.NewBytes = (Get-Item $tempOut).Length 
                    Move-Item $tempOut $finalOut -Force
                    
                    if (-not [string]::IsNullOrWhiteSpace($Task.BackupPath)) {
                        if (-not (Test-Path $Task.BackupDir)) { New-Item $Task.BackupDir -ItemType Directory -Force | Out-Null }
                        Move-Item $src $Task.BackupPath -Force
                    }

                    $resultTemplate.Success  = $true
                    $resultTemplate.ToolUsed = $cmdObj.ToolName
                    return [pscustomobject]$resultTemplate
                } else {
                    throw "命令: $($cmdObj.DisplayCmd)`n退出码: $LASTEXITCODE`n终端输出: $($output -join "`n")"
                }
            }
            catch {
                # 记录日志前清理当前方案产生的残余
                if (Test-Path $tempOut) { Remove-Item $tempOut -Force -ErrorAction SilentlyContinue }

                $logFile = Join-Path $rootPath "err-$(Get-Date -Format 'yyyy-MM-dd').log"
                $errDetail = $_.Exception.Message
                $logContent = "[$(Get-Date -Format 'HH:mm:ss')] 失败: $rel`n方案: $toolLabel`n错误: $errDetail`n$('-' * 60)"

                if ($null -ne $LogMutex) {
                    $null = $LogMutex.WaitOne(); try { Add-Content $logFile "`n$logContent" } finally { $LogMutex.ReleaseMutex() }
                } else { Add-Content $logFile "`n$logContent" }

                Write-Host " [FAILED] " -BackgroundColor Red -ForegroundColor White -NoNewline
                Write-Host " $($cmdObj.DisplayCmd) " -BackgroundColor Black -ForegroundColor Yellow
                
                if ($idx -lt ($totalCmds - 1)) {
                    Write-Host "⚠ $toolLabel 失败，已记录日志，重试下一个方案..." -ForegroundColor Yellow
                } else {
                    # 最后一个方案也失败，返回结果对象
                    Write-Host "✖ 任务彻底失败, 源文件: $src" -ForegroundColor Red
                    $resultTemplate.ErrorMessage = "全方案失败。末次错误: $errDetail"
                    $resultTemplate.Success      = $false
                    return [pscustomobject]$resultTemplate
                }
            }
        } # End For
    }
    finally {
        # 终极保底清理，放在循环外
        if (Test-Path $tempOut) { Remove-Item $tempOut -Force -ErrorAction SilentlyContinue }
    }
}

$stats = @{
    image = @{ SrcBytes = 0; NewBytes = 0; Success = 0; Failed = 0 }
    video = @{ SrcBytes = 0; NewBytes = 0; Success = 0; Failed = 0 }
}

if ($parallelEnabled){
    $totalTasks = $videoTaskList.Count
    $allTasks = @($videoTaskList) 
}else{
    $totalTasks = $videoTaskList.Count+$imageTaskList.Count
    $allTasks = @($videoTaskList) + @($imageTaskList)
}

if ($parallelEnabled -and @($imageTaskList).Count -gt 0) {
    # --- 并行模式 ---
    $invokeFuncStr = ${function:Invoke-ProcessTask}.ToString()
    $logMutex = New-Object System.Threading.Mutex($false, "FileLockMutex")

    @($imageTaskList) | ForEach-Object -Parallel {
        Set-Item -Path function:Invoke-ProcessTask -Value ([ScriptBlock]::Create($using:invokeFuncStr))
        Invoke-ProcessTask -Task $_ -ShowDetails $false -LogMutex ($using:logMutex)
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        $res = $_
        $counter++
        $type = "image"

        if ($res.Success) {
            $stats[$type].SrcBytes += $res.SrcBytes
            $stats[$type].NewBytes += $res.NewBytes
            $stats[$type].Success++
            $elapsed = [math]::Round(((Get-Date) - $res.StartTime).TotalSeconds, 2)
            Write-CompressionStatus -File $res.File -SrcBytes $res.SrcBytes -NewBytes $res.NewBytes -Index $counter -Total $totalTasks -ElapsedSeconds $elapsed
        } else {
            $stats[$type].Failed++
            Write-Host "✖ 处理失败 ($counter/$totalTasks): $($res.File)" -ForegroundColor Red
        }
    }
    $logMutex.Dispose()
}

for ($i = 0; $i -lt $totalTasks; $i++) {
    $currentTask = $allTasks[$i]
    
    # 调用处理函数
    $res = Invoke-ProcessTask -Task $currentTask -ShowDetails $false -LogMutex $null

    # 获取任务类型 (Image 或 Video)
    $type = if ($null -ne $res.Type) { ([string]$res.Type).ToLower() } else { "unknown" }
    $elapsed = [math]::Round(((Get-Date) - $res.StartTime).TotalSeconds, 2)
    if ($res.Success) {
        # 成功统计
        $stats[$type].SrcBytes += $res.SrcBytes
        $stats[$type].NewBytes += $res.NewBytes
        $stats[$type].Success++
        
        # 调用输出函数显示进度 (假设已定义 Write-CompressionStatus)
        Write-CompressionStatus -File $currentTask.RelativePath -SrcBytes $res.SrcBytes -NewBytes $res.NewBytes -Index ($i + 1) -Total $totalTasks -ElapsedSeconds $elapsed
    } else {
        # 失败统计
        $stats[$type].Failed++
        # 保持在控制台有明显的失败提示
        Write-Host "✖ 处理失败 ($($i+1)/$totalTasks): $($res.File)" -ForegroundColor Red
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

exit
######################################################################################################################################################################

# ---------- 保留原来的 ScriptBlock（用于并行模式）----------
function Process-Image {
    param($file, $config)

    if ($null -eq $file) { return } # 安全检查

    # 记录开始时间
    $startTime = Get-Date

    $src = $file.FullName
    $rootPath = $config.InputRoot
    if ($null -eq $rootPath) { $rootPath = $InputRoot } # fallback for sequential

    $rel = $src.Substring($rootPath.Length).TrimStart('\')
    $dir = Split-Path $rel -Parent
    $name = $file.Name
    $oldSize = $file.Length

    # 获取当前 Runspace 的唯一线程 ID
    $runspaceId = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    # 路径构造 (仅当备份启用时使用 $config.BackupRoot)
    $backupDir = $null
    $backup = $null
    if ($config.Mode -eq 0) {
        $backupDir = Join-Path $config.BackupRoot $dir
        $backup = Join-Path $backupDir $name
    }

    $avifOut = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($name) + ".avif")
    $tempOut = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($name) + ".tmp")
    
    try {

        # 0. 输出进度
        #Write-Host "[$progress] 正在处理: $rel (Runspace ID: $runspaceId)" -ForegroundColor DarkGray

        # 2. 转换
        $isHEIF = $file.Extension -in @(".heic", ".heif")
        $newSize = 0  # 初始化
        $actualOldSize = if (Test-Path $src) { (Get-Item $src).Length } else { $oldSize }
        if ($isHEIF) {
            # ── HEIC/HEIF (NConvert) ──

            # 构造 nconvert 参数
            $nconvertArgs = @("-out", "avif")
            $nconvertArgs += @("-q", $config.HeicQuality)
            $nconvertArgs += "-keep_icc"
            $nconvertArgs += "-overwrite"

            if ($config.ShowDetails) {
                $nconvertArgs += "-v"
            }
            else {
                $nconvertArgs += "-quiet"
            }

            # 输出文件 (先写 tmp)
            $nconvertArgs += @("-o", $tempOut)

            # 输入文件
            $nconvertArgs += $src

            # 构造参数字符串用于诊断
            $nconvertArgStr = "$($nconvertArgs -join ' ')"

            if ($config.ShowDetails) {
                Write-Host "CMD: $($config.NConvertExe) $nconvertArgStr" -ForegroundColor Yellow
                $output= & $config.NConvertExe @nconvertArgs  2>&1
                Write-Host $output -ForegroundColor Yellow
            }
            else {
                # 并发修复：直接重定向到 $null，避免 Out-Null 的内存泄漏
                $null = & $config.NConvertExe @nconvertArgs 2>&1
            }

            if ($LASTEXITCODE -ne 0) {
                throw "NConvert 转换失败 (HEIF, ExitCode: $LASTEXITCODE)`n命令: $($config.NConvertExe) $nconvertArgStr"
            }

            # 转换成功后重命名
            if (Test-Path $tempOut) {
                Move-Item $tempOut $avifOut -Force
            }

        }
        else {
            # 转换普通文件 (jpg, png)，使用 Avifenc
            $avifArgs = @()
            if ($config.encoderOptions) { $avifArgs += $config.encoderOptions }
            $avifArgs += @("-q", $config.AvifQuality, $src, $tempOut)

            # 构造参数字符串用于诊断
            $avifArgStr = "$($avifArgs -join ' ')"

            # 捕获输出用于错误诊断
            $output = & $config.AvifEncExe @avifArgs 2>&1

            if ($config.ShowDetails) {
                Write-Host "CMD: $($config.AvifEncExe) $avifArgStr" -ForegroundColor DarkYellow
                Write-Host $output -ForegroundColor Yellow
            }

            if ($LASTEXITCODE -ne 0) {
                throw "avifenc 编码失败 (退出码: $LASTEXITCODE)`n尝试执行: $($config.AvifEncExe) $avifArgStr`n错误信息: $($output -join "`n")"
            }

            # 转换成功后重命名
            if (Test-Path $tempOut) {
                Move-Item $tempOut $avifOut -Force
            }

            # 获取转换后的文件大小
            
        }

        # 重新获取源文件大小，避免并发时 $file.Length 不准确

        $newSize = (Get-Item $avifOut).Length

        
    }
    catch {
        # 清理失败 (如果存在部分写入的临时文件)
        if (Test-Path $tempOut) { Remove-Item $tempOut -Force -ErrorAction SilentlyContinue }
        # 在并行模式下，使用 Write-Host 配合颜色提示失败
        Write-Host "✖ 处理失败: $rel $($_.Exception.Message)" -ForegroundColor Red

        # 写入日志 (使用 Mutex 保证线程安全)
        $logFile = Join-Path $rootPath "err-$(Get-Date -Format 'yyyy-MM-dd').log"
        $logContent = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] 失败: $src`n错误: $($_.Exception.Message)`n" + ("-" * 60) + "`n"

        $logMutex = $config.LogMutex
       
        try {
            $logMutex.WaitOne() | Out-Null  # 请求访问互斥锁
            Add-Content $logFile $logContent -ErrorAction SilentlyContinue  # 写入日志
        } finally {
            $logMutex.ReleaseMutex()  # 释放互斥锁
        }

        return [pscustomobject]@{
            File     = $src
            SrcBytes = $actualOldSize
            NewBytes = 0  # 返回失败时的 NewBytes 设为 0
            StartTime = $startTime
        }
    }
    finally {
        # 清理临时文件 (.tmp)
        if (Test-Path $tempOut) {
            Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
            Write-Host "临时文件已删除: $tempOut" -ForegroundColor Green
        }
    }
    [pscustomobject]@{
        File     = $src
        SrcBytes = $actualOldSize
        NewBytes = $newSize
        StartTime = $startTime
    }
}


# ---------- 执行处理 (统一入口) ----------
if ($imageFiles.Count -gt 0) {

    $BackupEnabled = ($Mode -eq 0) # 只有 Mode 0 (备份模式) 启用备份

    # 统计变量
    $imageSuccessCount = 0
    $imageFailedCount = 0
    $imageSrcBytes = 0
    $imageNewBytes = 0

    # 构造配置对象 (用于传递给并行/顺序脚本块)
    $scriptConfig = @{
        InputRoot      = $InputRoot
        BackupRoot     = $BackupRoot

        HeicQuality    = $HeicQuality
        ShowDetails    = $ShowDetails
        encoderOptions = $encoderOptions

        AvifQuality    = $AvifQuality
        Mode           = $Mode
        BackupEnabled  = $BackupEnabled

        AvifEncExe     = $AvifEncExe
        NConvertExe    = $NConvertExe
        LogMutex = [System.Threading.Mutex]::new($false, "Global\PhotoScriptLogMutex")
    }

    if ($parallelEnabled) {
        $totalCount = $imageFiles.Count
        $range = if ($totalCount -gt 0) { 0..($totalCount - 1) } else { @() }

        # 必须先转为字符串，因为 ForEach-Object -Parallel 不支持直接传递 $using:ScriptBlock

        $processFunc = ${function:Process-Image}.ToString()

        $index = 0
        $range | ForEach-Object -Parallel {
            $index = $_
            $localConfig = $using:scriptConfig
            $localFiles = $using:imageFiles
            $file = $localFiles[$index]
            $total = $using:totalCount

            $progress = "$($index + 1)/$total"

            # 在子线程中重建脚本块
            Set-Item -Path function:Process-Image -Value ([ScriptBlock]::Create($using:processFunc))

            # 只做事，不输出
            Process-Image $file $localConfig
            # $sb = [ScriptBlock]::Create($using:sbStr)
            # & $sb $file $localConfig
        } -ThrottleLimit $MaxThreads |
        ForEach-Object {

            # 主 Runspace：顺序输出
            $index++

            # 计算耗时
            $elapsed = ((Get-Date) - $_.StartTime).TotalSeconds

            Write-CompressionStatus `
                -File $_.File `
                -SrcBytes $_.SrcBytes `
                -NewBytes $_.NewBytes `
                -Index $index `
                -Total $totalCount `
                -ElapsedSeconds $elapsed

            # 统计
            $script:imageSrcBytes += $_.SrcBytes
            if ($_.NewBytes -gt 0) {
                $script:imageNewBytes += $_.NewBytes
                $script:imageSuccessCount++
            } else {
                $script:imageFailedCount++
            }
        }

    }
    else {
        # 顺序执行: 直接调用函数
        $i = 1
        $totalCount = $imageFiles.Count
        $imageFiles | ForEach-Object {
            $result = Process-Image $_ $scriptConfig

            # 统计
            $imageSrcBytes += $result.SrcBytes
            if ($result.NewBytes -gt 0) {
                $imageNewBytes += $result.NewBytes
                $imageSuccessCount++
            } else {
                $imageFailedCount++
            }

            $i++
        }
    }
}

# ---------- 执行处理 (视频 / 顺序扫描) ----------
if ($videoFiles.Count -gt 0) {
    Write-Host ""
    Write-Host ">>> 开始处理视频 (顺序执行)..." -ForegroundColor Magenta

    # 视频统计
    $videoSuccessCount = 0
    $videoFailedCount = 0
    $videoSrcBytes = 0
    $videoNewBytes = 0

    $i = 1
    $totalVideos = $videoFiles.Count
    foreach ($file in $videoFiles) {
        $src = $file.FullName
        $rootPath = $InputRoot
        $rel = $src.Substring($InputRoot.Length).TrimStart('\')
        $dir = Split-Path $rel -Parent
        $name = $file.Name
        $oldSize = $file.Length
        $fileBaseName = [IO.Path]::GetFileNameWithoutExtension($name)
                
        $progress = "[$i/$totalVideos]"
                
        # 视频固定输出命名规则: name.h265.mp4
        $targetName = "$fileBaseName.h265.mp4"
        $finalOut = Join-Path $file.Directory.FullName $targetName
        $tempOut = "$finalOut.tmp" # 使用 name.h265.mp4.tmp
    
        # 路径构造
        $backupDir = $null
        $backup = $null

        if ($Mode -eq 0) {
            # 修正从 $config.Mode 变为 $Mode
            $backupDir = Join-Path $BackupRoot $dir
            $backup = Join-Path $backupDir $name
        }
        
        Write-Host "$progress 正在处理视频: [$rel]" -ForegroundColor Cyan
    
        try {
            if ($useGpu) {
                $cmdKey = $file.Extension.ToLower()+"_gpu"
            }else{
                $cmdKey = $file.Extension.ToLower()+"_cpu"
            }
            Write-Host "  命令键: $cmdKey" -ForegroundColor Green
            $tools = $commandMap[$cmdKey]
            if ($null -eq $tools -or $tools.Count -eq 0) {
                throw "错误: 配置中虽然存在键名 [$cmdKey]，但没有关联任何有效的工具命令。"
            }
            $tool = $tools[0]
            $finalArgs = $tool.ArgsArray | ForEach-Object { $_.Replace('$IN$', $src).Replace('$OUT$', $tempOut) }
            if ($ShowDetails) {
                $displayCmd = "$($tool.SafePath) $($finalArgs -join ' ')"
                Write-Host "CMD ($($tool.ToolName)): $displayCmd" -ForegroundColor Yellow
            }
            # 调用 FFmpeg

            
            & $tool.Path @finalArgs
                
            if ($LASTEXITCODE -ne 0) {
                throw "FFmpeg 转换失败 (ExitCode: $LASTEXITCODE)"
            }

            # 转换成功后重命名
            if (Test-Path $tempOut) {
                 Move-Item $tempOut $finalOut -Force
            }





            
            # # # 2. 转换 (FFmpeg)
            # $ffmpegArgs = @("-y", "-hide_banner", "-i", $src)
            # $ffmpegArgs += @("-c:v", $Codec)
                
            # if ($useGpu) {
            #     $ffmpegArgs += @("-cq", $CQ)
            #     $ffmpegArgs += @("-preset", "p4")
            # }
            # else {
            #     $ffmpegArgs += @("-crf", $CRF)
            #     $ffmpegArgs += @("-preset", "medium")
            # }

            # $ffmpegArgs += @("-c:a", "aac")
            # $ffmpegArgs += @("-movflags", "+faststart")
            # $ffmpegArgs += @("-pix_fmt", "yuv420p")

            # # 参数必须在输出文件名之前
            # if ($ShowDetails) {
            #     # 详细模式不加 loglevel warning
            # }
            # else {
            #     # 增加 -stats 以在 warning 级别下依然显示进度条
            #     $ffmpegArgs += @("-loglevel", "warning", "-stats")
                    
            #     # 如果是 libx265 且为静默模式，抑制其内部 info 输出
            #     if ($Codec -eq "libx265") {
            #         $ffmpegArgs += @("-x265-params", "log-level=error")
            #     }
            # }

            # # 增加 -f mp4 参数，因为输出文件以后缀 .tmp 结尾，ffmpeg 无法自动判断格式
            # $ffmpegArgs += @("-f", "mp4", $tempOut)
                
            # if ($ShowDetails) {
            #     $cmd = "$FFmpegExe $($ffmpegArgs -join ' ')"
            #     Write-Host "CMD: $cmd" -ForegroundColor Yellow
            # }
                
            # # Dry-Run 模式：仅输出命令
            # if ($Mode -eq 9) {
            #     Write-Host "[DRY-RUN] 处理视频: $rel" -ForegroundColor Cyan
            #     # ...
            #     continue
            # }
            # else {
            #     # 调用 FFmpeg
            #     & $FFmpegExe @ffmpegArgs
                
            #     if ($LASTEXITCODE -ne 0) {
            #         throw "FFmpeg 转换失败 (ExitCode: $LASTEXITCODE)"
            #     }

            #     # 转换成功后重命名
            #     if (Test-Path $tempOut) {
            #         Move-Item $tempOut $finalOut -Force
            #     }
            # }
            
            # 3. 显示压缩率
            $actualOldSize = if (Test-Path $src) { (Get-Item $src).Length } else { $oldSize }
            $newSize = (Get-Item $finalOut).Length

            Write-CompressionStatus -File $rel -SrcBytes $actualOldSize -NewBytes $newSize -Index $i -Total $totalVideos

            # 统计
            $videoSrcBytes += $actualOldSize
            $videoNewBytes += $newSize
            $videoSuccessCount++

            if ($Mode -eq 0) {
                # 修正变量名
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                Move-Item $src $backup -Force
                Write-Host "💾 移动源文件$src->$backup" -ForegroundColor Blue
            }

            $i++
        }
        catch {
            Write-Host "✖ 视频处理失败: $rel $($_.Exception.Message)" -ForegroundColor Red
            $videoFailedCount++
        }
        finally {
            # 强制清理临时文件
            if (Test-Path $tempOut) {
                Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
                Write-Host "[清理] 已移除临时文件: $tempOut" -ForegroundColor Gray
            }
        }
    }
}





Write-Host ""
Write-Host "✅ 全部完成" -ForegroundColor Yellow
Write-Host "====================== 处理完成统计 ======================" -ForegroundColor Yellow

if ($imageFiles.Count -gt 0) {
    $imageTotalCount = $imageSuccessCount + $imageFailedCount
    Write-Host "📸 图片处理: 成功 $imageSuccessCount 个, 失败 $imageFailedCount 个" -ForegroundColor Cyan
    if ($imageTotalCount -gt 0) {
        $imageSaved = $imageSrcBytes - $imageNewBytes
        $imageSavedStr = Format-Size $imageSaved
        Write-Host "   原大小: $(Format-Size $imageSrcBytes) → 转换后: $(Format-Size $imageNewBytes) | 节省: $imageSavedStr" -ForegroundColor Green
    }
}

if ($videoFiles.Count -gt 0) {
    $videoTotalCount = $videoSuccessCount + $videoFailedCount
    Write-Host "🎬 视频处理: 成功 $videoSuccessCount 个, 失败 $videoFailedCount 个" -ForegroundColor Cyan
    if ($videoTotalCount -gt 0) {
        $videoSaved = $videoSrcBytes - $videoNewBytes
        $videoSavedStr = Format-Size $videoSaved
        Write-Host "   原大小: $(Format-Size $videoSrcBytes) → 转换后: $(Format-Size $videoNewBytes) | 节省: $videoSavedStr" -ForegroundColor Green
    }
}

$totalSrcBytes = $imageSrcBytes + $videoSrcBytes
$totalNewBytes = $imageNewBytes + $videoNewBytes
if ($totalSrcBytes -gt 0) {
    $totalSaved = $totalSrcBytes - $totalNewBytes
    $totalSavedStr = Format-Size $totalSaved
    $totalPercent = [math]::Round(($totalNewBytes / $totalSrcBytes) * 100, 1)
    Write-Host "💾 总计节省: $totalSavedStr ($(Format-Size $totalSrcBytes) → $(Format-Size $totalNewBytes), $totalPercent%)" -ForegroundColor Green
}

# 计算运行时间
$endTime = Get-Date
$elapsed = ($endTime - $startTime).TotalMinutes
$elapsedStr = "{0:N2}" -f $elapsed

Write-Host "⏱️ 耗时: $elapsedStr 分钟" -ForegroundColor Yellow


