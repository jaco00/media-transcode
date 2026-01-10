@echo off
setlocal
chcp 65001

REM Check if PowerShell 7 (pwsh) is available
where pwsh >nul 2>nul
if %ERRORLEVEL%==1 (
    echo PowerShell 7 detected.
    set "PS_CMD=pwsh -NoProfile -ExecutionPolicy Bypass -File"
) else (
    cls
:: 使用 Unicode 字符创建框架
echo ╔════════════════════════════════════════════════════════╗
echo ║        PowerShell 7 is not installed.                  ║
echo ║                                                        ║
echo ║    You can easily install PowerShell 7 with:           ║
echo ║                                                        ║
echo ║    winget install --id Microsoft.PowerShell            ║
echo ║                                                        ║
echo ║    PowerShell 7 is highly recommended for improved     ║
echo ║    performance and parallel processing support.        ║
echo ╚════════════════════════════════════════════════════════╝
pause

    REM fallback to PowerShell 5
    set "PS_CMD=powershell -NoProfile -ExecutionPolicy Bypass -File"
)

REM Handle the trailing backslash bug (Batch escapes \" as a literal quote)
REM We append "\." to the path. The .ps1 script uses [System.IO.Path]::GetFullPath()
REM to standardize and remove this suffix from the final output/logs.

if not "%~1"=="" (
    if not "%~2"=="" (
        %PS_CMD% "%~dp0comp.ps1" -SourcePath "%~1\." -Dir "%~2\."
    ) else (
        %PS_CMD% "%~dp0comp.ps1" -SourcePath "%~1\."
    )
) else (
    %PS_CMD% "%~dp0comp.ps1"
)

endlocal
