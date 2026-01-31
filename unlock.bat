@echo off
:: 1. Request Administrator Privileges
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%~dp0"

:: 2. Core Operations
echo --------------------------------------------------
echo [1/2] Unblocking all PowerShell scripts in directory...
:: Use -LiteralPath to handle special characters in file paths
powershell -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -Filter *.ps1 | Unblock-File"
echo Done!

echo [2/2] Setting ExecutionPolicy to RemoteSigned (Permanent)...
powershell -Command "Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force"
echo Done!
echo --------------------------------------------------

echo ✅ Authorization Successful! 
echo You can now run .ps1 scripts directly.
echo.
pause