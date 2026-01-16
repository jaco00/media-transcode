@echo off
setlocal
chcp 65001 >nul

:: =============================================================
:: 自动核心限制逻辑：智能计算可用核心
:: =============================================================
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "[Environment]::ProcessorCount"') do set /a TOTAL_CORES=%%i

:: 核心分配策略：
:: 如果总核心 > 4，则使用 (总数 - 4) 个核
:: 如果总核心 <= 4，则强制保留 1 个核心给脚本
if %TOTAL_CORES% GTR 4 (
    set /a USE_CORES=%TOTAL_CORES% - 4
) else (
    set USE_CORES=1
)

:: 使用 PowerShell 计算十六进制位掩码
set "CALC_MASK=$m=0; 0..(%USE_CORES%-1) | %%{$m += [Math]::Pow(2,$_)}; '{0:X}' -f [long]$m"
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "%CALC_MASK%"') do set "HEX_MASK=%%i"

echo [System] CPU总核心: %TOTAL_CORES% 
echo [System] 策略: 优先留出 4 核给系统 (当前分配 %USE_CORES% 核给处理脚本)
echo [System] 运行掩码: 0x%HEX_MASK%
:: =============================================================

REM Check if PowerShell 7 (pwsh) is available
where pwsh >nul 2>nul
if %ERRORLEVEL%==1 (
    echo [Detection] PowerShell 7 detected, will use pwsh
    set "PS_CMD=pwsh -NoProfile -ExecutionPolicy Bypass -File"
) else (
    cls
    echo =============================================================
    echo     This computer does not have PowerShell 7 installed
    echo =============================================================
    echo.
    echo     Install PowerShell 7 for parallel processing support
    echo.
    echo     Use the following command to install:
    echo.
    echo     winget install --id Microsoft.PowerShell
    echo =============================================================
    echo.
    pause

    REM fallback to PowerShell 5
    set "PS_CMD=powershell -NoProfile -ExecutionPolicy Bypass -File"
)

REM Handle the trailing backslash bug (Batch escapes \" as a literal quote)
REM We append "\." to the path. zip.ps1 uses [System.IO.Path]::GetFullPath() 
REM to standardize and remove this suffix from the final output/logs.

if not "%~1"=="" (
    if not "%~2"=="" (
        %PS_CMD% "%~dp0zip.ps1" -SourcePath "%~1\." -BackupDirName "%~2\."
    ) else (
        %PS_CMD% "%~dp0zip.ps1" -SourcePath "%~1\."
    )
) else (
    %PS_CMD% "%~dp0zip.ps1"
)

endlocal