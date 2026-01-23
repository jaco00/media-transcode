
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
        [int]$Total,
        [double]$ElapsedSeconds = 0
    )

    # 计算压缩率（小于100表示变小，大于100表示变大）
    $percent = (($SrcBytes - $NewBytes) / $SrcBytes) * 100
    if ([double]::IsNaN($percent)) {
        $percent = 0
    }
    $percentStr = "{0:N1}%" -f $percent
        

    $indexWidth = ($Total).ToString().Length
    $indexStr = $("[{0," + $indexWidth + "}/{1," + $indexWidth + "}]") -f $Index, $Total

    # 进度条长度
    $progressBarLength = 10

    $fillPercent = [math]::Min([math]::Abs($percent) / 100, 1) 
    $filledLength = [math]::Round($progressBarLength * $fillPercent)
    
    # 填充进度条
    $barFilled = "█" * $filledLength
    $barEmpty = "░" * ($progressBarLength - $filledLength)
    $barColor = if ($percent -lt 10) { "Red" } else { "Green" }

    $srcStr = "{0,9}" -f (Format-Size $SrcBytes)
    $newStr = "{0,9}" -f (Format-Size $NewBytes)

    $icon = Get-FileIcon $File

    # 输出：图标/序号 Cyan，进度条颜色根据压缩或膨胀变化，大小/百分比 Yellow，文件名 Cyan
    Write-Host "$icon $indexStr " -NoNewline -ForegroundColor Cyan
    Write-Host "$barFilled" -NoNewline -ForegroundColor $barColor
    
    Write-Host "$barEmpty" -NoNewline -ForegroundColor DarkGray

    $percentColor = if ($percent -ge 10) { "Green" } else { "Red" }
    $percentDisplay = "[{0,6}]" -f $percentStr
    Write-Host $percentDisplay -ForegroundColor $percentColor -NoNewline
    if ($ElapsedSeconds -gt 0) {
        $elapsedStr = "[{0,6:N1}s]" -f $ElapsedSeconds
        Write-Host " $elapsedStr" -NoNewline -ForegroundColor DarkYellow
    }
    Write-Host " $srcStr → $newStr | $File" -ForegroundColor White
}

function New-ConsoleSpinner {
    param (
        [string]$Title = "Processing",
        [int]$Total = 0,
        [int]$SamplingRate = 1
    )

    $count = 0
    $spinnerChars = @('-', '\', '|', '/')
    $spinnerIndex = 0
    $esc = [char]27

    return {
        param(
            [string]$Describe = "",
            [switch]$Finalize
        )

        $script:count++

        if ($Total -gt 0 -and $script:count -eq $Total) {
            $Finalize=$true
        }

        if ( $Finalize -or $script:count % $SamplingRate -eq 0 ) {
            $char = $spinnerChars[$spinnerIndex % $spinnerChars.Count]
            $spinnerIndex++

            if ($Total -gt 0) {
                $percent = [math]::Round(($script:count / $Total) * 100, 1)
                $percentText = "{0,6:0.0}%" -f $percent
                $text = "$Title $char [$script:count/$Total $percentText] $Describe"
            } else {
                $text = "$Title $char [$script:count] $Describe"
            }
            Write-Host -NoNewline "$esc[2K$esc[G$text"
        }
        if ($Finalize) {
            Write-Host ""
        }
    }.GetNewClosure()
}

function Write-ScanSummary {
    param (
        [string]$Title,        # 标题，如 "图片文件"
        [int]$Count,           # 已压缩数量
        [long]$SrcSize,        # 原始大小
        [long]$DstSize,        # 压缩后大小
        [int]$UnconvertedCount,# 未转换数量
        [long]$UnconvertedSize,# 未转换大小
        [int]$DoneCount     # 已删除源文件数量
    )

    $SavedSize = $SrcSize - $DstSize
    $SavedPercent = if ($SrcSize -gt 0) { 
        [math]::Round((1 - $DstSize / $SrcSize) * 100, 1) 
    }
    else { 0 }

    # 打印子标题
    Write-Host ""
    Write-Host "$Title" -ForegroundColor Cyan

    # --- 处理已压缩部分 ---
    if ($Count -gt 0) {
        Write-Host ("  已压缩数量: ", $Count) -ForegroundColor White
        Write-Host ("  原始总计: ", (Format-Size $SrcSize)) -ForegroundColor Gray
        Write-Host ("  当前总计: ", (Format-Size $DstSize)) -ForegroundColor Gray
        Write-Host ("  节省空间: ", "$(Format-Size $SavedSize) ($SavedPercent%)") -ForegroundColor Green
    } else {
        Write-Host ("  已压缩数量: ", "0") -ForegroundColor DarkGray
    }

    # --- 处理未转换部分 ---
    if ($UnconvertedCount -gt 0) {
        Write-Host ("  未转换数量: ", $UnconvertedCount) -ForegroundColor Yellow
        Write-Host ("  未转换大小: ", (Format-Size $UnconvertedSize)) -ForegroundColor Gray
    } else {
        Write-Host ("  未转换数量: ", "0") -ForegroundColor DarkGray
    }

    # --- 清理记录 ---
    Write-Host ("  已删除源文件:",$DoneCount) -ForegroundColor DarkGray
}

function CalcRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    try {
        # 规范化路径（解决 .. / . / 大小写）
        $root = (Resolve-Path -LiteralPath $RootPath).Path.TrimEnd('\')
        $full = (Resolve-Path -LiteralPath $FullPath).Path
    }
    catch {
        Write-Host "路径解析失败：$FullPath" -ForegroundColor Red
        return $null
    }

    # 必须是目录边界匹配，防 D:\root 和 D:\root2
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "路径不在源目录下，无法计算相对路径：$full" -ForegroundColor Red
        return $null
    }

    return $full.Substring($root.Length + 1)
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
        Write-Host "🔧 [$toolPath] " -ForegroundColor Gray -NoNewline
        Write-Host "✓" -ForegroundColor Green
        return $toolPath
    }
    catch {
        throw "$ExeName 找到路径 $toolPath，但无法运行"
    }
}

function Parse-ExtFilter {
    param(
        [string]$ExtInput
    )

    if (-not $ExtInput) { return @() }
    $rawList = $ExtInput -split '[,|\s]+'

    $UserExtFilter = $rawList | ForEach-Object {
        $e = $_.Trim().ToLower()
        if ($e -ne '') {
            $e = $e.TrimStart('*')
            if ($e -notmatch '^\.' ) { $e = ".$e" }
            $e
        }
    }
    return $UserExtFilter | Sort-Object -Unique
}