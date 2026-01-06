@echo off
setlocal enabledelayedexpansion

if not "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clean.ps1" -Dir "%~1\."
) else (
    REM If no parameter provided, prompt user for directory
    echo.
    echo Usage: clean.bat [directory]
    echo Example: clean.bat "05.photo"
    echo.
    set /p DIR_INPUT="Enter directory to clean: "
    if not "!DIR_INPUT!"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clean.ps1" -Dir "!DIR_INPUT!."
    ) else (
        echo No directory specified. Exiting.
        exit /b 1
    )
)

endlocal
