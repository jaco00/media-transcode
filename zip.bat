@echo off
setlocal

REM Check if PowerShell 7 (pwsh) is available
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    echo PowerShell 7 detected.
    set "PS_CMD=pwsh -NoProfile -ExecutionPolicy Bypass -File"
) else (
    echo PowerShell 7 is not installed.
    echo.
    echo You can install PowerShell 7 using the following command:
    echo [ winget install --id Microsoft.PowerShell ]
    echo.
    echo Installing PowerShell 7 is recommended for parallel processing support.
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