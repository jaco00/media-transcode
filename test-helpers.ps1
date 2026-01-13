# ===============================
# 1. 导入 helper（主 Runspace）
# ===============================

# 检查是否在 pwsh 中运行，如果不是则用 pwsh 重新运行
$requiredVersion = [version]"7.0.0"
$isPwsh = $PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSEdition -eq "Core"

if (-not $isPwsh) {
    $pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshPath) {
        Write-Host "未找到 PowerShell 7 (pwsh)。请安装 PowerShell 7 或更高版本。" -ForegroundColor Red
        Write-Host "安装 PowerShell 7 请使用以下命令：" -ForegroundColor Yellow
        Write-Host "winget install --id Microsoft.Powershell --source winget"
        exit 1
    }

    # 提示用户
    Write-Host "检测到当前不在 PowerShell 7 (pwsh) 中运行，正在切换到 pwsh..." -ForegroundColor Yellow
    Write-Host "路径: $($pwshPath.Source)" -ForegroundColor Cyan

    # 用 pwsh 重新运行当前脚本
    & $pwshPath -File $MyInvocation.MyCommand.Path
    exit $LASTEXITCODE
}

. "$PSScriptRoot\helpers.ps1"


$index = 0

# ===============================
# 2. 定义业务函数（只写一次）
# ===============================
function Process-OneFile {
    param($file)

    # 记录开始时间
    $startTime = Get-Date

    # 真实场景这里跑 ffmpeg
    Start-Sleep -Milliseconds (Get-Random -Min 100 -Max 500)

    [pscustomobject]@{
        File     = $file.Name
        SrcBytes = $file.SrcSize
        NewBytes = $file.NewSize
        StartTime = $startTime
    }
}

# 把函数定义“文本化”（关键）
$processFuncText = ${function:Process-OneFile}.ToString()

# ===============================
# 3. 模拟数据
# ===============================
$files = @(
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1524  }
    @{ Name = "b.png"; SrcSize = 5120;  NewSize = 2560  }
    @{ Name = "c.bmp"; SrcSize = 10240; NewSize = 15120 }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 2000  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 1924  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 2024  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 124  }
    @{ Name = "a.jpg"; SrcSize = 2048;  NewSize = 924  }
)

$total = $files.Count


Write-Host "---- 顺序处理 ----" -ForegroundColor Cyan

$index = 0
foreach ($file in $files) {
    $index++

    $r = Process-OneFile $file

    # 计算耗时
    $elapsed = ((Get-Date) - $r.StartTime).TotalSeconds

    Write-CompressionStatus `
        -File $r.File `
        -SrcBytes $r.SrcBytes `
        -NewBytes $r.NewBytes `
        -Index $index `
        -Total $total `
        -ElapsedSeconds $elapsed
}


# ===============================
# 4. 并行处理（标准写法）
# ===============================
$index = 0

$files |
ForEach-Object -Parallel {

    # 🔑 子 Runspace：重建业务函数
    Set-Item -Path function:Process-OneFile -Value $using:processFuncText

    # 只做事，不输出
    Process-OneFile $_

} -ThrottleLimit 3 | ForEach-Object {

    # 主 Runspace：顺序输出
    $index++

    # 计算耗时
    $elapsed = ((Get-Date) - $_.StartTime).TotalSeconds

    Write-CompressionStatus `
        -File $_.File `
        -SrcBytes $_.SrcBytes `
        -NewBytes $_.NewBytes `
        -Index $index `
        -Total $total `
        -ElapsedSeconds $elapsed
}
