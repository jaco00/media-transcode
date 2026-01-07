# -*- coding: utf-8 -*-
# zip.ps1 —— AVIF 批量压缩（断电安全 · 幂等 · 并行/顺序处理）
# Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

param(
    [string]$SourcePath = "05.photo",      # 源目录
    [int]$Quality = 80,                 # AVIF 质量模式 (-q)。根据用户测试，数值越高，画质越清晰 (80 为高质量，范围 0-100)。
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
$imageExtensions = @(".jpg", ".jpeg", ".png", ".heic", ".heif")
$videoExtensions = @(".mp4", ".mov", ".wmv", ".avi", ".mkv")

function Resolve-ToolExe {
    param(
        [Parameter(Mandatory)]
        [string]$ExeName
    )

    # 尝试解析脚本目录
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not $scriptDir) {
        $scriptDir = (Get-Location).Path
    } 
    # bin 目录
    $binDir = Join-Path $scriptDir "bin"
    $binExe = Join-Path $binDir $ExeName
    

    $toolPath = $null

    # 先找 bin
    if (Test-Path -LiteralPath $binExe) {
        $toolPath = $binExe
    }
    # 再找 PATH
    elseif ($cmd = Get-Command $ExeName -ErrorAction SilentlyContinue) {
        $toolPath = $cmd.Path
    }
    else {
        throw "未找到可用的 $ExeName（bin 或 PATH）"
    }

    # 测试可执行性
    try {
        & "$toolPath" -version *> $null
        Write-Host "[命令测试] $toolPath 可执行 ✅" -ForegroundColor Green
        return $toolPath
    }
    catch {
        throw "$ExeName 找到路径 $toolPath，但无法运行"
    }
}

$FFmpegExe = Resolve-ToolExe "ffmpeg.exe"
$AvifEncExe = Resolve-ToolExe "avifenc.exe"
$NConvertExe = Resolve-ToolExe "nconvert.exe"


# 1. 源目录 (SourcePath)
if (-not $PSBoundParameters.ContainsKey('SourcePath')) {
    $InputSourcePath = Read-Host "请输入 源目录 (SourcePath) [默认: $SourcePath]"
    $SourcePath = if ([string]::IsNullOrWhiteSpace($InputSourcePath)) { $SourcePath } else { $InputSourcePath }
}

# 2. 模式选择 (提前到此处，以便根据模式决定后续询问内容)
Write-Host ""
Write-Host "====================== 模式选择 ======================" -ForegroundColor Yellow
Write-Host "请选择处理模式：" -ForegroundColor White
Write-Host "  [回车] 或 [0]: 正常模式 (备份 → 转换 → 删除源)" -ForegroundColor Cyan
Write-Host "  [1]: 比对模式 (备份 → 转换 → 保留源)" -ForegroundColor Cyan
Write-Host "  [2]: 清理模式 (源文件移动到备份目录 - 需转换文件已存在)" -ForegroundColor Magenta
Write-Host "  [9]: Dry-Run 模式 (仅显示将执行的操作，不实际执行)" -ForegroundColor Yellow
Write-Host "========================================================" -ForegroundColor Yellow
$Mode = $null
do {
    $response = Read-Host "输入模式 (0/1/2/9，默认回车=0)"
    if ([string]::IsNullOrEmpty($response) -or $response -ceq "0") { $Mode = 0 }
    elseif ($response -ceq "1") { $Mode = 1 }
    elseif ($response -ceq "2") { $Mode = 2 }
    elseif ($response -ceq "9") { $Mode = 9 }
    
    if ($Mode -ne $null) { break }
    else { Write-Host "输入无效，请重新输入 (0, 1, 2, 9)。" -ForegroundColor Red }
} while ($true)

# 3. 询问目录信息 (Mode 2 强制要求备份目录)
if ($Mode -eq 2) {
    # 清理模式：必须提供备份目录
    if (-not $PSBoundParameters.ContainsKey('BackupDirName')) {
        do {
            $InputBackupDir = Read-Host "请输入备份目录名称 (清理模式必填)"
            if ([string]::IsNullOrWhiteSpace($InputBackupDir)) {
                Write-Host "错误: 清理模式必须提供备份目录，否则无法移动源文件。" -ForegroundColor Red
            }
        } while ([string]::IsNullOrWhiteSpace($InputBackupDir))
        $BackupDirName = $InputBackupDir
    }
}
else {
    # 其他模式：备份目录可选
    if (-not $PSBoundParameters.ContainsKey('BackupDirName')) {
        $InputBackupDir = Read-Host "请输入备份目录名称 [默认: $BackupDirName]"
        $BackupDirName = if ([string]::IsNullOrWhiteSpace($InputBackupDir)) { $BackupDirName } else { $InputBackupDir }
    }
}

# 扫描子目录
$InputInclude = Read-Host "请输入扫描子目录 (逗号分隔，如 2023,2024；留空则全扫) [默认: 全部扫描]"
$IncludeDirs = if ([string]::IsNullOrWhiteSpace($InputInclude)) { @() } else { $InputInclude.Split(',').Trim() }

# 处理类型选择 (清理模式也需要知道处理图片还是视频)
$InputProcessType = Read-Host "请选择处理类型 [0] 仅图片(默认) [1] 仅视频 [2] 所有"
if ([string]::IsNullOrWhiteSpace($InputProcessType)) { $ProcessType = 0 }
elseif ($InputProcessType -match '^[012]$') { $ProcessType = [int]$InputProcessType }
else { $ProcessType = 0 }

# 4. 询问压制参数 (仅当不是清理模式时)
if ($Mode -ne 2) {
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
    
    $UseDefaultQuality = Read-Host "是否使用默认质量设置 (HEIC: $HeicQuality, AVIF: $Quality, $videoQualityLabel = $defaultVideoQuality) ? (Y/N) [默认: Y]"
    if ($UseDefaultQuality -match '^[Nn]') {
        $InputHeicQuality = Read-Host "请输入 HEIC 转换质量 (HeicQuality) [默认: $HeicQuality]"
        $HeicQuality = if ([string]::IsNullOrWhiteSpace($InputHeicQuality)) { $HeicQuality } else { [int]$InputHeicQuality }

        $InputQuality = Read-Host "请输入 AVIF 质量 (0-100) [默认: $Quality]"
        $Quality = if ([string]::IsNullOrWhiteSpace($InputQuality)) { $Quality } else { [int]$InputQuality }
        
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


if ([string]::IsNullOrWhiteSpace($BackupDirName)) {
    $BackupRoot = $null
    $BackupEnabled = $false
}
else {
    if ([System.IO.Path]::IsPathRooted($BackupDirName)) {
        $BackupRoot = [System.IO.Path]::GetFullPath($BackupDirName)
    }
    else {
        $BackupRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $BackupDirName))
    }
    $BackupEnabled = Test-Path $BackupRoot
}

# 共存模式 (Mode 1) 不需要备份
if ($Mode -eq 1) {
    $BackupEnabled = $false
}

# 打印过滤信息
if ($IncludeDirs.Count -gt 0) {
    Write-Host "子目录过滤器已启用: $($IncludeDirs -join ', ')" -ForegroundColor Yellow
}
else {
    Write-Host "子目录过滤器已禁用: 扫描所有子目录" -ForegroundColor Yellow
}

# 检查 PowerShell 版本是否支持并行
$parallelEnabled = ($PSVersionTable.PSVersion.Major -ge 7) -and ($MaxThreads -gt 1)


# ---------- 准备目录 ----------
# 检查备份目录是否存在
if ([string]::IsNullOrWhiteSpace($BackupDirName)) {
    # 未指定备份，静默跳过
}
elseif (!$BackupEnabled) {
    Write-Host "警告: 备份目录 [$BackupDirName] 不存在，将跳过备份步骤并仅保留源文件。" -ForegroundColor Yellow
}


# ---------- 扫描文件 ----------

$files = @()      # 图片列表
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

    # B. 被标记手动跳过的 (符合当前 ProcessType 范围才统计)
    if ($isExplicitSkip) {
        if (($ProcessType -in 0, 2 -and $isImage) -or ($ProcessType -in 1, 2 -and $isVideo)) {
            $skipCount++
        }
        continue
    }

    # C. 正常分类到待处理列表
    if ($ProcessType -in 0, 2 -and $isImage) {
        $files += $file
    }
    elseif ($ProcessType -in 1, 2 -and $isVideo) {
        $videoFiles += $file
    }
}

Write-Host ""
Write-Host "====================== 扫描统计 ======================" -ForegroundColor Yellow
Write-Host " 📸 待处理图片: $($files.Count)" -ForegroundColor Green
Write-Host " 🎬 待处理视频: $($videoFiles.Count)" -ForegroundColor Green
Write-Host " ⏩ 手动已跳过: $skipCount" -ForegroundColor Gray
Write-Host "======================================================" -ForegroundColor Yellow

if ($files.Count -eq 0 -and $videoFiles.Count -eq 0) {
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
    $displayDirs = $files | ForEach-Object {
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



# 此处逻辑已移至脚本开头。保留变量声明以防后续引用报错。
$modeText = switch ($Mode) {
    0 { "正常模式 (Mode 0): 备份 → 转换 → 删除源" }
    1 { "共存模式 (Mode 1): 转换 → 保留源 (跳过备份)" }
    2 { "清理模式 (Mode 2): 归档到备份目录" }
    9 { "Dry-Run 模式 (Mode 9): 仅显示操作" }
}
Write-Host "选择模式: $modeText" -ForegroundColor Magenta

Write-Host "====================== 当前配置摘要 ======================" -ForegroundColor Yellow
Write-Host " 源目录: $InputRoot" -ForegroundColor Green
if ($BackupEnabled) {
    Write-Host " 备份目录: $BackupRoot" -ForegroundColor Green
}
else {
    Write-Host " 备份目录: $BackupDirName (目录不存在 - 将跳过备份)" -ForegroundColor Red
}
Write-Host " 扫描子目录: $($IncludeDirs -join ', ')" -ForegroundColor Green
Write-Host " 最大线程: $MaxThreads" -ForegroundColor Green
Write-Host " HEIC质量: $HeicQuality" -ForegroundColor Green
Write-Host " AVIF质量: $Quality" -ForegroundColor Green
if ($useGpu) {
    Write-Host " 视频转码: $Codec (CQ: $CQ)" -ForegroundColor Green
}
else {
    Write-Host " 视频转码: $Codec (CRF: $CRF)" -ForegroundColor Green
}
Write-Host " 详细输出/静默: $(if ($ShowDetails) {'详细输出 (非静默)'} else {'静默模式'})" -ForegroundColor Green

if ($parallelEnabled -and ($Mode -ne 2)) {
    # 提示用户多线程处于活动状态
    Write-Host "处理模式: 并行 ($MaxThreads 线程，父进程 PID: $pid)。AVIFjobs: $AVIFJobs" -ForegroundColor Cyan
}
elseif ($Mode -ne 2) {
    
    Write-Host "处理模式: 顺序 (PS 版本: $psMajor, MaxThreads: $MaxThreads)。AVIFjobs: $AVIFJobs。$quietStatus" -ForegroundColor Cyan
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
        $confirm = $true
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


# --- Mode 2 清理逻辑 (移至归档目录) ---
if ($Mode -eq 2) {
    Write-Host ""
    Write-Host "====================== Mode 2: 归档源文件到备份 ======================" -ForegroundColor Yellow
    Write-Host "将检查文件是否已转换，若存在则将源文件移动到备份目录..." -ForegroundColor Cyan

    $cleanupCount = 0
    $allFilesToClean = $files + $videoFiles
    
    foreach ($file in $allFilesToClean) {
        $src = $file.FullName
        $rel = $src.Substring($InputRoot.Length + 1)
        $dir = Split-Path $rel -Parent
        $name = $file.Name
        $ext = $file.Extension.ToLower()
        
        # 寻找对应的转换后文件
        $targetOut = $null
        if ($ext -in $imageExtensions) {
            $targetOut = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($name) + ".avif")
        }
        elseif ($ext -in $videoExtensions) {
            $targetOut = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($name) + ".h265.mp4")
        }

        # 归档路径
        $archiveDir = Join-Path $BackupRoot $dir
        $archivePath = Join-Path $archiveDir $name

        # 检查转换后的文件是否存在且有效
        $targetExists = $false
        if ($targetOut -and (Test-Path $targetOut -PathType Leaf)) {
            if ((Get-Item $targetOut).Length -gt 0) {
                $targetExists = $true
            }
        }

        if ($targetExists) {
            # 执行移动
            if (!(Test-Path $archiveDir)) { 
                New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null 
            }
            
            try {
                Move-Item $src $archivePath -Force -ErrorAction Stop
                $cleanupCount++
                Write-Host "📦 已归档源文件: $rel -> $archivePath" -ForegroundColor Green
            }
            catch {
                Write-Host "✖ 归档失败: $rel ($($_.Exception.Message))" -ForegroundColor Red
            }
        }
        else {
            Write-Host "⏩ 跳过归档: $rel (未找到转换后的版本或版本无效)" -ForegroundColor DarkGray
        }
    }
    
    Write-Host ""
    Write-Host "====================== 归档完成 ======================" -ForegroundColor Yellow
    Write-Host "总共归档了 $cleanupCount 个源文件。工具运行结束。" -ForegroundColor Cyan
    exit 0
}


$processImageBlock = {
    param($file, $config, $progress)
        
    if ($null -eq $file) { return } # 安全检查
    
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
    if ($config.BackupEnabled) {
        $backupDir = Join-Path $config.BackupRoot $dir
        $backup = Join-Path $backupDir $name
    }

    $avifOut = Join-Path $file.Directory.FullName ([IO.Path]::GetFileNameWithoutExtension($name) + ".avif")
    # 用户要求直接输出为 avif，不再使用 .tmp 后缀，避免工具识别问题
    
    try {
        # Dry-Run 模式：仅输出命令
        if ($config.Mode -eq 9) {
            Write-Host "[$progress] [DRY-RUN] $runspaceId 处理: $rel" -ForegroundColor Cyan
            if ($config.BackupEnabled) {
                Write-Host "  → 备份: $backup" -ForegroundColor Gray
            }
            else {
                Write-Host "  → 跳过备份 (备份目录不存在)" -ForegroundColor Gray
            }
            
            $isHEIF = $file.Extension -in @(".heic", ".heif")
            if ($isHEIF) {
                Write-Host "  → 命令: $($config.NConvertExe) -out avif -q $($config.HeicQuality) -keep_icc $src" -ForegroundColor White
            }
            else {
                Write-Host "  → 命令: $($config:AvifEncExe) -q $($config.Quality) $src $avifOut" -ForegroundColor White
            }
            
            Write-Host "  → 行为: 备份转换并删除源文件" -ForegroundColor Gray
            return
        }

        # 0. 输出进度
        Write-Host "[$progress] 正在处理: $rel (Runspace ID: $runspaceId)" -ForegroundColor DarkGray


        # 1. 备份 (仅当备份功能启用时)
        if ($config.BackupEnabled) {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Copy-Item $src $backup -Force
        }

        # 2. 转换
        $isHEIF = $file.Extension -in @(".heic", ".heif")
        
        if ($isHEIF) {
            # ── HEIC/HEIF (NConvert) ──
            
            # 构造 nconvert 参数
            $nconvertArgs = @("-out", "avif")
            $nconvertArgs += @("-q", $config.HeicQuality)
            $nconvertArgs += "-keep_icc"
            $nconvertArgs += "-overwrite"
            
            if ($config.ShowDetails) {
                $nconvertArgs += "-info"
            }
            else {
                $nconvertArgs += "-quiet"
            }
            
            # 输出文件 (直接写 avif)
            $nconvertArgs += @("-o", $avifOut)
            
            # 输入文件
            $nconvertArgs += $src

            # 构造参数字符串用于诊断
            $nconvertArgStr = "$($nconvertArgs -join ' ')"

            if ($config.ShowDetails) {
                Write-Host "CMD: $config.NConvertExe $nconvertArgStr" -ForegroundColor Yellow
                &   $using:NConvertExe @nconvertArgs
            }
            else {
                # 并发修复：直接重定向到 $null，避免 Out-Null 的内存泄漏
                $null = & $using:NConvertExe @nconvertArgs 2>&1
            }
            
            if ($LASTEXITCODE -ne 0) { 
                throw "NConvert 转换失败 (HEIF, ExitCode: $LASTEXITCODE)`n命令: $NConvertExe $nconvertArgStr" 
            }
            
        }
        else {
            # 转换普通文件 (jpg, png)，使用 Avifenc
            $avifArgs = @()
            if ($config.encoderOptions) { $avifArgs += $config.encoderOptions }
            $avifArgs += @("-q", $config.Quality, $src, $avifOut)

            # 构造参数字符串用于诊断
            $avifArgStr = "$($avifArgs -join ' ')"

            if ($config.ShowDetails) {
                Write-Host "CMD: $($config.AvifEncExe) $avifArgStr" -ForegroundColor DarkYellow
                & $config.AvifEncExe @avifArgs
            }
            else {
                # 并发修复：直接重定向到 $null，避免 Out-Null 的内存泄漏
                $null = & $config.AvifEncExe @avifArgs 2>&1
            }

            if ($LASTEXITCODE -ne 0) { 
                throw "avifenc 编码失败 (退出码: $LASTEXITCODE)`n尝试执行: $AvifEncExe $avifArgStr" 
            }
        }

        # 3. 显示压缩率 (在删除前重新获取源文件大小，避免并发时 $file.Length 不准确)
        # 重新获取源文件大小，因为并发时 $file.Length 可能不准确
        $actualOldSize = if (Test-Path $src) { (Get-Item $src).Length } else { $oldSize }
        $newSize = (Get-Item $avifOut).Length
        
        if ($actualOldSize -gt 0) {
            $ratio = [Math]::Round((1 - [double]$newSize / [double]$actualOldSize) * 100, 1)
            $oldSizeKB = [Math]::Round($actualOldSize / 1KB, 1)
            $newSizeKB = [Math]::Round($newSize / 1KB, 1)
            Write-Host "✔ $progress $rel  源: ${oldSizeKB}KB → 新: ${newSizeKB}KB  节省 $ratio%" -ForegroundColor Green
        }
        else {
            Write-Host "✔ $progress $rel  已转换" -ForegroundColor Green
        }

        # 4. 删除源文件 (Mode 0: 删除, Mode 1: 保留)
        if ($config.Mode -eq 0) {
            Remove-Item $src -Force
        }
        elseif ($config.Mode -eq 1) {
            Write-Host "💾 $progress $rel  已保留源文件 (共存模式 - 跳过备份)" -ForegroundColor Blue
        }
    }
    catch {
        # 清理失败 (如果存在部分写入的文件)
        if (Test-Path $avifOut) { Remove-Item $avifOut -Force -ErrorAction SilentlyContinue }
        # 在并行模式下，使用 Write-Host 配合颜色提示失败
        Write-Host "✖ 处理失败: $rel $($_.Exception.Message)" -ForegroundColor Red
    }
}


# ---------- 执行处理 (统一入口) ----------
if ($Mode -ne 2 -and $files.Count -gt 0) {
    
    # 构造配置对象 (用于传递给并行/顺序脚本块)
    $scriptConfig = @{
        InputRoot      = $InputRoot
        BackupRoot     = $BackupRoot

        nconvertDir    = $nconvertDir
        avifenc        = $avifenc
        avifencDir     = $avifencDir
        HeicQuality    = $HeicQuality
        ShowDetails    = $ShowDetails
        encoderOptions = $encoderOptions

        Quality        = $Quality
        Mode           = $Mode
        BackupEnabled  = ($BackupEnabled -and ($Mode -ne 1)) # Disable backup if Mode is 1

        AvifEncExe     = $AvifEncExe
        NConvertExe    = $NConvertExe
    }

    if ($parallelEnabled) {
        $totalCount = $files.Count
        $range = if ($totalCount -gt 0) { 0..($totalCount - 1) } else { @() }
        
        # 必须先转为字符串，因为 ForEach-Object -Parallel 不支持直接传递 $using:ScriptBlock
        $sbStr = $processImageBlock.ToString()

        $range | ForEach-Object -Parallel {
            $index = $_
            $localConfig = $using:scriptConfig
            $localFiles = $using:files
            $file = $localFiles[$index]
            $total = $using:totalCount
            
            $progress = "$($index + 1)/$total"
            
            # 在子线程中重建脚本块
            $sb = [ScriptBlock]::Create($using:sbStr)
            & $sb $file $localConfig $progress
        } -ThrottleLimit $MaxThreads
    }
    else {
        # 顺序执行: 直接调用脚本块
        $i = 1
        $totalCount = $files.Count
        $files | ForEach-Object {
            $progress = "$i/$totalCount"
            & $processImageBlock $_ $scriptConfig $progress
            $i++
        }
    }
}

# ---------- 执行处理 (视频 / 顺序扫描) ----------
if ($Mode -ne 2 -and $videoFiles.Count -gt 0) {
    Write-Host ""
    Write-Host ">>> 开始处理视频 (顺序执行)..." -ForegroundColor Magenta
    
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
                
        # 再次检查目标是否存在 (避免扫描时的竞态或误判)
        # 用户要求强制覆盖，故移除跳过逻辑
        # if (Test-Path $finalOut) {
        #    Write-Host "跳过已存在: $targetName" -ForegroundColor DarkGray
        #    continue
        # }
    
        # 路径构造 (仅当备份启用时使用 $BackupRoot)
        $backupDir = $null
        $backup = $null
        if ($BackupEnabled -and ($Mode -ne 1)) {
            # Disable backup if Mode is 1
            $backupDir = Join-Path $BackupRoot $dir
            $backup = Join-Path $backupDir $name
        }
        
        Write-Host "$progress 正在处理视频: [$rel]" -ForegroundColor Cyan
    
        try {
               

            # 1. 备份 (仅当备份功能启用时)
            if ($BackupEnabled -and ($Mode -ne 1)) {
                # Disable backup if Mode is 1
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                Copy-Item $src $backup -Force
            }
    
            # 2. 转换 (FFmpeg)
            $ffmpegArgs = @("-hide_banner", "-i", $src)
            $ffmpegArgs += @("-c:v", $Codec)
                
            if ($useGpu) {
                $ffmpegArgs += @("-cq", $CQ)
                $ffmpegArgs += @("-preset", "p4")
            }
            else {
                $ffmpegArgs += @("-crf", $CRF)
                $ffmpegArgs += @("-preset", "medium")
            }

            $ffmpegArgs += @("-c:a", "aac")
            $ffmpegArgs += @("-movflags", "+faststart")
            $ffmpegArgs += @("-pix_fmt", "yuv420p")

            # 参数必须在输出文件名之前
            if ($ShowDetails) {
                # 详细模式不加 loglevel warning
            }
            else {
                # 增加 -stats 以在 warning 级别下依然显示进度条
                $ffmpegArgs += @("-loglevel", "warning", "-stats")
                    
                # 如果是 libx265 且为静默模式，抑制其内部 info 输出
                if ($Codec -eq "libx265") {
                    $ffmpegArgs += @("-x265-params", "log-level=error")
                }
            }

            $ffmpegArgs += $finalOut
            $ffmpegArgs += "-y"
                
            if ($ShowDetails) {
                $cmd = "$FFmpegExe $($ffmpegArgs -join ' ')"
                Write-Host "CMD: $cmd" -ForegroundColor Yellow
            }
                
            # Dry-Run 模式：仅输出命令
            if ($Mode -eq 9) {
                Write-Host "[DRY-RUN] 处理视频: $rel" -ForegroundColor Cyan
                if ($BackupEnabled -and ($Mode -ne 1)) {
                    # Disable backup if Mode is 1
                    Write-Host "  → 备份: $backup" -ForegroundColor Gray
                }
                Write-Host "  → 命令: $FFmpegExe $($ffmpegArgs -join ' ')" -ForegroundColor White
                continue
            }
            else {
                # 使用 & 符号调用命令，配合数组传参，能最稳健地处理空格
                & $FFmpegExe @ffmpegArgs
                
                if ($LASTEXITCODE -ne 0) {
                    throw "FFmpeg 转换失败 (ExitCode: $LASTEXITCODE)"
                }

            }
            
            # 3. 显示压缩率 (重新获取源文件大小以确保准确)
            $actualOldSize = if (Test-Path $src) { (Get-Item $src).Length } else { $oldSize }
            $newSize = (Get-Item $finalOut).Length
            if ($actualOldSize -gt 0) {
                $ratio = [Math]::Round((1 - [double]$newSize / [double]$actualOldSize) * 100, 1)
                $oldSizeMB = [Math]::Round($actualOldSize / 1MB, 2)
                $newSizeMB = [Math]::Round($newSize / 1MB, 2)
                Write-Host "✔ $progress $rel  源: ${oldSizeMB}MB → 新: ${newSizeMB}MB  节省 $ratio%" -ForegroundColor Green
            }

            # 4. 删除/保留源文件
            if ($Mode -eq 0) {
                Remove-Item $src -Force
            }
            elseif ($Mode -eq 1) {
                Write-Host "💾 $progress $rel  已保留源文件 (共存模式 - 跳过备份)" -ForegroundColor Blue
            }
            else {
                Write-Host "✔ $progress $rel  已转换 (无备份)" -ForegroundColor Green
            }
                
            $i++
        }
        catch {
            # 清理失败
            if (Test-Path $finalOut) { Remove-Item $finalOut -Force -ErrorAction SilentlyContinue }
            Write-Host "✖ 视频处理失败: $rel $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}



Write-Host "全部完成 ✅ 可随时中断 / 重跑" -ForegroundColor Yellow
