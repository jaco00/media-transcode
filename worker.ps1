

function Invoke-FfmpegWithProgress {
    param(
        [Parameter(Mandatory)] [string]$ExePath,
        [Parameter(Mandatory)] [string[]]$Args,
        [Parameter(Mandatory)] [double]$TotalSeconds,
        [Parameter(Mandatory)] [string]$ActivityText,
        [ref]$ProcessRef
    )

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName = $ExePath
    $proc.StartInfo.Arguments = $Args -join " "
    $proc.StartInfo.RedirectStandardError = $true
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.CreateNoWindow = $true

    $proc.Start() | Out-Null
    $ProcessRef.Value = $proc

    while (-not $proc.HasExited) {
        $line = $proc.StandardError.ReadLine()
        if (-not $line) { continue }
        if ($line -match "time=(\d{2}:\d{2}:\d{2}\.\d{2}).*speed=\s*(\d+\.?\d*)x") {

            $currentTimeStr = $Matches[1]
            $speed = [double]$Matches[2]

            $ts = [timespan]::Parse($currentTimeStr)
            $currentSec = $ts.TotalSeconds

            $percent = 0
            $remaining = -1
            if ($TotalSeconds -gt 0) {
                $percent = ($currentSec / $TotalSeconds) * 100
                if ($speed -gt 0.05) {
                    $remaining = ($TotalSeconds - $currentSec) / $speed
                }
            }
            Update-VideoProgressUI `
                -Activity $ActivityText `
                -Percent $percent `
                -Speed $speed `
                -CurrentTime $currentTimeStr `
                -RemainingSeconds $remaining
        }
    }

    $proc.WaitForExit()
    Write-Progress -Activity $ActivityText -Completed
    Write-Host -NoNewline "`e[2K`e[G"

    return $proc.ExitCode
}

function Update-VideoProgressUI {
    param(
        [Parameter(Mandatory)] [string]$Activity,
        [Parameter(Mandatory)] [double]$Percent,
        [Parameter(Mandatory)] [double]$Speed,
        [Parameter(Mandatory)] [string]$CurrentTime,
        [double]$RemainingSeconds = -1
    )

    $Percent = [math]::Max(0, [math]::Min(100, $Percent))

    $params = @{
        Activity        = $Activity
        Status          = "速率 $($Speed)x | 已处理 $CurrentTime"
        PercentComplete = $Percent
    }

    if ($RemainingSeconds -gt 0) {
        $params.SecondsRemaining = [int]$RemainingSeconds
    }

    Write-Progress @params
}

function Worker {
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Task,
        [Parameter()] [bool]$ShowDetails = $false,
        [Parameter()] $LogMutex = $null,
        [Parameter()] [string]$LogDir = ""
    )

    if ($null -eq $Task) { return $null }

    $startTime = Get-Date
    $src, $rel, $tempOut, $finalOut = $Task.Src, $Task.RelativePath, $Task.TempOut, $Task.TargetOut
    $resultTemplate = [ordered]@{
        File         = $src
        Type         = $Task.Type
        SrcBytes     = $Task.OldSize
        NewBytes     = 0
        StartTime    = $startTime
        Success      = $false
        ToolUsed     = ""
        ErrorMessage = ""
    }
    $proc = $null

    if (-not $Task.Cmds -or $Task.Cmds.Count -eq 0) {
        $resultTemplate.ErrorMessage = "任务 [$rel] 配置异常: 无有效工具命令。"
        return [pscustomobject]$resultTemplate
    }

    # 外层 try 包裹整个循环，确保 finally 能在函数结束时执行一次
    try {
        $totalCmds = $Task.Cmds.Count
        for ($idx = 0; $idx -lt $totalCmds; $idx++) {
            $cmdObj = $Task.Cmds[$idx]
            $toolLabel = if ($totalCmds -gt 1) { "[$($cmdObj.ToolName)] ($($idx+1)/$totalCmds)" } else { "[$($cmdObj.ToolName)]" }
            $output = ""
            $currentExitCode = -1 
            try {
                if ($Task.Type.ToString() -eq "video") {

                    if ($ShowDetails) { Write-Host "CMD ${toolLabel}: $($cmdObj.DisplayCmd)" -ForegroundColor Yellow }
                    if ($cmdObj.ToolName -like "*ffmpeg*") {
                        $currentExitCode = Invoke-FfmpegWithProgress `
                        -ExePath $cmdObj.Path `
                        -Args $cmdObj.Args `
                        -TotalSeconds $Task.Duration `
                        -ActivityText "正在压缩视频: $rel" `
                        -ProcessRef ([ref]$proc)
                    } else {
                        & $cmdObj.Path @($cmdObj.Args)
                        $currentExitCode = $LASTEXITCODE
                    }
                } else {
                    $output = & $cmdObj.Path @($cmdObj.Args) 2>&1
                    $currentExitCode = $LASTEXITCODE
                    if ($ShowDetails) {
                        Write-Host "CMD ${toolLabel}: $($cmdObj.DisplayCmd)" -ForegroundColor Yellow 
                        Write-Host ($output -join "`n") -ForegroundColor Yellow
                    }
                }

                if ($currentExitCode -eq 0 -and (Test-Path $tempOut)) {
                    # 必须在 Move-Item 之前获取大小，因为移动后临时路径就消失了
                    $resultTemplate.NewBytes = (Get-Item $tempOut).Length 
                    #Move-Item $tempOut $finalOut -Force

                    Move-Item $tempOut $finalOut -Force -ErrorAction SilentlyContinue

                    if (-not $?) {
                        $parent = Split-Path $finalOut -Parent
                        $leaf = Split-Path $finalOut -Leaf
                        $timestamp = Get-Date -Format "yyyyMMdd_HHmmssfff"
    
                        $newName = "conflict_$timestamp`_$leaf"
                        $newPath = Join-Path $parent $newName

                        Move-Item $tempOut $newPath -Force
                        Write-Host " [!] 目标被占用，已另存为: $newName" -ForegroundColor Yellow
                    }

                    
                    if (-not [string]::IsNullOrWhiteSpace($Task.BackupPath)) {
                        if (-not (Test-Path $Task.BackupDir)) { New-Item $Task.BackupDir -ItemType Directory -Force | Out-Null }
                        Move-Item $src $Task.BackupPath -Force
                    }

                    $resultTemplate.Success  = $true
                    $resultTemplate.ToolUsed = $cmdObj.ToolName
                    return [pscustomobject]$resultTemplate
                } else {
                    throw "命令: $($cmdObj.DisplayCmd)`n退出码: $LASTEXITCODE`n终端输出: $($output -join "`n")"
                }
            }
            catch {
                # 记录日志前清理当前方案产生的残余
                if (Test-Path $tempOut) { Remove-Item $tempOut -Force -ErrorAction SilentlyContinue }

                $logFile = Join-Path $LogDir "err-$(Get-Date -Format 'yyyy-MM-dd').log"
                $errDetail = $_.Exception.Message
                $logContent = "[$(Get-Date -Format 'HH:mm:ss')] 失败: $rel`n方案: $toolLabel`n错误: $errDetail`n$('-' * 60)"
                

                if ($null -ne $LogMutex) {
                    $null = $LogMutex.WaitOne(); try { Add-Content $logFile "`n$logContent" } finally { $LogMutex.ReleaseMutex() }
                } else { Add-Content $logFile "`n$logContent" }

                Write-Host " [FAILED] " -BackgroundColor Red -ForegroundColor White -NoNewline
                Write-Host " $($cmdObj.DisplayCmd) " -BackgroundColor Black -ForegroundColor Yellow
                
                if ($idx -lt ($totalCmds - 1)) {
                    Write-Host "⚠ $toolLabel 失败，已记录日志，重试下一个方案..." -ForegroundColor Yellow
                } else {
                    # 最后一个方案也失败，返回结果对象
                    Write-Host "✖ 任务彻底失败, 源文件: $src" -ForegroundColor Red
                    $resultTemplate.ErrorMessage = "全方案失败。末次错误: $errDetail"
                    $resultTemplate.Success      = $false
                    return [pscustomobject]$resultTemplate
                }
            }
        } # End For
    }
    finally {
        # 终极保底清理，放在循环外

        if ($proc -and -not $proc.HasExited) {
            try {
                $mypid  = $proc.Id
                $name = [System.IO.Path]::GetFileName($proc.StartInfo.FileName)
                $proc.Kill($true)

                Write-Host "✖ 已强制终止进程: $name (PID=$mypid) $args" -ForegroundColor Red
            }
            catch {
                Write-Host "✖ 终止进程失败: PID=$($proc?.Id) $_" -ForegroundColor Red
            }
        }

        if (Test-Path $tempOut) { Remove-Item $tempOut -Force -ErrorAction SilentlyContinue }
    }
}
