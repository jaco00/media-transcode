# 设置目录
$sourceDir = "D:\linux\05.photo"
$deletedDir = "D:\deleted_photo"

# 获取所有图片文件，包括子目录
$sourceFiles = Get-ChildItem -Path $sourceDir -Recurse -File | Where-Object { $_.Extension -match "\.(jpg|jpeg|png|bmp|gif|heic)$" }

# 创建存储要删除的文件列表
$filesToDelete = @()

# 遍历所有源目录中的文件
foreach ($sourceFile in $sourceFiles) {
    $relativePath = $sourceFile.FullName.Substring($sourceDir.Length)  # 计算相对路径
    $deletedFile = Join-Path -Path $deletedDir -ChildPath $relativePath  # 目标路径

    # 如果目标文件存在，则添加到删除列表
    if (Test-Path -Path $deletedFile) {
        $filesToDelete += $deletedFile
    }
}

# 显示要删除的文件总数
Write-Host "共找到 $($filesToDelete.Count) 个文件需要删除。"

# 展示前10个文件
$filesToDelete[0..[Math]::Min(9, $filesToDelete.Length - 1)] | ForEach-Object { Write-Host $_ }

# 用户确认删除
$userInput = Read-Host "显示前 10 个文件，确认删除？(y/n)"
if ($userInput -eq "y") {
    # 删除文件
    $filesToDelete | ForEach-Object {
        Remove-Item -Path $_ -Force
        Write-Host "已删除：$_"
    }
} else {
    Write-Host "操作已取消。"
}
