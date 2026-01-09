
function Get-FileIcon {
    param([string]$FileName)

    $ext = [IO.Path]::GetExtension($FileName).ToLower()

    # 配置分组
    $images = @(".jpg", ".jpeg", ".png", ".bmp", ".heic", ".gif")
    $videos = @(".mp4", ".mov", ".avi", ".mkv")
   
    if ($images -contains $ext) { return "🖼️" }
    elseif ($videos -contains $ext) { return "🎬" }
    else { return "📄" }
}

function Format-Size {
    param($bytes)
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N1} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N1} KB" -f ($bytes / 1KB) }
    else { "$bytes B" }
}

function Write-CompressionStatus {
    param(
        [string]$File,
        [double]$SrcBytes,
        [double]$NewBytes,
        [int]$Index,
        [int]$Total
    )

    # 计算压缩率（小于100表示变小，大于100表示变大）
    $percent = 100 - ($NewBytes / $SrcBytes * 100)
    $percentStr = if ($percent -ge 0) {
        "{0:N1}%" -f $percent
    } else {
        # 负数表示文件变大，用红色显示
        "{0:N1}%" -f -$percent
    }

    $indexWidth = ($Total).ToString().Length
    $indexStr = $("[{0," + $indexWidth + "}/{1," + $indexWidth + "}]") -f $Index, $Total

    # 进度条长度
    $progressBarLength = 10
    # 如果文件变大，进度条长度应该是 0，否则按压缩比例填充
    $filledLength = if ($percent -ge 0) { [math]::Round($progressBarLength * [math]::Min([math]::Abs($percent) / 100, 1)) } else { 0 }
    
    # 填充进度条
    $barFilled = "█" * $filledLength
    $barEmpty = "░" * ($progressBarLength - $filledLength)

    $srcStr = Format-Size $SrcBytes
    $newStr = Format-Size $NewBytes

    $icon = Get-FileIcon $File

    # 输出：图标/序号 Cyan，进度条颜色根据压缩或膨胀变化，大小/百分比 Yellow，文件名 Cyan
    Write-Host "$icon $indexStr " -NoNewline -ForegroundColor Cyan

    if ($percent -ge 0) {
        # 压缩后变小，进度条用绿色
        Write-Host "$barFilled" -NoNewline -ForegroundColor Green
    } else {
        # 压缩后变大，进度条显示为空
        Write-Host "$barFilled" -NoNewline -ForegroundColor DarkGray
    }
    
    Write-Host "$barEmpty" -NoNewline -ForegroundColor DarkGray

    if ($percent -ge 0) {
        Write-Host " $srcStr → $newStr " -NoNewline
        Write-Host "[$percentStr]" -ForegroundColor Green -NoNewline
        Write-Host " | $File" -ForegroundColor White
    } else {
        Write-Host " $srcStr → $newStr " -NoNewline
        Write-Host "[$percentStr]" -ForegroundColor Red -NoNewline
        Write-Host " | $File" -ForegroundColor White
    }
}

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
