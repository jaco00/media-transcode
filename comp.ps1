# -*- coding: utf-8 -*-
# clean_optimized.ps1 —— 清理已压缩的源文件（扫描并删除已转换的源文件）

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [ValidateRange(1,64)]
    [int]$MaxThreads=2
)
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\tools-cfg.ps1"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $MaxThreads = 1
}

$script:CheckerByExt = @{}
$ImageOutputExt=""
$VideoOutputExt=""

function Initialize-Config {
    param([string]$ConfigName)

    $ScriptDir = $PSScriptRoot
    if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

    $configPath = Join-Path $scriptDir $ConfigName

    if (-not (Test-Path $configPath)) {
        throw "配置文件不存在: $configPath"
    }
     # 读取 JSON
    $jsonText = Get-Content $configPath -Raw -Encoding UTF8

    try {
        $config = ConvertFrom-Json $jsonText
        $script:ImageOutputExt = $config.ImageOutputExt
        $script:VideoOutputExt = $config.VideoOutputExt
        if ($null -eq $config.checker) {
            Write-Host "❌ 警告: checker 属性确实是空的！" -ForegroundColor Red
        }
    } catch {
        throw "❌ JSON 解析失败: $_"
    }

    # 建立扩展名映射
    $map = @{}
    foreach ($checker in $config.checker) {
        foreach ($fmt in $checker.format) {
            $ext = $fmt.ToLower()
            if (-not $map.ContainsKey($ext)) {
                $map[$ext] = @()
            }
            $map[$ext] += $checker
        }
    }
    Write-Host "配置初始化完成，共 $($config.checker.Count) 个 checker"
    foreach ($c in $config.checker) {
        $formats = $c.format -join ", "
        Write-Host "  📊 $($c.name), Metric: $($c.metric_name), Formats: $formats" -ForegroundColor Green
    }
    $script:CheckerByExt=$map
}

function Get-CheckersByExtension {
    param([string]$Extension)
    if (-not $Extension) {
        return @()
    }
    # 标准化扩展名，保证带点，且小写
    $ext = $Extension.ToLower()
    if (-not $ext.StartsWith(".")) {
        $ext = "." + $ext
    }
    # 查表，如果找不到返回空数组
    if ($script:CheckerByExt.ContainsKey($ext)) {
        return ,$script:CheckerByExt[$ext]
    }
    return @()
}

function Measure-FileQuality {
    param(
        [Parameter(Mandatory=$true)][string]$SrcFile,
        [Parameter(Mandatory=$true)][string]$DstFile,
        [Parameter(Mandatory=$true)][PSObject]$Checker,
        [Parameter(Mandatory=$true)]$Tools
    )

    $result = [PSCustomObject]@{
        SrcFile      = $SrcFile
        DstFile      = $DstFile
        SrcSize      = 0
        DstSize      = 0
        CheckerName  = $Checker.name
        QualityValue = 0
        Grade        = "F"
        Color        = "Gray"
        Metric       = $Checker.metric_name
        Success      = $false
        FileName     = $SrcFile
        Ratio        = 0
    }
    try {
        if (-not (Test-Path $SrcFile)) { throw "源文件不存在: $SrcFile" }
        if (-not (Test-Path $DstFile)) { throw "压缩文件不存在: $DstFile" }

        # ----------------------
        # 获取源/压缩文件大小
        # ----------------------
        $result.SrcSize = (Get-Item $SrcFile).Length
        $result.DstSize = (Get-Item $DstFile).Length
        # 压缩率计算
        $compressRatio =0
        if ($result.SrcSize -gt 0){
            $compressRatio = 1 - ($result.DstSize / $result.SrcSize)
        }
        $result.Ratio = [math]::Round($compressRatio * 100, 1)

        # ----------------------
        # 视频参数填充
        # ----------------------
        $startTime = "0"
        $durationLimit = "10"
        $subsample = "1"

        if ($Checker.category -eq "video_quality") {
            #$ffprobePath = Resolve-ToolExe -ExeName "ffprobe"
            $realLenText = & $Tools.ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$SrcFile`"" 2>$null
            if ($realLenText -match '^[0-9.]+$') {
                $realLen = [double]$realLenText
                if ($realLen -gt 10) {
                    $startTime = "5"
                    $subsample = "6"
                } else {
                    $durationLimit = $realLen.ToString()
                }
            }
        }

        # ----------------------
        # 获取工具可执行路径
        # ----------------------
        $ToolName = $Checker.tool
        $toolPath = $Tools.$ToolName
        if (-not $toolPath) {
             throw "错误: 检测器 [$($Checker.name)] 指定的工具 [$ToolName] 在 Tools 结构体中未定义或路径为空。"
        }

        # ----------------------
        # 参数扁平化与变量替换
        # ----------------------
        $flatArgs = @()
        foreach ($paramRow in $Checker.parameters) {
            foreach ($item in $paramRow) {
                #$processed = $item.Replace('$SRC$', "`"$SrcFile`"").Replace('$DST$', "`"$DstFile`"")
                $processed = $item.Replace('$SRC$', "$SrcFile").Replace('$DST$', "$DstFile")
                $processed = $processed.Replace('$START_TIME$', $startTime).Replace('$DURATION$', $durationLimit).Replace('$SUBSAMPLE$', $subsample)
                $flatArgs += $processed
            }
        }

        # ----------------------
        # 执行检测
        # ----------------------
        #Write-Host "DEBUG: 执行命令: $toolPath $($flatArgs -join ' ')" -ForegroundColor Yellow
        $output = & $toolPath $flatArgs 2>&1 | Select-Object -Last 20 | Out-String
        $exitCode = $LASTEXITCODE
        if ($exitCode -gt 1) {
            #Write-Warning "工具执行失败 (exit code $exitCode)！"
            #Write-Warning "`n$output`n"
            Write-Host ""
            Write-Host "$icon ⚠ 工具执行失败: $srcName" -ForegroundColor Red
            Write-Host ("  ExitCode: " + $exitCode) -ForegroundColor Yellow
            Write-Host "  命令输出:" -ForegroundColor Cyan
            $output.Split("`n") | ForEach-Object {
                Write-Host ("    " + $_) -ForegroundColor DarkGray
            }
        }
         
        # ----------------------
        # 解析结果
        # ----------------------
        if ($output -match $Checker.result_regex) {
            $score = [double]$Matches[1]
            $result.QualityValue = [math]::Round($score, 3)
            $result.Success = $true

            if (-not [string]::IsNullOrWhiteSpace($Checker.value_transform)) {
                $expanded = $Checker.value_transform -replace '\bx\b', $result.QualityValue
                $result.QualityValue = Invoke-Expression $expanded
            } 

            # 查找评分
            #$gradeEntry = $Checker.grading | Sort-Object min -Descending | Where-Object { $score -ge $_.min } | Select-Object -First 1
            $gradeEntry = $Checker.grading | Where-Object { $score -ge $_.min -and $score -lt $_.max } | Select-Object -First 1
            if ($gradeEntry) {
                $result.Grade = $gradeEntry.grade
                $result.Color = $gradeEntry.color
            }
        }

    } catch {
        Write-Warning "[$($result.SrcFile)] 检测失败: $($_.Exception.Message)"
    }

    return $result
}

function Show-Result {
    param(
        $r,
        [int]$Current,
        [int]$Total
    )

    $icon = if ($r.Type -eq "video") { "🎬" } else { "🖼️" }

    $w = $Total.ToString().Length
    $progress = "[{0}/{1}]" -f $Current.ToString().PadLeft($w), $Total

    # 使用辅助函数格式化文件大小
    $srcStr = Format-Size $r.SrcSize
    $dstStr = Format-Size $r.DstSize 

    # 压缩率颜色
    $ratioColor = if ($r.Ratio -lt 20) { "Red" } else { "Green" }

    # 对齐宽度
    $srcStr = $srcStr.PadLeft(8)
    $dstStr = $dstStr.PadLeft(8)
    $ratioStr = ("{0,6}%" -f $r.Ratio)

    # 构造输出
    Write-Host "$icon $progress $srcStr → $dstStr [" -NoNewline
    Write-Host $ratioStr -ForegroundColor $ratioColor -NoNewline
    Write-Host "] | $($r.Metric): " -NoNewline
    $qualityStr = "{0,6:N3}" -f $r.QualityValue
    Write-Host $qualityStr -ForegroundColor $r.Color -NoNewline
    Write-Host " [$($r.Grade)] | $($r.FileName)"
}



if (-not (Test-Path -LiteralPath $SourcePath)) {
    Write-Host "错误: 目录不存在: $SourcePath" -ForegroundColor Red
    exit 1
}

Initialize-Config "tools.json" 

$Tools = [PSCustomObject]@{
    ffprobe = (Resolve-ToolExe "ffprobe")
    ffmpeg  = (Resolve-ToolExe "ffmpeg")
    magick  = (Resolve-ToolExe "magick")
}


$tasks = [System.Collections.Generic.List[object]]::new()
$spinner = New-ConsoleSpinner -Title "扫描目录中" -SamplingRate 500
Get-ChildItem -Path $SourcePath -Recurse -File | ForEach-Object {
    $srcFile = $_
    &$spinner $srcFile.FullName

    if ($srcFile.Name.ToLower().EndsWith($ImageOutputExt.ToLower()) -or
        $srcFile.Name.ToLower().EndsWith($VideoOutputExt.ToLower())) {
        return
    }
    $ext = $srcFile.Extension.ToLower()

    # 根据扩展名获取对应 checker
    $checkers = Get-CheckersByExtension $ext
    if (-not $checkers -or $checkers.Count -eq 0) { return }  # 无对应 checker

    $targetChecker = $checkers[0]

    # 判断类型和目标文件
    if ($targetChecker.category -eq "video_quality") {
        $dstFile = [IO.Path]::ChangeExtension($srcFile.FullName, $VideoOutputExt)
        $type = "video"
    } elseif ($targetChecker.category -eq "image_quality") {
        $dstFile = [IO.Path]::ChangeExtension($srcFile.FullName, $ImageOutputExt)
        $type = "image"
    }else{
        return
    }

    # 目标文件存在才生成 task
    if (Test-Path $dstFile) {
        $tasks.Add([PSCustomObject]@{
            Src     = $srcFile.FullName
            Dst     = $dstFile
            Type    = $type
            Checker = $targetChecker
            Result  = $null
        })
    }
}
&$spinner "Done" -Finalize
$tasks = $tasks | Sort-Object Type
$current=0
if ($MaxThreads -gt 1) {
    Write-Host "▶ 并行模式 ($MaxThreads threads)" -ForegroundColor Green
    $funcDefinition = "function Measure-FileQuality { ${function:Measure-FileQuality} }"
    $tasks | ForEach-Object -Parallel {
        Invoke-Expression $using:funcDefinition
        $res = Measure-FileQuality -SrcFile $_.Src -DstFile $_.Dst -Checker $_.Checker -Tools $using:Tools 
        $_.Result=$res
        $res
    } -ThrottleLimit $MaxThreads |
    ForEach-Object {
        $current++
        Show-Result $_ $current $tasks.Count
    }
}
else {
    Write-Host "▶ 串行模式" -ForegroundColor White

    @($tasks) | ForEach-Object {
        $res = Measure-FileQuality -SrcFile $_.Src -DstFile $_.Dst -Checker $_.Checker -Tools $Tools
        Show-Result $res $current $tasks.Count
        $_.Result=$res
    }
}

Write-Host "`n📊 正在按类型分组并排序结果，请稍候..." -ForegroundColor Cyan
$tasks |
    Group-Object Type |
    ForEach-Object {
        Write-Host "`n=== TOP10 $($_.Name) ===" -ForegroundColor Cyan

        $_.Group |
            Sort-Object { $_.Result.QualityValue } |
            Select-Object -First 10 |
            ForEach-Object {
                Write-Host (
                    "{0,7:F4}  {1,6}%  {2,8} → {3,-8}  {4}" -f
                    [double]$_.Result.QualityValue,
                    $_.Result.Ratio,
                    (Format-Size $_.Result.SrcSize),
                    (Format-Size $_.Result.DstSize),
                    $_.Src
                )
            }
    }
