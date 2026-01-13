# -*- coding: utf-8 -*-
# config_parser.ps1 —— 用于解析 tools.json 并提供命令行填充接口

# --- 脚本作用域变量 ---
$script:ConfigJson = $null

# --- 1. 内部函数：加载配置 ---
function Load-ToolConfig {
    $ConfigName = "tools.json"
    
    # 获取脚本所在的真实物理路径
    $ScriptDir = $PSScriptRoot
    if (-not $ScriptDir) { 
        $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition 
    }

    $PossiblePaths = @(
        (Join-Path $ScriptDir $ConfigName),
        (Join-Path (Get-Location) $ConfigName)
    )

    $SelectedPath = $null
    foreach ($path in $PossiblePaths) {
        if (Test-Path -LiteralPath $path) {
            $SelectedPath = $path
            break
        }
    }

    if (-not $SelectedPath) {
        Write-Warning "未能在以下路径找到 $ConfigName : $($PossiblePaths -join ', ')"
        return $null
    }

    try {
        $RawContent = Get-Content -LiteralPath $SelectedPath -Raw -Encoding UTF8
        $script:ConfigJson = $RawContent | ConvertFrom-Json
        if (-not $script:ConfigJson.tools) {
            Write-Error "JSON 格式非法：缺少 'tools' 节点"
            return $null
        }
    } catch {
        Write-Error "解析 $ConfigName 失败: $($_.Exception.Message)"
        return $null
    }
    return $script:ConfigJson
}

# --- 2. 内部函数：解析工具路径 ---
function Resolve-ToolExe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExeName
    )

    # 尝试解析脚本目录
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { 
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

    # 检查 bin 目录
    $binDir = Join-Path $scriptDir "bin"
    $binExe = Join-Path $binDir $ExeName
    # 兼容没有扩展名的情况
    if ($ExeName -notmatch "\.exe$") { $binExe += ".exe" }

    $toolPath = $null

    # 1. 先找 bin 目录
    if (Test-Path -LiteralPath $binExe) {
        $toolPath = $binExe
    }
    # 2. 再找系统 PATH
    elseif ($cmd = Get-Command $ExeName -ErrorAction SilentlyContinue) {
        $toolPath = $cmd.Path
    }
    else {
        # 如果还是找不到，且输入本身看起来像完整路径，则直接返回
        if (Test-Path -LiteralPath $ExeName) { return $ExeName }
        Write-Warning "未找到可用的 $ExeName（不在 bin 目录或 PATH 中）"
        return $ExeName 
    }

    return $toolPath
}

# --- 3. 内部函数：生成命令字符串模板 ---
function Get-CommandTemplate {
    param(
        [array]$RawParams,
        [object]$TemplateParams
    )
    
    $FinalParts = @()
    foreach ($pair in $RawParams) {
        foreach ($item in $pair) {
            $val = $item.ToString()
            # 替换模板自定义变量 (如 $QUALITY$)
            if ($val.Contains('$') -and $TemplateParams) {
                foreach ($prop in $TemplateParams.PSObject.Properties) {
                    $key = "`$($prop.Name)`$"
                    if ($val.Contains($key)) {
                        $val = $val.Replace($key, $prop.Value.ToString())
                    }
                }
            }
            $FinalParts += $val
        }
    }
    # 返回空格分隔的参数字符串
    return $FinalParts -join " "
}

# --- 4. 接口函数：获取所有受支持的扩展名 ---
function Get-SupportedExtensions {
    if ($null -eq $script:ConfigJson) { if (-not (Load-ToolConfig)) { return @() } }
    $formats = @()
    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        $Tool = $script:ConfigJson.tools.$ToolName
        if ($Tool.format) { $formats += $Tool.format }
    }
    return $formats | Select-Object -Unique | Sort-Object
}

# --- 5. 核心接口：获取命令 Map (Key: ToolID -> Value: CmdObj) ---
function Get-CommandMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Format
    )

    if ($null -eq $script:ConfigJson) { if (-not (Load-ToolConfig)) { return @{} } }
    
    $CommandMap = @{}
    $FormatLower = $Format.Trim().ToLower()
    if (-not $FormatLower.StartsWith(".")) { $FormatLower = ".$FormatLower" }

    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        $Tool = $script:ConfigJson.tools.$ToolName
        $supportedFormats = $Tool.format | ForEach-Object { $_.Trim().ToLower() }
        
        if ($supportedFormats -contains $FormatLower) {
            # 路径解析逻辑：如果 path 为空或仅为文件名，则尝试 Resolve
            $RawPath = $Tool.path
            $ResolvedPath = $null

            if ([string]::IsNullOrWhiteSpace($RawPath)) {
                # 如果为空，默认使用工具节点的名称作为文件名查找
                $ResolvedPath = Resolve-ToolExe -ExeName $ToolName
            } elseif ($RawPath -notmatch "[\\/]") {
                # 如果只是文件名 (不含路径符)，尝试 Resolve
                $ResolvedPath = Resolve-ToolExe -ExeName $RawPath
            } else {
                # 已经是路径，直接使用
                $ResolvedPath = $RawPath
            }

            # 处理引号
            $SafePath = $ResolvedPath
            if (-not ($SafePath.StartsWith('"')) -and $SafePath.Contains(" ")) { 
                $SafePath = "`"$SafePath`"" 
            }

            if ($Tool.modes) {
                foreach ($mProp in $Tool.modes.PSObject.Properties) {
                    $modeKey = $mProp.Name
                    $mode = $mProp.Value
                    $tParams = if ($mode.template_parameters) { $mode.template_parameters } else { $Tool.template_parameters }
                    $FullCmdTemplate = "$SafePath $(Get-CommandTemplate -RawParams $mode.parameters -TemplateParams $tParams)"
                    
                    $Key = "$($ToolName)_$($modeKey)"
                    $CommandMap[$Key] = [pscustomobject]@{
                        ToolName    = $ToolName
                        Mode        = $modeKey
                        FullCommand = $FullCmdTemplate
                        Category    = $Tool.category
                        Path        = $ResolvedPath
                    }
                }
            } else {
                $FullCmdTemplate = "$SafePath $(Get-CommandTemplate -RawParams $Tool.parameters -TemplateParams $Tool.template_parameters)"
                $Key = "$($ToolName)_default"
                $CommandMap[$Key] = [pscustomobject]@{
                    ToolName    = $ToolName
                    Mode        = "default"
                    FullCommand = $FullCmdTemplate
                    Category    = $Tool.category
                    Path        = $ResolvedPath
                }
            }
        }
    }
    return $CommandMap
}

# --- 6. 测试块：自动遍历所有扩展名并输出 Map ---
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "`n======================================================================" -ForegroundColor Cyan
    Write-Host "  ⚙️  Map 数据完整导出模式 (支持自动路径解析)" -ForegroundColor White
    Write-Host "======================================================================" -ForegroundColor Cyan

    $allExts = Get-SupportedExtensions
    
    if ($allExts.Count -eq 0) {
        Write-Host "未发现任何支持的格式，请检查 tools.json。" -ForegroundColor Red
    } else {
        foreach ($ext in $allExts) {
            $map = Get-CommandMap -Format $ext
            Write-Host "`n[ 格式: $ext ] (可用工具: $($map.Count))" -ForegroundColor Yellow -Style Bold
            Write-Host "----------------------------------------------------" -ForegroundColor Gray

            foreach ($key in $map.Keys) {
                $cmdObj = $map[$key]
                Write-Host "  ID: " -NoNewline
                Write-Host $key -ForegroundColor Cyan
                Write-Host "  解析路径: " -NoNewline
                Write-Host $cmdObj.Path -ForegroundColor DarkCyan
                
                # 模拟并行替换
                $mockIn = "input$ext"
                $mockOut = "output.avif"
                if ($cmdObj.Category -eq "video") { $mockOut = "output.mp4" }
                
                $readyToRun = $cmdObj.FullCommand.Replace('$IN$', "`"$mockIn`"").Replace('$OUT$', "`"$mockOut`"")
                
                Write-Host "  模板: " -NoNewline
                Write-Host $cmdObj.FullCommand -ForegroundColor DarkGray
                Write-Host "  示例: " -NoNewline
                Write-Host $readyToRun -ForegroundColor Green
            }
        }
    }
    Write-Host "`n======================================================================" -ForegroundColor Cyan
}