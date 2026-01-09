param(
    [string]$Dir = ".",
    [int]$Duration = 20,
    [ValidateSet("start","middle")]
    [string]$Mode = "start"
)

$ffmpeg = Join-Path $PSScriptRoot "bin\ffmpeg.exe"
$ffprobe = Join-Path $PSScriptRoot "bin\ffprobe.exe"

# 推荐值
$recommendedPSNR = 30
$recommendedSSIM = 0.95

# 获取所有待处理文件
$files = Get-ChildItem $Dir -File -Recurse | Where-Object { $_.Name -notmatch "\.h265\.mp4$" }
$total = $files.Count

if ($total -eq 0) {
    Write-Host "未找到可处理文件。" -ForegroundColor Yellow
    return
}

# 输出推荐值
Write-Host ("推荐参考值: PSNR >= {0}, SSIM >= {1}" -f $recommendedPSNR, $recommendedSSIM) -ForegroundColor Green
Write-Host ("-"*100)

# 遍历文件
for ($i=0; $i -lt $total; $i++) {
    $file = $files[$i]
    $index = $i + 1
    $base = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $encoded = Join-Path $file.DirectoryName "$base.h265.mp4"

    if (!(Test-Path $encoded)) { continue }

    # 计算起始时间
    $start = 0
    $actualDuration = $Duration

    if ($Mode -eq "middle") {
        # 尝试从 container 获取总时长（兼容 MKV / MP4 / HEVC）
        $durStr = & $ffprobe -v error -show_entries format=duration -of csv=p=0 "`"$($file.FullName)`""
        $dur = 0

        if ([double]::TryParse($durStr, [ref]$dur)) {
            # dur 是视频总时长，计算中间开始位置
            $start = [Math]::Max(0, ($dur / 2) - ($Duration / 2))

            # 实际截取长度，避免视频太短导致超出末尾
            $actualDuration = [Math]::Min($Duration, $dur - $start)
            if ($actualDuration -le 0) {
                Write-Host "⚠ 视频太短，跳过: $($file.Name)" -ForegroundColor Yellow
                continue
            }
        } else {
            Write-Host "⚠ 无法获取时长，使用开头开始: $($file.Name)" -ForegroundColor Yellow
            $start = 0
            $actualDuration = $Duration
        }
    }

    # FFmpeg 参数
    $args = @(
        "-hide_banner",
        "-loglevel", "info",
        "-nostats",
        "-ss", "$start",
        "-t", "$actualDuration",
        "-i", "`"$($file.FullName)`"",
        "-ss", "$start",
        "-t", "$actualDuration",
        "-i", "`"$encoded`"",
        "-filter_complex", "`"[0:v][1:v]psnr;[0:v][1:v]ssim`"",
        "-f", "null", "-"
    )

    # 执行 FFmpeg 并捕获输出
    $output = & $ffmpeg @args 2>&1

    # 提取 PSNR average
    $psnrLine = $output | Where-Object { $_ -match "PSNR.*average:" }
    $psnr = 0
    if ($psnrLine -match "average:([0-9\.]+)") { $psnr = [double]$matches[1] }

    # 提取 SSIM All
    $ssimLine = $output | Where-Object { $_ -match "SSIM.*All:" }
    $ssim = 0
    if ($ssimLine -match "All:([0-9\.]+)") { $ssim = [double]$matches[1] }

    # 设置颜色：高于推荐值 -> 绿色，低于 -> 红色
    if ($psnr -ge $recommendedPSNR -and $ssim -ge $recommendedSSIM) {
        $color = "Green"
    } else {
        $color = "Red"
    }

    # 输出序号 + 数值 + 文件名
    $indexStr = "[{0,3}/{1}]" -f $index, $total   # 序号右对齐 3位
    $psnrStr = "{0:N6}" -f $psnr
    $ssimStr = "{0:N6}" -f $ssim
    Write-Host -NoNewline $indexStr
    Write-Host -NoNewline (" PSNR={0,-10} SSIM={1,-8}" -f $psnrStr, $ssimStr) -ForegroundColor $color
    Write-Host (" $($file.Name)")
}

Write-Host ("-"*100)
Write-Host "全部处理完成。" -ForegroundColor Cyan
