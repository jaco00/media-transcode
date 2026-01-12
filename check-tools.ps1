# -*- coding: utf-8 -*-
# config_parser.ps1 —— 用于解析 tool_config.json 并提供命令行接口函数

# --- Script Scoped Variables ---
# 用于在脚本会话中缓存配置
$script:ConfigJson = $null
$script:FormatToToolsMap = $null  # 缓存扩展名到命令的映射

# --- 1. 内部函数：加载配置 ---
function Load-ToolConfig {
    # 假设 tool_config.json 位于脚本的同级目录
    $ConfigPath = Join-Path $PSScriptRoot "tools.json"

    if (-not (Test-Path $ConfigPath)) {
        Write-Error "错误：未找到配置文件 $ConfigPath"
        exit 1
    }

    try {
        # 使用 Out-String 确保整个文件作为一个字符串被解析，避免多行问题
        $script:ConfigJson = Get-Content $ConfigPath | Out-String | ConvertFrom-Json
    } catch {
        Write-Error "错误：无法解析 tool_config.json 文件。请检查 JSON 格式是否正确。"
        Write-Error "原始错误: $($_.Exception.Message)"
        exit 1
    }
    
    # 返回配置对象，方便调用
    return $script:ConfigJson
}

# --- 2. 接口函数：获取支持的扩展名 ---
function Get-SupportedExtensions {
    param(
        [string]$Filter = "ImageAll" # 过滤模式: "Video", "ImageAll", "All"
    )
    
    # 确保配置已加载
    if (-not $script:ConfigJson) {
        Load-ToolConfig | Out-Null
    }

    $SupportedFormats = @()
    # 遍历所有工具
    foreach ($ToolName in $script:ConfigJson.tools.PSObject.Properties.Name) {
        $Tool = $script:ConfigJson.tools.$ToolName
        
        # 检查是否匹配过滤器
        $IsImage = ($Tool.category -eq "image")
        $IsVideo = ($Tool.category -eq "video")
        
        $Match = $false
        switch ($Filter.ToLower()) {
            "all" { $Match = $true }
            "imageall" { if ($IsImage) { $Match = $true } }
            "video" { if ($IsVideo) { $Match = $true } }
            default { Write-Warning "不支持的过滤器: $Filter。返回所有格式。" ; $Match = $true }
        }

        if ($Match -and $Tool.format) {
            $SupportedFormats += $Tool.format
        }
    }
    
    # 筛选出唯一的格式并排序
    return $SupportedFormats | Select-Object -Unique | Sort-Object
}

# --- 3. 接口函数：构建扩展名到命令的映射（缓存以提高效率）---
function Get-FormatToToolsMap {
    # 如果已缓存，直接返回
    if ($script:FormatToToolsMap) {
        return $script:FormatToToolsMap
    }

    # 确保配置已加载
    if (-not $script:ConfigJson) {
        Load-ToolConfig | Out-Null
    }

    # 创建映射表
    $map = @{}
    $Config = $script:ConfigJson

    # 遍历所有工具
    foreach ($ToolName in $Config.tools.PSObject.Properties.Name) {
        $Tool = $Config.tools.$ToolName

        # 确保 format 字段存在
        if ($Tool.format -is [array]) {
            # 为每个支持的扩展名创建条目
            foreach ($Format in $Tool.format) {
                $FormatLower = $Format.ToLower()

                # 如果映射中还没有这个扩展名，初始化数组
                if (-not $map.ContainsKey($FormatLower)) {
                    $map[$FormatLower] = @()
                }

                # 构造命令信息对象
                $TemplateInfo = [pscustomobject]@{
                    ToolName = $ToolName
                    Priority = $Tool.priority
                    Template = $Tool.template
                    GpuTemplate = $Tool.gpu_template
                    CpuTemplate = $Tool.cpu_template
                    # Magick ICC 路径
                    P3_ICC_PATH = if ($ToolName -eq 'magick') { $Config.P3_ICC_PATH } else { $null }
                    SRGB_ICC_PATH = if ($ToolName -eq 'magick') { $Config.SRGB_ICC_PATH } else { $null }
                }

                # 添加到映射数组
                $map[$FormatLower] += $TemplateInfo
            }
        }
    }

    # 对每个扩展名的工具按优先级排序
    foreach ($key in $map.Keys) {
        $map[$key] = $map[$key] | Sort-Object -Property Priority
    }

    # 缓存结果
    $script:FormatToToolsMap = $map
    return $map
}

# --- 4. 接口函数：获取特定格式的所有命令行（优化版，使用映射）---
function Get-CommandLines {
    param(
        [string]$Format # 文件扩展名 (例如 ".jpg", ".mp4")
    )

    if (-not $Format) {
        Write-Error "错误：必须提供文件扩展名。"
        return @()
    }

    # 强制扩展名小写
    $Format = $Format.ToLower()

    # 获取映射表
    $map = Get-FormatToToolsMap

    # 直接从映射中返回结果
    if ($map.ContainsKey($Format)) {
        return $map[$Format]
    }

    # 未找到支持的格式
    return @()
}


# --- 4. 测试和结构化输出 (仅当脚本直接运行时执行) ---
# 使用 $PSScriptRoot 确保只有在脚本作为文件运行时才执行此块
if ($PSScriptRoot) {
    # 尝试加载配置并开始输出
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host " ⚙️  配置解析测试输出 (用于验证函数接口)" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    
    try {
        Load-ToolConfig | Out-Null
    } catch {
        # 错误已在 Load-ToolConfig 中处理
        exit 1
    }

    Write-Host "--- 1. 支持的图像扩展名 (Get-SupportedExtensions 'ImageAll') ---" -ForegroundColor Yellow
    $ImageExts = Get-SupportedExtensions -Filter "ImageAll"
    Write-Host ($ImageExts -join ', ') -ForegroundColor Green
    
    Write-Host "`n--- 2. 支持的视频扩展名 (Get-SupportedExtensions 'Video') ---" -ForegroundColor Yellow
    $VideoExts = Get-SupportedExtensions -Filter "Video"
    Write-Host ($VideoExts -join ', ') -ForegroundColor Green
    
    Write-Host "`n--- 3. 详细命令行模板输出 ---" -ForegroundColor Yellow
    
    # 合并所有扩展名进行遍历
    $AllExts = $ImageExts + $VideoExts | Select-Object -Unique | Sort-Object

    foreach ($Ext in $AllExts) {
        Write-Host "`n---------------------------------------------" -ForegroundColor DarkGray
        Write-Host "📁 文件格式: $Ext" -ForegroundColor Yellow
        Write-Host "---------------------------------------------" -ForegroundColor DarkGray
        
        $CmdLines = Get-CommandLines -Format $Ext
        
        if ($CmdLines.Count -eq 0) {
            Write-Host "  未找到命令行模板。" -ForegroundColor Red
            continue
        }
        
        foreach ($Cmd in $CmdLines) {
            $PrioDisplay = if ($Cmd.Priority -eq 99) { "低 (99)" } else { $Cmd.Priority }

            Write-Host "  > 工具: $($Cmd.ToolName) (优先级: $PrioDisplay)" -ForegroundColor Green
            
            # 模板输出
            if ($Cmd.Template) {
                Write-Host "    [标准模板]: $($Cmd.Template)" -ForegroundColor White
            }
            if ($Cmd.GpuTemplate) {
                Write-Host "    [GPU 模板]: $($Cmd.GpuTemplate)" -ForegroundColor Blue
            }
            if ($Cmd.CpuTemplate) {
                Write-Host "    [CPU 模板]: $($Cmd.CpuTemplate)" -ForegroundColor Blue
            }

          
        }
    }
    
    Write-Host "`n=============================================" -ForegroundColor Cyan
    Write-Host " ✅ 接口测试完成。这些函数可以被其他脚本调用。" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
}