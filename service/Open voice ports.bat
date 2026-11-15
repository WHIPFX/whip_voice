@echo off
rem ============================================
rem whip_voice: open the voice ports in Windows Firewall, for the BUILT-IN voice server. DOUBLE-CLICK ME.
rem ============================================
rem Players' games send their voices to UDP 7882-7893 (TCP 7881 when UDP is blocked). This opens those ports inbound
rem and takes away any block Windows put on the voice server (someone answered Cancel to its "allow access?" box).
rem It asks Windows for administrator rights, then runs firewall.ps1 and keeps the window open so you can read it.
rem Ports changed in server.cfg (whip_voice_udp, whip_voice_tcp)? From a command prompt here:
rem     "Open voice ports.bat" -Udp 7982-7993 -Tcp 7981
rem Your own voice server on another machine: open its ports there, not with this.

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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0firewall.ps1" -Fix %*
echo.
pause
