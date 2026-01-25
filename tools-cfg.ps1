# -*- coding: utf-8 -*-
# config_parser.ps1 —— 用于解析 tool_config.json 并提供命令行填充接口

# --- 脚本作用域变量 ---
$script:ConfigJson = $null

enum MediaType {
    Image = 0
    Video = 1
    All = 2
}

. "$PSScriptRoot\helpers.ps1"

# --- 1. 内部函数：加载配置 ---
function Load-ToolConfig {
    $ConfigName = "tools.json"
    $ScriptDir = if ($PSScriptRoot) {
        $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $null
    }

    $PossiblePaths = @(
        (Join-Path $ScriptDir $ConfigName),
        (Join-Path (Get-Location) $ConfigName)
    )

    $SelectedPath = $null
    foreach ($path in $PossiblePaths) {
        if (Test-Path -LiteralPath $path) { $SelectedPath = $path; break }
    }

    if (-not $SelectedPath) { 
        Write-Error "Could not locate configuration file: $ConfigName" -ErrorAction Stop
    }

    try {
        $RawContent = Get-Content -LiteralPath $SelectedPath -Raw -Encoding UTF8
        $script:ConfigJson = $RawContent | ConvertFrom-Json
        Write-Host "✅ Configuration file loaded: $SelectedPath" -ForegroundColor Green
    } catch {
        Write-Error "Failed to parse JSON configuration: $($_.Exception.Message)" -ErrorAction Stop
    }
    return $true
}

# ---  交互逻辑：参数确认与修改 ---
function Invoke-ParameterInteraction {
    param(
        [Parameter(Mandatory = $false)]
        [MediaType]$Type = [MediaType]::All,
        [bool]$UseGpu = $true,
        [bool]$Silent = $false
    )

    # 加载配置检测
    if ($null -eq $script:ConfigJson) { if (-not (Load-ToolConfig)) { return @{} } }

    $typeFilter = $Type.ToString().ToLower()
    $ToolList = @() 

    # --- 1. 数据预处理：提取完整工具元数据 ---
    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        $Tool = $script:ConfigJson.tools.$ToolName
        if ($typeFilter -ne "all" -and $Tool.category -ne $typeFilter) { continue }
        
        # 预先处理指令数组：将 [["-q", "80"], ["$IN$"]] 转为 "-q 80 $IN$"
        $cmdPreview = ""
        if ($Tool.parameters) {
            $cmdPreview = ($Tool.parameters | ForEach-Object { $_ -join ' ' }) -join ' '
        }

        # 视频工具特殊模式处理 (GPU/CPU)
        if ($Tool.category -eq "video" -and $Tool.modes) {
            $targetMode = if ($UseGpu) { "gpu" } else { "cpu" }
            if ($Tool.modes.$targetMode) {
                $tParams = if ($Tool.modes.$targetMode.template_parameters) { $Tool.modes.$targetMode.template_parameters } else { $Tool.template_parameters }
                # 如果模式中有独立的指令定义则覆盖
                if ($Tool.modes.$targetMode.parameters) {
                    $cmdPreview = ($Tool.modes.$targetMode.parameters | ForEach-Object { $_ -join ' ' }) -join ' '
                }
                $ToolList += [pscustomobject]@{
                    Name     = $ToolName
                    Category = $Tool.category
                    Formats  = ($Tool.format -join ', ')
                    RawCmd   = $cmdPreview
                    Mode     = $targetMode
                    Params   = $tParams
                }
            }
        } else {
            $ToolList += [pscustomobject]@{
                Name     = $ToolName
                Category = $Tool.category
                Formats  = ($Tool.format -join ', ')
                RawCmd   = $cmdPreview
                Mode     = "default"
                Params   = $Tool.template_parameters
            }
        }
    }

    $FinalParamsMap = @{}

    # --- 逻辑 A: 静默模式 ---
    if ($Silent) {
        foreach ($item in $ToolList) {
            if (-not $FinalParamsMap.ContainsKey($item.Name)) { $FinalParamsMap[$item.Name] = @{} }
            $FinalParamsMap[$item.Name][$item.Mode] = Get-DefaultParams -Template $item.Params
        }
        return $FinalParamsMap
    }

    # --- 逻辑 B: 视觉增强预览区 ---
    Write-Host ""
    Write-Host " TOOLCHAIN PREVIEW" -ForegroundColor Cyan
    Write-Host " ─────────────────" -ForegroundColor DarkGray 

    foreach ($item in $ToolList) {
        $icon = if ($item.Category -eq "video") { "🎬" } else { "📸" }
        $modeSuffix = if ($item.Mode -ne "default") { " ($($item.Mode))" } else { "" }
        
        # 打印工具标题
        Write-Host " $icon [$($item.Name)$modeSuffix]" -ForegroundColor Yellow

        # 对齐输出详细信息
        Write-Host "$(Get-AlignedLabel "工具分类" 18)" -NoNewline -ForegroundColor Gray
        Write-Host $item.Category -ForegroundColor White

        if ($item.Formats) {
            Write-Host "$(Get-AlignedLabel "支持格式" 18)" -NoNewline -ForegroundColor Gray
            Write-Host $item.Formats -ForegroundColor White
        }

        # 模板变量
        $defaults = Get-DefaultParams -Template $item.Params
        if ($defaults.Count -gt 0) {
            Write-Host "$(Get-AlignedLabel "变量配置" 18)" -NoNewline -ForegroundColor Gray
            $pString = @()
            foreach ($k in $defaults.Keys) { $pString += "$k=$($defaults[$k])" }
            Write-Host ($pString -join " | ") -ForegroundColor Green
        }

        # 执行指令预览
        if ($item.RawCmd) {
            Write-Host "$(Get-AlignedLabel "执行指令" 18)" -NoNewline -ForegroundColor Gray
            Write-Host $item.RawCmd -ForegroundColor DarkCyan
        }
        Write-Host "" # 工具间距
    }

    Write-Host ("  " + ("─" * 52)) -ForegroundColor DarkGray
    
    # --- 询问逻辑 ---
    Write-Host "确认使用以上默认值请按 [任意键] 继续，如需修改参数请输入 [M]: " -NoNewline -ForegroundColor Cyan
    $userInput = Read-Host
    $doModify = ($userInput -match "^[mM]$")

    # --- 处理最终映射与交互修改 ---
    foreach ($item in $ToolList) {
        if (-not $FinalParamsMap.ContainsKey($item.Name)) { $FinalParamsMap[$item.Name] = @{} }
        
        $currentDefaults = Get-DefaultParams -Template $item.Params
        
        if ($doModify -and $currentDefaults.Count -gt 0) {
            $label = if ($item.Mode -eq "default") { $item.Name } else { "$($item.Name) ($($item.Mode))" }
            Write-Host "`n  ── 修改参数: [$label] ──" -ForegroundColor Yellow
            $modified = @{}
            foreach ($k in $currentDefaults.Keys) {
                Write-Host "  > $k (当前: $($currentDefaults[$k])): " -NoNewline -ForegroundColor Gray
                $userInput = Read-Host
                $modified[$k] = if ([string]::IsNullOrWhiteSpace($userInput)) { $currentDefaults[$k] } else { $userInput }
            }
            $FinalParamsMap[$item.Name][$item.Mode] = $modified
        } else {
            $FinalParamsMap[$item.Name][$item.Mode] = $currentDefaults
        }
    }

    return $FinalParamsMap
}

# 辅助函数：仅获取默认值，不进行交互
function Get-DefaultParams {
    param($Template)
    $res = @{}
    if ($null -eq $Template) { return $res }
    foreach ($prop in $Template.PSObject.Properties) {
        $res[$prop.Name] = $prop.Value.ToString()
    }
    return $res
}

# --- 4. 核心接口：获取分层有序命令 Map ---
function Get-CommandMap {
    param(
        [Parameter(Mandatory = $true)]
        [Hashtable]$UserParamsMap
    )

    if ($null -eq $script:ConfigJson) { if (-not (Load-ToolConfig)) { return @{} } }
    $MasterMap = @{}

    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        if (-not $UserParamsMap.ContainsKey($ToolName)) { continue }

        $Tool = $script:ConfigJson.tools.$ToolName
        $ExeNameForLookup = if ($Tool.path -and $Tool.path -ne "") { $Tool.path } else { $ToolName }
        $ResolvedPath = if ($ExeNameForLookup -notmatch "[\\/]") { Resolve-ToolExe -ExeName $ExeNameForLookup } else { $ExeNameForLookup }
        $SafePath = if ($ResolvedPath -and $ResolvedPath.Contains(" ") -and -not $ResolvedPath.StartsWith('"')) { "`"$ResolvedPath`"" } else { $ResolvedPath }
        $Priority = if ($null -ne $Tool.priority) { [int]$Tool.priority } else { 99 }
        $EnableParallel = if ($null -ne $Tool.enable_parallel) { [bool]$Tool.enable_parallel } else { $false }

        foreach ($ext in $Tool.format) {
            $extLower = $ext.ToLower().Trim()
            if (-not $extLower.StartsWith(".")) { $extLower = ".$extLower" }

            foreach ($modeName in $UserParamsMap[$ToolName].Keys) {
                $modeKey = if ($modeName -eq "default") { $extLower } else { "$extLower`_$modeName" }
                if (-not $MasterMap.ContainsKey($modeKey)) { $MasterMap[$modeKey] = New-Object System.Collections.Generic.List[PSObject] }

                $rawArgsDef = if ($Tool.modes) { $Tool.modes.$modeName.parameters } else { $Tool.parameters }
                $finalValues = $UserParamsMap[$ToolName][$modeName]

                $processedArgs = [System.Collections.Generic.List[string]]::new()
                foreach ($argLine in $rawArgsDef) {
                    foreach ($arg in $argLine) {
                        $val = $arg.ToString()
                        foreach ($pk in $finalValues.Keys) {
                            $placeholder = "`$$($pk.ToUpperInvariant())`$" 
                            $val = $val.Replace($placeholder, $finalValues[$pk])
                        }
                        $processedArgs.Add($val)
                    }
                }

                $MasterMap[$modeKey].Add([pscustomobject]@{
                    ToolName       = $ToolName
                    Mode           = $modeName
                    ArgsArray      = $processedArgs.ToArray()
                    Priority       = $Priority
                    Path           = $ResolvedPath
                    SafePath       = $SafePath
                    Category       = $Tool.category
                    EnableParallel = $EnableParallel
                })
            }
        }
    }

    $FinalMap = @{}
    foreach ($key in $MasterMap.Keys) {
        $FinalMap[$key] = $MasterMap[$key] | Sort-Object Priority | ForEach-Object { $_ }
    }
    return $FinalMap
}

# --- 5. 获取支持的扩展名 ---
function Get-SupportedExtensions {
    if ($null -eq $script:ConfigJson) { if (-not (Load-ToolConfig)) { return @{ image = @(); video = @() } } }
    $imageExts = [System.Collections.Generic.HashSet[string]]::new()
    $videoExts = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        $Tool = $script:ConfigJson.tools.$ToolName
        foreach ($ext in $Tool.format) {
            $fmt = $ext.ToLower().Trim(); if (-not $fmt.StartsWith(".")) { $fmt = ".$fmt" }
            if ($Tool.category -eq "video") { [void]$videoExts.Add($fmt) } else { [void]$imageExts.Add($fmt) }
        }
    }
    return @{ image = $imageExts | Sort-Object; video = $videoExts | Sort-Object }
}


function Get-VideoDuration {
    param (
        [string]$FFprobePath,
        [string]$SourceFile
    )
    $duration = 0
    if (Test-Path $FFprobePath) {
        try {
            # 获取时长字符串并去除可能的空白字符
            $output = & $FFprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SourceFile" 2>$null
            if ($output -and [double]::TryParse($output.Trim(), [ref]$duration)) {
                return $duration
            }
        } catch {
            # 探测失败，默认返回 0
        }
    }
    return $duration
}

# 将文件列表转换为任务对象
function Convert-FilesToTasks {
    param(
        [Parameter(Mandatory)]
        [array]$files,           # FileInfo 对象数组

        [Parameter(Mandatory)]
        [string]$InputRoot,

        [Parameter(Mandatory = $false)]
        [string]$BackupRoot = $null,

        [Parameter(Mandatory = $true)]
        [MediaType]$Type,        # 外部传入的 MediaType 枚举: Image, Video, All

        [Parameter(Mandatory = $false)]
        [bool]$UseGpu = $false,   # 明确指定是否使用 GPU

        [Parameter(Mandatory = $false)]
        [bool]$Silent = $false   # 新增参数：是否静默处理（不输出转换预览）
    )

    $tasks = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $files -or $files.Count -eq 0) { return @() }
    if ($null -eq $script:ConfigJson) {
        if (-not (Load-ToolConfig)) {
            Write-Host "`n[错误] 无法加载工具配置文件 (config.json)。" -ForegroundColor Red
            Write-Host "请检查文件是否存在或 JSON 格式是否正确。`n" -ForegroundColor Red
            return $null  # 终止当前函数并返回空，而不是直接关闭窗口
        }
    }
    
    $userParams = Invoke-ParameterInteraction -Type $Type -UseGpu $UseGpu -Silent $Silent
    $commandMap = Get-CommandMap -UserParamsMap $userParams
    if ($null -eq $commandMap -or $commandMap.Count -eq 0) {
        Write-Host "没有加载到可用的格式配置！" -ForegroundColor Red
        return @()
    } else {
        $keys = $commandMap.Keys -join ', '
        Write-Host "已经加载到可用的的格式配置: " -NoNewline -ForegroundColor Gray
        Write-Host "[$keys]" -ForegroundColor Green
    }


    $supported = Get-SupportedExtensions
    
    $spinner = New-ConsoleSpinner -Title "正在生成任务" -Total $files.Count -SamplingRate 100 
    foreach ($file in $files) {
        $src = $file.FullName
        & $spinner $src 
        $rel = $src.Substring($InputRoot.Length).TrimStart('\')
        $dir = Split-Path $rel -Parent
        $name = $file.Name
        $oldSize = $file.Length
        
        # Bug 修复 1: 获取真实的后缀名（带点的，如 .jpg）并转为小写
        $ext = $file.Extension.ToLower()
        $fileBaseName = [IO.Path]::GetFileNameWithoutExtension($name)

        # 1. 确定媒体类型
        $type = if ($supported.video -contains $ext) { 
            [MediaType]::Video 
        } elseif ($supported.image -contains $ext) { 
            [MediaType]::Image 
        } else { 
            continue # 如果后缀不在配置内，跳过
        }

        
        $targetName = switch ($type) {
            ([MediaType]::Image) { "$fileBaseName.avif" }
            ([MediaType]::Video) { "$fileBaseName.h265.mp4" }
            default { "$fileBaseName.avif" }
        }

        $targetOut = Join-Path $file.Directory.FullName $targetName
        $tempOut = "$targetOut.tmp"

        # 2. 备份路径处理
        $backupDir = $null
        $backup = $null
        if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) {
            $backupDir = Join-Path $BackupRoot $dir
            $backup = Join-Path $backupDir $name
        }

        # 3. 确定命令键 (CmdKey)
        $cmdKey = switch ($type) {
            ([MediaType]::Video) {
                # 确保 $useGpu 在当前作用域可用
                if ($UseGpu) { "$ext" + "_gpu" } else { "$ext" + "_cpu" }
            }
            ([MediaType]::Image) { $ext }
            default { $ext }
        }

        # 4. 构建任务所需的命令结构体数组
        $readyCmds = @()
        $taskEnableParallel = $false # 默认不开启
        $duration=0
        if ($commandMap.ContainsKey($cmdKey)) {
            $tools = $commandMap[$cmdKey]
            if ($tools.Count -gt 0) {
                $taskEnableParallel = $tools[0].EnableParallel
            }
            foreach ($tool in $tools) {
                $finalArgs = $tool.ArgsArray | ForEach-Object { 
                    $_.Replace('$IN$', $src).Replace('$OUT$', $tempOut) 
                }

                $readyCmds += [pscustomobject]@{
                    ToolName   = $tool.ToolName
                    Path       = $tool.Path
                    Args       = $finalArgs
                    DisplayCmd = "$($tool.SafePath) $($finalArgs -join ' ')"
                }
                if ($type -eq [MediaType]::Video -and $tool.ToolName -like "*ffmpeg*" ) {
                    $binDir = Split-Path $tool.Path -Parent
                    $ffprobePath = Join-Path $binDir ("ffprobe" + [IO.Path]::GetExtension($tool.Path))
                    if (Test-Path $ffprobePath) {
                        $duration = Get-VideoDuration -FFprobePath $ffprobePath -SourceFile $src
                        # Write-Host "Duration:$duration" -ForegroundColor Red
                    }
                }
            }
        }

        # 5. 生成任务对象
        $tasks.Add([pscustomobject]@{
            SourceFile   = $file
            Src          = $src
            RelativePath = $rel
            TargetOut    = $targetOut
            TempOut      = $tempOut
            BackupDir    = $backupDir
            BackupPath   = $backup
            OldSize      = $oldSize
            Cmds         = $readyCmds
            Type         = $type
            Duration       = $duration
            EnableParallel = $taskEnableParallel
        })
    }
    return $tasks
}
