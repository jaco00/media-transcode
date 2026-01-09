@echo off
chcp 65001 >nul
setlocal

REM === bat 所在目录 ===
set "BASEDIR=%~dp0"

set "SRC=%BASEDIR%photo.bak"
set "TEST=%BASEDIR%photo.test"
set "ORIGIN=%BASEDIR%photo.origin"

echo.
echo ================= 初始化测试用例 =================
echo.

REM === 检查源目录 ===
if not exist "%SRC%" (
    echo [ERROR] 源目录不存在: %SRC%
    pause
    exit /b 1
)

REM === 处理 photo.test ===
if exist "%TEST%" (
    echo [WARN] 目标目录已存在:
    echo        %TEST%
    echo.
    choice /M "是否删除并重新初始化"

    REM  choice 返回值：Y=1  N=2
    if errorlevel 2 (
        echo 已取消操作。
        pause
        exit /b 0
    )

    echo 正在删除 photo.test ...
    rmdir /s /q "%TEST%"
)

echo 正在复制 photo.bak → photo.test ...
xcopy "%SRC%" "%TEST%\" /E /I /H /K >nul

if errorlevel 1 (
    echo [ERROR] 复制失败！
    pause
    exit /b 1
)

REM === 初始化 photo.origin ===
if exist "%ORIGIN%" (
    echo 正在清空 photo.origin ...
    rmdir /s /q "%ORIGIN%"
)

mkdir "%ORIGIN%"

echo.
echo ================= 初始化完成 =================
echo photo.test   ← 测试目录
echo photo.origin ← 空备份目录
echo.

pause
endlocal
