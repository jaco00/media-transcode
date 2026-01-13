# -*- coding: utf-8 -*-
# config_parser.ps1 —— 用于解析 tool_config.json 并提供命令行填充接口

# --- 脚本作用域变量 ---
$script:ConfigJson = $null

# --- 1. 内部函数：加载配置 ---
function Load-ToolConfig {
    $ConfigName = "tools.json"
    $ScriptDir = $PSScriptRoot
    if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

    $PossiblePaths = @(
        (Join-Path $ScriptDir $ConfigName),
        (Join-Path (Get-Location) $ConfigName)
    )

    $SelectedPath = $null
    foreach ($path in $PossiblePaths) {
        if (Test-Path -LiteralPath $path) { $SelectedPath = $path; break }
    }

    if (-not $SelectedPath) { Write-Warning "未找到 $ConfigName"; return $null }

    try {
        $RawContent = Get-Content -LiteralPath $SelectedPath -Raw -Encoding UTF8
        $script:ConfigJson = $RawContent | ConvertFrom-Json
        return $script:ConfigJson
    } catch {
        Write-Error "解析 JSON 失败: $($_.Exception.Message)"
        return $null
    }
}

# --- 2. 解析工具路径 ---
function Resolve-ToolExe {
    param(
        [Parameter(Mandatory)]
        [string]$ExeName
    )

    if ($ExeName -notmatch "\.exe$") { $ExeName += ".exe" }


    # 使用 $PSScriptRoot 获取脚本目录（更可靠）
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) {
        # 备用方案：从当前脚本路径解析
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (-not $scriptDir) {
            $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
        }
        if (-not $scriptDir) {
            $scriptDir = (Get-Location).Path
        }
    }

    # bin 目录
    $binDir = Join-Path $scriptDir "bin"
    $binExe = Join-Path $binDir $ExeName

     
    $toolPath = $null

    # 先找 bin
    if (Test-Path -LiteralPath $binExe) {
        $toolPath = $binExe
        #Write-Host "[找到工具] bin 目录: $binExe" -ForegroundColor DarkGreen
    }
    # 再找 PATH
    elseif ($cmd = Get-Command $ExeName -ErrorAction SilentlyContinue) {
        $toolPath = $cmd.Path
        #Write-Host "[找到工具] PATH: $toolPath" -ForegroundColor DarkGreen
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


# --- 3. 交互逻辑：参数确认与修改 ---
function Invoke-ParameterInteraction {
    param(
        [ValidateSet("image", "video", "all")]
        [string]$Type = "all",
        [bool]$UseGpu = $true,
        [bool]$Silent = $false
    )

    if ($null -eq $script:ConfigJson) { if (-not (Load-ToolConfig)) { return @{} } }

    $ToolList = @() # 预扫描符合条件的工具
    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        $Tool = $script:ConfigJson.tools.$ToolName
        if ($Type -ne "all" -and $Tool.category -ne $Type) { continue }
        
        if ($Tool.category -eq "video" -and $Tool.modes) {
            $targetMode = if ($UseGpu) { "gpu" } else { "cpu" }
            if ($Tool.modes.$targetMode) {
                $tParams = if ($Tool.modes.$targetMode.template_parameters) { $Tool.modes.$targetMode.template_parameters } else { $Tool.template_parameters }
                $ToolList += [pscustomobject]@{ Name = $ToolName; Mode = $targetMode; Params = $tParams; Category = $Tool.category }
            }
        } else {
            $ToolList += [pscustomobject]@{ Name = $ToolName; Mode = "default"; Params = $Tool.template_parameters; Category = $Tool.category }
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

    # --- 逻辑 B: 非静默模式 (展示所有 -> 询问确认 -> 可选修改) ---
    Write-Host "`n===============================================" -ForegroundColor Gray
    Write-Host "   🚀 待执行工具及默认参数预览" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Gray

    foreach ($item in $ToolList) {
        $icon = if ($item.Category -eq "video") { "🎬" } else { "📸" }
        
        Write-Host " $icon [$($item.Name)]" -NoNewline -ForegroundColor Yellow
        if ($item.Mode -ne "default") {
            $modeColor = if ($item.Mode -eq "gpu") { "Green" } else { "Magenta" }
            Write-Host " ($($item.Mode))" -ForegroundColor $modeColor
        } else {
            Write-Host ""
        }

        $defaults = Get-DefaultParams -Template $item.Params
        if ($defaults.Count -eq 0) {
            Write-Host "    (无自定义参数)" -ForegroundColor Gray
        } else {
            foreach ($k in $defaults.Keys) {
                # 修复：PowerShell 中 "$k: " 会被误认为驱动器引用。使用 "${k}: " 明确范围。
                Write-Host "    - ${k}: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($defaults[$k])" -ForegroundColor Green
            }
        }
       
    }

    $needModify = Read-Host "确认使用以上默认值请按 [回车]，如需修改参数请输入 [y]"
    $doModify = ($needModify -match "^[yY]$")

    foreach ($item in $ToolList) {
        if (-not $FinalParamsMap.ContainsKey($item.Name)) { $FinalParamsMap[$item.Name] = @{} }
        
        $currentDefaults = Get-DefaultParams -Template $item.Params
        if ($doModify -and $currentDefaults.Count -gt 0) {
            $label = if ($item.Mode -eq "default") { $item.Name } else { "$($item.Name) ($($item.Mode))" }
            Write-Host "`n--- 正在修改 [$label] 的参数 ---" -ForegroundColor Cyan
            $modified = @{}
            foreach ($k in $currentDefaults.Keys) {
                $input = Read-Host "请输入 $k (当前: $($currentDefaults[$k]))"
                $modified[$k] = if ([string]::IsNullOrWhiteSpace($input)) { $currentDefaults[$k] } else { $input }
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
                    ToolName    = $ToolName
                    Mode        = $modeName
                    ArgsArray   = $processedArgs.ToArray()
                    Priority    = $Priority
                    Path        = $ResolvedPath
                    SafePath    = $SafePath
                    Category    = $Tool.category
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

# --- 6. 测试演示 ---
if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Load-ToolConfig)) { exit }

    $userParams = Invoke-ParameterInteraction -Type "all" -UseGpu $true -Silent $false
    $commandMap = Get-CommandMap -UserParamsMap $userParams
    
    $MockIn = "C:\Test\Input.png"
    $MockOut = "C:\Test\Output.avif"

    Write-Host "`n--- 命令预览 ---" -ForegroundColor Cyan
    foreach ($key in $commandMap.Keys) {
        Write-Host "格式组 [$key]:" -ForegroundColor Yellow
        foreach ($t in $commandMap[$key]) {
            $finalArgs = $t.ArgsArray | ForEach-Object { $_.Replace('$IN$', "`"$MockIn`"").Replace('$OUT$', "`"$MockOut`"") }
            Write-Host "  > [$($t.ToolName)] : $($t.SafePath) $($finalArgs -join ' ')" -ForegroundColor White
        }
    }
}