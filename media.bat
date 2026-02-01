@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

:: Change the working directory to the current batch file's location
cd /d "%~dp0"

:: --- 1. Automatic Unblocking ---
:: Recursively unblock all .ps1 files in the current folder and subfolders.
:: This removes the "Mark of the Web" (Zone.Identifier) that causes security warnings.
powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Filter *.ps1 -Recurse | Unblock-File -ErrorAction SilentlyContinue"

:: =============================================================
:: Argument Preprocessing (Use quotes for paths with spaces)
:: =============================================================
set "CMD=%~1"
set "SRC_DIR=%~2"
set "DST_DIR=%~3"

call :CleanPath SRC_DIR
call :CleanPath DST_DIR

:: Show usage if no command provided
if "%CMD%" == "" goto :usage

:: =============================================================
:: PowerShell Environment Detection (Prefer pwsh over powershell)
:: =============================================================
where pwsh >nul 2>nul
if %ERRORLEVEL% == 0 (
    set "PS_CMD=pwsh -NoProfile -ExecutionPolicy Bypass -File"
) else (
    set "PS_CMD=powershell -NoProfile -ExecutionPolicy Bypass -File"
)

:: =============================================================
:: Routing Logic
:: =============================================================

:: Core compression tasks (zip, all, img, video) call zip.ps1
for %%a in (zip all img video filter) do (
    if /i "%CMD%" == "%%a" goto :media_logic
)

if /i "%CMD%" == "comp" goto :comp_logic
if /i "%CMD%" == "clean" goto :clean_logic

:: Handle invalid commands
echo [Error] Unknown command: "%CMD%"
goto :usage

:: =============================================================
:: Task Implementation Blocks
:: =============================================================

:media_logic
if "%SRC_DIR%" == "" goto :missing_src
if "%DST_DIR%" == "" (
    %PS_CMD% "%~dp0zip.ps1" -Cmd "%CMD%" -SourcePath "%SRC_DIR%"
) else (
    %PS_CMD% "%~dp0zip.ps1" -Cmd "%CMD%" -SourcePath "%SRC_DIR%" -BackupDirName "%DST_DIR%"
)
goto :end

:comp_logic
if "%SRC_DIR%" == "" goto :missing_src
%PS_CMD% "%~dp0comp.ps1" -SourcePath "%SRC_DIR%" 
goto :end

:clean_logic
if "%SRC_DIR%" == "" goto :missing_src
:: Match clean.ps1 parameters: -SourcePath and -BackupDirName
if "%DST_DIR%" == "" (
    %PS_CMD% "%~dp0clean.ps1" -SourcePath "%SRC_DIR%"
) else (
    %PS_CMD% "%~dp0clean.ps1" -SourcePath "%SRC_DIR%" -BackupDirName "%DST_DIR%"
)
goto :end



:: =============================================================
:: Error and Usage Information
:: =============================================================

:missing_src
echo [Error] Source directory [srcdir] is required for command: %CMD%
echo.
exit /b 1

:usage
echo Usage: media.bat [Command] [srcdir] [dstdir]
echo.
echo Commands:
echo   zip    - Interactive mode for all media 
echo   all    - Automatic mode for all media 
echo   img    - Process images only 
echo   video  - Process videos only 
echo   filter - Process files by ext filter
echo   comp   - Compare quality between source and compressed files
echo   clean  - Remove source files after compression
echo.
echo Examples:
echo   media.bat zip "D:\photo" "D:\photo_backup"
echo   media.bat all "D:\photo"
echo   media.bat comp "D:\photo.test"
echo   media.bat clean "D:\photo" "D:\photo_backup"
exit /b 1

:end
endlocal

:: =============================================================
:: CleanPath function
:: Removes trailing backslashes and quotes
:: =============================================================
:CleanPath
set "temp_val=!%1!"
if "!temp_val!"=="" goto :eof

:: Remove trailing double quote
if "!temp_val:~-1!"=="\"" set "temp_val=!temp_val:~0,-1!"

:: Recursively remove backslashes from the end
:strip_loop
if "!temp_val:~-1!"=="\" (
    set "temp_val=!temp_val:~0,-1!"
    goto strip_loop
)

set "%1=!temp_val!"
goto :eof