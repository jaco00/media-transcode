
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
    $percent =  ($NewBytes / $SrcBytes * 100)
    if ([double]::IsNaN($percent)) {
        $percent = 0
    }
    $percentStr = "{0:N1}%" -f $percent
        
    

    $indexWidth = ($Total).ToString().Length
    $indexStr = $("[{0," + $indexWidth + "}/{1," + $indexWidth + "}]") -f $Index, $Total

    # 进度条长度
    $progressBarLength = 10
    # 如果文件变大，进度条长度应该是 0，否则按压缩比例填充
    $filledLength = [math]::Round($progressBarLength * [math]::Min([math]::Abs($percent) / 100, 1))
    
    # 填充进度条
    $barFilled = "█" * $filledLength
    $barEmpty = "░" * ($progressBarLength - $filledLength)

    $srcStr = Format-Size $SrcBytes
    $newStr = Format-Size $NewBytes

    $icon = Get-FileIcon $File

    # 输出：图标/序号 Cyan，进度条颜色根据压缩或膨胀变化，大小/百分比 Yellow，文件名 Cyan
    Write-Host "$icon $indexStr " -NoNewline -ForegroundColor Cyan

    if ($percent -le 90) {
        # 压缩后变小，进度条用绿色
        Write-Host "$barFilled" -NoNewline -ForegroundColor Green
    } else {
    
        Write-Host "$barFilled" -NoNewline -ForegroundColor Red
    }
    
    Write-Host "$barEmpty" -NoNewline -ForegroundColor DarkGray

    if ($percent -le 100) {
        $percentDisplay = "[{0,6}]" -f $percentStr
        Write-Host $percentDisplay -ForegroundColor Green -NoNewline
        if ($ElapsedSeconds -gt 0) {
            $elapsedStr = "[{0:N2}s]" -f $ElapsedSeconds
            Write-Host " $elapsedStr" -NoNewline -ForegroundColor DarkYellow
        }
        Write-Host " $srcStr → $newStr | $File" -ForegroundColor White
    } else {
        $percentDisplay = "[{0,6}]" -f $percentStr
        Write-Host $percentDisplay -ForegroundColor Red -NoNewline
        if ($ElapsedSeconds -gt 0) {
            $elapsedStr = "[{0:N2}s]" -f $ElapsedSeconds
            Write-Host " $elapsedStr" -NoNewline -ForegroundColor DarkYellow
        }
        Write-Host " $srcStr → $newStr | $File" -ForegroundColor White
    }
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
