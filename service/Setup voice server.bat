@echo off
rem ============================================
rem whip_voice: set up the voice server on this Windows machine. DOUBLE-CLICK ME.
rem ============================================
rem It asks Windows for administrator rights, then runs the set-up wizard (install.ps1) and keeps
rem the window open at the end so you can read what it said. The guide: ..\docs\SETUP.md

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking Windows for administrator rights...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
