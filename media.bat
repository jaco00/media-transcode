@echo off
setlocal
chcp 65001 >nul

if "%~1"=="" (
    echo Usage: media.bat [zip^|comp^|clean] [srcdir] [dstdir]
    echo.
    echo Actions:
    echo   zip   - Compress images to AVIF / videos to H.265
    echo            [backupdir] is optional. If specified, backup source files.
    echo   comp   - Compare quality between source and compressed files
    echo   clean  - Remove source files after compression
    echo            [backupdir] is optional. If specified, backup source files.
    echo.
    echo Examples:
    echo   media.bat zip "D:\photo" "D:\photo_backup"
    echo   media.bat comp "D:\photo.test" 
    echo   media.bat clean "D:\photo.test"  "D:\photo_backup"
    exit /b 1
)

set "ACTION=%~1"
set "SRC_DIR=%~2"
set "DST_DIR=%~3"

REM Check if PowerShell 7 (pwsh) is available
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
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

if /i "%ACTION%"=="zip" (
    if "%SRC_DIR%"=="" (
        echo Usage: media.bat zip [srcdir] [backupdir]
        echo Example: media.bat zip "photo.test"
        echo Example: media.bat zip "photo.test" "photo_backup"
        exit /b 1
    ) else (
        if "%DST_DIR%"=="" (
            REM No backup directory specified (对比模式 - keeps source files)
            %PS_CMD% "%~dp0zip.ps1" -SourcePath "%SRC_DIR%\."
        ) else (
            REM With backup directory (备份模式 - moves source to backup)
            %PS_CMD% "%~dp0zip.ps1" -SourcePath "%SRC_DIR%\." -BackupDirName "%DST_DIR%\."
        )
    )
) else if /i "%ACTION%"=="comp" (
    if "%SRC_DIR%"=="" (
        echo Usage: media.bat comp [srcdir]
        echo Example: media.bat comp "D:\photo.test"
        exit /b 1
    ) else (
        %PS_CMD% "%~dp0comp.ps1" -SourcePath "%SRC_DIR%\." -Mode middle
    )
) else if /i "%ACTION%"=="clean" (
    if "%SRC_DIR%"=="" (
        echo Usage: media.bat clean [srcdir] [backupdir]
        echo Example: media.bat clean "photo.test"
        echo Example: media.bat clean "photo.test" "photo_backup"
        exit /b 1
    ) else (
        if "%DST_DIR%"=="" (
            %PS_CMD% "%~dp0clean.ps1" -SourcePath "%SRC_DIR%\."
        ) else (
            %PS_CMD% "%~dp0clean.ps1" -SourcePath "%SRC_DIR%\." -BackupDirName "%DST_DIR%\."
        )
    )
) else (
    echo Invalid action: %ACTION%
    echo Valid actions: zip, comp, clean
    exit /b 1
)

endlocal
