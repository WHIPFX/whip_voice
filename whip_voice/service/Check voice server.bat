@echo off
rem ============================================
rem whip_voice: check the voice server set-up on this machine. DOUBLE-CLICK ME. It changes nothing.
rem ============================================
rem It asks Windows for administrator rights (to read the voice server's keys), then runs check.ps1 and
rem keeps the window open so you can read it. In game, an admin can also type /voicecheck.

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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check.ps1" %*
echo.
pause
