@echo off
setlocal
chcp 65001 >nul

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