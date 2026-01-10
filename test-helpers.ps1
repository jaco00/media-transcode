# ===============================
# 1. 导入 helper（主 Runspace）
# ===============================
. "$PSScriptRoot\helpers.ps1"

# 检查 PowerShell 是否安装，特别是 pwsh
$requiredVersion = [version]"7.0.0"
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue

if (-not $pwshPath) {
    Write-Host "未找到 PowerShell 7 (pwsh)。请安装 PowerShell 7 或更高版本，并运行 pwsh。"
    Write-Host "安装 PowerShell 7 请使用以下命令："
    Write-Host "winget install --id Microsoft.Powershell --source winget"
    exit 1  # 退出脚本
}

# 获取当前 pwsh 的版本
$currentVersionString = & $pwshPath --version

# 提取 PowerShell 版本号并去掉前缀 "PowerShell "
$currentVersion = [version]($currentVersionString -replace 'PowerShell ', '')

if ($currentVersion -lt $requiredVersion) {
    Write-Host "当前 PowerShell 版本为 $currentVersion。此脚本需要 PowerShell 7.0 或更高版本。"
    Write-Host "请运行以下命令以安装 PowerShell 7 或更高版本："
    Write-Host "winget install --id Microsoft.Powershell --source winget"
    exit 1  # 退出脚本
}


$index = 0

# ===============================
# 2. 定义业务函数（只写一次）
# ===============================
function Process-OneFile {
    param($file)

    # 真实场景这里跑 ffmpeg
    Start-Sleep -Milliseconds (Get-Random -Min 100 -Max 500)

    [pscustomobject]@{
        File     = $file.Name
        SrcBytes = $file.SrcSize
        NewBytes = $file.NewSize
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

    Write-CompressionStatus `
        -File $r.File `
        -SrcBytes $r.SrcBytes `
        -NewBytes $r.NewBytes `
        -Index $index `
        -Total $total
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

} -ThrottleLimit 3 |
ForEach-Object {

    # 主 Runspace：顺序输出
    $index++

    Write-CompressionStatus `
        -File $_.File `
        -SrcBytes $_.SrcBytes `
        -NewBytes $_.NewBytes `
        -Index $index `
        -Total $total
}
